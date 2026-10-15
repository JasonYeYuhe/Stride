#!/usr/bin/env node
// @ts-check
/**
 * demo-add-habits.js — add 1.4.1's two demo habits to the App Review demo account, with 90 days
 * of history, and change nothing that is already there (RELEASE-1.4.1.md D13 item 2).
 *
 * Usage (on the host, once, only while no App Review is open — DEPLOY.md):
 *   /usr/bin/node /root/stride-server/ops/demo-add-habits.js [--dry-run]
 *
 * What it adds, to demo@stride-review.com:
 *   - "Water": a count habit, target 8, unit "glasses" (what the app stores for its template
 *     unit), daily: mostly 8 or more, some partial days, two days with nothing logged;
 *   - "Stretch": yes/no, 3 times a week, checked every Monday, Wednesday and Friday.
 * Each gets 90 days of history ending on the entry-day cap (ops/demo-topup.js `entryDayCap`,
 * min(UTC today, America/Los_Angeles today)) and three notes on days it has a check-in (D7:
 * notes only on days with a record; never a value-0 or note-only record). From then on
 * ops/demo-topup.js keeps both current, by the rules in its PATTERNS.
 *
 * Why not seed-demo.js. A re-seed deletes the account's sessions and tokens and re-creates every
 * habit under a new id: a reviewer signed in at the time is signed out and loses what is on their
 * device (seed-demo.js header). This script only INSERTs a habit and its check-ins:
 *   - never a session, token, tombstone or user row, and never an existing habit or check-in;
 *     the ids it writes are new upper-case UUIDs, like every id the apps send;
 *   - idempotent per (account, name): a habit of that name already in the account, archived or
 *     not, is left alone and the script still exits 0, so a second run adds nothing;
 *   - created_at is written explicitly, CREATED_DAYS_BACK (91) days back: the server sets it only
 *     on insert, an app never writes it, and the history must not start before the habit;
 *   - updated_at = client_updated_at = now on the habit and on every check-in, so the next
 *     ?since pull of a signed-in device picks them up (routes/sync.js "Two clocks").
 *
 * seed-demo.js creates the same two habits through `insertDemoHabit`, so a full seed and this
 * script write the same shapes (test/demo-scripts.test.js). Opens the database through ../db
 * (WAL: safe with the server running). Required rather than run, it does nothing.
 */

const crypto = require("crypto");
const { DEMO_EMAIL, DAY_MS, PATTERNS, addDays, weekdayOf, entryDayCap } = require("./demo-topup");

/** Days of history each habit gets, ending on the entry-day cap. */
const HISTORY_DAYS = 90;
/** created_at, this many days before now: before the first day of history in every zone. */
const CREATED_DAYS_BACK = 91;

/**
 * A demo habit: its row, and `day(index, date)` — the check-in for day `index` of the history
 * (0 = the oldest, HISTORY_DAYS − 1 = the cap), or null for none. Each of `notes` is
 * [days back from the cap, text], and goes on the newest check-in on or before that day that has
 * no note yet.
 * @typedef {{
 *   name: string, emoji: string, color: string,
 *   kind: "binary" | "count", target: number, unit: string | null,
 *   schedule: "daily" | "timesPerWeek" | "specificDays", timesPerWeek: number, activeDaysMask: number,
 *   day: (index: number, date: string) => { value: number } | null,
 *   notes: [number, string][],
 * }} DemoHabitDef
 */

/** Water's logged glasses, by position in a 30-day cycle (0 = no check-in that day). The days at
 * 8 or more are ops/demo-topup.js's PATTERNS.Water. */
const WATER_VALUES = [8,8,6,8,8,8,0,8,8,7,8,8,10,8,5,8,8,8,8,0,8,8,8,6,8,8,9,8,8,8];

const stretchRule = /** @type {{ weekdays: number[] }} */ (PATTERNS.Stretch);

/** The habits this script adds, in sort order. @type {DemoHabitDef[]} */
const ADDED_HABITS = [
  {
    name: "Water", emoji: "🚰", color: "#007AFF",
    kind: "count", target: 8, unit: "glasses",
    schedule: "daily", timesPerWeek: 7, activeDaysMask: 127,
    day: (i) => {
      const value = WATER_VALUES[i % WATER_VALUES.length];
      return value > 0 ? { value } : null;
    },
    // Days back from the cap: 17 is cycle position 12 (10 glasses), 6 is position 23 (6), 38 is
    // position 21 (8), whatever the date (day i of the history is position i % 30).
    notes: [
      [6, "Left my bottle at home"],
      [17, "Hot day, two extra glasses"],
      [38, "Herbal tea counts too"],
    ],
  },
  {
    name: "Stretch", emoji: "🤸", color: "#FFCC00",
    kind: "binary", target: 1, unit: null,
    schedule: "timesPerWeek", timesPerWeek: 3, activeDaysMask: 127,
    day: (_i, date) => (stretchRule.weekdays.includes(weekdayOf(date)) ? { value: 1 } : null),
    // At least three days apart, so each lands on its own Monday, Wednesday or Friday.
    notes: [
      [1, "Hamstrings feel looser"],
      [9, "Ten minutes after the run"],
      [30, "Yoga class instead"],
    ],
  },
];

