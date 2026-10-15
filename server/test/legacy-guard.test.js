// Legacy-shaped pushes are refused, and notes survive a day held under two ids
// (routes/sync.js legacyShape, upsertEntry, adoptMissingNote; RELEASE-1.4.1.md O5 option (1')
// and Data safety 2, decided 2026-10-15).
//
// Every payload below is built the way a tagged app's encoder builds it, read from the tag:
//   1.1      5e6c8b2   Stride/Sources/Services/{SyncService,APIClient}.swift — snake_case keys,
//                      habits with no note and no v2 fields (no `kind`), entries
//                      {id, habit_id, date, note?, created_at}, no groups.
//   1.2.0/1  v1.2.0, v1.2.1  the v2 models (habits with `kind`, groups), entries with no
//                      `updated_at`, all snake_case (.convertToSnakeCase).
//   1.2.2    v1.2.2    the same models camelCase: entries still have no `updatedAt`.
//   1.2.3    v1.2.3    Shared/SyncModels.swift + SyncService.pushLocal: every entry carries
//            and 1.3.0 `updatedAt: SyncTimestamp.string(from: record.updatedAt ?? record.date)`,
//                      whole seconds; 1.3.0 adds the X-Stride-Client header.
//   1.4.0    v1.3.1 and m3/1.4.0 Shared/SyncPushPlanner.swift wireHabit/wireEntry/wireGroup:
//                      the same fields, stamps through SyncWireStamp (milliseconds), all six
//                      arrays in every chunk, the header.
// Synthesized Encodable leaves a nil optional out (encodeIfPresent), so an unset note or unit is
// absent, never null.

const { describe, it, before, after } = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const crypto = require("node:crypto");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");
const Database = require("better-sqlite3");

const PORT = 3097;
const BASE = `http://localhost:${PORT}`;
const DB_PATH = path.join(__dirname, "..", "stride.db");
const PAUSE_FILE = path.join(os.tmpdir(), `stride-test-SYNC_PAUSED-${process.pid}`);

const SENTENCE = "This version of Stride can no longer sync. Update Stride from the App Store to keep syncing; nothing on this device was changed.";
const V130 = "ios/1.3.0(18)";
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
  proc.stderr.on("data", (d) => { out.stderr += d; process.stderr.write(d); });
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

const users = [];
function user() {
  const email = `legacy-guard-${crypto.randomUUID()}@stride-test.local`;
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

async function pull(token, { since, client = V140 } = {}) {
  const qs = since ? `?since=${encodeURIComponent(since)}` : "";
  const res = await fetch(`${BASE}/v1/sync/pull${qs}`, { headers: { Authorization: `Bearer ${token}`, "X-Stride-Client": client } });
  return res.json();
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

const entryRow = (habitId, date) =>
  db.prepare("SELECT id, note, value, client_updated_at, updated_at FROM habit_entries WHERE habit_id = ? AND date = ?").get(habitId, date);

// ---------- the apps' encoders ----------

/** A device's store, as the encoders below read it (Habit, HabitRecord, HabitGroup). */
const habit = (id, over = {}) => ({
  id, name: "Water", emoji: "\u{1F4A7}", colorHex: "#007AFF", isArchived: false, sortOrder: 1790000000,
  reminderEnabled: false, reminderHour: 20, reminderMinute: 0, note: null,
  kind: "count", targetValue: 8, unit: "glasses", scheduleKind: "daily", timesPerWeek: 7, activeDaysMask: 127,
  groupId: null, createdAt: "2026-09-01T08:00:00.000Z", updatedAt: "2026-09-01T08:00:00.000Z", records: [], ...over,
});
/** `updatedAt: null` is a record never edited since the v2 migration (the push sends its day). */
const record = (id, date, over = {}) => ({ id, date, note: null, value: 1, updatedAt: null, ...over });
const group = (id, over = {}) => ({
  id, name: "Health", colorHex: "#FF9500", sortOrder: 1, createdAt: "2026-09-01T08:00:00.000Z", updatedAt: null, ...over,
});

/** encodeIfPresent: nil optionals are left out. */
const present = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== null && v !== undefined));
const toSnake = (k) => k.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase());
/** JSONEncoder.keyEncodingStrategy = .convertToSnakeCase (1.1 – 1.2.1), every key. */
const snakeCase = (v) => (Array.isArray(v) ? v.map(snakeCase)
  : v && typeof v === "object" ? Object.fromEntries(Object.entries(v).map(([k, x]) => [toSnake(k), snakeCase(x)])) : v);
