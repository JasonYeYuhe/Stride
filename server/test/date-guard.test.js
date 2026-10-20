// Entry dates must be real Gregorian days near today (routes/sync.js entryDateOk; X2,
// docs/X2-non-gregorian-day-keys.md on m4/1.4.1, sections 5(c) and 5(d)).
//
// The refused keys are the ones X2 measured on 2026-10-15 in Tokyo, one per calendar: what every
// shipped build since 1.2.0 writes for that day on a device whose system calendar is not
// Gregorian (the key is built with the device calendar and formatted with a Gregorian one).
//
// Payloads are built the way the tagged apps' encoders build them (as test/legacy-guard.test.js):
//   1.2.3 / 1.3.0  v1.2.3, v1.3.0 SyncService.pushLocal: the full store, whole-second stamps,
//                  every entry with `updatedAt`; 1.3.0 adds the X-Stride-Client header.
//   1.3.1 / 1.4.0  v1.3.1 Shared/SyncPushPlanner.swift wireEntry: millisecond stamps, the header.
// Apps <= 1.2.2 send entries with no `updatedAt`, and are refused before this guard (legacyShape).

const { describe, it, before, after } = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const crypto = require("node:crypto");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");
const Database = require("better-sqlite3");

const PORT = 3095;
const BASE = `http://localhost:${PORT}`;
const DB_PATH = path.join(__dirname, "..", "stride.db");
const PAUSE_FILE = path.join(os.tmpdir(), `stride-test-SYNC_PAUSED-${process.pid}`);

const SENTENCE = "Stride can't sync some dates on this device. Update Stride from the App Store to keep syncing; nothing on this device was changed.";
const LEGACY_SENTENCE = "This version of Stride can no longer sync. Update Stride from the App Store to keep syncing; nothing on this device was changed.";
const V130 = "ios/1.3.0(18)";
const V131 = "ios/1.3.1(21)";
const V140 = "ios/1.4.0(22)";
const V140_MAC = "macos/1.4.0(22)";

/** The environment for a spawned test server (as test/api.test.js serverEnv). */
function serverEnv(port) {
  const env = { ...process.env, PORT: String(port), NODE_ENV: "test", SYNC_PAUSE_FILE: PAUSE_FILE };
  for (const k of ["SYNC_PAUSED", "SYNC_PAUSE_RETRY_AFTER_SECONDS", "SYNC_RATE_LIMIT_PER_MIN",
    "SYNC_AUTH_FAILURE_LIMIT_PER_15MIN", "GLOBAL_RATE_LIMIT_PER_15MIN", "STRIDE_TEST_HOOKS"]) delete env[k];
  for (const k of ["SENTRY_DSN", "SENTRY_TRACES_SAMPLE_RATE", "RESEND_API_KEY"]) env[k] = "";
  return env;
}

async function startServer(port) {
  const proc = spawn(process.execPath, [path.join(__dirname, "..", "index.js")], { env: serverEnv(port), stdio: "pipe" });
  const out = { stdout: "", stderr: "" };
  proc.stdout.on("data", (d) => { out.stdout += d; });
  proc.stderr.on("data", (d) => { out.stderr += d; });
  const start = Date.now();
  for (;;) {
    try { if ((await fetch(`http://localhost:${port}/health`)).ok) break; } catch { /* not up yet */ }
    if (Date.now() - start > Number(process.env.TEST_SERVER_START_TIMEOUT_MS || 60000)) throw new Error("server did not start");
    await new Promise((r) => setTimeout(r, 150));
  }
  return { proc, out };
}

async function stopServer(proc) {
  if (!proc || proc.exitCode !== null || proc.signalCode !== null) return;
  await new Promise((resolve) => { proc.once("exit", resolve); proc.kill("SIGTERM"); });
}

let server, db;

before(async () => {
  db = new Database(DB_PATH);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  fs.rmSync(PAUSE_FILE, { force: true });
  server = await startServer(PORT);
});

after(async () => {
  await stopServer(server?.proc);
  fs.rmSync(PAUSE_FILE, { force: true });
  if (db?.open) {
    cleanup();
    db.close();
  }
});

// ---------- accounts, requests, state ----------

const uuid = () => crypto.randomUUID().toUpperCase();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
/** A UTC day relative to the server's today, as YYYY-MM-DD. */
const utcDay = (offsetDays) => new Date(Date.now() + offsetDays * 86400000).toISOString().slice(0, 10);

