#!/usr/bin/env node
// @ts-check
/**
 * restore-drill.js — restore last night's backup and prove it opens, every night.
 *
 * Usage (on the host; root crontab, see ops/crontab.stride):
 *   /usr/bin/node /root/stride-server/ops/restore-drill.js            run the drill
 *   node ops/restore-drill.js --dry-run-sentry                        print what would be sent
 *
 * Why. backup.sh has run nightly since June and until 2026-09-26 nobody had restored one of
 * its files on the host; its log was 0 bytes, so a cron that had stopped and a backup that
 * was unreadable would both have looked exactly like success. The offsite pull checks the
 * copies it fetches, but only while one Mac is awake. This runs where the backups are.
 *
 * What it does. Takes the newest NIGHTLY file (stride-YYYY-MM-DD-HHMM.db — never the
 * predeploy/preseed snapshots, which are hand-made and can be weeks old), copies it into a
 * private temp directory (opening the backup itself would leave -wal/-shm files beside it in
 * /root/backups), and requires:
 *   - PRAGMA integrity_check = ok and an empty foreign_key_check;
 *   - users > 0, and at least half of the previous nightly file's users. A backup of a
 *     database the server re-created empty (db.js builds the schema on first open, so a lost
 *     or replaced stride.db looks like that) is a perfectly healthy SQLite file: integrity ok,
 *     FK ok, users=0. The first version of this drill passed it (review of 2026-09-26).
 *     Habit and entry counts are logged but not judged: a demo re-seed legitimately drops
 *     hundreds of topped-up entries at once;
 *   - the file from the MOST RECENT scheduled backup (03:30 UTC, once BACKUP_GRACE_MINUTES
 *     have passed). A plain age limit could not do this: at 04:10 yesterday's file is 24.7 h
 *     old, so the first version's 26 h let a failed backup night pass as ok, and backup.sh
 *     has no alert path of its own. This rule holds at any hour, so hand runs need no flag.
 * One log line either way. The temp directory is mkdtemp's (0700) and is deleted in every
 * case: the copy holds every user's email, and backups are 0644 — under root's cron
 * os.tmpdir() is the world-readable /tmp, so a plain temp file there was readable by every
 * account on the VM for as long as the drill ran, or until tmpfiles cleaned up after a kill.
 *
 * Alerting. On failure a Sentry message; on every run a Sentry cron check-in, so a drill
 * that stops running at all (cron edited away, node moved) alerts too — the failure mode a
 * message-on-failure cannot see. Both need SENTRY_DSN in /root/stride-server/.env; without
 * it the script says so in its log and exits non-zero on failure, which only the log sees.
 *
 * Env, for exercising it on a copy: STRIDE_BACKUP_DIR (default /root/backups),
 * STRIDE_ENV_FILE (default ../.env).
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const Database = require("better-sqlite3");

const BACKUP_DIR = process.env.STRIDE_BACKUP_DIR || "/root/backups";
const ENV_FILE = process.env.STRIDE_ENV_FILE || path.join(__dirname, "..", ".env");
// backup.sh's line in ops/crontab.stride (30 3 * * *, UTC) — change both together. Grace
// covers cron's start jitter and the backup's own run time (seconds at today's size).
const BACKUP_AT = { hour: 3, minute: 30 };
const BACKUP_GRACE_MINUTES = 20;
const TABLES = ["users", "habits", "habit_entries", "habit_groups", "deletion_tombstones", "sessions"];
// backup.sh names files with `date +%F-%H%M` on a host whose zone is Etc/UTC.
const NIGHTLY = /^stride-(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})\.db$/;
const DRY_RUN_SENTRY = process.argv.includes("--dry-run-sentry");

// Sentry cron monitor. Keep the schedule in step with the drill's line in ops/crontab.stride:
// Sentry flags a missed check-in against THIS schedule, not against the crontab.
const MONITOR_SLUG = "stride-restore-drill";
const MONITOR_CONFIG = {
  schedule: { type: /** @type {const} */ ("crontab"), value: "10 4 * * *" },
  timezone: "Etc/UTC",
  checkinMargin: 60, // minutes
  maxRuntime: 10, // minutes
};

require("dotenv").config({ path: ENV_FILE });

/** @param {...string} parts */
function log(...parts) {
  console.log(`[restore-drill] ${new Date().toISOString()} ${parts.join(" ")}`);
}

/** Nightly files, oldest first. @returns {{ file: string, takenAt: number }[]} */
function nightlies() {
  return fs.readdirSync(BACKUP_DIR).filter((n) => NIGHTLY.test(n)).sort().map((name) => {
    const [, y, mo, d, h, mi] = /** @type {RegExpExecArray} */ (NIGHTLY.exec(name)).map(Number);
    return { file: path.join(BACKUP_DIR, name), takenAt: Date.UTC(y, mo - 1, d, h, mi) };
  });
}

/**
 * When the newest nightly file must have been taken: the latest scheduled 03:30 UTC run
 * that is at least BACKUP_GRACE_MINUTES in the past (at 04:10, today's; at 03:40, yesterday's).
 * @param {number} now @returns {number}
 */
function lastScheduledBackup(now) {
  const d = new Date(now - BACKUP_GRACE_MINUTES * 60_000);
  const at = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), BACKUP_AT.hour, BACKUP_AT.minute);
  return at <= d.getTime() ? at : at - 86_400_000;
}

/**
 * Copy a backup into `dir` and open it read-write (a WAL-mode file needs its -shm), so the
 * caller's checks never touch /root/backups.
 * @param {string} file @param {string} dir @returns {import("better-sqlite3").Database}
 */
function restore(file, dir) {
  const copy = path.join(dir, path.basename(file));
  fs.copyFileSync(file, copy);
  return new Database(copy, { fileMustExist: true });
}

