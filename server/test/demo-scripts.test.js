// The App Review demo account's scripts (RELEASE-1.4.1.md D13, W8): seed-demo.js (destructive
// re-seed), ops/demo-add-habits.js (add-only, run once at deploy) and ops/demo-topup.js (nightly).
//
// Every database here is a temp copy: a schema made by running a copy of db.js in a temp
// directory (db.js opens the stride.db next to itself), and the scripts run from a copy of this
// server, the way they run on the host (`node seed-demo.js`, `node ops/demo-add-habits.js`).
// better-sqlite3 and dotenv come from this server's node_modules through NODE_PATH; nothing is
// linked into a temp directory, so removing one can never reach the real modules.
//
// Gate 2 (check_demo_account.sh exits 4 when a habit done on at least 25 of the last 30 days
// scores below 0.75) is checked with a port of Shared/HabitScore.swift and the HabitStats inputs
// it reads, which first reproduces HabitScoreTests' reference values.

const { describe, it, before, after } = require("node:test");
const assert = require("node:assert/strict");
const { execFile, spawn } = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const Database = require("better-sqlite3");

const SERVER = path.join(__dirname, "..");
const NODE_MODULES = path.join(SERVER, "node_modules");
const topup = require("../ops/demo-topup");
const addOnly = require("../ops/demo-add-habits");
const seedDemo = require("../seed-demo");
const { DEMO_EMAIL, PATTERNS, DAY_MS, addDays, dayString, dayIn, entryDayCap, isChecked, digest, uuidFrom, weekdayOf,
  patternIndex, demoHabitId } = topup;

const PORT = 3094;
const SIX = ["Morning Run", "Read 30 Minutes", "Meditate", "Drink 8 Glasses", "Practice Guitar", "Journal"];
/** The cron's time: 03:50 UTC on the 16th is 20:50 on the 15th in Los Angeles. */
const CRON_NIGHT = new Date("2026-10-16T03:50:00.000Z");
const UPPER_UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;

// ---------- copies of this server ----------

const temps = [];
after(() => { for (const dir of temps) fs.rmSync(dir, { recursive: true, force: true }); });

/** A temp copy of this server's runtime files: no node_modules, tests, databases or .env. */
function serverCopy() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "stride-demo-scripts-"));
  temps.push(dir);
  fs.cpSync(SERVER, dir, {
    recursive: true,
    filter: (src) => {
      const name = path.basename(src);
      if (src === SERVER) return true;
      return !(name === "node_modules" || name === "test" || name.startsWith(".env") || /\.db(-wal|-shm)?$/.test(name));
    },
  });
  return dir;
}

/** The environment of a script run on the host, as `env -i` would leave it plus `extra`. */
function scriptEnv(extra = {}) {
  return { PATH: process.env.PATH, NODE_PATH: NODE_MODULES, ...extra };
}

/** Run a script of the copy `dir`, with cwd = `dir` (so dotenv looks for the copy's .env). */
function run(dir, script, args = [], env = scriptEnv()) {
  return new Promise((resolve) => {
    execFile(process.execPath, [path.join(dir, script), ...args], { cwd: dir, env, encoding: "utf8" }, (err, stdout, stderr) => {
      resolve({ status: err ? (typeof err.code === "number" ? err.code : 1) : 0, stdout, stderr });
    });
  });
}

/** A server copy whose stride.db has the schema (db.js run once, as on a first boot). */
async function copyWithSchema() {
  const dir = serverCopy();
  const r = await run(dir, "db.js");
  assert.equal(r.status, 0, r.stderr);
  return dir;
}

let template; // a stride.db with the schema and nothing else, copied for each in-process test
before(async () => {
  template = path.join(await copyWithSchema(), "stride.db");
  // One self-contained file: whatever db.js left in the WAL goes into it, so a copy of the file
  // alone holds the whole schema.
  const db = new Database(template);
  db.pragma("wal_checkpoint(TRUNCATE)");
  db.pragma("journal_mode = DELETE");
  db.close();
});

/** A fresh database with the schema, open in this process. */
function scratchDb() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "stride-demo-db-"));
  temps.push(dir);
  const file = path.join(dir, "stride.db");
  fs.copyFileSync(template, file);
  const db = new Database(file);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  return db;
}

/** Every row of every table the demo scripts could reach, in a stable order. */
function snapshot(db) {
  const rows = (sql) => db.prepare(sql).all().map((r) => ({ ...r }));
  return {
    users: rows("SELECT * FROM users ORDER BY id"),
    sessions: rows("SELECT * FROM sessions ORDER BY id"),
    magic_link_tokens: rows("SELECT * FROM magic_link_tokens ORDER BY id"),
    deletion_tombstones: rows("SELECT * FROM deletion_tombstones ORDER BY id"),
    habit_groups: rows("SELECT * FROM habit_groups ORDER BY id"),
    habits: rows("SELECT * FROM habits ORDER BY id"),
    habit_entries: rows("SELECT * FROM habit_entries ORDER BY id"),
  };
}

