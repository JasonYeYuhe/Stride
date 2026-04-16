const { describe, it, before, after } = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const crypto = require("node:crypto");
const path = require("node:path");
const Database = require("better-sqlite3");

const PORT = 3099;
const BASE = `http://localhost:${PORT}`;
const DB_PATH = path.join(__dirname, "..", "stride.db");

// ---------- helpers ----------

let serverProcess;
let db;

/** Hash a token the same way auth.js does */
function hashToken(token) {
  return crypto.createHash("sha256").update(token).digest("hex");
}

/** Create a test user directly in the DB, return { userId, email } */
function createTestUser(email = `test-${crypto.randomUUID()}@stride-test.local`) {
  db.prepare("INSERT OR IGNORE INTO users (email) VALUES (?)").run(email);
  const user = db.prepare("SELECT id, email FROM users WHERE email = ?").get(email);
  return { userId: user.id, email: user.email };
}

/** Create a session for a user, return the raw token for Authorization header */
function createTestSession(userId) {
  const token = crypto.randomBytes(32).toString("hex");
  const tokenHash = hashToken(token);
  const expiresAt = Date.now() + 1000 * 60 * 60 * 24; // 24h
  db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)").run(
    userId,
    tokenHash,
    expiresAt,
  );
  return token;
}

/** Make an authenticated request */
async function api(method, urlPath, { body, token, query } = {}) {
  let url = `${BASE}${urlPath}`;
  if (query) {
    const qs = new URLSearchParams(query).toString();
    url += `?${qs}`;
  }
  const opts = {
    method,
    headers: {},
  };
  if (token) opts.headers["Authorization"] = `Bearer ${token}`;
  if (body !== undefined) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(url, opts);
  const json = await res.json().catch(() => null);
  return { status: res.status, json };
}

/** Wait until the server responds on /health */
async function waitForServer(maxMs = 8000) {
  const start = Date.now();
  while (Date.now() - start < maxMs) {
    try {
      const r = await fetch(`${BASE}/health`);
      if (r.ok) return;
    } catch {
      // not ready yet
    }
    await new Promise((r) => setTimeout(r, 150));
  }
  throw new Error(`Server did not start within ${maxMs}ms`);
}

// ---------- lifecycle ----------

before(async () => {
  // Open db connection for test helpers
  db = new Database(DB_PATH);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");

  // Spawn the server
  serverProcess = spawn(process.execPath, [path.join(__dirname, "..", "index.js")], {
    env: { ...process.env, PORT: String(PORT), NODE_ENV: "test" },
    stdio: "pipe",
  });

  serverProcess.stderr.on("data", (d) => process.stderr.write(d));

  await waitForServer();
});

after(() => {
  // Kill server
  if (serverProcess) {
    serverProcess.kill("SIGTERM");
    serverProcess = null;
  }
  // Close db
  if (db && db.open) {
    db.close();
  }
});

// ================================================================
// Tests
// ================================================================

describe("Health", () => {
  it("GET /health returns ok and version", async () => {
    const { status, json } = await api("GET", "/health");
    assert.equal(status, 200);
    assert.equal(json.ok, true);
    assert.equal(json.version, "1.0.0");
    assert.ok(Array.isArray(json.apiVersions));
    assert.ok(typeof json.uptime === "number");
  });
});

// ----------------------------------------------------------------

describe("Static pages", () => {
  for (const page of ["/privacy", "/terms", "/support"]) {
    it(`GET ${page} returns 200`, async () => {
      const res = await fetch(`${BASE}${page}`);
      assert.equal(res.status, 200);
      const text = await res.text();
      assert.ok(text.includes("<!DOCTYPE html") || text.includes("<html"), `${page} should return HTML`);
    });
  }
});

// ----------------------------------------------------------------