const users = [];
function user() {
  const email = `date-guard-${crypto.randomUUID()}@stride-test.local`;
  db.prepare("INSERT INTO users (email) VALUES (?)").run(email);
  const { id: userId } = db.prepare("SELECT id FROM users WHERE email = ?").get(email);
  const token = crypto.randomBytes(32).toString("hex");
  db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)")
    .run(userId, crypto.createHash("sha256").update(token).digest("hex"), Date.now() + 86400000);
  users.push(userId);
  return { userId, email, token };
}

function cleanup() {
  for (const userId of users) {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userId);
    for (const t of ["habits", "habit_groups", "deletion_tombstones", "sync_snapshot_requests", "sessions"]) {
      db.prepare(`DELETE FROM ${t} WHERE user_id = ?`).run(userId);
    }
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  }
}

async function push(token, body, { client = null, mount = "/v1/sync/push", base = BASE } = {}) {
  const headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  if (client) headers["X-Stride-Client"] = client;
  const res = await fetch(`${base}${mount}`, { method: "POST", headers, body: JSON.stringify(body) });
  return { status: res.status, json: await res.json().catch(() => null) };
}

async function pull(token, { client = V140 } = {}) {
  const headers = { Authorization: `Bearer ${token}` };
  if (client) headers["X-Stride-Client"] = client;
  return (await fetch(`${BASE}/v1/sync/pull`, { headers })).json();
}

/** Everything this account has on the server, every column, tombstones included. */
function state(userId) {
  return {
    habits: db.prepare("SELECT * FROM habits WHERE user_id = ? ORDER BY id").all(userId),
    entries: db.prepare("SELECT * FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?) ORDER BY id").all(userId),
    groups: db.prepare("SELECT * FROM habit_groups WHERE user_id = ? ORDER BY id").all(userId),
    tombstones: db.prepare("SELECT * FROM deletion_tombstones WHERE user_id = ? ORDER BY id").all(userId),
  };
}

const entryById = (id) => db.prepare("SELECT id, habit_id, date, note, value FROM habit_entries WHERE id = ?").get(id);
const entryCount = (userId) =>
  db.prepare("SELECT COUNT(*) AS n FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").get(userId).n;

// ---------- the apps' encoders ----------

const habit = (id, over = {}) => ({
  id, name: "Water", emoji: "\u{1F4A7}", colorHex: "#007AFF", isArchived: false, sortOrder: 1790000000,
  reminderEnabled: false, reminderHour: 20, reminderMinute: 0, note: null,
  kind: "count", targetValue: 8, unit: "glasses", scheduleKind: "daily", timesPerWeek: 7, activeDaysMask: 127,
  groupId: null, createdAt: "2026-09-01T08:00:00.000Z", updatedAt: "2026-09-01T08:00:00.000Z", records: [], ...over,
});
/** `at` is the check-in's real instant: record.date is an instant, the key is derived from it. */
const record = (id, date, over = {}) => ({ id, date, note: null, value: 1, at: "2026-10-15T03:00:00.000Z", updatedAt: "2026-10-15T09:00:00.000Z", ...over });
const group = (id, over = {}) => ({ id, name: "Health", colorHex: "#FF9500", sortOrder: 1, createdAt: "2026-09-01T08:00:00.000Z", updatedAt: null, ...over });

const present = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== null && v !== undefined));
const whole = (iso) => new Date(iso).toISOString().replace(/\.\d{3}Z$/, "Z");
const millis = (iso) => new Date(iso).toISOString();