/** @param {import("better-sqlite3").Database} db @param {string} table @returns {number} */
const count = (db, table) => /** @type {{ n: number }} */ (db.prepare(`SELECT count(*) AS n FROM ${table}`).get()).n;

/**
 * Restore the newest nightly backup to a private temp directory and check it.
 * @returns {{ summary: string, problems: string[] }}
 */
function drill() {
  /** @type {string[]} */
  const problems = [];
  const files = nightlies();
  const newest = files[files.length - 1];
  const previous = files[files.length - 2];
  if (!newest) {
    return { summary: `no nightly backup in ${BACKUP_DIR}`, problems: ["no nightly backup (stride-YYYY-MM-DD-HHMM.db) found"] };
  }

  const now = Date.now();
  const ageHours = (now - newest.takenAt) / 3_600_000;
  const due = lastScheduledBackup(now);
  if (newest.takenAt < due) {
    problems.push(`no backup from the ${new Date(due).toISOString().slice(0, 16)}Z run — newest nightly is ` +
      `${path.basename(newest.file)}, ${ageHours.toFixed(1)} h old. Did backup.sh fail (stride-backup.log) or stop running?`);
  }

  const parts = [path.basename(newest.file), `age=${ageHours.toFixed(1)}h`];
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "stride-restore-drill-"));
  try {
    const db = restore(newest.file, dir);
    try {
      // A damaged file reports every bad page in one newline-separated value; keep the log
      // to one line per run and the Sentry message short.
      const integrity = String(db.pragma("integrity_check", { simple: true })).replace(/\s*\n\s*/g, " | ");
      parts.push(`integrity_check: ${integrity === "ok" ? "ok" : "FAILED"}`);
      if (integrity !== "ok") problems.push(`integrity_check: ${integrity.slice(0, 300)}`);

      const fk = /** @type {{ table: string, parent: string }[]} */ (db.pragma("foreign_key_check"));
      parts.push(`foreign_key_check: ${fk.length === 0 ? "ok" : `${fk.length} violations`}`);
      if (fk.length > 0) {
        const where = [...new Set(fk.map((r) => `${r.table}→${r.parent}`))].join(", ");
        problems.push(`foreign_key_check: ${fk.length} violations (${where})`);
      }

      for (const table of TABLES) parts.push(`${table}=${count(db, table)}`);
      const users = count(db, "users");
      if (users === 0) problems.push("users=0: the backup is an empty database — was stride.db lost or re-created?");

      // Against the night before. Only the one number that cannot fall by half overnight in
      // normal use; the previous file is copied too, for the same -wal/-shm reason.
      if (previous && users > 0) {
        let before = null;
        try {
          const prev = restore(previous.file, dir);
          try { before = count(prev, "users"); } finally { prev.close(); }
        } catch (err) {
          // That night's drill already failed on it; this one judges tonight's file.
          parts.push(`(previous ${path.basename(previous.file)} unreadable)`);
        }
        if (before !== null) {
          parts.push(`users_before=${before}`);
          if (users < before / 2) {
            problems.push(`users fell from ${before} (${path.basename(previous.file)}) to ${users} — a replaced or rolled-back stride.db?`);
          }
        }
      }
    } finally {
      db.close();
    }
  } catch (err) {
    // A truncated or overwritten file usually fails here ("file is not a database",
    // "database disk image is malformed") rather than in integrity_check.
    problems.push(`restore failed: ${err instanceof Error ? err.message : String(err)}`);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  return { summary: parts.join(" "), problems };
}

/**
 * Cron check-in on every run, plus a message on failure.
 * @param {boolean} ok @param {string} message @param {number} seconds
 */
async function report(ok, message, seconds) {
  const status = ok ? "ok" : "error";
  if (DRY_RUN_SENTRY) {
    log(`dry-run: would send check-in ${MONITOR_SLUG} status=${status}${ok ? "" : ` and an error message: ${message}`}`);
    return;
  }
  const dsn = process.env.SENTRY_DSN;
  if (!dsn) {
    log(`SENTRY_DSN is not set in ${ENV_FILE}: ${ok ? "no check-in sent" : "THIS FAILURE WAS NOT SENT ANYWHERE — only this log has it"}`);
    return;
  }
  // Loaded only here: the SDK is heavy and a healthy run with no DSN does not need it.
  const Sentry = require("@sentry/node");
  Sentry.init({ dsn, environment: process.env.NODE_ENV || "production", tracesSampleRate: 0 });
  Sentry.captureCheckIn({ monitorSlug: MONITOR_SLUG, status, duration: seconds }, MONITOR_CONFIG);
  if (!ok) Sentry.captureMessage(`[restore-drill] ${message}`, { level: "error", tags: { job: MONITOR_SLUG } });
  // A cron process exits right after this; unflushed events are simply lost.
  if (!(await Sentry.flush(10_000))) log("WARN: Sentry flush timed out; the report may not have been delivered");
}

async function main() {
  const started = Date.now();
  let result;
  try {
    result = drill();
  } catch (err) {
    // readdir on a missing directory, etc. — still a failed drill, still reported.
    result = { summary: "drill did not run", problems: [err instanceof Error ? err.message : String(err)] };
  }
  const ok = result.problems.length === 0;
  log(result.summary);
  if (!ok) log(`FAIL: ${result.problems.join("; ")}`);
  await report(ok, ok ? "ok" : result.problems.join("; "), Math.round((Date.now() - started) / 1000));
  return ok ? 0 : 1;
}

main().then(
  (code) => process.exit(code),
  (err) => {
    console.error("[restore-drill] crashed:", err);
    process.exit(1);
  },
);