describe("Auth", () => {
  it("POST /v1/auth/request-link rejects invalid email", async () => {
    const { status, json } = await api("POST", "/v1/auth/request-link", { body: { email: "bad" } });
    assert.equal(status, 400);
    assert.ok(json.error);
  });

  it("POST /v1/auth/verify rejects missing token", async () => {
    const { status, json } = await api("POST", "/v1/auth/verify", { body: {} });
    assert.equal(status, 400);
    assert.ok(json.error);
  });

  it("POST /v1/auth/verify rejects invalid token", async () => {
    const { status, json } = await api("POST", "/v1/auth/verify", { body: { token: "bogus" } });
    assert.equal(status, 400);
    assert.match(json.error, /invalid|expired/i);
  });

  it("full magic link flow: request-link -> extract token from db -> verify -> session", async () => {
    const email = `flow-${crypto.randomUUID()}@stride-test.local`;

    // Create user + magic link token directly in DB (since we can't actually send email in tests)
    const user = createTestUser(email);
    const rawToken = crypto.randomBytes(32).toString("hex");
    const tokenHash = hashToken(rawToken);
    const expiresAt = Date.now() + 1000 * 60 * 30;
    db.prepare("INSERT INTO magic_link_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)").run(
      user.userId,
      tokenHash,
      expiresAt,
    );

    // Verify the token via API
    const { status, json } = await api("POST", "/v1/auth/verify", { body: { token: rawToken } });
    assert.equal(status, 200);
    assert.equal(json.ok, true);
    assert.ok(json.sessionToken);
    assert.equal(json.user.email, email);

    // Use the returned session token to call /session
    const sess = await api("GET", "/v1/auth/session", { token: json.sessionToken });
    assert.equal(sess.status, 200);
    assert.equal(sess.json.user.email, email);

    // Cleanup
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(user.userId);
    db.prepare("DELETE FROM magic_link_tokens WHERE user_id = ?").run(user.userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(user.userId);
  });

  it("GET /v1/auth/session returns null user when unauthenticated", async () => {
    const { status, json } = await api("GET", "/v1/auth/session");
    assert.equal(status, 200);
    assert.equal(json.user, null);
  });

  it("POST /v1/auth/logout returns ok", async () => {
    const { status, json } = await api("POST", "/v1/auth/logout");
    assert.equal(status, 200);
    assert.equal(json.ok, true);
  });
});

// ----------------------------------------------------------------

describe("Auth required (401)", () => {
  const protectedRoutes = [
    ["GET", "/v1/habits"],
    ["POST", "/v1/habits"],
    ["PUT", "/v1/habits/fake-id"],
    ["DELETE", "/v1/habits/fake-id"],
    ["POST", "/v1/habits/fake-id/entries"],
    ["GET", "/v1/habits/fake-id/entries"],
    ["DELETE", "/v1/habits/fake-id/entries/2025-01-01"],
    ["POST", "/v1/sync/push"],
    ["GET", "/v1/sync/pull"],
  ];

  for (const [method, urlPath] of protectedRoutes) {
    it(`${method} ${urlPath} returns 401 without auth`, async () => {
      const { status } = await api(method, urlPath, { body: method !== "GET" ? {} : undefined });
      assert.equal(status, 401);
    });
  }
});

// ----------------------------------------------------------------

describe("Habits CRUD", () => {
  let token;
  let userId;
  let habitId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    // Cleanup everything for this user
    const habits = db.prepare("SELECT id FROM habits WHERE user_id = ?").all(userId);
    for (const h of habits) {
      db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(h.id);
    }
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST /v1/habits creates a habit", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Read books", emoji: "📚", colorHex: "#FF0000" },
    });
    assert.equal(status, 201);
    assert.ok(json.habit);
    assert.equal(json.habit.name, "Read books");
    assert.equal(json.habit.emoji, "📚");
    assert.equal(json.habit.color_hex, "#FF0000");
    habitId = json.habit.id;
  });

  it("GET /v1/habits lists habits with pagination", async () => {
    // Create a second habit
    await api("POST", "/v1/habits", { token, body: { name: "Exercise" } });

    const { status, json } = await api("GET", "/v1/habits", { token, query: { limit: "1", offset: "0" } });
    assert.equal(status, 200);
    assert.equal(json.habits.length, 1);
    assert.ok(json.pagination);
    assert.equal(json.pagination.total, 2);
    assert.equal(json.pagination.hasMore, true);

    // Second page
    const page2 = await api("GET", "/v1/habits", { token, query: { limit: "1", offset: "1" } });
    assert.equal(page2.json.habits.length, 1);
    assert.equal(page2.json.pagination.hasMore, false);
  });

  it("PUT /v1/habits/:id updates a habit", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { name: "Read daily", emoji: "📖", isArchived: true },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.name, "Read daily");
    assert.equal(json.habit.emoji, "📖");
    assert.equal(json.habit.is_archived, 1);
  });

  it("PUT /v1/habits/:id returns 404 for nonexistent habit", async () => {
    const { status } = await api("PUT", "/v1/habits/nonexistent-id", {
      token,
      body: { name: "Nope" },
    });
    assert.equal(status, 404);
  });

  it("DELETE /v1/habits/:id deletes a habit", async () => {
    // Create one to delete
    const create = await api("POST", "/v1/habits", { token, body: { name: "To delete" } });
    const id = create.json.habit.id;

    const { status, json } = await api("DELETE", `/v1/habits/${id}`, { token });
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    // Verify gone
    const { status: s2 } = await api("PUT", `/v1/habits/${id}`, { token, body: { name: "ghost" } });
    assert.equal(s2, 404);
  });

  it("DELETE /v1/habits/:id returns 404 for nonexistent habit", async () => {
    const { status } = await api("DELETE", "/v1/habits/nonexistent-id", { token });
    assert.equal(status, 404);
  });
});