/** ISO8601DateFormatter(): UTC, whole seconds (SyncTimestamp.string, and every app before it). */
const whole = (iso) => new Date(iso).toISOString().replace(/\.\d{3}Z$/, "Z");
/** SyncWireStamp.string (1.3.1+): three fractional digits. */
const millis = (iso) => new Date(iso).toISOString();
/** `record.date`, a UTC day key, through either formatter. */
const dayStamp = (date, fmt) => fmt(`${date}T00:00:00.000Z`);

const v2Habit = (h, fmt) => present({
  id: h.id, name: h.name, emoji: h.emoji, colorHex: h.colorHex, isArchived: h.isArchived, sortOrder: h.sortOrder,
  reminderEnabled: h.reminderEnabled, reminderHour: h.reminderHour, reminderMinute: h.reminderMinute, note: h.note,
  kind: h.kind, targetValue: h.targetValue, unit: h.unit, scheduleKind: h.scheduleKind, timesPerWeek: h.timesPerWeek,
  activeDaysMask: h.activeDaysMask, groupId: h.groupId, createdAt: fmt(h.createdAt), updatedAt: fmt(h.updatedAt ?? h.createdAt),
});
const v2Group = (g, fmt) => ({
  id: g.id, name: g.name, colorHex: g.colorHex, sortOrder: g.sortOrder, createdAt: fmt(g.createdAt), updatedAt: fmt(g.updatedAt ?? g.createdAt),
});
const queued = (q = {}) => ({ deletedHabitIds: q.habits ?? [], deletedEntryIds: q.entries ?? [], deletedGroupIds: q.groups ?? [] });

/** 5e6c8b2 (1.1): no groups, no deletedGroupIds; a habit's updatedAt is the push time. */
function encode11(store, q = {}) {
  return snakeCase({
    habits: store.habits.map((h) => present({
      id: h.id, name: h.name, emoji: h.emoji, colorHex: h.colorHex, isArchived: h.isArchived, sortOrder: h.sortOrder,
      reminderEnabled: h.reminderEnabled, reminderHour: h.reminderHour, reminderMinute: h.reminderMinute,
      createdAt: whole(h.createdAt), updatedAt: whole(new Date().toISOString()),
    })),
    entries: store.habits.flatMap((h) => h.records.map((r) => present({
      id: r.id, habitId: h.id, date: r.date, note: r.note, createdAt: dayStamp(r.date, whole),
    }))),
    deletedHabitIds: q.habits ?? [], deletedEntryIds: q.entries ?? [],
  });
}

/** v1.2.2: camelCase, and SyncEntry has no updatedAt. */
function encode122(store, q = {}) {
  return {
    habits: store.habits.map((h) => v2Habit(h, whole)),
    entries: store.habits.flatMap((h) => h.records.map((r) => present({
      id: r.id, habitId: h.id, date: r.date, note: r.note, value: r.value, createdAt: dayStamp(r.date, whole),
    }))),
    groups: (store.groups ?? []).map((g) => v2Group(g, whole)),
    ...queued(q),
  };
}

/** v1.2.0 / v1.2.1: 1.2.2's models through .convertToSnakeCase. */
const encode120 = (store, q) => snakeCase(encode122(store, q));

