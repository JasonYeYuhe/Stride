#!/usr/bin/env node
// @ts-check
/**
 * demo-topup.js — keep the App Review demo account's history current, without re-seeding it.
 *
 * Usage (on the host; root crontab, see ops/crontab.stride):
 *   /usr/bin/node /root/stride-server/ops/demo-topup.js [--dry-run]
 *
 * Why not seed-demo.js on a timer. seed-demo.js DELETES the demo account's sessions and
 * magic-link tokens and re-creates its habits under new ids. Run by cron in the middle of a
 * review, it would sign the reviewer out and replace every habit on their device — the kind
 * of "the app lost my data" moment a rejection is made of. This script only ADDS check-ins:
 * the user, its reusable token, its sessions and its habit ids are never touched, and nothing
 * is ever deleted (a deletion without a tombstone would strand every device that pulls
 * incrementally; one with a tombstone would empty the reviewer's history).
 *
 * Why it is needed. Seed data is generated relative to seed time. Streaks count back from
 * today with one day of grace, so within two days of a seed every streak is 0 and
 * scripts/check_demo_account.sh exits 3 (STALE) — the reason RELEASE-1.2.3.md says "re-seed
 * if review slips". Hence daily, not weekly: a weekly top-up would still be stale five days in
 * seven.
 *
 * Which habits. Those seed-demo.js or ops/demo-add-habits.js created: a name in PATTERNS AND
 * created before the backfill window (both back-date created_at by CREATED_DAYS_BACK, 91 days).
 * A habit a reviewer adds is left alone even when they give it a seeded name — e.g. deleting
 * "Journal" to test delete and adding it back — because a name match alone wrote 28 check-ins
 * dated before that habit existed (review of 2026-09-26). Belt and braces, no day before a
 * habit's own created_at is ever written.
 *
 * What it writes. For each of those, one check-in per day from the day after the habit's
 * last entry through the entry-day cap (`entryDayCap`, below), at most BACKFILL_DAYS back.
 * Whether a day is checked follows the habit's rule in PATTERNS (`isChecked`): for a daily
 * habit, its 30-day seed pattern, at a position chosen by a hash of habit id + date instead of a
 * coin flip, so a re-run on the same day inserts nothing and a second host would write the same
 * rows; for "Stretch" (3 times a week), a fixed Monday/Wednesday/Friday, because a per-day hash
 * can leave a Monday-to-Sunday week with fewer than three and break its weekly streak. Entry
 * ids come from the same hash. A count habit is filled at its target, the only value that counts
 * as done (Habit.completedDayKeys). Timestamps are "now", so a device's next ?since pull picks
 * the rows up; ids are upper case like everything the apps send (migrations/canonicalizeIds.js).
 *
 * The entry-day cap is min(UTC today, America/Los_Angeles today), the same for all three demo
 * scripts (RELEASE-1.4.1.md D13 item 5). The cron runs at 03:50 Etc/UTC, which is the previous
 * evening in the US: dated by UTC, every run wrote a check-in for a US reviewer's tomorrow.
 *
 * A reviewer's un-check stays un-checked. Un-checking deletes the entry and the push records
 * a tombstone. Skipping just the ids this script would generate protected only rows it had
 * written itself: un-check one of seed-demo.js's (random ids) or one the reviewer made, and
 * "last" moved back and the next run checked the day again (reproduced 2026-09-26). So the fill
 * never reaches back to or before the UTC day of the account's newest entry tombstone: whatever
 * the reviewer had on screen when they deleted something is not rewritten. Since the 1.3.1
 * server an entry tombstone also names the deleted row's habit and day (deletion_tombstones
 * .habit_id / .entry_date, E2E S4), but not every one does: rows from before that deploy, a
 * retried deletion, and an entry the server no longer held keep NULL. The account-wide floor is
 * the rule that covers all of them, so it stays. That costs at most one day of streak, which the
 * one day of grace absorbs. seed-demo.js clears the tombstones, so a re-seed lifts the floor.
 *
 * Opens the database through ../db, like seed-demo.js and ops/request-snapshot.js (WAL, so it
 * is safe with the server running). Required rather than run (seed-demo.js,
 * ops/demo-add-habits.js and the tests read PATTERNS and the day rules), it does nothing.
 */

const crypto = require("crypto");