// ----------------------------------------------------------------

describe("Habit entries", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Meditate" } });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST /v1/habits/:id/entries creates an entry", async () => {
    const { status, json } = await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { date: "2025-06-15" },
    });
    assert.equal(status, 201);
    assert.equal(json.entry.date, "2025-06-15");
    assert.equal(json.entry.habit_id, habitId);
  });

  it("POST /v1/habits/:id/entries rejects duplicate date", async () => {
    const { status } = await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { date: "2025-06-15" },
    });
    assert.equal(status, 409);
  });

  it("GET /v1/habits/:id/entries lists entries with pagination", async () => {
    // Add more entries
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: "2025-06-16" } });
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: "2025-06-17" } });

    const { status, json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { limit: "2", offset: "0" },
    });
    assert.equal(status, 200);
    assert.equal(json.entries.length, 2);
    assert.equal(json.pagination.total, 3);
    assert.equal(json.pagination.hasMore, true);
  });

  it("GET /v1/habits/:id/entries supports date range filter", async () => {
    const { json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { from: "2025-06-16", to: "2025-06-17" },
    });
    assert.equal(json.entries.length, 2);
    assert.equal(json.pagination.total, 2);
  });

  it("DELETE /v1/habits/:id/entries/:date removes an entry", async () => {
    const { status, json } = await api("DELETE", `/v1/habits/${habitId}/entries/2025-06-17`, { token });
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    // Verify it's gone
    const list = await api("GET", `/v1/habits/${habitId}/entries`, { token });
    const dates = list.json.entries.map((e) => e.date);
    assert.ok(!dates.includes("2025-06-17"));
  });

  it("returns 404 for entries on nonexistent habit", async () => {
    const { status } = await api("POST", "/v1/habits/nonexistent/entries", {
      token,
      body: { date: "2025-01-01" },
    });
    assert.equal(status, 404);
  });
});

// ----------------------------------------------------------------

describe("Validation", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Valid habit" } });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("rejects habit with missing name", async () => {
    const { status, json } = await api("POST", "/v1/habits", { token, body: {} });
    assert.equal(status, 400);
    assert.match(json.error, /name/i);
  });

  it("rejects habit with empty name", async () => {
    const { status } = await api("POST", "/v1/habits", { token, body: { name: "   " } });
    assert.equal(status, 400);
  });

  it("rejects habit name longer than 100 characters", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "x".repeat(101) },
    });
    assert.equal(status, 400);
    assert.match(json.error, /100/);
  });

  it("rejects entry with missing date", async () => {
    const { status, json } = await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: {},
    });
    assert.equal(status, 400);
    assert.match(json.error, /date/i);
  });

  it("rejects entry with bad date format", async () => {
    const { status, json } = await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { date: "June 15" },
    });
    assert.equal(status, 400);
    assert.match(json.error, /YYYY-MM-DD/i);
  });

  it("rejects entry with invalid date value", async () => {
    const { status, json } = await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { date: "2025-02-30" },
    });
    assert.equal(status, 400);
    assert.match(json.error, /invalid|date/i);
  });
});

// ----------------------------------------------------------------