/** v1.2.3 and v1.3.0: 1.2.2 plus the entry's `updatedAt: record.updatedAt ?? record.date`. */
function encode123(store, q = {}) {
  return {
    ...encode122(store, q),
    entries: store.habits.flatMap((h) => h.records.map((r) => present({
      id: r.id, habitId: h.id, date: r.date, note: r.note, value: r.value, createdAt: dayStamp(r.date, whole),
      updatedAt: r.updatedAt ? whole(r.updatedAt) : dayStamp(r.date, whole),
    }))),
  };
}

/** v1.3.1 / 1.4.0: the planner's wire mapping, millisecond stamps, all six arrays. */
function encode140(store, q = {}) {
  return {
    habits: store.habits.map((h) => v2Habit(h, millis)),
    entries: store.habits.flatMap((h) => h.records.map((r) => present({
      id: r.id, habitId: h.id, date: r.date, note: r.note, value: r.value, createdAt: dayStamp(r.date, millis),
      updatedAt: r.updatedAt ? millis(r.updatedAt) : dayStamp(r.date, millis),
    }))),
    groups: (store.groups ?? []).map((g) => v2Group(g, millis)),
    ...queued(q),
  };
}

/** An account the server already holds, from a 1.4.0 device: two habits, a group, check-ins. */
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

/** The same account as an old device holds it: everything renamed, a day re-checked under its
 * own id without the note, a new habit, group and check-in, and all three deletions queued. */
function oldDeviceEdits({ ids, store }) {
  const h3 = uuid();
  return {
    store: {
      groups: [group(uuid(), { name: "Morning" })],
      habits: [
        habit(ids.h2, { name: "Water (old device)", groupId: null, records: [record(uuid(), "2026-10-02", { value: 2 })] }),
        habit(h3, { name: "New on the old device", records: [record(uuid(), "2026-10-03")] }),
      ],
    },
    queue: { habits: [ids.h1], entries: [ids.e1], groups: [ids.g1] },
    h3,
    before: store,
  };
}

function assertRefusedShape(r, client) {
  assert.equal(r.status, 426);
  if (client) {
    assert.deepEqual(r.json, { error: "client_update_required", code: "client_update_required", message: SENTENCE });
  } else {
    assert.deepEqual(r.json, { error: SENTENCE, code: "client_update_required" },
      "the sentence in `error`: every app before 1.3.0 prints it verbatim, and has no `message`");
  }
}

// ================================================================