const wireHabit = (h, fmt) => present({
  id: h.id, name: h.name, emoji: h.emoji, colorHex: h.colorHex, isArchived: h.isArchived, sortOrder: h.sortOrder,
  reminderEnabled: h.reminderEnabled, reminderHour: h.reminderHour, reminderMinute: h.reminderMinute, note: h.note,
  kind: h.kind, targetValue: h.targetValue, unit: h.unit, scheduleKind: h.scheduleKind, timesPerWeek: h.timesPerWeek,
  activeDaysMask: h.activeDaysMask, groupId: h.groupId, createdAt: fmt(h.createdAt), updatedAt: fmt(h.updatedAt ?? h.createdAt),
});
const wireGroup = (g, fmt) => ({
  id: g.id, name: g.name, colorHex: g.colorHex, sortOrder: g.sortOrder, createdAt: fmt(g.createdAt), updatedAt: fmt(g.updatedAt ?? g.createdAt),
});
/** @param {(iso: string) => string} fmt */
const encoder = (fmt) => (store, q = {}) => ({
  habits: store.habits.map((h) => wireHabit(h, fmt)),
  entries: store.habits.flatMap((h) => h.records.map((r) => present({
    id: r.id, habitId: h.id, date: r.date, note: r.note, value: r.value, createdAt: fmt(r.at), updatedAt: fmt(r.updatedAt),
  }))),
  groups: (store.groups ?? []).map((g) => wireGroup(g, fmt)),
  deletedHabitIds: q.habits ?? [], deletedEntryIds: q.entries ?? [], deletedGroupIds: q.groups ?? [],
});
/** v1.2.3 and v1.3.0: the whole store, whole seconds. */
const encode123 = encoder(whole);
/** v1.3.1 / 1.4.0: the planner's wire mapping, milliseconds. */
const encode140 = encoder(millis);

/** An account the server already holds, from a 1.4.0 device: two habits, a group, two check-ins. */
async function seeded() {
  const u = user();
  const ids = { h1: uuid(), h2: uuid(), g1: uuid(), e1: uuid(), e2: uuid() };
  const store = {
    groups: [group(ids.g1)],
    habits: [
      habit(ids.h1, { name: "Read", records: [record(ids.e1, "2026-10-01", { updatedAt: "2026-10-01T21:00:00.000Z" })] }),
      habit(ids.h2, { groupId: ids.g1, records: [record(ids.e2, "2026-10-02", { note: "felt great", value: 6, updatedAt: "2026-10-02T21:00:00.000Z" })] }),
    ],
  };
  const r = await push(u.token, encode140(store), { client: V140 });
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.applied, { habits: 2, entries: 2, groups: 1 });
  return { u, ids, store };
}

/** A one-habit account, for the per-date cases. */
async function oneHabit() {
  const u = user();
  const h = uuid();
  const r = await push(u.token, encode140({ habits: [habit(h)] }), { client: V140 });
  assert.equal(r.status, 200);
  return { u, h };
}

function assertRefused(r, client) {
  assert.equal(r.status, 426);
  if (client) {
    assert.deepEqual(r.json, { error: "client_update_required", code: "client_update_required", message: SENTENCE });
  } else {
    assert.deepEqual(r.json, { error: SENTENCE, code: "client_update_required" },
      "the sentence in `error`: 1.2.3 prints it verbatim, and has no `message`");
  }
}

// ================================================================

/** X2 section 2: 2026-10-15 in Tokyo, as each calendar's device keys it. */
const CALENDAR_KEYS = [
  ["japanese", "0008-10-15"],
  ["buddhist", "2569-10-15"],
  ["roc", "0115-10-15"],
  ["islamicCivil", "1448-05-03"],
  ["islamicUmmAlQura", "1448-05-04"],
  ["islamic", "1448-05-05"],
  ["hebrew", "5787-02-04"],
  ["persian", "1405-07-23"],
  ["indian", "1948-07-23"],
  ["coptic", "1743-02-05"],
  ["ethiopicAmeteMihret", "2019-02-05"],
  ["ethiopicAmeteAlem", "7519-02-05"],
  ["chinese", "0043-09-06"],
];
const REFUSED = [
  ...CALENDAR_KEYS.map(([cal, key]) => [`${cal} key ${key}`, key]),
  ["no such day: 2026-02-30", "2026-02-30"],
  ["no such day: 2025-02-29 (not a leap year)", "2025-02-29"],
  ["no such month: 2026-13-01", "2026-13-01"],
  ["day zero: 2026-10-00", "2026-10-00"],
  ["not zero-padded: 2026-2-3", "2026-2-3"],
  ["a timestamp, not a day: 2026-10-15T00:00:00Z", "2026-10-15T00:00:00Z"],
  ["a leading space", " 2026-10-15"],
  ["a trailing newline", "2026-10-15\n"],
  ["full-width digits", "２０２６-１０-１５"],
  ["Arabic-Indic digits", "٢٠٢٦-١٠-١٥"],
  ["a number, not a string", 20261015],
  ["the day before the floor: 2024-12-31", "2024-12-31"],
  ["a real leap day before the floor: 2024-02-29", "2024-02-29"],
  ["a real leap day far past any ceiling: 2096-02-29", "2096-02-29"],
  ["today + 3 (UTC)", () => utcDay(3)],
];
const ACCEPTED = [
  ["the floor: 2025-01-01", "2025-01-01"],
  ["Stride's first commit: 2026-03-27", "2026-03-27"],
  ["today (UTC)", () => utcDay(0)],
  ["yesterday (UTC)", () => utcDay(-1)],
  ["today + 2 (UTC), the ceiling", () => utcDay(2)],
];
const valueOf = (v) => (typeof v === "function" ? v() : v);