describe("Sync", () => {
  let token;
  let userId;
  const pushedHabitId = crypto.randomUUID();
  const pushedEntryId = crypto.randomUUID();

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(pushedHabitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST /v1/sync/push upserts habits and entries", async () => {
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [
          {
            id: pushedHabitId,
            name: "Synced habit",
            emoji: "🔄",
            colorHex: "#0000FF",
            isArchived: false,
            sortOrder: 0,
          },
        ],
        entries: [
          {
            id: pushedEntryId,
            habitId: pushedHabitId,
            date: "2025-07-01",
          },
        ],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);
  });

  it("GET /v1/sync/pull returns pushed data", async () => {
    const { status, json } = await api("GET", "/v1/sync/pull", { token });
    assert.equal(status, 200);
    assert.ok(json.serverTime);

    const habit = json.habits.find((h) => h.id === pushedHabitId);
    assert.ok(habit);
    assert.equal(habit.name, "Synced habit");
    assert.equal(habit.colorHex, "#0000FF");

    const entry = json.entries.find((e) => e.id === pushedEntryId);
    assert.ok(entry);
    assert.equal(entry.date, "2025-07-01");
    assert.equal(entry.habitId, pushedHabitId);
  });

  it("GET /v1/sync/pull with ?since filters by timestamp", async () => {
    // Use a future timestamp so nothing matches
    const future = new Date(Date.now() + 86400000 * 365).toISOString();
    const { json } = await api("GET", "/v1/sync/pull", { token, query: { since: future } });
    assert.equal(json.habits.length, 0);
    // entries may still show up depending on created_at vs since, but habits should be empty
  });

  it("POST /v1/sync/push handles deletes", async () => {
    const deleteHabitId = crypto.randomUUID();

    // First push a habit
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: deleteHabitId, name: "Will delete", sortOrder: 0 }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Then push a delete
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [],
        entries: [],
        deletedHabitIds: [deleteHabitId],
        deletedEntryIds: [],
      },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    // Verify gone from pull
    const pull = await api("GET", "/v1/sync/pull", { token });
    const found = pull.json.habits.find((h) => h.id === deleteHabitId);
    assert.equal(found, undefined);
  });

  it("reminder and note fields round-trip through push/pull", async () => {
    const habitId = crypto.randomUUID();
    const entryId = crypto.randomUUID();

    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{
          id: habitId,
          name: "Reminder habit",
          emoji: "⏰",
          colorHex: "#FF0000",
          isArchived: false,
          sortOrder: 1,
          reminderEnabled: true,
          reminderHour: 9,
          reminderMinute: 30,
          note: "habit-level note",
        }],
        entries: [{
          id: entryId,
          habitId: habitId,
          date: "2025-08-01",
          note: "entry-level note",
        }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    const habit = pull.json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "habit should exist in pull");
    assert.equal(habit.reminderEnabled, true);
    assert.equal(habit.reminderHour, 9);
    assert.equal(habit.reminderMinute, 30);
    assert.equal(habit.note, "habit-level note");

    const entry = pull.json.entries.find((e) => e.id === entryId);
    assert.ok(entry, "entry should exist in pull");
    assert.equal(entry.note, "entry-level note");

    // Cleanup
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
  });

  it("deletion tombstones propagate via pull with ?since", async () => {
    const habitId = crypto.randomUUID();
    const entryId = crypto.randomUUID();

    // Push a habit + entry
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Will be tombstoned", sortOrder: 0 }],
        entries: [{ id: entryId, habitId: habitId, date: "2025-09-01" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Record a "since" timestamp before deletion
    const beforeDelete = new Date(Date.now() - 1000).toISOString();

    // Push deletes
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [],
        entries: [],
        deletedHabitIds: [habitId],
        deletedEntryIds: [entryId],
      },
    });

    // Pull with ?since should contain tombstones
    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: beforeDelete } });
    assert.ok(Array.isArray(pull.json.deletedHabitIds), "deletedHabitIds should be an array");
    assert.ok(Array.isArray(pull.json.deletedEntryIds), "deletedEntryIds should be an array");
    assert.ok(pull.json.deletedHabitIds.includes(habitId), "deleted habit should appear in tombstones");
    assert.ok(pull.json.deletedEntryIds.includes(entryId), "deleted entry should appear in tombstones");

    // Cleanup tombstones
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
  });

  it("full pull returns entry for a date even if pushed with different id than CRUD-created", async () => {
    const habitId = crypto.randomUUID();
    const crudEntryId = crypto.randomUUID();
    const pushEntryId = crypto.randomUUID();

    // Push habit via sync
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "ID conflict habit", sortOrder: 0 }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Create entry via CRUD route (gets its own ID)
    await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { id: crudEntryId, date: "2025-10-10" },
    });

    // Now push same date via sync with a different ID — ON CONFLICT(habit_id,date) keeps existing
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [],
        entries: [{ id: pushEntryId, habitId, date: "2025-10-10", note: "from push" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Full pull: the date should still have exactly one entry
    const pull = await api("GET", "/v1/sync/pull", { token });
    const dateEntries = pull.json.entries.filter(
      (e) => e.habitId === habitId && e.date === "2025-10-10",
    );
    assert.equal(dateEntries.length, 1, "should have exactly one entry for that date");
    // Note should have been updated by the ON CONFLICT DO UPDATE
    assert.equal(dateEntries[0].note, "from push");

    // Cleanup
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
  });

  it("deleted habit cannot be resurrected by concurrent push", async () => {
    const habitId = crypto.randomUUID();

    // Push with both the habit data AND a delete for it — delete should win
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Ghost", sortOrder: 0 }],
        entries: [],
        deletedHabitIds: [habitId],
        deletedEntryIds: [],
      },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    const found = pull.json.habits.find((h) => h.id === habitId);
    assert.equal(found, undefined, "deleted habit should not reappear");

    // Cleanup tombstones
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
  });
});