describe("Legacy-shaped pushes are refused whole: 426 client_update_required, nothing written", () => {
  const cases = [
    ["1.2.2 (camelCase, entries without updatedAt)", encode122, "/v1/sync/push"],
    ["1.2.0 / 1.2.1 (snake_case, entries without updated_at)", encode120, "/v1/sync/push"],
    ["1.2.2 on the legacy /sync mount", encode122, "/sync/push"],
    ["1.2.0 / 1.2.1 on the legacy /sync mount", encode120, "/sync/push"],
  ];
  for (const [label, encode, mount] of cases) {
    it(`${label}: refused, and no habit, entry, group or deletion is applied`, async () => {
      const account = await seeded();
      const old = oldDeviceEdits(account);
      const body = encode(old.store, old.queue);
      // The fixture really is that app's shape, and really carries every kind of write.
      for (const e of body.entries) assert.equal(e.updatedAt ?? e.updated_at, undefined);
      assert.ok(body.habits.every((h) => h.kind === "count"));
      assert.equal((body.deletedHabitIds ?? body.deleted_habit_ids).length, 1);
      assert.equal((body.deletedEntryIds ?? body.deleted_entry_ids).length, 1);
      assert.equal((body.deletedGroupIds ?? body.deleted_group_ids).length, 1);

      const before0 = state(account.u.userId);
      await sleep(5);
      const r = await push(account.u.token, body, { mount });
      assertRefusedShape(r, null);
      assert.deepEqual(state(account.u.userId), before0, "not one row, clock or tombstone moved");
      assert.equal(entryRow(account.ids.h2, "2026-10-02").note, "felt great");
    });
  }

  it("1.1 (5e6c8b2): habits without kind, and their check-ins, refused on both mounts", async () => {
    for (const mount of ["/v1/sync/push", "/sync/push"]) {
      const account = await seeded();
      const before0 = state(account.u.userId);
      const body = encode11({ habits: [habit(account.ids.h2, { name: "1.1 rename", records: [record(uuid(), "2026-10-02", { note: "1.1" })] })] },
        { habits: [account.ids.h1], entries: [account.ids.e1] });
      assert.equal(body.habits[0].kind, undefined);
      assertRefusedShape(await push(account.u.token, body, { mount }), null);
      assert.deepEqual(state(account.u.userId), before0);
    }
  });

  it("1.1 with habits and no check-in yet is refused too: the habits alone have no kind", async () => {
    const account = await seeded();
    const before0 = state(account.u.userId);
    const body = encode11({ habits: [habit(account.ids.h2, { name: "1.1 rename" }), habit(uuid())] });
    assert.deepEqual(body.entries, []);
    assertRefusedShape(await push(account.u.token, body), null);
    assert.deepEqual(state(account.u.userId), before0, "kind, target, unit, schedule and group were not reset");
  });

  it("one legacy row is enough: a 1.4.0 chunk with one stamp-less entry is refused whole", async () => {
    // No shipped app >= 1.2.3 sends this (the stamp is never nil); the rule is per row, so a
    // mixed push cannot sneak the rest in. A header-bearing app gets the code in `error` and the
    // sentence in `message` (errorBody); 1.3.1+ maps any 426 to "update required" and stops.
    const account = await seeded();
    const before0 = state(account.u.userId);
    const body = encode140({ habits: [habit(account.ids.h2, { name: "renamed", updatedAt: "2026-10-10T00:00:00.000Z" })] });
    body.entries.push({ id: uuid(), habitId: account.ids.h2, date: "2026-10-05", value: 1, createdAt: "2026-10-05T00:00:00.000Z" });
    assertRefusedShape(await push(account.u.token, body, { client: V140 }), V140);
    assert.deepEqual(state(account.u.userId), before0);
  });

  it("a null stamp is no stamp", async () => {
    const account = await seeded();
    const body = encode123({ habits: [habit(account.ids.h2, { records: [record(uuid(), "2026-10-06")] })] });
    body.entries[0].updatedAt = null;
    assertRefusedShape(await push(account.u.token, body), null);
  });

  it("a stamp that does not parse: refused without a header; from a header-bearing app it keeps the old `now` stamp", async () => {
    // ISO8601DateFormatter reads and writes a five-digit year; Date.parse does not. Only a
    // hand-edited backup restored on 1.3.0+ can put one in a store, and refusing it would stop
    // that account syncing for good behind a message no update can clear (legacyShape).
    const account = await seeded();
    const id = uuid();
    const body = encode123({ habits: [habit(account.ids.h2, { records: [record(id, "2026-10-07", { value: 3 })] })] });
    body.entries[0].updatedAt = "10000-01-01T00:00:00Z";
    assertRefusedShape(await push(account.u.token, body), null);
    assert.equal(entryRow(account.ids.h2, "2026-10-07"), undefined);

    const t0 = new Date().toISOString();
    const r = await push(account.u.token, body, { client: V130 });
    assert.equal(r.status, 200);
    assert.equal(r.json.applied.entries, 1);
    const row = entryRow(account.ids.h2, "2026-10-07");
    assert.equal(row.value, 3);
    assert.ok(row.client_updated_at >= t0, `stamped now, as before: ${row.client_updated_at}`);
  });

  it("a row with no usable id does not classify a push: it is dropped, as it always was", async () => {
    const account = await seeded();
    const body = encode123({ habits: [habit(account.ids.h2, { name: "With junk rows", records: [record(uuid(), "2026-10-12")] })] });
    body.habits.push({ name: "no id, no kind" }, null);
    body.entries.push({ habitId: account.ids.h2, date: "2026-10-08" }, "x", null);
    const r = await push(account.u.token, body);
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.applied, { habits: 1, entries: 1, groups: 0 });
  });

  it("an entry's stamp is read in either casing, as the upsert reads it", async () => {
    const account = await seeded();
    const id = uuid();
    const r = await push(account.u.token, {
      entries: [{ id, habit_id: account.ids.h2, date: "2026-10-09", value: 4, created_at: "2026-10-09T00:00:00Z", updated_at: "2026-10-09T20:00:00Z" }],
    });
    assert.equal(r.status, 200);
    assert.equal(entryRow(account.ids.h2, "2026-10-09").client_updated_at, "2026-10-09T20:00:00.000Z");
  });
});