const DEMO_EMAIL = "demo@stride-review.com"; // seed-demo.js
const BACKFILL_DAYS = 30; // the window the 30-day rate reads
const DAY_MS = 86_400_000;
/** The zone of the entry-day cap: App Review's (Cupertino). */
const REVIEW_TIME_ZONE = "America/Los_Angeles";

/**
 * A habit's rule: a 30-day seed pattern (1 = checked), or fixed weekdays (0 = Sunday … 6 =
 * Saturday, as getUTCDay numbers a YYYY-MM-DD day).
 * @typedef {number[] | { weekdays: number[] }} DemoRule
 */

// seed-demo.js lays each pattern down in order (day 0 of 90 is pattern[0], and the last day is
// pattern[29]); the top-up picks a position by hash (`isChecked`), so each habit keeps the
// completion rate it was seeded with (Morning Run 23/30, Read 27/30, …) without repeating the
// same 30-day shape every month.
/** @type {Record<string, DemoRule>} */
const PATTERNS = {
  "Morning Run": [1,1,0,1,1,1,0,1,1,1,1,0,1,0,1,1,1,0,1,1,1,0,1,1,0,1,1,1,1,1],
  "Read 30 Minutes": [1,1,1,1,1,0,1,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1],
  "Meditate": [1,0,1,1,0,0,1,1,0,1,1,0,1,0,1,1,0,1,1,0,1,1,0,0,1,1,1,0,1,1],
  "Drink 8 Glasses": [1,1,1,0,1,1,1,1,0,1,1,1,1,1,0,1,1,1,0,1,1,1,1,1,0,1,1,1,1,0],
  "Practice Guitar": [1,0,0,1,1,0,1,0,0,1,1,0,0,1,0,1,0,1,1,0,0,1,1,0,1,0,0,1,1,0],
  "Journal": [0,1,0,1,1,1,0,1,1,1,1,0,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1],
  // 1.4.1 (ops/demo-add-habits.js). Water: the days its seeded history reaches the target of 8
  // (24 of 30; the other six hold partial days or none, which the top-up does not write).
  "Water": [1,1,0,1,1,1,0,1,1,0,1,1,1,1,0,1,1,1,1,0,1,1,1,0,1,1,1,1,1,1],
  // Three times a week, Monday-anchored like the app's weeks (Habit.swift): every week has three.
  "Stretch": { weekdays: [1, 3, 5] },
};

/** @param {string} habitId @param {string} date */
function digest(habitId, date) {
  return crypto.createHash("sha256").update(`stride-demo-topup|${habitId.toUpperCase()}|${date}`).digest();
}

/** UUID-shaped (version 5 / RFC 4122 variant bits) upper-case id from a digest. @param {Buffer} h */
function entryId(h) {
  const b = Buffer.from(h.subarray(0, 16));
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  const x = b.toString("hex").toUpperCase();
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
}

/** YYYY-MM-DD, UTC. @param {Date} d */
const dayString = (d) => d.toISOString().slice(0, 10);

/** @param {string} day @param {number} n */
function addDays(day, n) {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return dayString(d);
}

/** 0 = Sunday … 6 = Saturday. @param {string} day */
const weekdayOf = (day) => new Date(`${day}T00:00:00Z`).getUTCDay();

/** YYYY-MM-DD in `timeZone` at `now`. @param {Date} now @param {string} timeZone */
function dayIn(now, timeZone) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone, year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(now);
  /** @param {string} type */
  const part = (type) => parts.find((p) => p.type === type)?.value ?? "";
  const day = `${part("year")}-${part("month")}-${part("day")}`;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error(`could not read the ${timeZone} date (${day})`);
  return day;
}

/**
 * The newest day any demo script writes a check-in on: min(UTC today, America/Los_Angeles
 * today). Strings compare as dates (YYYY-MM-DD).
 * @param {Date} now
 */
function entryDayCap(now) {
  const utc = dayString(now);
  const la = dayIn(now, REVIEW_TIME_ZONE);
  return la < utc ? la : utc;
}

/**
 * Whether the top-up checks `day` for a habit with this rule.
 * @param {DemoRule} rule @param {string} habitId @param {string} day
 */
function isChecked(rule, habitId, day) {
  if (Array.isArray(rule)) return rule[digest(habitId, day).readUInt32BE(28) % rule.length] === 1;
  return rule.weekdays.includes(weekdayOf(day));
}

/** @typedef {{ id: string, name: string, kind: string, target_value: number, created: string, last: string|null }} DemoHabit */