describe("1.3.1 and 1.4.0: an entry on a refused date is skipped as invalid_value, the rest applies", () => {
  for (const [label, date] of REFUSED) {
    it(`${label}: skipped invalid_value, the good entry in the same push applied, nothing stored on that date`, async () => {
      const { u, h } = await oneHabit();
      const bad = uuid(), good = uuid();
      const body = encode140({ habits: [habit(h, { records: [record(bad, valueOf(date)), record(good, "2026-10-15")] })] });
      const r = await push(u.token, body, { client: V140 });
      assert.equal(r.status, 200);
      assert.deepEqual(r.json.applied, { habits: 1, entries: 1, groups: 0 });
      assert.deepEqual(r.json.skipped, { habits: [], entries: [bad], groups: [] });
      assert.deepEqual(r.json.skippedReasons.entries, { [bad]: "invalid_value" });
      assert.equal(entryById(bad), undefined);
      assert.equal(entryById(good).date, "2026-10-15");
      assert.equal(entryCount(u.userId), 1);
    });
  }
  for (const [label, date] of ACCEPTED) {
    it(`${label}: applied`, async () => {
      const { u, h } = await oneHabit();
      const id = uuid();
      const r = await push(u.token, encode140({ habits: [habit(h, { records: [record(id, valueOf(date))] })] }), { client: V140 });
      assert.equal(r.status, 200);
      assert.deepEqual(r.json.skipped.entries, []);
      assert.equal(entryById(id).date, valueOf(date));
    });
  }
});

describe("Apps before 1.3.1: a push with an entry on a refused date is refused whole, 426, nothing written", () => {
  for (const [label, date] of REFUSED) {
    it(`${label}: 426 client_update_required, the sentence in error`, async () => {
      const { u, h } = await oneHabit();
      const before0 = state(u.userId);
      const body = encode123({ habits: [habit(h, { name: "renamed", records: [record(uuid(), "2026-10-15"), record(uuid(), valueOf(date))] })] });
      assertRefused(await push(u.token, body), null);
      assert.deepEqual(state(u.userId), before0);
    });
  }
  for (const [label, date] of ACCEPTED) {
    it(`${label}: accepted`, async () => {
      const { u, h } = await oneHabit();
      const id = uuid();
      const r = await push(u.token, encode123({ habits: [habit(h, { records: [record(id, valueOf(date))] })] }));
      assert.equal(r.status, 200);
      assert.deepEqual(r.json.skipped.entries, []);
      assert.equal(entryById(id).date, valueOf(date));
    });
  }
});