describe("Pushes the guard cannot classify are answered as before", () => {
  it("an empty push: 200, nothing applied", async () => {
    const { u } = await seeded();
    for (const body of [{}, encode122({ habits: [] }), encode11({ habits: [] })]) {
      const r = await push(u.token, body);
      assert.equal(r.status, 200, JSON.stringify(body));
      assert.deepEqual(r.json.applied, { habits: 0, entries: 0, groups: 0 });
    }
  });

  it("a deletions-only push from a 1.2.2 or 1.1 device: applied, tombstones written", async () => {
    for (const [encode, mount] of [[encode122, "/v1/sync/push"], [encode120, "/sync/push"], [encode11, "/v1/sync/push"]]) {
      const { u, ids } = await seeded();
      const q = encode === encode11 ? { habits: [ids.h1], entries: [ids.e2] } : { habits: [ids.h1], entries: [ids.e2], groups: [ids.g1] };
      const r = await push(u.token, encode({ habits: [] }, q), { mount });
      assert.equal(r.status, 200);
      const s = state(u.userId);
      assert.deepEqual(s.habits.map((h) => h.id), [ids.h2]);
      assert.deepEqual(s.entries, []);
      assert.deepEqual(s.tombstones.map((t) => [t.entity_type, t.entity_id]).sort(),
        [["entry", ids.e2], ["habit", ids.h1], ...(q.groups ? [["group", ids.g1]] : [])].sort());
    }
  });

  it("a groups-only push from a 1.2.2 device: applied", async () => {
    const { u } = await seeded();
    const g = uuid();
    const r = await push(u.token, encode122({ habits: [], groups: [group(g, { name: "Evening" })] }));
    assert.equal(r.status, 200);
    assert.equal(r.json.applied.groups, 1);
  });

  it("a 1.2.x device with habits and no check-in yet: accepted (its habits have kind), until its first check-in", async () => {
    const { u } = await seeded();
    const h = uuid();
    const r = await push(u.token, encode122({ habits: [habit(h, { name: "Fresh install", updatedAt: "2026-10-10T08:00:00.000Z" })] }));
    assert.equal(r.status, 200);
    assert.equal(r.json.applied.habits, 1);
    const next = encode122({ habits: [habit(h, { name: "Fresh install", updatedAt: "2026-10-10T08:00:00.000Z", records: [record(uuid(), "2026-10-10")] })] });
    assertRefusedShape(await push(u.token, next), null);
  });
});