/**
 * One top-up of the demo account in `db`, as of `now`. Writes nothing when `dryRun`.
 * @param {import('better-sqlite3').Database} db
 * @param {{ now?: Date, dryRun?: boolean }} [opts]
 * @returns {{ status: number, line: string, added: number }}
 */
function topUp(db, { now = new Date(), dryRun = false } = {}) {
  const user = /** @type {{ id: number } | undefined} */ (
    db.prepare("SELECT id FROM users WHERE email = ?").get(DEMO_EMAIL)
  );
  if (!user) {
    return { status: 1, added: 0, line: `[demo-topup] no ${DEMO_EMAIL} account — run seed-demo.js first` };
  }
  const habits = /** @type {DemoHabit[]} */ (db.prepare(`
    SELECT h.id, h.name, h.kind, h.target_value, substr(h.created_at, 1, 10) AS created,
           (SELECT max(e.date) FROM habit_entries e WHERE e.habit_id = h.id) AS last
    FROM habits h WHERE h.user_id = ? AND h.is_archived = 0 ORDER BY h.sort_order
  `).all(user.id));

  const nowIso = now.toISOString();
  const today = entryDayCap(now);
  const earliest = addDays(today, -(BACKFILL_DAYS - 1));

  const seeded = habits.filter((h) => PATTERNS[h.name] && h.created < earliest);
  if (seeded.length === 0) {
    return { status: 1, added: 0, line: `[demo-topup] ${DEMO_EMAIL} has none of the seeded habits — run seed-demo.js first` };
  }

  // deleted_at is the server's push time, UTC ISO (routes/sync.js), so its first ten
  // characters are the UTC day of the reviewer's newest deletion.
  const { lastDeleted } = /** @type {{ lastDeleted: string | null }} */ (db.prepare(
    "SELECT substr(max(deleted_at), 1, 10) AS lastDeleted FROM deletion_tombstones WHERE user_id = ? AND entity_type = 'entry'",
  ).get(user.id));
  const insert = db.prepare(`
    INSERT OR IGNORE INTO habit_entries (id, habit_id, date, value, created_at, updated_at, client_updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `);

  /** @type {string[]} */
  const report = [];
  let total = 0;
  const run = db.transaction(() => {
    for (const habit of seeded) {
      const rule = PATTERNS[habit.name];
      // The latest of: the day after its last entry, the window's start, the habit's own
      // creation day, the day after the newest deletion (see the header). String max works:
      // all are YYYY-MM-DD.
      const floors = [earliest, habit.created];
      if (habit.last) floors.push(addDays(habit.last, 1));
      if (lastDeleted) floors.push(addDays(lastDeleted, 1));
      let day = floors.reduce((a, b) => (a > b ? a : b));
      const from = day;
      let added = 0;
      for (; day <= today; day = addDays(day, 1)) {
        if (!isChecked(rule, habit.id, day)) continue;
        const id = entryId(digest(habit.id, day));
        // A count habit is "done" only at its target (Habit.completedDayKeys).
        const value = habit.kind === "count" ? Math.max(1, habit.target_value) : 1;
        if (!dryRun) added += insert.run(id, habit.id, day, value, nowIso, nowIso, nowIso).changes;
        else added += 1;
      }
      total += added;
      report.push(from > today ? `${habit.name} +0 (current)` : `${habit.name} +${added} (${from}..${today})`);
    }
  });
  run();

  const skipped = habits.length - seeded.length;
  const line =
    `[demo-topup] ${nowIso}${dryRun ? " DRY RUN" : ""} ${total} check-ins added — ${report.join(", ")}` +
    (skipped ? `; ${skipped} habit(s) not from seed-demo.js left alone` : "") +
    (lastDeleted ? `; nothing written on or before ${lastDeleted} (newest deletion)` : "");
  return { status: 0, line, added: total };
}

function main() {
  const db = require("../db");
  const result = topUp(db, { dryRun: process.argv.includes("--dry-run") });
  (result.status === 0 ? console.log : console.error)(result.line);
  return result.status;
}

if (require.main === module) process.exitCode = main();

module.exports = {
  DEMO_EMAIL, BACKFILL_DAYS, DAY_MS, REVIEW_TIME_ZONE, PATTERNS,
  digest, entryId, dayString, addDays, weekdayOf, dayIn, entryDayCap, isChecked, topUp,
};