describe("By version: the same edits from another device, one of them on a Japanese-calendar key", () => {
  /** That device renamed h2, checked today and (on its own calendar) 2026-10-15, and unchecked e1. */
  function otherDevice({ ids }) {
    const good = uuid(), bad = uuid();
    return {
      good, bad,
      store: {
        groups: [group(ids.g1, { name: "Health (renamed)", updatedAt: "2026-10-15T10:00:00.000Z" })],
        habits: [
          habit(ids.h1, { name: "Read", records: [] }),
          habit(ids.h2, { name: "Water (renamed)", groupId: ids.g1, updatedAt: "2026-10-15T10:00:00.000Z",
            records: [record(ids.e2, "2026-10-02", { note: "felt great", value: 6, updatedAt: "2026-10-02T21:00:00.000Z" }),
              record(good, utcDay(0)), record(bad, "0008-10-15")] }),
        ],
      },
      queue: { entries: [ids.e1] },
    };
  }

  for (const [label, client, mount] of [
    ["1.2.3 (no header)", null, "/v1/sync/push"],
    ["1.2.3 on the legacy /sync mount", null, "/sync/push"],
    ["1.3.0 (header)", V130, "/v1/sync/push"],
    ["1.3.0 on the legacy /sync mount", V130, "/sync/push"],
    ["a header that does not parse (read as no header)", "ios/1.4.0", "/v1/sync/push"],
  ]) {
    it(`${label}: refused whole — no rename, no check-in, no deletion, no clock moved`, async () => {
      const account = await seeded();
      const other = otherDevice(account);
      const before0 = state(account.u.userId);
      await sleep(5);
      const r = await push(account.u.token, encode123(other.store, other.queue), { client, mount });
      assertRefused(r, client === V130 ? V130 : null);
      assert.deepEqual(state(account.u.userId), before0);
    });
  }

  for (const [label, client] of [["1.3.1 (21)", V131], ["1.4.0 on iOS", V140], ["1.4.0 on the Mac", V140_MAC]]) {
    it(`${label}: the Japanese key alone is skipped invalid_value; the rename, today's check-in and the deletion apply`, async () => {
      const account = await seeded();
      const other = otherDevice(account);
      const r = await push(account.u.token, encode140(other.store, other.queue), { client });
      assert.equal(r.status, 200);
      assert.deepEqual(r.json.skipped, { habits: [], entries: [other.bad], groups: [] });
      assert.deepEqual(r.json.skippedReasons, { habits: {}, entries: { [other.bad]: "invalid_value" }, groups: {} });
      assert.deepEqual(r.json.applied, { habits: 2, entries: 2, groups: 1 });
      const s = state(account.u.userId);
      assert.equal(s.habits.find((h) => h.id === account.ids.h2).name, "Water (renamed)");
      assert.equal(s.groups[0].name, "Health (renamed)");
      assert.equal(entryById(other.good).date, utcDay(0));
      assert.equal(entryById(other.bad), undefined);
      assert.equal(entryById(account.ids.e1), undefined, "the deletion applied");
      assert.ok(s.tombstones.some((t) => t.entity_id === account.ids.e1));
      assert.deepEqual(s.entries.map((e) => e.date).sort(), ["2026-10-02", utcDay(0)].sort());
    });
  }

  it("a 1.2.2-shaped push (no updatedAt) with a refused date: the legacy refusal answers, it runs first", async () => {
    const account = await seeded();
    const before0 = state(account.u.userId);
    const body = encode123({ habits: [habit(account.ids.h2, { records: [record(uuid(), "0008-10-15")] })] });
    for (const e of body.entries) delete e.updatedAt;
    const r = await push(account.u.token, body);
    assert.equal(r.status, 426);
    assert.deepEqual(r.json, { error: LEGACY_SENTENCE, code: "client_update_required" });
    assert.deepEqual(state(account.u.userId), before0);
  });
});