describe("Every shipped app from 1.2.3 on is accepted", () => {
  it("1.2.3 (no header) and 1.3.0 (header): the full snapshot from the 1.2.3 encoder", async () => {
    for (const client of [null, V130]) {
      const { u, ids, store } = await seeded();
      // A record edited on this device and one never edited since the v2 migration (stamp = its day).
      store.habits[0].records.push(record(uuid(), "2026-10-04", { note: "edited", updatedAt: "2026-10-04T19:30:12.000Z" }));
      store.habits[0].records.push(record(uuid(), "2026-09-20"));
      const body = encode123(store);
      for (const e of body.entries) assert.match(e.updatedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
      const r = await push(u.token, body, { client });
      assert.equal(r.status, 200, String(client));
      assert.deepEqual(r.json.applied, { habits: 2, entries: 4, groups: 1 });
      assert.equal(entryRow(ids.h1, "2026-10-04").note, "edited");
      assert.equal(entryRow(ids.h1, "2026-09-20").client_updated_at, "2026-09-20T00:00:00.000Z");
    }
  });

  it("1.4.0 on iOS and on the Mac: the planner's chunk, millisecond stamps", async () => {
    for (const client of [V140, V140_MAC]) {
      const { u, ids, store } = await seeded();
      store.habits[1].records[0] = { ...store.habits[1].records[0], note: "edited on 1.4.0", updatedAt: "2026-10-12T07:15:42.317Z" };
      const r = await push(u.token, encode140(store), { client });
      assert.equal(r.status, 200, client);
      assert.equal(entryRow(ids.h2, "2026-10-02").note, "edited on 1.4.0");
      assert.equal(entryRow(ids.h2, "2026-10-02").client_updated_at, "2026-10-12T07:15:42.317Z");
    }
  });
});

describe("Notes on a day held under two ids (Data safety 2)", () => {
  const D = "2026-10-11";
  async function day(noted) {
    const { u, ids, store } = await seeded();
    const H = ids.h1;
    if (noted) {
      const r = await push(u.token, encode140({ habits: [habit(H, { records: [record(noted.id, D, noted)] })] }), { client: V140 });
      assert.equal(r.status, 200);
    }
    const send = (id, rec, client = V140) => push(u.token,
      (client ? encode140 : encode123)({ habits: [habit(H, { records: [record(id, D, rec)] })] }), { client });
    return { u, H, send, store };
  }

  it("a different id with no note keeps the stored note (it is a device that has none, not a clear)", async () => {
    const A = uuid();
    const { H, send } = await day({ id: A, note: "felt great", value: 1, updatedAt: "2026-10-11T08:00:00.000Z" });
    // Newer, and a different value: the value is the newer edit's, the note stays.
    assert.equal((await send(uuid(), { value: 2, updatedAt: "2026-10-11T20:00:00.000Z" })).status, 200);
    assert.deepEqual({ ...entryRow(H, D), updated_at: undefined },
      { id: A, note: "felt great", value: 2, client_updated_at: "2026-10-11T20:00:00.000Z", updated_at: undefined });
    // The same stamp and value from yet another id: nothing to write, the note still kept.
    assert.equal((await send(uuid(), { value: 2, updatedAt: "2026-10-11T20:00:00.000Z" }, null)).status, 200);
    assert.equal(entryRow(H, D).note, "felt great");
    assert.equal(entryRow(H, D).value, 2);
  });

  it("the stored row's own id with no note clears it (the owner removed the note)", async () => {
    const A = uuid();
    const { H, send } = await day({ id: A, note: "felt great", value: 1, updatedAt: "2026-10-11T08:00:00.000Z" });
    assert.equal((await send(A, { value: 1, updatedAt: "2026-10-11T09:00:00.000Z" })).status, 200);
    assert.equal(entryRow(H, D).note, null);
    // And an older copy of that same row, still noted, does not bring it back (LWW, same id).
    assert.equal((await send(A, { note: "felt great", value: 1, updatedAt: "2026-10-11T08:00:00.000Z" })).status, 200);
    assert.equal(entryRow(H, D).note, null);
  });

  it("a different id with a note is an edit: the newer one wins, an older one does not", async () => {
    const A = uuid();
    const { H, send } = await day({ id: A, note: "felt great", value: 1, updatedAt: "2026-10-11T08:00:00.000Z" });
    assert.equal((await send(uuid(), { note: "older note", updatedAt: "2026-10-11T07:00:00.000Z" })).status, 200);
    assert.equal(entryRow(H, D).note, "felt great");
    assert.equal((await send(uuid(), { note: "newer note", updatedAt: "2026-10-11T09:00:00.000Z" })).status, 200);
    assert.deepEqual([entryRow(H, D).id, entryRow(H, D).note], [A, "newer note"]);
  });

  it("push order: the newer no-note row lands first, then the older noted one — the note ends on the stored row and re-feeds", async () => {
    const B = uuid(), A = uuid();
    const { u, H, send } = await day(null);
    // Device B checked the day (no note) at 20:00 and pushed first.
    assert.equal((await send(B, { value: 1, updatedAt: "2026-10-11T20:00:00.000Z" })).status, 200);
    const cursor = (await pull(u.token)).serverTime;
    await sleep(5);
    // Device A had checked it at 08:00 with a note, offline, and pushes now: it loses the guard.
    const r = await send(A, { note: "felt great", value: 1, updatedAt: "2026-10-11T08:00:00.000Z" });
    assert.equal(r.status, 200);
    assert.equal(r.json.applied.entries, 1);
    assert.deepEqual(r.json.aliases, { entries: { [A]: B } }, "A takes the stored id");
    const row = entryRow(H, D);
    assert.deepEqual([row.id, row.note, row.value, row.client_updated_at], [B, "felt great", 1, "2026-10-11T20:00:00.001Z"],
      "the note is copied; the value stays the newer edit's, and the stamp moves one millisecond past it");
    // Every device's next pull brings it — B's (which lacks the note) included.
    const inc = await pull(u.token, { since: cursor });
    const pulled = inc.entries.find((e) => e.date === D);
    assert.ok(pulled, "the row re-feeds");
    assert.deepEqual([pulled.id, pulled.note, pulled.updatedAt], [B, "felt great", "2026-10-11T20:00:00.001Z"]);
  });

  it("push order, when the newer row came from 1.2.3: its next snapshot, pushed before it pulls, does not undo the merge", async () => {
    const B = uuid(), A = uuid();
    const { u, H, send } = await day(null);
    const bRow = { value: 1, updatedAt: "2026-10-11T20:00:00.000Z" };
    assert.equal((await send(B, bRow, null)).status, 200);   // 1.2.3: whole seconds, no header
    const bCursor = (await pull(u.token, { client: null })).serverTime;
    await sleep(5);
    assert.equal((await send(A, { note: "felt great", value: 1, updatedAt: "2026-10-11T08:00:00.000Z" })).status, 200);
    // B's next sync: its whole store first — the day under the stored id, still without the
    // note, at exactly the stamp it was stored with. At that stamp the stored id's NULL would
    // clear the note; one millisecond on, it is older and changes nothing.
    assert.equal((await send(B, bRow, null)).status, 200);
    assert.equal(entryRow(H, D).note, "felt great");
    // Then its pull, in whole seconds as 1.2.3 reads them: the merged row, which it takes (its
    // guard keeps a local value only when strictly newer, and :00 is not newer than :00).
    const pulled = (await pull(u.token, { since: bCursor, client: null })).entries.find((e) => e.date === D);
    assert.deepEqual([pulled.id, pulled.note, pulled.updatedAt], [B, "felt great", "2026-10-11T20:00:00Z"]);
    // Holding it, B's snapshots now echo the note and move nothing.
    const clock = entryRow(H, D).updated_at;
    await sleep(5);
    assert.equal((await send(B, { ...bRow, note: "felt great" }, null)).status, 200);
    assert.deepEqual([entryRow(H, D).note, entryRow(H, D).updated_at], ["felt great", clock]);
  });

  it("push order, when the older noted row also lost on value: note merged, value stays the newer one's", async () => {
    const B = uuid(), A = uuid();
    const { H, send } = await day(null);
    assert.equal((await send(B, { value: 5, updatedAt: "2026-10-11T20:00:00.000Z" }, null)).status, 200);
    assert.equal((await send(A, { note: "felt great", value: 2, updatedAt: "2026-10-11T08:00:00.000Z" }, null)).status, 200);
    assert.deepEqual([entryRow(H, D).note, entryRow(H, D).value], ["felt great", 5]);
  });

  it("the merge never overwrites a note: an older noted row against a stored note keeps the stored one", async () => {
    const B = uuid();
    const { H, send } = await day({ id: B, note: "B's note", value: 1, updatedAt: "2026-10-11T20:00:00.000Z" });
    assert.equal((await send(uuid(), { note: "A's older note", updatedAt: "2026-10-11T08:00:00.000Z" })).status, 200);
    assert.equal(entryRow(H, D).note, "B's note");
  });

  it("a 1.4.1-style note edit, then a raw legacy push of that day: refused, and the note intact", async () => {
    const A = uuid();
    const { u, H, send } = await day({ id: A, value: 1, updatedAt: "2026-10-11T08:00:00.000Z" });
    // History's setNote on a past day: only the note changes, with a new stamp (RELEASE-1.4.1.md D4).
    assert.equal((await send(A, { note: "added in History", value: 1, updatedAt: "2026-10-14T10:00:00.123Z" })).status, 200);
    const before0 = state(u.userId);
    // A 1.2.2 device that holds the day under its own id, without the note — and with the same id.
    for (const id of [uuid(), A]) {
      const legacy = encode122({ habits: [habit(H, { records: [record(id, D, { value: 1 })] })] });
      assertRefusedShape(await push(u.token, legacy), null);
      assertRefusedShape(await push(u.token, snakeCase(legacy), { mount: "/sync/push" }), null);
    }
    assert.deepEqual(state(u.userId), before0);
    assert.equal(entryRow(H, D).note, "added in History");
  });
});

describe("Refusals are counted and logged (second server)", () => {
  const PORT2 = 3096, BASE2 = `http://localhost:${PORT2}`;
  const NAMES = ["legacy_push_refused", "habit_without_kind"];
  const totals = () => Object.fromEntries(NAMES.map((n) =>
    [n, db.prepare("SELECT COALESCE(SUM(value), 0) AS n FROM usage_counters WHERE name = ?").get(n).n]));
  let second, u, before0, after0;

  before(async () => {
    u = user();
    before0 = totals();
    second = await startServer(PORT2);
    const h = uuid();
    assert.equal((await push(u.token, encode122({ habits: [habit(h, { records: [record(uuid(), "2026-10-01")] })] }), { base: BASE2 })).status, 426);
    assert.equal((await push(u.token, encode11({ habits: [habit(h, { records: [record(uuid(), "2026-10-01")] }), habit(uuid())] }), { base: BASE2, mount: "/sync/push" })).status, 426);
    assert.equal((await push(u.token, encode140({ habits: [habit(h, { records: [record(uuid(), "2026-10-01")] })] }), { base: BASE2, client: V140 })).status, 200);
    await stopServer(second.proc);   // SIGTERM flushes the counters
    after0 = totals();
  });
  after(async () => { await stopServer(second?.proc); });

  it("legacy_push_refused per refused push, habit_without_kind per habit, nothing for the accepted one", () => {
    assert.deepEqual(Object.fromEntries(NAMES.map((n) => [n, after0[n] - before0[n]])), {
      legacy_push_refused: 2, habit_without_kind: 2,
    });
  });

  it("one line per refusal, with the user id and the shape, and no email", () => {
    const lines = second.out.stderr.split("\n").filter((l) => l.includes("refused legacy-shaped push"));
    assert.deepEqual(lines.map((l) => l.replace(/^.*\[sync\]/, "[sync]")), [
      `[sync] push user=${u.userId} refused legacy-shaped push: 1 entries without updatedAt, 0 habits without kind`,
      `[sync] push user=${u.userId} refused legacy-shaped push: 1 entries without updatedAt, 2 habits without kind`,
    ]);
    assert.ok(!second.out.stderr.includes(u.email) && !second.out.stdout.includes(u.email));
    assert.match(second.out.stdout, new RegExp(`POST /v1/sync/push 426 \\d+ms client=- sync user=${u.userId} legacyRefused=entries:1,habits:0(\\s|$)`));
    assert.match(second.out.stdout, new RegExp(`POST /sync/push 426 \\d+ms client=- sync user=${u.userId} legacyRefused=entries:1,habits:2(\\s|$)`));
  });
});