const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");
/** A fixed upper-case UUID for a label, so hash-picked top-up days are the same on every run. */
function fixedId(label) {
  const x = sha256(label).slice(0, 32).toUpperCase();
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-4${x.slice(13, 16)}-8${x.slice(17, 20)}-${x.slice(20)}`;
}

/**
 * The top-up as it ran before 1.4.1 (0d61b1c), for an account shaped like production's: the six
 * habits by name and age, dated by UTC, each day picked by a hash of habit id + date, nothing on
 * or before the UTC day of the newest entry tombstone.
 */
function preW8TopUp(db, now) {
  const user = db.prepare("SELECT id FROM users WHERE email = ?").get(DEMO_EMAIL);
  const today = dayString(now), earliest = addDays(today, -29), at = now.toISOString();
  const { lastDeleted } = db.prepare("SELECT substr(max(deleted_at), 1, 10) AS lastDeleted FROM deletion_tombstones WHERE user_id = ? AND entity_type = 'entry'").get(user.id);
  const habits = db.prepare(`SELECT h.id, h.name, substr(h.created_at, 1, 10) AS created,
    (SELECT max(e.date) FROM habit_entries e WHERE e.habit_id = h.id) AS last FROM habits h WHERE h.user_id = ? AND h.is_archived = 0`).all(user.id);
  for (const h of habits) {
    if (!SIX.includes(h.name) || !(h.created < earliest)) continue;
    const floors = [earliest, h.created];
    if (h.last) floors.push(addDays(h.last, 1));
    if (lastDeleted) floors.push(addDays(lastDeleted, 1));
    for (let day = floors.reduce((a, b) => (a > b ? a : b)); day <= today; day = addDays(day, 1)) {
      const d = digest(h.id, day);
      if (PATTERNS[h.name][d.readUInt32BE(28) % 30] !== 1) continue;
      db.prepare("INSERT OR IGNORE INTO habit_entries (id, habit_id, date, value, created_at, updated_at, client_updated_at) VALUES (?, ?, ?, 1, ?, ?, ?)")
        .run(uuidFrom(d), h.id, day, at, at, at);
    }
  }
}

/**
 * The demo account as production holds it before 1.4.1: the six habits the way the 1.2.3-era
 * seed-demo.js inserted them (random ids; no kind or schedule columns, so the defaults; one
 * created_at for all six, 45 days before a seed whose 30 pattern days end on `seedDay`), the
 * pre-1.4.1 top-up nightly since, a signed-in reviewer (a session, the reusable token), a habit
 * the reviewer made with a noted check-in, and an entry tombstone from a reviewer's un-check.
 * `label` varies the habit ids (so the hash-picked days).
 * @returns {{ userId: number, token: string, session: string }}
 */
function legacyAccount(db, { now, seedDay = addDays(entryDayCap(now), -29), label = "legacy" }) {
  const userId = Number(db.prepare("INSERT INTO users (email) VALUES (?)").run(DEMO_EMAIL).lastInsertRowid);
  const seedNow = new Date(`${seedDay}T09:00:00.000Z`);
  const createdAt = new Date(seedNow.getTime() - 45 * DAY_MS).toISOString();
  SIX.forEach((name, sort) => {
    const id = fixedId(`${label}|${name}`);
    db.prepare(`INSERT INTO habits (id, user_id, name, emoji, color_hex, sort_order, created_at, updated_at, client_updated_at)
      VALUES (?, ?, ?, '⭐', '#34C759', ?, ?, ?, ?)`).run(id, userId, name, sort, createdAt, createdAt, createdAt);
    const pattern = /** @type {number[]} */ (PATTERNS[name]);
    for (let day = 0; day < 30; day++) {
      if (!pattern[day]) continue;
      const date = addDays(seedDay, day - 29);
      const at = `${date}T09:00:00.000Z`;
      db.prepare("INSERT INTO habit_entries (id, habit_id, date, created_at, updated_at, client_updated_at) VALUES (?, ?, ?, ?, ?, ?)")
        .run(fixedId(`${label}|${name}|${date}`), id, date, at, at, at);
    }
  });
  // A reviewer: a habit of their own, created last week, with one noted check-in; an un-check
  // well before the cap (its tombstone names the row's habit and day, as the 1.3.1 server writes).
  const own = fixedId("legacy|reviewer-habit");
  const ownCreated = new Date(now.getTime() - 7 * DAY_MS).toISOString();
  db.prepare(`INSERT INTO habits (id, user_id, name, kind, schedule_kind, created_at, updated_at, client_updated_at)
    VALUES (?, ?, 'Read Fiction', 'binary', 'daily', ?, ?, ?)`).run(own, userId, ownCreated, ownCreated, ownCreated);
  db.prepare("INSERT INTO habit_entries (id, habit_id, date, note, value, created_at, updated_at, client_updated_at) VALUES (?, ?, ?, 'Chapter 3', 1, ?, ?, ?)")
    .run(fixedId("legacy|reviewer-entry"), own, addDays(entryDayCap(now), -2), ownCreated, ownCreated, ownCreated);
  const deletedAt = `${addDays(seedDay, -3)}T12:00:00.000Z`;
  db.prepare("INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at, habit_id, entry_date) VALUES (?, 'entry', ?, ?, ?, ?)")
    .run(userId, fixedId(`${label}|deleted`), deletedAt, fixedId(`${label}|Journal`), addDays(seedDay, -3));
  // The nightly top-up since the seed, as it ran before 1.4.1.
  for (let night = addDays(seedDay, 1); night <= dayString(now); night = addDays(night, 1)) {
    const at = new Date(`${night}T03:50:00.000Z`);
    if (at <= now) preW8TopUp(db, at);
  }
  const token = crypto.randomBytes(24).toString("hex");
  db.prepare("INSERT INTO magic_link_tokens (user_id, token_hash, expires_at, is_reusable) VALUES (?, ?, ?, 1)")
    .run(userId, sha256(token), now.getTime() + 300 * DAY_MS);
  const session = crypto.randomBytes(32).toString("hex");
  db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)")
    .run(userId, sha256(session), now.getTime() + 30 * DAY_MS);
  return { userId, token, session };
}

const habitRow = (db, name) => db.prepare("SELECT * FROM habits WHERE name = ?").get(name);
const entriesOf = (db, habitId) =>
  db.prepare("SELECT * FROM habit_entries WHERE habit_id = ? ORDER BY date").all(habitId).map((r) => ({ ...r }));

// ---------- strength: Shared/HabitScore.swift, ported ----------

const dayNumber = (day) => Date.parse(`${day}T00:00:00Z`) / DAY_MS;

/**
 * HabitStats' strength and the completed days of the last 30, for a habit row and its entries,
 * as of `today` (a YYYY-MM-DD). The port: values by day (the max of a day's records, none after
 * today); completed = any record (yes/no) or value >= target (count); the walk from
 * min(created day, earliest record) to today when today is complete, else yesterday; input
 * yes/no 1|0, count min(1, value/target), times-per-week min(1, trailing-7 completions /
 * timesPerWeek), a specificDays rest day neutral; score = prev·m + input·(1−m), m = 0.5^(√freq/13).
 */
function strengthOf(habit, entries, today) {
  const t = dayNumber(today);
  const values = new Map();
  for (const e of entries) {
    const d = dayNumber(e.date);
    if (d <= t) values.set(d, Math.max(values.get(d) ?? -Infinity, e.value));
  }
  const completed = new Set();
  for (const [d, v] of values) if (habit.kind === "count" ? habit.target_value > 0 && v >= habit.target_value : true) completed.add(d);
  let done30 = 0;
  for (let d = t - 29; d <= t; d++) if (completed.has(d)) done30++;
  const created = dayNumber(habit.created_at.slice(0, 10));
  const start = values.size ? Math.min(created, ...values.keys()) : created;
  const last = completed.has(t) ? t : t - 1;
  const perWeek = habit.schedule_kind === "timesPerWeek" ? habit.times_per_week
    : habit.schedule_kind === "specificDays" ? [...Array(7).keys()].filter((b) => habit.active_days_mask & (1 << b)).length : 7;
  const freq = habit.schedule_kind === "daily" ? 1 : Math.min(7, Math.max(1, perWeek)) / 7;
  const m = Math.pow(0.5, Math.sqrt(freq) / 13);
  let trailing = 0;
  for (let d = start - 6; d < start; d++) if (completed.has(d)) trailing++;
  let score = 0;
  for (let d = start; d <= last; d++) {
    if (completed.has(d)) trailing++;
    if (completed.has(d - 7)) trailing--;
    let input;
    if (habit.schedule_kind === "timesPerWeek") input = Math.min(1, trailing / Math.max(1, habit.times_per_week));
    else if (habit.schedule_kind === "specificDays" && !(habit.active_days_mask & (1 << ((d % 7 + 11) % 7)))) input = null;
    else if (habit.kind === "count") {
      const v = values.get(d) ?? 0;
      input = habit.target_value > 0 ? Math.min(1, Math.max(0, v / habit.target_value)) : (v > 0 ? 1 : 0);
    } else input = completed.has(d) ? 1 : 0;
    if (input !== null) score = score * m + input * (1 - m);
  }
  return { score, done30 };
}

/** Gate 2 over every habit of the demo account in `db`, as of `today`. */
function gate2(db, today) {
  const habits = db.prepare("SELECT h.* FROM habits h JOIN users u ON u.id = h.user_id WHERE u.email = ?").all(DEMO_EMAIL);
  return habits.map((h) => ({ name: h.name, ...strengthOf(h, entriesOf(db, h.id), today) }));
}

// ---------- a reviewer, and the nights ----------

const demoUserId = (db) => db.prepare("SELECT id FROM users WHERE email = ?").get(DEMO_EMAIL).id;

/** A reviewer's un-check of `habitId` on `day` at `at`, written as routes/sync.js's push writes
 * it: the row goes, and its tombstone names the row's habit and day. */
function uncheck(db, habitId, day, at) {
  const row = db.prepare("SELECT id, habit_id, date FROM habit_entries WHERE habit_id = ? AND date = ?").get(habitId, day);
  assert.ok(row, `a check-in of ${habitId} on ${day}`);
  db.prepare("DELETE FROM habit_entries WHERE id = ?").run(row.id);
  db.prepare("INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at, habit_id, entry_date) VALUES (?, 'entry', ?, ?, ?, ?)")
    .run(demoUserId(db), row.id, at.toISOString(), row.habit_id, row.date);
}

/** A reviewer's check-in, as an app pushes one: a random id. Returns the id. */
function checkIn(db, habitId, day, at) {
  const id = crypto.randomUUID().toUpperCase();
  db.prepare("INSERT INTO habit_entries (id, habit_id, date, value, created_at, updated_at, client_updated_at) VALUES (?, ?, ?, 1, ?, ?, ?)")
    .run(id, habitId, day, at.toISOString(), at.toISOString(), at.toISOString());
  return id;
}

/** The cron's run on UTC day `day`. */
const night = (day) => new Date(`${day}T03:50:00.000Z`);

/** The cron's runs on UTC days `from` through `to`; their report lines. */
function nights(db, from, to) {
  const lines = [];
  for (let d = from; d <= to; d = addDays(d, 1)) {
    const r = topup.topUp(db, { now: night(d) });
    assert.equal(r.status, 0, r.line);
    lines.push(r.line);
  }
  return lines;
}

const newestDay = (db, habitId, onOrBefore) =>
  db.prepare("SELECT max(date) AS d FROM habit_entries WHERE habit_id = ? AND date <= ?").get(habitId, onOrBefore).d;

/**
 * Where the demo scripts' habits (those with a demo id) differ from their rules on [from, to]:
 * "<name> <day> checked" for a done day the rule has empty, "… empty" for the reverse. Done: any
 * check-in of a yes/no habit, a value at the target of a count habit.
 */
function offRule(db, from, to) {
  const out = [];
  const habits = db.prepare("SELECT h.* FROM habits h WHERE h.user_id = ? ORDER BY sort_order").all(demoUserId(db));
  for (const h of habits.filter((x) => PATTERNS[x.name] && x.id === demoHabitId(x.user_id, x.name, x.created_at))) {
    const done = new Set(entriesOf(db, h.id).filter((e) => h.kind !== "count" || e.value >= h.target_value).map((e) => e.date));
    for (let d = from; d <= to; d = addDays(d, 1)) {
      if (done.has(d) !== isChecked(PATTERNS[h.name], d)) out.push(`${h.name} ${d} ${done.has(d) ? "checked" : "empty"}`);
    }
  }
  return out;
}

// ---------- tests ----------

describe("the entry-day cap is min(UTC today, America/Los_Angeles today)", () => {
  it("is the Los Angeles day while that is behind UTC, as at the cron's 03:50 UTC", () => {
    assert.equal(dayString(CRON_NIGHT), "2026-10-16");
    assert.equal(entryDayCap(CRON_NIGHT), "2026-10-15");
    assert.equal(entryDayCap(new Date("2026-01-01T07:59:59.000Z")), "2025-12-31"); // 23:59 PST
    assert.equal(entryDayCap(new Date("2026-01-01T08:00:00.000Z")), "2026-01-01");
  });

  it("is the UTC day when both agree, on either side of both DST changes", () => {
    assert.equal(entryDayCap(new Date("2026-10-15T12:00:00.000Z")), "2026-10-15");
    assert.equal(entryDayCap(new Date("2026-03-08T06:59:00.000Z")), "2026-03-07"); // 22:59 PST
    assert.equal(entryDayCap(new Date("2026-03-08T08:00:00.000Z")), "2026-03-08"); // 00:00 PST
    assert.equal(entryDayCap(new Date("2026-03-09T06:59:00.000Z")), "2026-03-08"); // 23:59 PDT
    assert.equal(entryDayCap(new Date("2026-03-09T07:00:00.000Z")), "2026-03-09");
    assert.equal(entryDayCap(new Date("2026-11-01T06:59:00.000Z")), "2026-10-31"); // 23:59 PDT
    assert.equal(entryDayCap(new Date("2026-11-02T07:59:00.000Z")), "2026-11-01"); // 23:59 PST
  });
});

describe("the top-up's rules (ops/demo-topup.js)", () => {
  it("Stretch: Monday, Wednesday and Friday, so every Monday-to-Sunday week holds exactly three", () => {
    let monday = "2025-12-29"; // a Monday
    for (let week = 0; week < 104; week++, monday = addDays(monday, 7)) {
      const days = [0, 1, 2, 3, 4, 5, 6].map((n) => addDays(monday, n)).filter((d) => isChecked(PATTERNS.Stretch, d));
      assert.deepEqual(days.map(weekdayOf), [1, 3, 5], `week of ${monday}`);
    }
  });

  it("the daily patterns are laid down in order at the calendar's place, so any 30 days in a row hold exactly the pattern's count", () => {
    const sums = Object.fromEntries([...SIX, "Water"].map((n) => [n, /** @type {number[]} */ (PATTERNS[n]).reduce((a, b) => a + b, 0)]));
    assert.deepEqual(sums, { "Morning Run": 23, "Read 30 Minutes": 27, "Meditate": 19, "Drink 8 Glasses": 24, "Practice Guitar": 15, "Journal": 25, "Water": 24 });
    assert.equal(patternIndex("1970-01-01"), 0);
    assert.equal(patternIndex("1969-12-31"), 29);
    for (let day = "2026-01-01"; day <= "2026-12-31"; day = addDays(day, 1)) {
      assert.equal(patternIndex(addDays(day, 1)), (patternIndex(day) + 1) % 30, day);
      for (const name of [...SIX, "Water"]) {
        const pattern = /** @type {number[]} */ (PATTERNS[name]);
        assert.equal(isChecked(pattern, day), pattern[patternIndex(day)] === 1);
        let n = 0;
        for (let k = 0; k < 30; k++) if (isChecked(pattern, addDays(day, k))) n++;
        assert.equal(n, sums[name], `${name}, 30 days from ${day}`);
      }
    }
    // So only Read 30 Minutes and Journal are ever done on gate 2's 25 of 30.
    assert.deepEqual(Object.keys(PATTERNS).filter((n) => topup.reachesGate(PATTERNS[n])).sort(), ["Journal", "Read 30 Minutes"]);
  });

  it("Water's pattern is the days its seeded history reaches the target of 8", () => {
    assert.equal(addOnly.WATER_VALUES.length, 30);
    assert.deepEqual(PATTERNS.Water, addOnly.WATER_VALUES.map((v) => (v >= 8 ? 1 : 0)));
  });

  it("every habit seed-demo.js creates has a rule, and nothing else does", () => {
    assert.deepEqual(seedDemo.SEEDED_HABITS.map((h) => h.name).sort(), Object.keys(PATTERNS).sort());
    assert.deepEqual(addOnly.ADDED_HABITS.map((h) => h.name), ["Water", "Stretch"]);
  });

  it("fills a count habit at its target, Stretch on its weekdays only, and nothing for a habit the reviewer made", () => {
    const db = scratchDb();
    const now = new Date("2026-10-10T10:00:00.000Z");
    legacyAccount(db, { now });
    assert.equal(addOnly.addHabits(db, { now }).status, 0);
    const entriesBefore = snapshot(db).habit_entries.length;
    for (let n = 1; n <= 20; n++) assert.equal(topup.topUp(db, { now: new Date(now.getTime() + n * DAY_MS) }).status, 0);
    const water = habitRow(db, "Water"), stretch = habitRow(db, "Stretch");
    const after = entriesOf(db, water.id).filter((e) => e.date > "2026-10-10");
    assert.ok(after.length > 0);
    for (const e of after) assert.equal(e.value, 8, e.date);
    const stretched = entriesOf(db, stretch.id).filter((e) => e.date > "2026-10-10");
    assert.ok(stretched.length >= 8);
    for (const e of stretched) assert.ok([1, 3, 5].includes(weekdayOf(e.date)), e.date);
    assert.equal(entriesOf(db, fixedId("legacy|reviewer-habit")).length, 1);
    assert.ok(snapshot(db).habit_entries.length > entriesBefore);
  });
});

describe("no entry is dated after the Los Angeles day", () => {
  it("seed-demo.js, at the cron's 03:50 UTC: the newest check-in is the 15th, not the UTC 16th", () => {
    const db = scratchDb();
    seedDemo.seed(db, { token: "t".repeat(48), now: CRON_NIGHT });
    assert.equal(db.prepare("SELECT max(date) AS d FROM habit_entries").get().d, "2026-10-15");
    assert.equal(db.prepare("SELECT min(date) AS d FROM habit_entries").get().d, "2026-07-18"); // 90 days
  });

  it("demo-add-habits.js, at the cron's 03:50 UTC", () => {
    const db = scratchDb();
    legacyAccount(db, { now: new Date("2026-10-15T20:00:00.000Z") });
    assert.equal(addOnly.addHabits(db, { now: CRON_NIGHT }).status, 0);
    for (const name of ["Water", "Stretch"]) {
      const rows = entriesOf(db, habitRow(db, name).id);
      assert.ok(rows.every((e) => e.date <= "2026-10-15"), name);
      assert.ok(rows.every((e) => e.date >= "2026-07-18"), name);
    }
  });

  it("demo-topup.js fills through the Los Angeles day, and the UTC day only the night after", () => {
    const db = scratchDb();
    legacyAccount(db, { now: new Date("2026-10-10T10:00:00.000Z") });
    const r = topup.topUp(db, { now: CRON_NIGHT });
    assert.equal(r.status, 0);
    assert.match(r.line, /\.\.2026-10-15\)/);
    assert.equal(db.prepare("SELECT max(date) AS d FROM habit_entries").get().d <= "2026-10-15", true);
    assert.equal(db.prepare("SELECT count(*) AS n FROM habit_entries WHERE date > '2026-10-15'").get().n, 0);
    topup.topUp(db, { now: new Date("2026-10-17T03:50:00.000Z") });
    assert.equal(db.prepare("SELECT count(*) AS n FROM habit_entries WHERE date > '2026-10-16'").get().n, 0);
    assert.ok(db.prepare("SELECT count(*) AS n FROM habit_entries WHERE date = '2026-10-16'").get().n > 0);
  });
});

describe("a reviewer's un-check stays un-checked, and costs no other habit a day", () => {
  /** A fresh seed on 2026-10-01 and the cron's runs since, through UTC `through`. */
  const seeded = (through) => {
    const db = scratchDb();
    seedDemo.seed(db, { token: "u".repeat(48), now: new Date("2026-10-01T20:00:00.000Z") });
    nights(db, "2026-10-02", through);
    assert.deepEqual(offRule(db, "2026-10-02", entryDayCap(night(through))), [], "the seed and the nights follow the rules");
    return db;
  };
  // A daily habit other than Journal that the rule checks on Tuesday 2026-10-20.
  const own = SIX.find((n) => n !== "Journal" && isChecked(PATTERNS[n], "2026-10-20"));

  for (const [when, at] of [["11:00 PDT (18:00 UTC)", "2026-10-20T18:00:00.000Z"], ["19:00 PDT (02:00 UTC, before the 03:50 run)", "2026-10-21T02:00:00.000Z"]]) {
    it(`on Tuesday 2026-10-20 at ${when}: the next two runs write every rule day around it but the un-checked ones`, () => {
      const db = seeded("2026-10-20"); // the 03:50 UTC run of the 20th wrote through Monday the 19th (Los Angeles)
      const journal = habitRow(db, "Journal").id;
      const lastJournal = newestDay(db, journal, "2026-10-19");
      // Journal's newest check-in un-checked; and the reviewer's own tick of today, un-ticked.
      uncheck(db, journal, lastJournal, new Date(at));
      checkIn(db, habitRow(db, own).id, "2026-10-20", new Date(Date.parse(at) - 3600_000));
      uncheck(db, habitRow(db, own).id, "2026-10-20", new Date(at));

      const lines = nights(db, "2026-10-21", "2026-10-22"); // through Wednesday the 21st
      assert.deepEqual(offRule(db, "2026-10-12", "2026-10-21").sort(),
        [`Journal ${lastJournal} empty`, `${own} 2026-10-20 empty`].sort());
      assert.match(lines[0], new RegExp(`un-checked days kept: .*Journal through ${lastJournal}`));
      // Stretch keeps three in the week of Monday the 19th (Monday, Wednesday and, after Friday's run, Friday).
      nights(db, "2026-10-23", "2026-10-24");
      const stretch = entriesOf(db, habitRow(db, "Stretch").id).filter((e) => e.date >= "2026-10-19" && e.date <= "2026-10-25");
      assert.deepEqual(stretch.map((e) => e.date), ["2026-10-19", "2026-10-21", "2026-10-23"]);
    });
  }

  it("on Tuesday 2026-11-03 at 21:00 PST (05:00 UTC on the 4th): Wednesday the 4th is written for every other habit, and Stretch's week holds three", () => {
    const db = scratchDb();
    seedDemo.seed(db, { token: "v".repeat(48), now: new Date("2026-10-20T20:00:00.000Z") });
    nights(db, "2026-10-21", "2026-11-04"); // through Tuesday the 3rd (Los Angeles)
    const read = habitRow(db, "Read 30 Minutes").id;
    const lastRead = newestDay(db, read, "2026-11-03");
    uncheck(db, read, lastRead, new Date("2026-11-04T05:00:00.000Z"));
    nights(db, "2026-11-05", "2026-11-07"); // through Friday the 6th
    assert.deepEqual(offRule(db, "2026-10-28", "2026-11-06"), [`Read 30 Minutes ${lastRead} empty`]);
    const stretch = entriesOf(db, habitRow(db, "Stretch").id).filter((e) => e.date >= "2026-11-02" && e.date <= "2026-11-08");
    assert.deepEqual(stretch.map((e) => e.date), ["2026-11-02", "2026-11-04", "2026-11-06"]);
  });

  it("a tombstone that names no habit and day (its DELETE removed nothing: a retry, an id never pushed) costs no day", () => {
    const db = seeded("2026-10-20");
    const journal = habitRow(db, "Journal").id;
    const lastJournal = newestDay(db, journal, "2026-10-19");
    const at = new Date("2026-10-20T18:00:00.000Z");
    uncheck(db, journal, lastJournal, at);
    const add = db.prepare("INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, 'entry', ?, ?)");
    const retried = db.prepare("SELECT entity_id FROM deletion_tombstones WHERE habit_id IS NOT NULL").get().entity_id;
    add.run(demoUserId(db), retried, new Date(at.getTime() + 60_000).toISOString());                         // the retry
    add.run(demoUserId(db), crypto.randomUUID().toUpperCase(), new Date(at.getTime() + 120_000).toISOString()); // never pushed
    nights(db, "2026-10-21", "2026-10-22");
    assert.deepEqual(offRule(db, "2026-10-12", "2026-10-21"), [`Journal ${lastJournal} empty`]);
  });

  it("on an account filled before 1.4.1: nothing on or before the un-checked day is written again, though the rule there has changed", () => {
    const db = scratchDb();
    legacyAccount(db, { now: new Date("2026-10-20T10:00:00.000Z") });
    const before = new Map();
    let reread = 0; // days the in-order rule checks between a habit's previous check-in and the un-checked one
    for (const name of SIX) {
      const id = fixedId(`legacy|${name}`);
      const dates = entriesOf(db, id).map((e) => e.date);
      const last = dates[dates.length - 1], previous = dates[dates.length - 2];
      for (let d = addDays(previous, 1); d <= last; d = addDays(d, 1)) if (isChecked(PATTERNS[name], d)) reread++;
      uncheck(db, id, last, new Date("2026-10-20T18:00:00.000Z"));
      before.set(name, { id, last, kept: dates.slice(0, -1) });
    }
    assert.ok(reread > 0, "the floor is what keeps those days");
    nights(db, "2026-10-21", "2026-10-26");
    for (const [name, { id, last, kept }] of before) {
      const dates = entriesOf(db, id).map((e) => e.date);
      assert.deepEqual(dates.filter((d) => d <= last), kept, name);
      assert.ok(dates.some((d) => d > last), `${name} is still filled after ${last}`);
    }
  });
});

describe("which habits the top-up fills: the demo scripts', by identity", () => {
  const now = new Date("2026-10-20T10:00:00.000Z");
  /** A reviewer's habit from an earlier review: a random id, created `daysAgo` days before `now`. */
  const reviewerHabit = (db, name, columns = {}, daysAgo = 40) => {
    const id = crypto.randomUUID().toUpperCase();
    const at = new Date(now.getTime() - daysAgo * DAY_MS).toISOString();
    const c = { kind: "binary", target_value: 1, schedule_kind: "daily", times_per_week: 7, ...columns };
    db.prepare(`INSERT INTO habits (id, user_id, name, kind, target_value, schedule_kind, times_per_week, created_at, updated_at, client_updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(id, demoUserId(db), name, c.kind, c.target_value, c.schedule_kind, c.times_per_week, at, at, at);
    return id;
  };

  it("a reviewer's own daily \"Stretch\" (the template) from an earlier review: demo-add-habits.js leaves it alone, and so does the top-up", () => {
    const db = scratchDb();
    legacyAccount(db, { now });
    const theirs = reviewerHabit(db, "Stretch");
    assert.deepEqual(addOnly.addHabits(db, { now }).added, ["Water"]);
    nights(db, "2026-10-21", "2026-11-05");
    assert.equal(entriesOf(db, theirs).length, 0);
    assert.ok(entriesOf(db, habitRow(db, "Water").id).some((e) => e.date > "2026-10-20"));
  });

  it("a reviewer's \"Stretch\" made 3 times a week, or \"Water\" of 8, has no demo id, so gets nothing either", () => {
    const db = scratchDb();
    legacyAccount(db, { now });
    const ids = [reviewerHabit(db, "Stretch", { schedule_kind: "timesPerWeek", times_per_week: 3 }),
      reviewerHabit(db, "Water", { kind: "count", target_value: 8 })];
    assert.deepEqual(addOnly.addHabits(db, { now }).added, []);
    const line = nights(db, "2026-10-21", "2026-10-28").pop();
    for (const id of ids) assert.equal(entriesOf(db, id).length, 0);
    assert.match(line, /; 3 habit\(s\) not from the demo scripts left alone/); // and Read Fiction
  });

  it("beside the six seeded before 1.4.1 (one created_at for all six), a reviewer's own \"Meditate\" from an earlier review is left alone", () => {
    const db = scratchDb();
    legacyAccount(db, { now });
    const theirs = reviewerHabit(db, "Meditate");
    checkIn(db, theirs, "2026-10-01", now);
    nights(db, "2026-10-21", "2026-10-31");
    assert.deepEqual(entriesOf(db, theirs).map((e) => e.date), ["2026-10-01"]);
    for (const name of SIX) assert.ok(entriesOf(db, fixedId(`legacy|${name}`)).some((e) => e.date > "2026-10-20"), name);
  });

  it("after a re-seed only demo ids count: a reviewer's \"Morning Run\" older than the window gets nothing", () => {
    const db = scratchDb();
    seedDemo.seed(db, { token: "w".repeat(48), now: new Date("2026-09-01T20:00:00.000Z") });
    const theirs = reviewerHabit(db, "Morning Run", {}, 45);
    nights(db, "2026-09-02", "2026-10-21");
    assert.equal(entriesOf(db, theirs).length, 0);
    assert.deepEqual(offRule(db, "2026-09-02", "2026-10-20"), []);
  });

  it("a demo habit the reviewer has changed (Water's target, Stretch's schedule, Journal made a count) is theirs from then on", () => {
    const db = scratchDb();
    seedDemo.seed(db, { token: "x".repeat(48), now: new Date("2026-09-20T20:00:00.000Z") });
    nights(db, "2026-09-21", "2026-10-10");
    db.prepare("UPDATE habits SET target_value = 10 WHERE name = 'Water'").run();
    db.prepare("UPDATE habits SET schedule_kind = 'daily' WHERE name = 'Stretch'").run();
    db.prepare("UPDATE habits SET kind = 'count', target_value = 3 WHERE name = 'Journal'").run();
    const line = nights(db, "2026-10-11", "2026-10-20").pop();
    for (const name of ["Water", "Stretch", "Journal"]) {
      assert.ok(entriesOf(db, habitRow(db, name).id).every((e) => e.date <= "2026-10-09"), name);
    }
    assert.match(line, /; 3 habit\(s\) not from the demo scripts left alone/);
    assert.deepEqual(offRule(db, "2026-10-10", "2026-10-19").filter((d) => !/^(Water|Stretch|Journal) /.test(d)), []);
  });

  it("--dry-run reports exactly what a run would add, and writes nothing", () => {
    const db = scratchDb();
    seedDemo.seed(db, { token: "y".repeat(48), now: new Date("2026-10-01T20:00:00.000Z") });
    const rows = snapshot(db);
    const dry = topup.topUp(db, { now: night("2026-10-05"), dryRun: true });
    assert.deepEqual(snapshot(db), rows);
    const real = topup.topUp(db, { now: night("2026-10-05") });
    assert.ok(real.added > 0);
    assert.equal(dry.line.replace(" DRY RUN", ""), real.line);
  });
});