// ----------------------------------------------------------------

describe("Sync timestamp consistency", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    const habits = db.prepare("SELECT id FROM habits WHERE user_id = ?").all(userId);
    for (const h of habits) {
      db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(h.id);
    }
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("habit created via CRUD route is visible in sync pull with ?since", async () => {
    const beforeCreate = new Date(Date.now() - 1000).toISOString();

    // Create habit via CRUD route (not sync/push)
    const { json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "CRUD habit", emoji: "🛠️" },
    });
    const habitId = json.habit.id;

    // Pull with since=beforeCreate should include it
    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: beforeCreate } });
    const found = pull.json.habits.find((h) => h.id === habitId);
    assert.ok(found, "CRUD-created habit should appear in incremental sync pull");
    assert.equal(found.name, "CRUD habit");
  });

  it("habit updated via CRUD route is visible in sync pull with ?since", async () => {
    // Create a habit
    const { json: created } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Before update" },
    });
    const habitId = created.habit.id;

    // Wait a tick so the timestamps differ
    await new Promise((r) => setTimeout(r, 50));
    const beforeUpdate = new Date(Date.now() - 10).toISOString();

    // Update via CRUD
    await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { name: "After update" },
    });

    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: beforeUpdate } });
    const found = pull.json.habits.find((h) => h.id === habitId);
    assert.ok(found, "CRUD-updated habit should appear in incremental sync pull");
    assert.equal(found.name, "After update");
  });

  it("entry created via CRUD route is visible in sync pull with ?since", async () => {
    // Create habit
    const { json: created } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Entry test habit" },
    });
    const habitId = created.habit.id;

    const beforeEntry = new Date(Date.now() - 1000).toISOString();

    // Create entry via CRUD route
    await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { date: "2025-11-15" },
    });

    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: beforeEntry } });
    const found = pull.json.entries.find((e) => e.date === "2025-11-15");
    assert.ok(found, "CRUD-created entry should appear in incremental sync pull");
    assert.equal(found.habitId, habitId);
  });

  it("legacy space-format timestamps are migrated and visible in pull with ?since", async () => {
    const habitId = crypto.randomUUID();
    const entryId = crypto.randomUUID();

    // Directly insert rows with old datetime('now')-style format (space, no T, no Z)
    const legacyTs = "2025-06-01 12:00:00";
    db.prepare(`
      INSERT INTO habits (id, user_id, name, emoji, color_hex, sort_order, created_at, updated_at)
      VALUES (?, ?, ?, '⭐', '#34C759', 0, ?, ?)
    `).run(habitId, userId, "Legacy habit", legacyTs, legacyTs);

    db.prepare(`
      INSERT INTO habit_entries (id, habit_id, date, created_at)
      VALUES (?, ?, '2025-06-01', ?)
    `).run(entryId, habitId, legacyTs);

    // Run the migration manually (same SQL as db.js migrateIfNeeded)
    db.exec(`
      UPDATE habits SET
        created_at = REPLACE(created_at, ' ', 'T') || 'Z',
        updated_at = REPLACE(updated_at, ' ', 'T') || 'Z'
      WHERE created_at LIKE '%-%-% %:%:%' AND created_at NOT LIKE '%T%';

      UPDATE habit_entries SET
        created_at = REPLACE(created_at, ' ', 'T') || 'Z'
      WHERE created_at LIKE '%-%-% %:%:%' AND created_at NOT LIKE '%T%';
    `);

    // Verify the migrated timestamps are ISO8601
    const row = db.prepare("SELECT created_at, updated_at FROM habits WHERE id = ?").get(habitId);
    assert.ok(row.created_at.includes("T"), `migrated created_at should contain T, got: ${row.created_at}`);
    assert.ok(row.updated_at.includes("T"), `migrated updated_at should contain T, got: ${row.updated_at}`);

    // Pull with since= before the legacy timestamp should include it
    const beforeLegacy = "2025-05-01T00:00:00.000Z";
    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: beforeLegacy } });
    const habit = pull.json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "migrated legacy habit should appear in incremental pull");

    const entry = pull.json.entries.find((e) => e.id === entryId);
    assert.ok(entry, "migrated legacy entry should appear in incremental pull");

    // Cleanup
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
  });

  it("all timestamps in pull response are ISO8601 format", async () => {
    // Create via CRUD
    const { json: created } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Timestamp format test" },
    });
    const habitId = created.habit.id;

    await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { date: "2025-12-01" },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    const habit = pull.json.habits.find((h) => h.id === habitId);
    assert.ok(habit);

    // ISO8601 has 'T' separator and ends with 'Z'
    assert.ok(habit.createdAt.includes("T"), `createdAt should be ISO8601, got: ${habit.createdAt}`);
    assert.ok(habit.updatedAt.includes("T"), `updatedAt should be ISO8601, got: ${habit.updatedAt}`);

    const entry = pull.json.entries.find((e) => e.habitId === habitId);
    assert.ok(entry);
    assert.ok(entry.createdAt.includes("T"), `entry createdAt should be ISO8601, got: ${entry.createdAt}`);
  });
});