describe("Pushes the date guard does not concern are answered as before", () => {
  it("a deletions-only push from 1.2.3 and from 1.3.0: applied, tombstones written", async () => {
    for (const client of [null, V130]) {
      const account = await seeded();
      const r = await push(account.u.token, { habits: [], entries: [], groups: [], deletedHabitIds: [], deletedEntryIds: [account.ids.e1], deletedGroupIds: [] }, { client });
      assert.equal(r.status, 200);
      assert.equal(entryById(account.ids.e1), undefined);
      assert.ok(state(account.u.userId).tombstones.some((t) => t.entity_id === account.ids.e1));
    }
  });

  it("a deletions-only push from 1.4.0: applied", async () => {
    const account = await seeded();
    const r = await push(account.u.token, encode140({ habits: [] }, { entries: [account.ids.e1], habits: [account.ids.h1] }), { client: V140 });
    assert.equal(r.status, 200);
    assert.equal(entryById(account.ids.e1), undefined);
  });

  it("an empty push, and a habits-and-groups-only snapshot from 1.2.3: 200", async () => {
    const account = await seeded();
    assert.equal((await push(account.u.token, {})).status, 200);
    const r = await push(account.u.token, encode123({ groups: [group(uuid())], habits: [habit(uuid())] }));
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.applied, { habits: 1, entries: 0, groups: 1 });
  });

  it("an ordinary 1.2.3 snapshot of the account, every day in the window: 200, nothing skipped", async () => {
    const account = await seeded();
    const r = await push(account.u.token, encode123(account.store));
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skipped, { habits: [], entries: [], groups: [] });
  });

  it("from 1.2.3, an entry with no date is still missing_field and one with no id still dropped — not a refusal", async () => {
    const { u, h } = await oneHabit();
    const dateless = uuid();
    const r = await push(u.token, {
      habits: [], groups: [], deletedHabitIds: [], deletedEntryIds: [], deletedGroupIds: [],
      entries: [
        { id: dateless, habitId: h, value: 1, createdAt: "2026-10-15T00:00:00Z", updatedAt: "2026-10-15T00:00:00Z" },
        { habitId: h, date: "0008-10-15", value: 1, createdAt: "2026-10-15T00:00:00Z", updatedAt: "2026-10-15T00:00:00Z" },
      ],
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skippedReasons.entries, { [dateless]: "missing_field" });
    assert.equal(entryCount(u.userId), 0);
  });

  it("from 1.4.0, the reasons that come first still come first: missing_field, tombstoned, tombstoned_habit", async () => {
    const account = await seeded();
    // Delete h1 and the check-in e2 first, as another device would.
    assert.equal((await push(account.u.token, encode140({ habits: [] }, { habits: [account.ids.h1], entries: [account.ids.e2] }), { client: V140 })).status, 200);
    const ofDeletedHabit = uuid(), dateless = uuid();
    const r = await push(account.u.token, encode140({ habits: [
      habit(account.ids.h1, { records: [record(ofDeletedHabit, "0008-10-01")] }),
      habit(account.ids.h2, { groupId: account.ids.g1, records: [record(account.ids.e2, "0008-10-02")] }),
    ] }), { client: V140 });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skippedReasons.habits, { [account.ids.h1]: "tombstoned" });
    assert.deepEqual(r.json.skippedReasons.entries, { [ofDeletedHabit]: "tombstoned_habit", [account.ids.e2]: "tombstoned" },
      "a deleted row, or a deleted habit's row, is dropped on the device whatever its date — not held");
    const r2 = await push(account.u.token, { entries: [{ id: dateless, habitId: account.ids.h2, value: 1, createdAt: "2026-10-15T00:00:00.000Z", updatedAt: "2026-10-15T00:00:00.000Z" }] }, { client: V140 });
    assert.equal(r2.status, 200);
    assert.deepEqual(r2.json.skippedReasons.entries, { [dateless]: "missing_field" });
  });
});

describe("Rows stored before the guard are left alone (no server-side migration, pull not filtered)", () => {
  /** An account holding one wrong-year row, as one pushed before the guard would be stored. */
  async function withStoredJapaneseRow() {
    const account = await seeded();
    const wrong = uuid();
    db.prepare("INSERT INTO habit_entries (id, habit_id, date, note, value, created_at, updated_at, client_updated_at) VALUES (?, ?, '0008-10-14', NULL, 1, ?, ?, ?)")
      .run(wrong, account.ids.h1, "2026-10-14T03:00:00.000Z", "2026-10-14T03:00:00.000Z", "2026-10-14T09:00:00.000Z");
    return { ...account, wrong };
  }

  it("a full pull still serves it, to 1.4.0 and to 1.2.3", async () => {
    const { u, wrong } = await withStoredJapaneseRow();
    for (const client of [V140, null]) {
      const p = await pull(u.token, { client });
      assert.equal(p.entries.find((e) => e.id === wrong)?.date, "0008-10-14");
    }
  });

  it("1.4.0 re-sending it, edited: skipped invalid_value, the stored row unchanged", async () => {
    const { u, ids, wrong } = await withStoredJapaneseRow();
    const before0 = entryById(wrong);
    const r = await push(u.token, encode140({ habits: [habit(ids.h1, { name: "Read", records: [record(wrong, "0008-10-14", { note: "edited", updatedAt: "2026-10-15T12:00:00.000Z" })] })] }), { client: V140 });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skippedReasons.entries, { [wrong]: "invalid_value" });
    assert.deepEqual(entryById(wrong), before0);
  });

  it("a 1.2.3 device that pulled it is refused once its snapshot carries it (the cost: run the X2 prod query first)", async () => {
    const { u, ids, store, wrong } = await withStoredJapaneseRow();
    const before0 = state(u.userId);
    const snapshot = { ...store, habits: store.habits.map((h) => (h.id === ids.h1 ? { ...h, records: [...h.records, record(wrong, "0008-10-14")] } : h)) };
    assertRefused(await push(u.token, encode123(snapshot)), null);
    assert.deepEqual(state(u.userId), before0);
  });
});