describe("ops/demo-add-habits.js on the live account's shape (run as on the host)", () => {
  let dir, file, beforeRows, first;
  const open = () => new Database(file);

  it("adds Water and Stretch, and leaves every row that was there as it was: sessions, tokens, tombstones, habits, check-ins", async () => {
    dir = await copyWithSchema();
    file = path.join(dir, "stride.db");
    let db = open();
    legacyAccount(db, { now: new Date() });
    beforeRows = snapshot(db);
    db.close();

    first = await run(dir, "ops/demo-add-habits.js");
    assert.equal(first.status, 0, first.stderr);
    assert.match(first.stdout, /^\[demo-add-habits\] \S+ 2 habit\(s\) added — Water \+\d+ check-ins .*, Stretch \+\d+ check-ins /);

    db = open();
    const now = snapshot(db);
    db.close();
    for (const table of ["users", "sessions", "magic_link_tokens", "deletion_tombstones", "habit_groups"]) {
      assert.deepEqual(now[table], beforeRows[table], table);
    }
    const added = now.habits.filter((h) => !beforeRows.habits.some((b) => b.id === h.id));
    assert.deepEqual(added.map((h) => h.name).sort(), ["Stretch", "Water"]);
    assert.deepEqual(now.habits.filter((h) => beforeRows.habits.some((b) => b.id === h.id)), beforeRows.habits);
    const addedIds = new Set(added.map((h) => h.id));
    assert.deepEqual(now.habit_entries.filter((e) => !addedIds.has(e.habit_id)), beforeRows.habit_entries);
    // After the account's own habits, in the order of ADDED_HABITS.
    const maxSort = Math.max(...beforeRows.habits.map((h) => h.sort_order));
    assert.deepEqual(added.sort((a, b) => a.sort_order - b.sort_order).map((h) => [h.name, h.sort_order]),
      [["Water", maxSort + 1], ["Stretch", maxSort + 2]]);
  });

  it("a second run adds nothing and exits 0", async () => {
    let db = open();
    const once = snapshot(db);
    db.close();
    const again = await run(dir, "ops/demo-add-habits.js");
    assert.equal(again.status, 0, again.stderr);
    assert.match(again.stdout, /0 habit\(s\) added — Water already there, left alone, Stretch already there, left alone/);
    db = open();
    assert.deepEqual(snapshot(db), once);
    db.close();
  });

  it("--dry-run reports and writes nothing", async () => {
    const db = scratchDb();
    legacyAccount(db, { now: new Date() });
    const rowsBefore = snapshot(db);
    const r = addOnly.addHabits(db, { dryRun: true });
    assert.equal(r.status, 0);
    assert.match(r.line, / DRY RUN 2 habit\(s\) added — Water \+84 check-ins \(/);
    assert.deepEqual(snapshot(db), rowsBefore);
  });

  it("exits 1 without the demo account, and writes nothing", async () => {
    const empty = await copyWithSchema();
    const r = await run(empty, "ops/demo-add-habits.js");
    assert.equal(r.status, 1);
    assert.match(r.stderr, /no demo@stride-review\.com account — run seed-demo\.js first/);
    const db = new Database(path.join(empty, "stride.db"), { readonly: true });
    assert.equal(db.prepare("SELECT count(*) AS n FROM habits").get().n, 0);
    db.close();
  });

  it("leaves alone a habit of either name the account already has, archived or not", () => {
    const db = scratchDb();
    const { userId } = legacyAccount(db, { now: new Date() });
    db.prepare("INSERT INTO habits (id, user_id, name, is_archived) VALUES (?, ?, 'Water', 1)").run(fixedId("own water"), userId);
    const r = addOnly.addHabits(db, {});
    assert.deepEqual(r.added, ["Stretch"]);
    assert.equal(db.prepare("SELECT count(*) AS n FROM habits WHERE name = 'Water'").get().n, 1);
    assert.equal(entriesOf(db, fixedId("own water")).length, 0);
  });
});

describe("the rows demo-add-habits.js writes", () => {
  const now = new Date("2026-10-15T09:30:00.000Z");
  let db;
  before(() => {
    db = scratchDb();
    legacyAccount(db, { now: new Date("2026-10-15T05:00:00.000Z") });
    assert.equal(addOnly.addHabits(db, { now }).status, 0);
  });

  it("every column the pull serves, as the app stores it", () => {
    const pick = (h) => ({ kind: h.kind, target_value: h.target_value, unit: h.unit, schedule_kind: h.schedule_kind,
      times_per_week: h.times_per_week, active_days_mask: h.active_days_mask, is_archived: h.is_archived,
      group_id: h.group_id, note: h.note, reminder_enabled: h.reminder_enabled });
    assert.deepEqual(pick(habitRow(db, "Water")), { kind: "count", target_value: 8, unit: "glasses", schedule_kind: "daily",
      times_per_week: 7, active_days_mask: 127, is_archived: 0, group_id: null, note: null, reminder_enabled: 0 });
    assert.deepEqual(pick(habitRow(db, "Stretch")), { kind: "binary", target_value: 1, unit: null, schedule_kind: "timesPerWeek",
      times_per_week: 3, active_days_mask: 127, is_archived: 0, group_id: null, note: null, reminder_enabled: 0 });
  });

  it("created_at 91 days back, before the first check-in in any zone; updated_at = client_updated_at = now; upper-case ids, the habit's its demo id", () => {
    for (const name of ["Water", "Stretch"]) {
      const h = habitRow(db, name);
      assert.equal(h.created_at, new Date(now.getTime() - 91 * DAY_MS).toISOString());
      assert.equal(h.id, demoHabitId(h.user_id, name, h.created_at));
      assert.equal(h.updated_at, now.toISOString());
      assert.equal(h.client_updated_at, now.toISOString());
      assert.match(h.id, UPPER_UUID);
      const rows = entriesOf(db, h.id);
      // created_at's date in UTC+14 is still before the first day of history.
      const createdLatestZone = new Date(Date.parse(h.created_at) + 14 * 3600 * 1000).toISOString().slice(0, 10);
      assert.ok(createdLatestZone < rows[0].date, `${name}: created ${createdLatestZone}, first ${rows[0].date}`);
      assert.ok(rows[0].date >= "2026-07-18" && rows[rows.length - 1].date <= "2026-10-15");
      for (const e of rows) {
        assert.match(e.id, UPPER_UUID);
        assert.equal(e.updated_at, now.toISOString());
        assert.equal(e.client_updated_at, now.toISOString());
        assert.equal(e.created_at, now.toISOString());
      }
    }
  });

  it("no value-0 row; three notes each, every one on a check-in; Water's values from its cycle; Stretch on Mon/Wed/Fri", () => {
    const water = entriesOf(db, habitRow(db, "Water").id);
    const stretch = entriesOf(db, habitRow(db, "Stretch").id);
    for (const e of [...water, ...stretch]) assert.ok(e.value >= 1, `${e.date} ${e.value}`);
    assert.equal(water.filter((e) => e.note).length, 3);
    assert.equal(stretch.filter((e) => e.note).length, 3);
    const byDate = new Map(water.map((e) => [e.date, e]));
    for (let i = 0; i < 90; i++) {
      const date = addDays("2026-10-15", i - 89);
      const v = addOnly.WATER_VALUES[patternIndex(date)];
      assert.equal(byDate.get(date)?.value ?? 0, v, date);
    }
    // The notes say what the day shows.
    assert.equal(water.find((e) => e.note === "Hot day, two extra glasses").value, 10);
    assert.ok(water.find((e) => e.note === "Left my bottle at home").value < 8);
    assert.ok(stretch.every((e) => [1, 3, 5].includes(weekdayOf(e.date))));
    assert.equal(stretch.length, 38);
  });
});

describe("seed-demo.js and demo-add-habits.js agree", () => {
  const now = new Date("2026-10-15T09:30:00.000Z");
  let seeded, added;
  before(() => {
    seeded = scratchDb();
    seedDemo.seed(seeded, { token: "s".repeat(48), now });
    added = scratchDb();
    legacyAccount(added, { now: new Date("2026-10-15T05:00:00.000Z") });
    addOnly.addHabits(added, { now });
  });

  it("Water and Stretch are the same rows either way, apart from ids, owner and sort order", () => {
    const habit = (db, name) => { const { id, user_id, sort_order, ...rest } = habitRow(db, name); return rest; };
    const rows = (db, name) => entriesOf(db, habitRow(db, name).id).map(({ id, habit_id, ...rest }) => rest);
    for (const name of ["Water", "Stretch"]) {
      assert.deepEqual(habit(seeded, name), habit(added, name), name);
      assert.deepEqual(rows(seeded, name), rows(added, name), name);
    }
  });

  it("every seeded habit has every column filled, 90 days of its pattern in order, created 91 days back, its demo id", () => {
    const habits = seeded.prepare("SELECT * FROM habits ORDER BY sort_order").all();
    assert.deepEqual(habits.map((h) => h.name), [...SIX, "Water", "Stretch"]);
    for (const h of habits) {
      assert.equal(h.id, demoHabitId(h.user_id, h.name, h.created_at), h.name);
      assert.ok(topup.hasShape(h), h.name);
    }
    for (const h of habits.slice(0, 6)) {
      assert.deepEqual([h.kind, h.target_value, h.unit, h.schedule_kind, h.times_per_week, h.active_days_mask],
        ["binary", 1, null, "daily", 7, 127], h.name);
      assert.equal(h.created_at, new Date(now.getTime() - 91 * DAY_MS).toISOString());
      assert.equal(h.client_updated_at, now.toISOString());
      const dates = new Set(entriesOf(seeded, h.id).map((e) => e.date));
      const pattern = /** @type {number[]} */ (PATTERNS[h.name]);
      for (let i = 0; i < 90; i++) {
        const date = addDays("2026-10-15", i - 89);
        assert.equal(dates.has(date), pattern[patternIndex(date)] === 1, `${h.name} ${date}`);
      }
    }
  });

  it("a re-seed clears tombstones, tokens and sessions, and replaces the habits under new ids", () => {
    const db = scratchDb();
    const { userId } = legacyAccount(db, { now });
    const oldIds = new Set(db.prepare("SELECT id FROM habits").all().map((r) => r.id));
    seedDemo.seed(db, { token: "r".repeat(48), now });
    for (const table of ["sessions", "deletion_tombstones"]) {
      assert.equal(db.prepare(`SELECT count(*) AS n FROM ${table} WHERE user_id = ?`).get(userId).n, 0, table);
    }
    assert.deepEqual(db.prepare("SELECT token_hash FROM magic_link_tokens").all().map((r) => r.token_hash), [sha256("r".repeat(48))]);
    const ids = db.prepare("SELECT id FROM habits").all().map((r) => r.id);
    assert.equal(ids.length, 8);
    assert.ok(ids.every((id) => !oldIds.has(id) && UPPER_UUID.test(id)));
  });
});

describe("seed-demo.js's login token (run as on the host)", () => {
  const TOKEN_LINE = /^ {2}Token: ([0-9a-f]{16,})$/m; // scripts/sim_e2e/seed-demo.sh's sed pattern

  it("DEMO_TOKEN is installed and never printed", async () => {
    const dir = await copyWithSchema();
    const token = crypto.randomBytes(24).toString("hex");
    const r = await run(dir, "seed-demo.js", [], scriptEnv({ DEMO_TOKEN: token }));
    assert.equal(r.status, 0, r.stderr);
    assert.ok(!r.stdout.includes(token) && !r.stderr.includes(token), "the token is printed");
    assert.doesNotMatch(r.stdout, TOKEN_LINE);
    assert.match(r.stdout, /^ {2}Token: DEMO_TOKEN from the environment \(not printed\)$/m);
    const db = new Database(path.join(dir, "stride.db"), { readonly: true });
    assert.deepEqual(db.prepare("SELECT token_hash, is_reusable FROM magic_link_tokens").all().map((r) => ({ ...r })),
      [{ token_hash: sha256(token), is_reusable: 1 }]);
    db.close();
  });

  it("without DEMO_TOKEN it refuses before writing anything", async () => {
    const dir = serverCopy();
    const r = await run(dir, "seed-demo.js");
    assert.equal(r.status, 2);
    assert.match(r.stderr, /DEMO_TOKEN is not set\. .* Nothing was written\./);
    assert.equal(fs.existsSync(path.join(dir, "stride.db")), false, "not even the database was opened");
  });

  it("--print-token, and NODE_ENV=test as the sim kit runs it, print the generated token in the line seed-demo.sh reads", async () => {
    for (const [args, env] of [[["--print-token"], scriptEnv()], [[], scriptEnv({ NODE_ENV: "test" })]]) {
      const dir = await copyWithSchema();
      const r = await run(dir, "seed-demo.js", args, env);
      assert.equal(r.status, 0, r.stderr);
      const token = r.stdout.match(TOKEN_LINE)?.[1];
      assert.ok(token, r.stdout);
      const db = new Database(path.join(dir, "stride.db"), { readonly: true });
      assert.equal(db.prepare("SELECT token_hash FROM magic_link_tokens").get().token_hash, sha256(token));
      assert.equal(db.prepare("SELECT count(*) AS n FROM habits").get().n, 8);
      db.close();
    }
  });
});

describe("a signed-in reviewer across demo-add-habits.js, on the real server (a copy)", () => {
  let dir, server, sessionToken, cursor;
  const V140 = "ios/1.4.0(22)";
  const BASE = `http://127.0.0.1:${PORT}`;
  const pauseFile = path.join(os.tmpdir(), `stride-demo-scripts-SYNC_PAUSED-${process.pid}`);
  const api = (p, { method = "GET", token = sessionToken, body } = {}) => fetch(`${BASE}${p}`, {
    method,
    headers: { "Content-Type": "application/json", "X-Stride-Client": V140, ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });

  before(async () => {
    dir = await copyWithSchema();
    const db = new Database(path.join(dir, "stride.db"));
    const { token } = legacyAccount(db, { now: new Date() });
    db.close();
    const env = scriptEnv({ PORT: String(PORT), NODE_ENV: "test", SYNC_PAUSE_FILE: pauseFile, SENTRY_DSN: "", RESEND_API_KEY: "" });
    server = spawn(process.execPath, [path.join(dir, "index.js")], { cwd: dir, env, stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    server.stderr.on("data", (d) => { stderr += d; });
    const start = Date.now();
    for (;;) {
      try { if ((await fetch(`${BASE}/health`)).ok) break; } catch { /* not up yet */ }
      if (server.exitCode !== null || Date.now() - start > 60000) throw new Error(`server did not start: ${stderr}`);
      await new Promise((r) => setTimeout(r, 150));
    }
    const verify = await api("/v1/auth/verify", { method: "POST", token: null, body: { token } });
    assert.equal(verify.status, 200);
    sessionToken = (await verify.json()).sessionToken;
    const full = await (await api("/v1/sync/pull")).json();
    assert.equal(full.habits.length, 7);
    cursor = full.serverTime;
  });

  after(async () => {
    if (server && server.exitCode === null) await new Promise((resolve) => { server.once("exit", resolve); server.kill("SIGTERM"); });
    fs.rmSync(pauseFile, { force: true });
  });

  it("the session survives, and its next ?since pull carries Water and Stretch, in the shapes the app reads", async () => {
    await new Promise((r) => setTimeout(r, 5)); // the add-only's `now` is after the cursor
    const r = await run(dir, "ops/demo-add-habits.js");
    assert.equal(r.status, 0, r.stderr);

    assert.equal((await api("/v1/auth/session")).status, 200);
    const pull = await api(`/v1/sync/pull?since=${encodeURIComponent(cursor)}`);
    assert.equal(pull.status, 200);
    const body = await pull.json();
    assert.deepEqual(body.deletedHabitIds, []);
    assert.deepEqual(body.deletedEntryIds, []);
    const byName = Object.fromEntries(body.habits.map((h) => [h.name, h]));
    assert.deepEqual(Object.keys(byName).sort(), ["Stretch", "Water"]);
    const shape = (h) => ({ kind: h.kind, targetValue: h.targetValue, unit: h.unit, scheduleKind: h.scheduleKind,
      timesPerWeek: h.timesPerWeek, activeDaysMask: h.activeDaysMask, isArchived: h.isArchived, groupId: h.groupId });
    assert.deepEqual(shape(byName.Water), { kind: "count", targetValue: 8, unit: "glasses", scheduleKind: "daily",
      timesPerWeek: 7, activeDaysMask: 127, isArchived: false, groupId: null });
    assert.deepEqual(shape(byName.Stretch), { kind: "binary", targetValue: 1, unit: null, scheduleKind: "timesPerWeek",
      timesPerWeek: 3, activeDaysMask: 127, isArchived: false, groupId: null });
    const ids = new Set([byName.Water.id, byName.Stretch.id]);
    assert.ok(body.entries.length > 100);
    assert.ok(body.entries.every((e) => ids.has(e.habitId)), "only the new habits' check-ins are new");
    const water = body.entries.filter((e) => e.habitId === byName.Water.id);
    assert.ok(water.some((e) => e.value < 8 && e.note === "Left my bottle at home"));
    for (const h of [byName.Water, byName.Stretch]) {
      const first = body.entries.filter((e) => e.habitId === h.id).map((e) => e.date).sort()[0];
      assert.ok(h.createdAt.slice(0, 10) < first, `${h.name} created ${h.createdAt}, first check-in ${first}`);
    }
  });

  it("a full pull afterwards: totals equal the arrays, every check-in's habit is in it, every id upper case", async () => {
    const body = await (await api("/v1/sync/pull")).json();
    assert.deepEqual(body.totals, { habits: body.habits.length, entries: body.entries.length, groups: body.groups.length });
    assert.equal(body.habits.length, 9);
    const habitIds = new Set(body.habits.map((h) => h.id));
    assert.ok(body.entries.every((e) => habitIds.has(e.habitId)));
    assert.ok([...body.habits, ...body.entries].every((r) => UPPER_UUID.test(r.id)));
    const days = new Set(body.entries.map((e) => `${e.habitId}|${e.date}`));
    assert.equal(days.size, body.entries.length, "one check-in per habit and day");
  });
});

describe("gate 2: strength (Shared/HabitScore.swift, ported)", () => {
  const binary = { kind: "binary", target_value: 1, schedule_kind: "daily", times_per_week: 7, active_days_mask: 127 };
  /** `days` days of `pattern`, repeated, ending on day 120 with the pattern's last day (HabitScoreTests). */
  const seedStrength = (pattern, days) => {
    const today = "2026-05-01";
    const entries = [];
    for (let i = 0; i < days; i++) if (pattern[i % 30]) entries.push({ date: addDays(today, i - (days - 1)), value: 1 });
    return strengthOf({ ...binary, created_at: `${addDays(today, -(days + 15))}T00:00:00.000Z` }, entries, today).score;
  };

  it("the port reproduces HabitScoreTests' reference values", () => {
    const perfect = (n) => seedStrength(Array(30).fill(1), n);
    assert.ok(Math.abs(perfect(30) - 0.798) < 0.0005);
    assert.ok(Math.abs(perfect(100) - 0.995) < 0.0005);
    assert.ok(Math.abs(seedStrength(PATTERNS["Read 30 Minutes"], 30) - 0.716) < 0.0005);
    assert.ok(Math.abs(seedStrength(PATTERNS.Journal, 30) - 0.711) < 0.0005);
    assert.ok(Math.abs(seedStrength(PATTERNS["Read 30 Minutes"], 90) - 0.890) < 0.0005);
    assert.ok(Math.abs(seedStrength(PATTERNS.Journal, 90) - 0.883) < 0.0005);
    // One miss after 60 days costs 4.98 points.
    const sixty = Array.from({ length: 60 }, (_, i) => ({ date: addDays("2026-05-01", i), value: 1 }));
    const h = { ...binary, created_at: "2026-05-01T00:00:00.000Z" };
    const lost = strengthOf(h, sixty, addDays("2026-05-01", 59)).score - strengthOf(h, sixty, addDays("2026-05-01", 61)).score;
    assert.ok(Math.abs(lost * 100 - 4.98) < 0.005, String(lost));
  });

  it("a full seed on any of 30 days in a row: on seed day and the two days after (before the next run), only Read 30 Minutes and Journal are done on 25 of 30, each at 0.75 or more", () => {
    const min = { "Read 30 Minutes": 1, "Journal": 1 };
    for (let k = 0; k < 30; k++) {
      const day = addDays("2026-10-15", k);
      const db = scratchDb();
      seedDemo.seed(db, { token: "g".repeat(48), now: new Date(`${day}T20:00:00.000Z`) });
      for (const today of [day, addDays(day, 1), addDays(day, 2)]) {
        for (const r of gate2(db, today).filter((x) => x.done30 >= 25)) {
          assert.ok(r.name in min, `${day}: ${r.name} done on ${r.done30} of 30`);
          assert.ok(r.score >= 0.75, `seeded ${day}, ${today}: ${r.name} ${r.score.toFixed(3)} (${r.done30}/30)`);
          min[r.name] = Math.min(min[r.name], r.score);
        }
      }
      db.close();
    }
    // What seed-demo.js's header says (the lowest over seed day and the two days after).
    assert.ok(min["Read 30 Minutes"] >= 0.81 && min.Journal >= 0.79, JSON.stringify(min));
  });

  // Checks between the run on UTC `day` and the next: Tokyo at 15:00 that day, Los Angeles at
  // about noon, and Tokyo at 10:00 the next day (before the 12:50 JST run).
  const checkTimes = (day) => [["Asia/Tokyo", `${day}T06:00:00.000Z`], ["America/Los_Angeles", `${day}T19:30:00.000Z`],
    ["Asia/Tokyo", `${addDays(day, 1)}T01:00:00.000Z`]];
  /** Run the cron for `days` nights after `deployDay`, checking gate 2 between runs; the failures, with the day. */
  const sixtyNights = (db, deployDay, days, lines) => {
    const failures = [];
    for (let k = 1; k <= days; k++) {
      const day = addDays(deployDay, k);
      lines.push(...nights(db, day, day));
      for (const [zone, iso] of checkTimes(day)) {
        const today = dayIn(new Date(iso), zone);
        for (const r of gate2(db, today)) {
          if (r.done30 >= 25 && r.score < 0.75) failures.push(`night ${k} ${zone} ${today}: ${r.name} ${r.score.toFixed(3)} (${r.done30}/30)`);
        }
      }
    }
    return failures;
  };

  it("60 nights after the deploy, on production's shape (seeded 2026-09-16, filled before 1.4.1 by hash) for six sets of habit ids: gate 2 holds from the second night on", () => {
    let held = 0;
    for (const label of ["p1", "p2", "p3", "p4", "p5", "p6"]) {
      const db = scratchDb();
      const deploy = new Date("2026-10-20T10:00:00.000Z");
      legacyAccount(db, { now: deploy, seedDay: "2026-09-16", label });
      assert.deepEqual(addOnly.addHabits(db, { now: deploy }).added, ["Water", "Stretch"]);
      const lines = [];
      // The first night writes nothing new: the pre-1.4.1 run of the 20th had written through the UTC 20th.
      const failures = sixtyNights(db, "2026-10-20", 60, lines).filter((f) => !f.startsWith("night 1 "));
      assert.deepEqual(failures, [], label);
      held += lines.filter((l) => / held below gate 2/.test(l)).length;
      db.close();
    }
    assert.ok(held > 0, "the hash-picked days made the top-up hold a day below gate 2 somewhere");
  });

  it("60 nights after a full seed: gate 2 holds every night, nothing is ever held, and every day follows its rule", () => {
    const db = scratchDb();
    seedDemo.seed(db, { token: "h".repeat(48), now: new Date("2026-10-20T10:00:00.000Z") });
    const lines = [];
    assert.deepEqual(sixtyNights(db, "2026-10-20", 60, lines), []);
    assert.ok(lines.every((l) => !/ held /.test(l)));
    assert.deepEqual(offRule(db, "2026-07-23", "2026-12-18"), []);
  });

  it("a habit whose rule stays under 25 of 30 is not written to 25 (the 29 days before hold 24), and is when they hold 23 or, past the gate already, 25", () => {
    let day = "2026-11-10";
    while (!isChecked(PATTERNS["Morning Run"], day)) day = addDays(day, 1);
    for (const [held, expectWritten] of [[24, false], [23, true], [25, true]]) {
      const db = scratchDb();
      seedDemo.seed(db, { token: "i".repeat(48), now: new Date(`${addDays(day, -40)}T20:00:00.000Z`) });
      nights(db, addDays(day, -39), day); // through the day before `day` (Los Angeles)
      const run = habitRow(db, "Morning Run").id;
      // Its 29 days before `day`: `held` done days, the last of them the day before.
      db.prepare("DELETE FROM habit_entries WHERE habit_id = ? AND date >= ?").run(run, addDays(day, -29));
      for (let k = 1; k <= held; k++) checkIn(db, run, addDays(day, -k), night(day));
      const r = topup.topUp(db, { now: night(addDays(day, 1)) }); // the run that writes `day`
      assert.equal(entriesOf(db, run).some((e) => e.date === day), expectWritten, `${held}: ${r.line}`);
      if (!expectWritten) assert.match(r.line, /Morning Run \+0 \([^)]*, 1 held below gate 2\)/);
      db.close();
    }
  });

  it("after demo-add-habits.js, Water and Stretch read as strong habits (above gate 2's bar either way)", () => {
    const db = scratchDb();
    legacyAccount(db, { now: new Date("2026-10-15T05:00:00.000Z") });
    addOnly.addHabits(db, { now: new Date("2026-10-15T09:30:00.000Z") });
    const rows = Object.fromEntries(gate2(db, "2026-10-15").map((r) => [r.name, r]));
    assert.ok(rows.Water.score >= 0.75, String(rows.Water.score));
    assert.equal(rows.Water.done30, 24);
    assert.ok(rows.Stretch.score >= 0.75, String(rows.Stretch.score));
    assert.ok(rows.Stretch.done30 >= 12 && rows.Stretch.done30 <= 13);
  });
});