// ----------------------------------------------------------------

describe("Stats", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Run" } });
    habitId = json.habit.id;

    // Add consecutive entries for streak testing
    const today = new Date();
    for (let i = 0; i < 5; i++) {
      const d = new Date(today);
      d.setDate(d.getDate() - i);
      const dateStr = d.toISOString().slice(0, 10);
      await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: dateStr } });
    }
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /v1/habits/:id/stats returns streak and completion data", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/stats`, { token });
    assert.equal(status, 200);
    assert.ok(json.currentStreak >= 4); // at least 4 consecutive days (today might not count depending on timing)
    assert.ok(json.bestStreak >= 4);
    assert.equal(json.totalEntries, 5);
    assert.ok(typeof json.completionRate === "number");
    assert.ok(json.completionRate > 0 && json.completionRate <= 1);
  });

  it("GET /v1/habits/:id/stats returns 404 for nonexistent habit", async () => {
    const { status } = await api("GET", "/v1/habits/fake-id/stats", { token });
    assert.equal(status, 404);
  });
});

// ----------------------------------------------------------------

describe("Auth: delete account", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    // Create a habit and entry so we can verify cascade deletion
    const { json } = await api("POST", "/v1/habits", { token, body: { name: "To delete" } });
    habitId = json.habit.id;
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: "2025-06-01" } });
  });

  // No after() cleanup — delete-account should clean up everything

  it("POST /v1/auth/delete-account returns ok", async () => {
    const { status, json } = await api("POST", "/v1/auth/delete-account", { token });
    assert.equal(status, 200);
    assert.equal(json.ok, true);
  });

  it("subsequent requests with the same token return 401", async () => {
    const { status } = await api("GET", "/v1/habits", { token });
    assert.equal(status, 401);
  });

  it("user and all habits/entries are deleted from database", () => {
    const user = db.prepare("SELECT id FROM users WHERE id = ?").get(userId);
    assert.equal(user, undefined, "User should be deleted");

    const habits = db.prepare("SELECT id FROM habits WHERE user_id = ?").all(userId);
    assert.equal(habits.length, 0, "All habits should be deleted");

    const entries = db.prepare("SELECT id FROM habit_entries WHERE habit_id = ?").all(habitId);
    assert.equal(entries.length, 0, "All entries should be deleted");
  });
});

// ----------------------------------------------------------------

describe("Auth: session expiration", () => {
  let expiredToken;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;

    // Create a session that already expired (1 second in the past)
    expiredToken = crypto.randomBytes(32).toString("hex");
    const tokenHash = hashToken(expiredToken);
    const expiredAt = Date.now() - 1000;
    db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)").run(
      userId,
      tokenHash,
      expiredAt,
    );
  });

  after(() => {
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("expired session token returns 401", async () => {
    const { status } = await api("GET", "/v1/habits", { token: expiredToken });
    assert.equal(status, 401);
  });
});
