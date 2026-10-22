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
 * Which habits. Only those seed-demo.js or ops/demo-add-habits.js created, told apart from a
 * reviewer's habit of the same name by identity, not by name — "Morning Run", "Meditate" and
 * "Stretch" are template names, and a reviewer's own habit from an earlier review (the account
 * outlives reviews) must not get invented history (reviews of 2026-09-26 and of W8):
 *   - since 1.4.1 both scripts give a habit the id `demoHabitId(account, name, created_at)`,
 *     which no app sends (apps make random ids);
 *   - the six habits seeded before 1.4.1 have random ids, and production's still do. They are
 *     the habits of those six names created before the backfill window that share one
 *     created_at, the one that seed run wrote for all six (a habit an app pushes carries its own
 *     createdAt); "the most of them share", so a reviewer's "Meditate" does not split them.
 *     Only until a habit of that name has a demo id: after a re-seed only demo ids count.
 *     "Water" and "Stretch" were never seeded that way, so they need a demo id.
 * Either way the habit must still be what the script made (`SHAPES`: kind, schedule, target):
 * a reviewer who changes that has made it theirs. Belt and braces, no day before a habit's own
 * created_at is ever written.
 *
 * What it writes. For each of those, one check-in per day from the day after the habit's
 * last entry through the entry-day cap (`entryDayCap`, below), at most BACKFILL_DAYS back.
 * Whether a day is checked follows the habit's rule in PATTERNS (`isChecked`): for a daily
 * habit, its 30-day pattern at the day's place in a 30-day cycle fixed by the calendar
 * (`patternIndex`), the same place seed-demo.js and demo-add-habits.js lay it down at, so every
 * 30-day stretch holds exactly the pattern's count; for "Stretch" (3 times a week), a fixed
 * Monday/Wednesday/Friday, so every Monday-to-Sunday week holds three. Entry ids come from a
 * hash of habit id + date, so a re-run inserts nothing and a second host would write the same
 * rows. A count habit is filled at its target, the only value that counts as done
 * (Habit.completedDayKeys). Timestamps are "now", so a device's next ?since pull picks the rows
 * up; ids are upper case like everything the apps send (migrations/canonicalizeIds.js).
 *
 * Gate 2 (check_demo_account.sh exits 4 when a habit done on at least GATE_DAYS of the last 30
 * days scores below 0.75). In order, only Read 30 Minutes (27 of 30) and Journal (25) are ever
 * done on 25 of 30, and both score at least 0.79 at every place in the cycle. The other habits'
 * patterns hold 24 or fewer, but before 1.4.1 the top-up picked each day's place by a hash of
 * habit id + date, so 30 days of production's account can hold more, and such a habit at 25 of
 * 30 can score 0.72 (review of W8). So the top-up never writes the day that would bring the 30
 * days ending on it up to GATE_DAYS for a habit whose rule stays below it (`reachesGate`). In
 * order the rule never asks for such a day, so this only acts while hash-picked days are still
 * in the window, the 30 days after the 1.4.1 deploy. A window already past GATE_DAYS (hash
 * luck) still gets the rule's day: skipping it would only lower the score while it is gated.
 * The days written before the deploy are what they are: on the deploy day itself gate 2 has the
 * same small chance of exit 4 it had before (DEPLOY.md).
 *
 * The entry-day cap is min(UTC today, America/Los_Angeles today), the same for all three demo
 * scripts (RELEASE-1.4.1.md D13 item 5). The cron runs at 03:50 Etc/UTC, which is the previous
 * evening in the US: dated by UTC, every run wrote a check-in for a US reviewer's tomorrow.
 *
 * A reviewer's un-check stays un-checked. Un-checking deletes the entry and the server records
 * a tombstone that names the deleted row's habit and day (deletion_tombstones.habit_id /
 * .entry_date: routes/sync.js and routes/habits.js, since the 1.3.1 server). So a habit never
 * gets a check-in on or before the newest day un-checked on it: not that day, and not a day
 * before it that the fill would otherwise look at again because the habit's last entry moved
 * back. Every other habit is filled as usual, so one un-check costs no other habit a day. (Until
 * W8 the floor was account-wide, at the UTC day of the newest deletion: with the cap on the Los
 * Angeles day, that left the reviewer's own day empty on every habit — review of W8.) A
 * tombstone with no habit and day is one whose DELETE removed nothing: a retried deletion
 * (the first one named the row), an id the server never held, another account's id, or an
 * entry of a habit deleted in the same push. There is nothing for it to protect, so it sets no
 * floor. Production had no tombstone at all when the 1.3.1 server shipped (RELEASE-1.3.1.md,
 * deploy of 2026-09-29), so it holds no older kind. seed-demo.js clears the tombstones.
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
/** Gate 2: a habit done on at least this many of the last 30 days must score 0.75 or more. */
const GATE_DAYS = 25;

/**
 * A habit's rule: a 30-day pattern (1 = checked), or fixed weekdays (0 = Sunday … 6 =
 * Saturday, as getUTCDay numbers a YYYY-MM-DD day).
 * @typedef {number[] | { weekdays: number[] }} DemoRule
 */

// Each pattern is laid down in order, day d at pattern[patternIndex(d)] — by seed-demo.js,
// demo-add-habits.js and the top-up alike — so each habit keeps the completion rate it was
// designed with (Morning Run 23/30, Read 27/30, …) in every 30 days.
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

/** The six habits seeded before 1.4.1, with random ids (see "Which habits"). */
const LEGACY_NAMES = ["Morning Run", "Read 30 Minutes", "Meditate", "Drink 8 Glasses", "Practice Guitar", "Journal"];

/**
 * What each demo habit is, in habits' columns, as seed-demo.js and demo-add-habits.js create it
 * (the six seeded before 1.4.1 had no such columns written, so the schema defaults: the same).
 * A key that is absent is not compared.
 * @typedef {{ kind: string, schedule_kind: string, target_value?: number, times_per_week?: number }} DemoShape
 * @type {Record<string, DemoShape>}
 */
const SHAPES = {
  ...Object.fromEntries(LEGACY_NAMES.map((name) => [name, { kind: "binary", schedule_kind: "daily" }])),
  "Water": { kind: "count", schedule_kind: "daily", target_value: 8 },
  "Stretch": { kind: "binary", schedule_kind: "timesPerWeek", times_per_week: 3 },
};

/** @param {string} habitId @param {string} date */
function digest(habitId, date) {
  return crypto.createHash("sha256").update(`stride-demo-topup|${habitId.toUpperCase()}|${date}`).digest();
}

/** UUID-shaped (version 5 / RFC 4122 variant bits) upper-case id from a digest. @param {Buffer} h */
function uuidFrom(h) {
  const b = Buffer.from(h.subarray(0, 16));
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  const x = b.toString("hex").toUpperCase();
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
}

/**
 * The id seed-demo.js and demo-add-habits.js give a demo habit, and the top-up recomputes to
 * know one: from the account, the name and the created_at they write (a fresh time on every
 * run, so a re-seed still makes new ids). An app sends random ids, so a reviewer's habit never
 * has it.
 * @param {number} userId @param {string} name @param {string} createdAt
 */
function demoHabitId(userId, name, createdAt) {
  return uuidFrom(crypto.createHash("sha256").update(`stride-demo-habit|${userId}|${name}|${createdAt}`).digest());
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

/** Days since 1970-01-01. @param {string} day */
const dayNumber = (day) => Math.round(Date.parse(`${day}T00:00:00Z`) / DAY_MS);

/**
 * Where `day` falls in a pattern of `length` days: fixed by the calendar, so every script and
 * every run agree on it, whatever day they run.
 * @param {string} day @param {number} [length]
 */
const patternIndex = (day, length = 30) => ((dayNumber(day) % length) + length) % length;

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
 * @param {DemoRule} rule @param {string} day
 */
function isChecked(rule, day) {
  if (Array.isArray(rule)) return rule[patternIndex(day, rule.length)] === 1;
  return rule.weekdays.includes(weekdayOf(day));
}

/**
 * Whether the rule, followed alone, is done on at least GATE_DAYS of some 30 days (a weekday
 * rule: at most five of each weekday in 30 days).
 * @param {DemoRule} rule
 */
function reachesGate(rule) {
  if (Array.isArray(rule)) return rule.reduce((a, b) => a + b, 0) * (30 / rule.length) >= GATE_DAYS;
  return rule.weekdays.length * 5 >= GATE_DAYS;
}

/**
 * @typedef {{ id: string, name: string, kind: string, target_value: number, schedule_kind: string,
 *   times_per_week: number, created_at: string, created: string, last: string|null }} DemoHabit
 */

/** Whether `habit` is still what the demo scripts made (`SHAPES`). @param {DemoHabit} habit */
function hasShape(habit) {
  const shape = SHAPES[habit.name];
  if (!shape) return false;
  return Object.entries(shape).every(([column, value]) => /** @type {any} */ (habit)[column] === value);
}

const DRY_RUN = Symbol("dry run");

/**
 * One top-up of the demo account in `db`, as of `now`. Writes nothing when `dryRun` (it runs
 * the same transaction and rolls it back, so the report is exact).
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
    SELECT h.id, h.name, h.kind, h.target_value, h.schedule_kind, h.times_per_week, h.created_at,
           substr(h.created_at, 1, 10) AS created,
           (SELECT max(e.date) FROM habit_entries e WHERE e.habit_id = h.id) AS last
    FROM habits h WHERE h.user_id = ? AND h.is_archived = 0 ORDER BY h.sort_order
  `).all(user.id));

  const nowIso = now.toISOString();
  const today = entryDayCap(now);
  const earliest = addDays(today, -(BACKFILL_DAYS - 1));

  // Which habits (the header): a demo id, or one of the six seeded before 1.4.1 by name, shape,
  // age and the created_at that run gave all six.
  /** @param {DemoHabit} h */
  const demoMade = (h) => h.id.toUpperCase() === demoHabitId(user.id, h.name, h.created_at);
  /** @param {DemoHabit} h */
  const fillable = (h) => Boolean(PATTERNS[h.name]) && hasShape(h) && h.created < earliest;
  const namesWithDemoIds = new Set(habits.filter(demoMade).map((h) => h.name));
  const legacy = habits.filter((h) => fillable(h) && !demoMade(h) &&
    LEGACY_NAMES.includes(h.name) && !namesWithDemoIds.has(h.name));
  /** @type {Map<string, number>} */
  const stamps = new Map();
  for (const h of legacy) stamps.set(h.created_at, (stamps.get(h.created_at) ?? 0) + 1);
  const shared = Math.max(0, ...stamps.values());
  const seeded = habits.filter((h) => fillable(h) &&
    (demoMade(h) || (legacy.includes(h) && stamps.get(h.created_at) === shared)));
  if (seeded.length === 0) {
    return { status: 1, added: 0, line: `[demo-topup] ${DEMO_EMAIL} has none of the seeded habits — run seed-demo.js first` };
  }

  // The newest day un-checked on each habit (the header). Ids compared upper case, as
  // canonicalizeIds stores them.
  const unchecked = new Map(/** @type {{ habitId: string, day: string }[]} */ (db.prepare(`
    SELECT upper(habit_id) AS habitId, max(entry_date) AS day FROM deletion_tombstones
    WHERE user_id = ? AND entity_type = 'entry' AND habit_id IS NOT NULL
      AND entry_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
    GROUP BY upper(habit_id)
  `).all(user.id)).map((r) => [r.habitId, r.day]));
  const insert = db.prepare(`
    INSERT OR IGNORE INTO habit_entries (id, habit_id, date, value, created_at, updated_at, client_updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `);
  // Completed days of a habit in [from, to]: any row of a yes/no habit, a value at the target
  // of a count habit (Habit.completedDayKeys). One row per habit and day (UNIQUE).
  const doneBetween = db.prepare(`
    SELECT count(*) AS n FROM habit_entries
    WHERE habit_id = ? AND date >= ? AND date <= ? AND (? <> 'count' OR value >= ?)
  `);

  /** @type {string[]} */
  const report = [];
  /** @type {string[]} */
  const kept = [];
  let total = 0;
  const run = db.transaction(() => {
    for (const habit of seeded) {
      const rule = PATTERNS[habit.name];
      const target = Math.max(1, habit.target_value);
      // The latest of: the day after its last entry, the window's start, the habit's own
      // creation day, the day after the newest day un-checked on it (the header). String max
      // works: all are YYYY-MM-DD.
      const floors = [earliest, habit.created];
      if (habit.last) floors.push(addDays(habit.last, 1));
      const uncheckedDay = unchecked.get(habit.id.toUpperCase());
      if (uncheckedDay) {
        floors.push(addDays(uncheckedDay, 1));
        if (uncheckedDay >= earliest) kept.push(`${habit.name} through ${uncheckedDay}`);
      }
      let day = floors.reduce((a, b) => (a > b ? a : b));
      const from = day;
      let added = 0, held = 0;
      for (; day <= today; day = addDays(day, 1)) {
        if (!isChecked(rule, day)) continue;
        if (!reachesGate(rule)) {
          // Gate 2 (the header): not the day that brings the 30 ending on it up to GATE_DAYS.
          const n = /** @type {{ n: number }} */ (
            doneBetween.get(habit.id, addDays(day, -29), addDays(day, -1), habit.kind, target)).n;
          if (n + 1 === GATE_DAYS) { held++; continue; }
        }
        // A count habit is "done" only at its target (Habit.completedDayKeys).
        const value = habit.kind === "count" ? target : 1;
        added += insert.run(uuidFrom(digest(habit.id, day)), habit.id, day, value, nowIso, nowIso, nowIso).changes;
      }
      total += added;
      report.push(from > today ? `${habit.name} +0 (current)`
        : `${habit.name} +${added} (${from}..${today}${held ? `, ${held} held below gate 2` : ""})`);
    }
    if (dryRun) throw DRY_RUN;
  });
  try {
    run();
  } catch (err) {
    if (err !== DRY_RUN) throw err;
  }

  const skipped = habits.length - seeded.length;
  const line =
    `[demo-topup] ${nowIso}${dryRun ? " DRY RUN" : ""} ${total} check-ins added — ${report.join(", ")}` +
    (skipped ? `; ${skipped} habit(s) not from the demo scripts left alone` : "") +
    (kept.length ? `; un-checked days kept: ${kept.join(", ")}` : "");
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
  DEMO_EMAIL, BACKFILL_DAYS, DAY_MS, REVIEW_TIME_ZONE, GATE_DAYS, PATTERNS, LEGACY_NAMES, SHAPES,
  digest, uuidFrom, demoHabitId, dayString, addDays, weekdayOf, dayNumber, patternIndex, dayIn, entryDayCap,
  isChecked, reachesGate, hasShape, topUp,
};