describe("Date refusals are counted and logged (second server)", () => {
  const PORT2 = 3094, BASE2 = `http://localhost:${PORT2}`;
  const NAMES = ["entry_date_push_refused", "invalid_entry_date"];
  const totals = () => Object.fromEntries(NAMES.map((n) =>
    [n, db.prepare("SELECT COALESCE(SUM(value), 0) AS n FROM usage_counters WHERE name = ?").get(n).n]));
  let second, u, h, before0, after0, ceiling, ids;

  before(async () => {
    u = user();
    before0 = totals();
    second = await startServer(PORT2);
    ceiling = utcDay(2);
    h = uuid();
    ids = { a: uuid(), b: uuid(), c: uuid(), d: uuid() };
    assert.equal((await push(u.token, encode140({ habits: [habit(h)] }), { base: BASE2, client: V140 })).status, 200);
    // 1.2.3: two refused dates in one push.
    assert.equal((await push(u.token, encode123({ habits: [habit(h, { records: [record(ids.a, "0008-10-15"), record(ids.b, "2569-10-15"), record(uuid(), "2026-10-15")] })] }), { base: BASE2 })).status, 426);
    // 1.3.0 on the legacy mount: one.
    assert.equal((await push(u.token, encode123({ habits: [habit(h, { records: [record(ids.c, "5787-02-04")] })] }), { base: BASE2, client: V130, mount: "/sync/push" })).status, 426);
    // 1.4.0: one skipped, one applied.
    assert.equal((await push(u.token, encode140({ habits: [habit(h, { records: [record(ids.d, "1448-05-04"), record(uuid(), "2026-10-14")] })] }), { base: BASE2, client: V140 })).status, 200);
    // 1.4.0, nothing wrong: not counted.
    assert.equal((await push(u.token, encode140({ habits: [habit(h, { records: [record(uuid(), "2026-10-13")] })] }), { base: BASE2, client: V140 })).status, 200);
    await stopServer(second.proc);   // SIGTERM flushes the counters
    after0 = totals();
  });
  after(async () => { await stopServer(second?.proc); });

  it("entry_date_push_refused per refused push, invalid_entry_date per refused entry in either path", () => {
    assert.deepEqual(Object.fromEntries(NAMES.map((n) => [n, after0[n] - before0[n]])), {
      entry_date_push_refused: 2, invalid_entry_date: 4,
    });
  });

  it("one line per push, with the user id and the count — no date, no entry id, no email", () => {
    const lines = second.out.stderr.split("\n").filter((l) => l.includes("not a real day"));
    assert.deepEqual(lines.map((l) => l.replace(/^.*\[sync\]/, "[sync]")), [
      `[sync] push user=${u.userId} refused push: 2 entry dates not a real day in 2025-01-01..${ceiling}`,
      `[sync] push user=${u.userId} refused push: 1 entry dates not a real day in 2025-01-01..${ceiling}`,
      `[sync] push user=${u.userId} skipped 1 entries as invalid_value: date not a real day in 2025-01-01..${ceiling}`,
    ]);
    const all = second.out.stderr + second.out.stdout;
    assert.ok(!all.includes(u.email));
    for (const s of ["0008-10-15", "2569-10-15", "5787-02-04", "1448-05-04", ...Object.values(ids)]) assert.ok(!all.includes(s), s);
    assert.match(second.out.stdout, new RegExp(`POST /v1/sync/push 426 \\d+ms client=- sync user=${u.userId} dateRefused=2(\\s|$)`));
    assert.match(second.out.stdout, new RegExp(`POST /sync/push 426 \\d+ms client=ios/1.3.0\\(18\\) sync user=${u.userId} dateRefused=1(\\s|$)`));
    assert.match(second.out.stdout, new RegExp(`POST /v1/sync/push 200 \\d+ms client=ios/1.4.0\\(22\\) sync user=${u.userId} .*reasons=invalid_value:1 badDates=1(\\s|$)`));
  });
});