/**
 * The check-ins `def` gets for HISTORY_DAYS days ending on `lastDay`, oldest first, with its
 * notes placed.
 * @param {DemoHabitDef} def @param {string} lastDay
 * @returns {{ date: string, value: number, note: string | null }[]}
 */
function historyOf(def, lastDay) {
  /** @type {{ date: string, value: number, note: string | null }[]} */
  const rows = [];
  for (let i = 0; i < HISTORY_DAYS; i++) {
    const date = addDays(lastDay, i - (HISTORY_DAYS - 1));
    const entry = def.day(i, date);
    if (entry && entry.value > 0) rows.push({ date, value: entry.value, note: null });
  }
  for (const [back, text] of def.notes) {
    const onOrBefore = addDays(lastDay, -back);
    for (let i = rows.length - 1; i >= 0; i--) {
      if (rows[i].date <= onOrBefore && rows[i].note === null) { rows[i].note = text; break; }
    }
  }
  return rows;
}

/**
 * Insert `def` and its history into `userId`'s account: one habit row with every column the
 * apps read (routes/sync.js pull), its check-ins, nothing else. Throws on any conflict, so the
 * caller's transaction rolls back.
 * @param {import('better-sqlite3').Database} db
 * @param {number} userId
 * @param {DemoHabitDef} def
 * @param {{ now: Date, sortOrder: number }} opts
 * @returns {{ id: string, entries: number, notes: number, from: string, to: string, createdAt: string }}
 */
function insertDemoHabit(db, userId, def, { now, sortOrder }) {
  const nowIso = now.toISOString();
  const lastDay = entryDayCap(now);
  const createdAt = new Date(now.getTime() - CREATED_DAYS_BACK * DAY_MS).toISOString();
  const id = crypto.randomUUID().toUpperCase();
  db.prepare(`
    INSERT INTO habits (id, user_id, name, emoji, color_hex, is_archived, sort_order,
                        reminder_enabled, reminder_hour, reminder_minute, note,
                        kind, target_value, unit, schedule_kind, times_per_week, active_days_mask,
                        group_id, created_at, updated_at, client_updated_at)
    VALUES (?, ?, ?, ?, ?, 0, ?, 0, 20, 0, NULL, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
  `).run(id, userId, def.name, def.emoji, def.color, sortOrder,
    def.kind, def.target, def.unit, def.schedule, def.timesPerWeek, def.activeDaysMask,
    createdAt, nowIso, nowIso);
  const insertEntry = db.prepare(`
    INSERT INTO habit_entries (id, habit_id, date, note, value, created_at, updated_at, client_updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const rows = historyOf(def, lastDay);
  for (const row of rows) {
    insertEntry.run(crypto.randomUUID().toUpperCase(), id, row.date, row.note, row.value, nowIso, nowIso, nowIso);
  }
  return {
    id, entries: rows.length, notes: rows.filter((r) => r.note !== null).length,
    from: rows[0]?.date ?? lastDay, to: rows[rows.length - 1]?.date ?? lastDay, createdAt,
  };
}

/**
 * Add whichever of ADDED_HABITS the demo account lacks, as of `now`. Writes nothing when `dryRun`.
 * @param {import('better-sqlite3').Database} db
 * @param {{ now?: Date, dryRun?: boolean }} [opts]
 * @returns {{ status: number, line: string, added: string[] }}
 */
function addHabits(db, { now = new Date(), dryRun = false } = {}) {
  const tag = `[demo-add-habits] ${now.toISOString()}${dryRun ? " DRY RUN" : ""}`;
  const user = /** @type {{ id: number } | undefined} */ (
    db.prepare("SELECT id FROM users WHERE email = ?").get(DEMO_EMAIL)
  );
  if (!user) return { status: 1, added: [], line: `${tag} no ${DEMO_EMAIL} account — run seed-demo.js first` };

  const named = db.prepare("SELECT 1 FROM habits WHERE user_id = ? AND name = ?");
  const nextSort = db.prepare("SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM habits WHERE user_id = ?");
  /** @type {string[]} */
  const report = [];
  /** @type {string[]} */
  const added = [];
  db.transaction(() => {
    let sortOrder = /** @type {{ n: number }} */ (nextSort.get(user.id)).n;
    for (const def of ADDED_HABITS) {
      if (named.get(user.id, def.name)) {
        report.push(`${def.name} already there, left alone`);
        continue;
      }
      if (dryRun) {
        const rows = historyOf(def, entryDayCap(now));
        report.push(`${def.name} +${rows.length} check-ins (${rows[0]?.date}..${rows[rows.length - 1]?.date})`);
      } else {
        const r = insertDemoHabit(db, user.id, def, { now, sortOrder });
        report.push(`${def.name} +${r.entries} check-ins (${r.from}..${r.to}, ${r.notes} notes, created ${r.createdAt.slice(0, 10)})`);
      }
      added.push(def.name);
      sortOrder++;
    }
  })();
  return { status: 0, added, line: `${tag} ${added.length} habit(s) added — ${report.join(", ")}` };
}

function main() {
  const db = require("../db");
  const result = addHabits(db, { dryRun: process.argv.includes("--dry-run") });
  (result.status === 0 ? console.log : console.error)(result.line);
  return result.status;
}

if (require.main === module) process.exitCode = main();

module.exports = { HISTORY_DAYS, CREATED_DAYS_BACK, WATER_VALUES, ADDED_HABITS, historyOf, insertDemoHabit, addHabits };
