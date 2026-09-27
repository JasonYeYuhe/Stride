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
 * Which habits. Those seed-demo.js created: a seeded name AND created before the backfill
 * window (seed-demo.js back-dates created_at by 45 days). A habit a reviewer adds is left
 * alone even when they give it a seeded name — e.g. deleting "Journal" to test delete and
 * adding it back — because a name match alone wrote 28 check-ins dated before that habit
 * existed (review of 2026-09-26). Belt and braces, no day before a habit's own created_at is
 * ever written.
 *
 * What it writes. For each of those, one check-in per day from the day after the habit's
 * last entry through today (UTC — the same day boundary seed-demo.js uses), at most
 * BACKFILL_DAYS back. Whether a day is checked follows that habit's seed pattern, chosen by a
 * hash of habit id + date instead of a coin flip, so a re-run on the same day inserts nothing
 * and a second host would write the same rows; entry ids come from the same hash. Timestamps
 * are "now", so a device's next ?since pull picks the rows up; ids are upper case like
 * everything the apps send (migrations/canonicalizeIds.js).
 *
 * A reviewer's un-check stays un-checked. Un-checking deletes the entry and the push records
 * a tombstone — but a tombstone holds only the entry id, not its habit or date, and the entry
 * is gone. Skipping just the ids this script would generate protected only rows it had written
 * itself: un-check one of seed-demo.js's (random ids) or one the reviewer made, and "last"
 * moved back and the next run checked the day again (reproduced 2026-09-26). So the fill never
 * reaches back to or before the UTC day of the account's newest entry tombstone: whatever the
 * reviewer had on screen when they deleted something is not rewritten. That costs at most one
 * day of streak, which the one day of grace absorbs. seed-demo.js clears the tombstones, so a
 * re-seed lifts the floor.
 *
 * Opens the database through ../db, like seed-demo.js and ops/request-snapshot.js (WAL, so it
 * is safe with the server running).
 */

const crypto = require("crypto");

const DEMO_EMAIL = "demo@stride-review.com"; // seed-demo.js
const BACKFILL_DAYS = 30; // the window seed-demo.js fills and the 30-day rate reads
const DRY_RUN = process.argv.includes("--dry-run");

// Positions in seed-demo.js's 30-day completionPatterns, by habit name. A day is checked when
// pattern[hash % 30] is 1, so each habit keeps the completion rate it was seeded with
// (Morning Run 23/30, Read 27/30, …) without repeating the same 30-day shape every month.
/** @type {Record<string, number[]>} */
const PATTERNS = {
  "Morning Run": [1,1,0,1,1,1,0,1,1,1,1,0,1,0,1,1,1,0,1,1,1,0,1,1,0,1,1,1,1,1],
  "Read 30 Minutes": [1,1,1,1,1,0,1,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1],
  "Meditate": [1,0,1,1,0,0,1,1,0,1,1,0,1,0,1,1,0,1,1,0,1,1,0,0,1,1,1,0,1,1],
  "Drink 8 Glasses": [1,1,1,0,1,1,1,1,0,1,1,1,1,1,0,1,1,1,0,1,1,1,1,1,0,1,1,1,1,0],
  "Practice Guitar": [1,0,0,1,1,0,1,0,0,1,1,0,0,1,0,1,0,1,1,0,0,1,1,0,1,0,0,1,1,0],
  "Journal": [0,1,0,1,1,1,0,1,1,1,1,0,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1],
};

/** @typedef {{ id: string, name: string, kind: string, target_value: number, created: string, last: string|null }} DemoHabit */

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

function main() {
  const db = require("../db");

  const user = /** @type {{ id: number } | undefined} */ (
    db.prepare("SELECT id FROM users WHERE email = ?").get(DEMO_EMAIL)
  );
  if (!user) {
    console.error(`[demo-topup] no ${DEMO_EMAIL} account — run seed-demo.js first`);
    return 1;
  }
  const habits = /** @type {DemoHabit[]} */ (db.prepare(`
    SELECT h.id, h.name, h.kind, h.target_value, substr(h.created_at, 1, 10) AS created,
           (SELECT max(e.date) FROM habit_entries e WHERE e.habit_id = h.id) AS last
    FROM habits h WHERE h.user_id = ? AND h.is_archived = 0 ORDER BY h.sort_order
  `).all(user.id));

  const now = new Date();
  const nowIso = now.toISOString();
  const today = dayString(now);
  const earliest = addDays(today, -(BACKFILL_DAYS - 1));

  const seeded = habits.filter((h) => PATTERNS[h.name] && h.created < earliest);
  if (seeded.length === 0) {
    console.error(`[demo-topup] ${DEMO_EMAIL} has none of the seeded habits — run seed-demo.js first`);
    return 1;
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
      const pattern = PATTERNS[habit.name];
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
        const h = digest(habit.id, day);
        if (!pattern[h.readUInt32BE(28) % pattern.length]) continue;
        const id = entryId(h);
        // A count habit is "done" only at its target (Habit.completedDayKeys).
        const value = habit.kind === "count" ? Math.max(1, habit.target_value) : 1;
        if (!DRY_RUN) added += insert.run(id, habit.id, day, value, nowIso, nowIso, nowIso).changes;
        else added += 1;
      }
      total += added;
      report.push(from > today ? `${habit.name} +0 (current)` : `${habit.name} +${added} (${from}..${today})`);
    }
  });
  run();

  const skipped = habits.length - seeded.length;
  console.log(
    `[demo-topup] ${nowIso}${DRY_RUN ? " DRY RUN" : ""} ${total} check-ins added — ${report.join(", ")}` +
      (skipped ? `; ${skipped} habit(s) not from seed-demo.js left alone` : "") +
      (lastDeleted ? `; nothing written on or before ${lastDeleted} (newest deletion)` : ""),
  );
  return 0;
}

process.exitCode = main();
