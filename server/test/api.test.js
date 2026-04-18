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

  it("POST /v1/habits creates habit with reminder and note fields", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Morning Alarm", reminderEnabled: true, reminderHour: 7, reminderMinute: 30, note: "wake up!" },
    });
    assert.equal(status, 201);
    assert.equal(json.habit.reminder_enabled, 1);
    assert.equal(json.habit.reminder_hour, 7);
    assert.equal(json.habit.reminder_minute, 30);
    assert.equal(json.habit.note, "wake up!");
  });

  it("GET /v1/habits returns reminder and note fields", async () => {
    const { status, json } = await api("GET", "/v1/habits", { token });
    assert.equal(status, 200);
    const h = json.habits.find((x) => x.note === "wake up!");
    assert.ok(h, "habit with note should be in list");
    assert.equal(h.reminder_enabled, 1);
    assert.equal(h.reminder_hour, 7);
    assert.equal(h.reminder_minute, 30);
  });

  it("PUT /v1/habits/:id updates reminder and note fields", async () => {
    const create = await api("POST", "/v1/habits", { token, body: { name: "Yoga" } });
    const id = create.json.habit.id;

    // Defaults: no reminder, no note
    assert.equal(create.json.habit.reminder_enabled, 0);
    assert.equal(create.json.habit.note, null);

    // Update reminder + note
    const { status, json } = await api("PUT", `/v1/habits/${id}`, {
      token,
      body: { reminderEnabled: true, reminderHour: 6, reminderMinute: 0, note: "stretch first" },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.reminder_enabled, 1);
    assert.equal(json.habit.reminder_hour, 6);
    assert.equal(json.habit.reminder_minute, 0);
    assert.equal(json.habit.note, "stretch first");
  });

  it("PUT /v1/habits/:id clears note when explicitly set to null", async () => {
    const create = await api("POST", "/v1/habits", { token, body: { name: "Run", note: "10km" } });
    const id = create.json.habit.id;
    assert.equal(create.json.habit.note, "10km");

    const { json } = await api("PUT", `/v1/habits/${id}`, { token, body: { note: null } });
    assert.equal(json.habit.note, null);
  });

  it("PUT /v1/habits/:id preserves note when not included in body", async () => {
    const create = await api("POST", "/v1/habits", { token, body: { name: "Swim", note: "pool at 8am" } });
    const id = create.json.habit.id;

    // Update only the name — note should be unchanged
    const { json } = await api("PUT", `/v1/habits/${id}`, { token, body: { name: "Swim (open water)" } });
    assert.equal(json.habit.name, "Swim (open water)");
    assert.equal(json.habit.note, "pool at 8am");
  });

  it("POST /v1/habits rejects out-of-range reminderHour", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Night Habit", reminderEnabled: true, reminderHour: 24, reminderMinute: 0 },
    });
    assert.equal(status, 400);
    assert.match(json.error, /reminderHour/);
  });

  it("POST /v1/habits rejects out-of-range reminderMinute", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Bad Minute Habit", reminderEnabled: true, reminderHour: 8, reminderMinute: 60 },
    });
    assert.equal(status, 400);
    assert.match(json.error, /reminderMinute/);
  });

  it("POST /v1/habits rejects negative reminderHour", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Neg Hour Habit", reminderEnabled: true, reminderHour: -1, reminderMinute: 0 },
    });
    assert.equal(status, 400);
    assert.match(json.error, /reminderHour/);
  });

  it("PUT /v1/habits/:id rejects out-of-range reminderHour", async () => {
    const create = await api("POST", "/v1/habits", { token, body: { name: "Update Reminder Test" } });
    const id = create.json.habit.id;
    const { status, json } = await api("PUT", `/v1/habits/${id}`, {
      token,
      body: { reminderHour: 99 },
    });
    assert.equal(status, 400);
    assert.match(json.error, /reminderHour/);
  });

  it("PUT /v1/habits/:id rejects out-of-range reminderMinute", async () => {
    const create = await api("POST", "/v1/habits", { token, body: { name: "Update Minute Test" } });
    const id = create.json.habit.id;
    const { status, json } = await api("PUT", `/v1/habits/${id}`, {
      token,
      body: { reminderMinute: -5 },
    });
    assert.equal(status, 400);
    assert.match(json.error, /reminderMinute/);
  });

  it("POST /v1/habits accepts valid boundary reminder values (0:0 and 23:59)", async () => {
    const { status: s1, json: j1 } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Midnight Habit", reminderEnabled: true, reminderHour: 0, reminderMinute: 0 },
    });
    assert.equal(s1, 201);
    assert.equal(j1.habit.reminder_hour, 0);
    assert.equal(j1.habit.reminder_minute, 0);

    const { status: s2, json: j2 } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Late Night Habit", reminderEnabled: true, reminderHour: 23, reminderMinute: 59 },
    });
    assert.equal(s2, 201);
    assert.equal(j2.habit.reminder_hour, 23);
    assert.equal(j2.habit.reminder_minute, 59);
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

  it("CRUD DELETE /habits/:id creates a tombstone visible in incremental sync pull", async () => {
    const habitId = crypto.randomUUID();

    // Create via CRUD
    await api("POST", "/v1/habits", { token, body: { id: habitId, name: "CRUD tombstone target" } });

    const beforeDelete = new Date(Date.now() - 1000).toISOString();

    // Delete via CRUD route (not sync push)
    const { status } = await api("DELETE", `/v1/habits/${habitId}`, { token });
    assert.equal(status, 200);

    // Incremental pull with ?since should include the habit in deletedHabitIds
    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: beforeDelete } });
    assert.ok(Array.isArray(pull.json.deletedHabitIds), "deletedHabitIds should be an array");
    assert.ok(
      pull.json.deletedHabitIds.includes(habitId),
      "CRUD-deleted habit should appear in tombstones on incremental pull",
    );

    // Habit should not appear in habits array
    const found = pull.json.habits.find((h) => h.id === habitId);
    assert.equal(found, undefined, "deleted habit should not appear in habits list");

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

  it("entry deleted via CRUD route creates tombstone visible in sync pull with ?since", async () => {
    // Create habit + entry
    const { json: created } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Tombstone entry test" },
    });
    const habitId = created.habit.id;

    const { json: entryRes } = await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { date: "2025-11-20" },
    });
    const entryId = entryRes.entry.id;

    const beforeDelete = new Date(Date.now() - 1000).toISOString();

    // Delete the entry via CRUD route
    await api("DELETE", `/v1/habits/${habitId}/entries/2025-11-20`, { token });

    // Incremental pull should return the entry id in deletedEntryIds
    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: beforeDelete } });
    assert.ok(Array.isArray(pull.json.deletedEntryIds), "deletedEntryIds should be an array");
    assert.ok(pull.json.deletedEntryIds.includes(entryId),
      `deleted entry ${entryId} should appear in tombstones`);
    // The entry itself should not appear in the entries list
    const stillPresent = pull.json.entries.find((e) => e.id === entryId);
    assert.equal(stillPresent, undefined, "deleted entry should not appear in entries list");
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

describe("Stats: broken streak", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Meditate" } });
    habitId = json.habit.id;

    // 5 entries from 6 days ago to 2 days ago — no entry today or yesterday
    for (let i = 6; i >= 2; i--) {
      const d = new Date();
      d.setDate(d.getDate() - i);
      await api("POST", `/v1/habits/${habitId}/entries`, {
        token,
        body: { date: d.toISOString().slice(0, 10) },
      });
    }
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("currentStreak is 0 when last entry was >1 day ago", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/stats`, { token });
    assert.equal(status, 200);
    assert.equal(json.currentStreak, 0);
    assert.equal(json.bestStreak, 5);
    assert.equal(json.totalEntries, 5);
  });
});

// ----------------------------------------------------------------

describe("Stats: best streak with gap", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Read" } });
    habitId = json.habit.id;

    // 3 consecutive days (-15,-14,-13), gap at -12, then 2 more (-11,-10)
    for (const offset of [15, 14, 13, 11, 10]) {
      const d = new Date();
      d.setDate(d.getDate() - offset);
      await api("POST", `/v1/habits/${habitId}/entries`, {
        token,
        body: { date: d.toISOString().slice(0, 10) },
      });
    }
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("bestStreak is the longest consecutive run, ignoring gaps", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/stats`, { token });
    assert.equal(status, 200);
    assert.equal(json.bestStreak, 3);
    assert.equal(json.currentStreak, 0);
    assert.equal(json.totalEntries, 5);
  });
});

// ----------------------------------------------------------------

describe("Stats: completionRate for new habit", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Journal" } });
    habitId = json.habit.id;

    // Single entry for today
    const today = new Date().toISOString().slice(0, 10);
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: today } });
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("completionRate is 1.0 when habit created today with one entry", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/stats`, { token });
    assert.equal(status, 200);
    assert.equal(json.completionRate, 1);
    assert.equal(json.currentStreak, 1);
    assert.equal(json.bestStreak, 1);
    assert.equal(json.totalEntries, 1);
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

describe("Auth: reusable magic link tokens", () => {
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
  });

  after(() => {
    db.prepare("DELETE FROM magic_link_tokens WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("reusable token can be verified multiple times", async () => {
    const rawToken = crypto.randomBytes(32).toString("hex");
    const tokenHash = hashToken(rawToken);
    const expiresAt = Date.now() + 1000 * 60 * 30; // 30 min
    db.prepare(
      "INSERT INTO magic_link_tokens (user_id, token_hash, expires_at, is_reusable) VALUES (?, ?, ?, 1)"
    ).run(userId, tokenHash, expiresAt);

    const first = await api("POST", "/v1/auth/verify", { body: { token: rawToken } });
    assert.equal(first.status, 200, "first verification should succeed");
    assert.ok(first.json.sessionToken, "first call should return session token");

    const second = await api("POST", "/v1/auth/verify", { body: { token: rawToken } });
    assert.equal(second.status, 200, "second verification should also succeed (reusable)");
    assert.ok(second.json.sessionToken, "second call should return a new session token");
  });

  it("reusable token does not have used_at set after use", async () => {
    const rawToken = crypto.randomBytes(32).toString("hex");
    const tokenHash = hashToken(rawToken);
    const expiresAt = Date.now() + 1000 * 60 * 30;
    db.prepare(
      "INSERT INTO magic_link_tokens (user_id, token_hash, expires_at, is_reusable) VALUES (?, ?, ?, 1)"
    ).run(userId, tokenHash, expiresAt);

    await api("POST", "/v1/auth/verify", { body: { token: rawToken } });

    const record = db.prepare("SELECT used_at FROM magic_link_tokens WHERE token_hash = ?").get(tokenHash);
    assert.ok(record, "token record should still exist after use");
    assert.equal(record.used_at, null, "used_at should remain null for reusable tokens");
  });

  it("normal token is single-use only", async () => {
    const rawToken = crypto.randomBytes(32).toString("hex");
    const tokenHash = hashToken(rawToken);
    const expiresAt = Date.now() + 1000 * 60 * 30;
    db.prepare(
      "INSERT INTO magic_link_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)"
    ).run(userId, tokenHash, expiresAt);

    const first = await api("POST", "/v1/auth/verify", { body: { token: rawToken } });
    assert.equal(first.status, 200, "first use should succeed");

    const second = await api("POST", "/v1/auth/verify", { body: { token: rawToken } });
    assert.equal(second.status, 400, "second use of normal token should fail");
  });
});

// ----------------------------------------------------------------

describe("Sync: cross-user isolation", () => {
  let userAToken;
  let userAId;
  let userBToken;
  let userBId;
  let habitAId;

  before(async () => {
    const userA = createTestUser();
    userAId = userA.userId;
    userAToken = createTestSession(userAId);

    const userB = createTestUser();
    userBId = userB.userId;
    userBToken = createTestSession(userBId);

    // Create a habit owned by user A via sync push
    habitAId = crypto.randomUUID();
    await api("POST", "/v1/sync/push", {
      token: userAToken,
      body: {
        habits: [{ id: habitAId, name: "User A Habit", emoji: "🏃", colorHex: "#FF0000",
                   isArchived: false, sortOrder: 0, reminderEnabled: false,
                   reminderHour: 20, reminderMinute: 0, note: null,
                   createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userAId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userBId);
  });

  it("user B cannot overwrite user A habit via sync push", async () => {
    await api("POST", "/v1/sync/push", {
      token: userBToken,
      body: {
        habits: [{ id: habitAId, name: "HIJACKED", emoji: "💀", colorHex: "#000000",
                   isArchived: false, sortOrder: 0, reminderEnabled: false,
                   reminderHour: 20, reminderMinute: 0, note: null,
                   createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const habit = db.prepare("SELECT name FROM habits WHERE id = ?").get(habitAId);
    assert.ok(habit, "habit should still exist");
    assert.equal(habit.name, "User A Habit", "user B should not be able to rename user A's habit");
  });

  it("user B cannot delete user A habit via sync push deletedHabitIds", async () => {
    await api("POST", "/v1/sync/push", {
      token: userBToken,
      body: {
        habits: [],
        entries: [],
        deletedHabitIds: [habitAId],
        deletedEntryIds: [],
      },
    });

    const habit = db.prepare("SELECT id FROM habits WHERE id = ?").get(habitAId);
    assert.ok(habit, "user B should not be able to delete user A's habit");
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

// ----------------------------------------------------------------

describe("CJK and Unicode support", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    const habits = db.prepare("SELECT id FROM habits WHERE user_id = ?").all(userId);
    for (const h of habits) {
      db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(h.id);
    }
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("creates and retrieves a habit with a Chinese name", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "每日阅读", emoji: "📖", colorHex: "#FF6B35" },
    });
    assert.equal(status, 201);
    assert.equal(json.habit.name, "每日阅读");
    assert.equal(json.habit.emoji, "📖");

    const list = await api("GET", "/v1/habits", { token });
    const found = list.json.habits.find((h) => h.name === "每日阅读");
    assert.ok(found, "Chinese habit should appear in list");
    assert.equal(found.color_hex, "#FF6B35");
  });

  it("creates and retrieves a habit with a Korean name", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "매일 운동", emoji: "🏃" },
    });
    assert.equal(status, 201);
    assert.equal(json.habit.name, "매일 운동");
  });

  it("sync push/pull preserves Japanese habit name without corruption", async () => {
    const habitId = crypto.randomUUID();
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{
          id: habitId,
          name: "毎日瞑想する",
          emoji: "🧘",
          colorHex: "#7C3AED",
          isArchived: false,
          sortOrder: 0,
        }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    const habit = pull.json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "Japanese habit should appear in pull");
    assert.equal(habit.name, "毎日瞑想する", "name must not be corrupted");
    assert.equal(habit.emoji, "🧘");
  });

  it("GET /v1/habits/:id/stats returns zeros for a habit with no entries", async () => {
    // Insert directly to avoid rate limiter in long test runs
    const emptyHabitId = crypto.randomUUID();
    const now = new Date().toISOString();
    db.prepare(
      "INSERT INTO habits (id, user_id, name, emoji, color_hex, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    ).run(emptyHabitId, userId, "Empty habit", "⭐", "#34C759", 0, now, now);

    const { status, json } = await api("GET", `/v1/habits/${emptyHabitId}/stats`, { token });
    assert.equal(status, 200);
    assert.equal(json.currentStreak, 0);
    assert.equal(json.bestStreak, 0);
    assert.equal(json.totalEntries, 0);
    assert.equal(json.completionRate, 0);
  });

  it("sync pull with malformed ?since value does not return 500", async () => {
    // Rate limiters may return 429 in long test runs; what matters is the server doesn't crash (500)
    const { status, json } = await api("GET", "/v1/sync/pull", {
      token,
      query: { since: "not-a-valid-timestamp" },
    });
    assert.ok(status !== 500, `Expected non-500, got ${status}`);
    // If not rate-limited, should return structured data
    if (status === 200) {
      assert.ok(Array.isArray(json.habits));
      assert.ok(Array.isArray(json.entries));
      assert.ok(json.serverTime);
    }
  });
});

// ----------------------------------------------------------------

describe("CRUD: cross-user isolation", () => {
  let userAToken;
  let userAId;
  let userBToken;
  let userBId;
  let habitAId;

  before(async () => {
    const userA = createTestUser();
    userAId = userA.userId;
    userAToken = createTestSession(userAId);

    const userB = createTestUser();
    userBId = userB.userId;
    userBToken = createTestSession(userBId);

    // User A creates a habit via CRUD POST
    const { json } = await api("POST", "/v1/habits", {
      token: userAToken,
      body: { name: "User A private habit", emoji: "🔒", colorHex: "#FF0000" },
    });
    habitAId = json.habit.id;

    // User A adds an entry so user B's entry GET has something to not-return
    await api("POST", `/v1/habits/${habitAId}/entries`, {
      token: userAToken,
      body: { date: "2026-01-01" },
    });
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userAId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userAId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userBId);
  });

  it("user B cannot update user A habit via CRUD PUT (returns 404)", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitAId}`, {
      token: userBToken,
      body: { name: "HIJACKED" },
    });
    assert.equal(status, 404);
    assert.ok(json.error);

    // Verify user A's habit is unchanged
    const { json: listJson } = await api("GET", "/v1/habits", { token: userAToken });
    const habit = listJson.habits.find((h) => h.id === habitAId);
    assert.equal(habit.name, "User A private habit");
  });

  it("user B cannot delete user A habit via CRUD DELETE (returns 404)", async () => {
    const { status, json } = await api("DELETE", `/v1/habits/${habitAId}`, {
      token: userBToken,
    });
    assert.equal(status, 404);
    assert.ok(json.error);

    // Verify user A's habit still exists
    const { json: listJson } = await api("GET", "/v1/habits", { token: userAToken });
    const habit = listJson.habits.find((h) => h.id === habitAId);
    assert.ok(habit, "habit should still exist after failed cross-user delete");
  });

  it("user B cannot get entries for user A habit via CRUD GET (returns 404)", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitAId}/entries`, {
      token: userBToken,
    });
    assert.equal(status, 404);
    assert.ok(json.error);
  });

  it("user B cannot post entries to user A habit via CRUD POST (returns 404)", async () => {
    const { status, json } = await api("POST", `/v1/habits/${habitAId}/entries`, {
      token: userBToken,
      body: { date: "2026-02-01" },
    });
    assert.equal(status, 404);
    assert.ok(json.error);
  });

  it("user B cannot get stats for user A habit via CRUD GET (returns 404)", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitAId}/stats`, {
      token: userBToken,
    });
    assert.equal(status, 404);
    assert.ok(json.error);
  });
});

// ----------------------------------------------------------------

describe("Habit list pagination", () => {
  let token;
  let userId;
  const habitIds = [];

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    // Insert 5 habits directly so sort_order is deterministic
    const now = new Date().toISOString();
    for (let i = 0; i < 5; i++) {
      const id = crypto.randomUUID();
      habitIds.push(id);
      db.prepare(
        "INSERT INTO habits (id, user_id, name, emoji, color_hex, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      ).run(id, userId, `Page habit ${i + 1}`, "⭐", "#34C759", i, now, now);
    }
  });

  after(() => {
    for (const id of habitIds) {
      db.prepare("DELETE FROM habits WHERE id = ?").run(id);
    }
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /v1/habits returns all habits by default", async () => {
    const { status, json } = await api("GET", "/v1/habits", { token });
    assert.equal(status, 200);
    assert.equal(json.pagination.total, 5);
    assert.equal(json.habits.length, 5);
    assert.equal(json.pagination.hasMore, false);
  });

  it("GET /v1/habits respects ?limit", async () => {
    const { status, json } = await api("GET", "/v1/habits", {
      token,
      query: { limit: "2" },
    });
    assert.equal(status, 200);
    assert.equal(json.habits.length, 2);
    assert.equal(json.pagination.total, 5);
    assert.equal(json.pagination.hasMore, true);
  });

  it("GET /v1/habits respects ?offset", async () => {
    const { status, json } = await api("GET", "/v1/habits", {
      token,
      query: { limit: "2", offset: "4" },
    });
    assert.equal(status, 200);
    assert.equal(json.habits.length, 1);
    assert.equal(json.pagination.hasMore, false);
    assert.equal(json.pagination.offset, 4);
  });

  it("GET /v1/habits with offset beyond total returns empty list", async () => {
    const { status, json } = await api("GET", "/v1/habits", {
      token,
      query: { limit: "10", offset: "10" },
    });
    assert.equal(status, 200);
    assert.equal(json.habits.length, 0);
    assert.equal(json.pagination.hasMore, false);
    assert.equal(json.pagination.total, 5);
  });

  it("GET /v1/habits clamps limit to maximum of 200", async () => {
    const { status, json } = await api("GET", "/v1/habits", {
      token,
      query: { limit: "999" },
    });
    assert.equal(status, 200);
    assert.equal(json.habits.length, 5);
    assert.equal(json.pagination.limit, 200);
  });
});

// ----------------------------------------------------------------

describe("Sync: archived habit round-trip", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    const habits = db.prepare("SELECT id FROM habits WHERE user_id = ?").all(userId);
    for (const h of habits) {
      db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(/** @type {any} */ (h).id);
    }
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("sync push/pull preserves isArchived=true", async () => {
    const habitId = crypto.randomUUID();
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{
          id: habitId,
          name: "Archived habit",
          emoji: "📦",
          colorHex: "#8E8E93",
          isArchived: true,
          sortOrder: 0,
        }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    const habit = pull.json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "archived habit should appear in pull");
    assert.equal(habit.isArchived, true, "isArchived should be true");
    assert.equal(habit.name, "Archived habit");
  });

  it("CRUD PUT archives a habit; pull reflects isArchived=true", async () => {
    const { json: created } = await api("POST", "/v1/habits", {
      token,
      body: { name: "To be archived" },
    });
    const habitId = created.habit.id;
    assert.equal(created.habit.is_archived, 0);

    await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { isArchived: true },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    const habit = pull.json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "archived habit should appear in pull");
    assert.equal(habit.isArchived, true, "isArchived should be true after CRUD PUT");
  });
});

// ----------------------------------------------------------------

describe("Habits: field defaults and sort ordering", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    const habits = db.prepare("SELECT id FROM habits WHERE user_id = ?").all(userId);
    for (const h of habits) {
      db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(h.id);
    }
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST /v1/habits defaults emoji to ⭐ when omitted", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "No emoji habit" },
    });
    assert.equal(status, 201);
    assert.equal(json.habit.emoji, "⭐");
  });

  it("POST /v1/habits defaults colorHex to #34C759 when omitted", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "No color habit" },
    });
    assert.equal(status, 201);
    assert.equal(json.habit.color_hex, "#34C759");
  });

  it("GET /v1/habits returns habits ordered by sort_order ASC", async () => {
    // Create 3 habits — they get auto-assigned sort_order 0, 1, 2
    const a = await api("POST", "/v1/habits", { token, body: { name: "Alpha" } });
    const b = await api("POST", "/v1/habits", { token, body: { name: "Beta" } });
    const c = await api("POST", "/v1/habits", { token, body: { name: "Gamma" } });
    const idA = a.json.habit.id;
    const idB = b.json.habit.id;
    const idC = c.json.habit.id;

    // Reorder: set Gamma to sort_order 0, Alpha to 1, Beta to 2
    await api("PUT", `/v1/habits/${idC}`, { token, body: { sortOrder: 0 } });
    await api("PUT", `/v1/habits/${idA}`, { token, body: { sortOrder: 1 } });
    await api("PUT", `/v1/habits/${idB}`, { token, body: { sortOrder: 2 } });

    const { json } = await api("GET", "/v1/habits", { token });
    const ids = json.habits.map((h) => h.id);
    const posC = ids.indexOf(idC);
    const posA = ids.indexOf(idA);
    const posB = ids.indexOf(idB);
    assert.ok(posC < posA, "Gamma (order 0) should appear before Alpha (order 1)");
    assert.ok(posA < posB, "Alpha (order 1) should appear before Beta (order 2)");
  });
});

// ----------------------------------------------------------------

describe("Auth: authenticated session", () => {
  let token;
  let userId;
  let email;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    email = user.email;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /v1/auth/session returns user id and email when authenticated", async () => {
    const { status, json } = await api("GET", "/v1/auth/session", { token });
    assert.equal(status, 200);
    assert.ok(json.user, "user should be non-null");
    assert.equal(json.user.id, userId);
    assert.equal(json.user.email, email);
  });
});

// ----------------------------------------------------------------

describe("Habit entries: idempotent delete", () => {
  let token;
  let userId;
  let habitId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    if (habitId) {
      db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
      db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    }
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("DELETE /v1/habits/:id/entries/:date for non-existent date returns 200 ok", async () => {
    const created = await api("POST", "/v1/habits", { token, body: { name: "Idempotent entry habit" } });
    habitId = created.json.habit.id;

    // Delete a date that was never checked in
    const { status, json } = await api("DELETE", `/v1/habits/${habitId}/entries/2020-01-01`, { token });
    assert.equal(status, 200);
    assert.equal(json.ok, true);
  });
});

// ----------------------------------------------------------------

describe("PUT /habits/:id: name validation", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const { json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Original name", emoji: "⭐", colorHex: "#34C759" },
    });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("PUT with empty name returns 400", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { name: "" },
    });
    assert.equal(status, 400);
    assert.match(json.error, /name/i);
  });

  it("PUT with whitespace-only name returns 400", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { name: "   " },
    });
    assert.equal(status, 400);
    assert.match(json.error, /name/i);
  });

  it("PUT with name longer than 100 chars returns 400", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { name: "あ".repeat(101) },
    });
    assert.equal(status, 400);
    assert.match(json.error, /100/);
  });

  it("PUT with name omitted leaves name unchanged", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { emoji: "🔥" },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.name, "Original name");
    assert.equal(json.habit.emoji, "🔥");
  });

  it("PUT with Japanese name preserves CJK characters without corruption", async () => {
    const jaName = "毎日の瞑想と読書の習慣";
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { name: jaName },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.name, jaName, "Japanese name must not be corrupted");

    // Verify via GET list too
    const list = await api("GET", "/v1/habits", { token });
    const found = list.json.habits.find((h) => h.id === habitId);
    assert.ok(found, "habit should appear in list");
    assert.equal(found.name, jaName);
  });

  it("PUT with Traditional Chinese name (zh-Hant) preserves characters", async () => {
    const zhHantName = "每日閱讀與冥想習慣";
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { name: zhHantName },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.name, zhHantName);
  });
});

// ----------------------------------------------------------------

describe("Sync: edge cases", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    const habits = db.prepare("SELECT id FROM habits WHERE user_id = ?").all(userId);
    for (const h of habits) {
      db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(/** @type {any} */ (h).id);
    }
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("sync push: if habit is in both habits array and deletedHabitIds, deletion wins", async () => {
    const conflictHabitId = crypto.randomUUID();

    // Push the same habit in both arrays simultaneously
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: conflictHabitId, name: "Conflict habit", sortOrder: 0 }],
        entries: [],
        deletedHabitIds: [conflictHabitId],
        deletedEntryIds: [],
      },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    // The habit should NOT appear in pull (deletion wins)
    const pull = await api("GET", "/v1/sync/pull", { token });
    const found = pull.json.habits.find((h) => h.id === conflictHabitId);
    assert.equal(found, undefined, "habit in deletedHabitIds should not be upserted");
  });

  it("sync push: entry for a habit that does not exist is silently skipped", async () => {
    const ghostHabitId = crypto.randomUUID();
    const orphanEntryId = crypto.randomUUID();

    // Push an entry referencing a habit that was never created
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [],
        entries: [{ id: orphanEntryId, habitId: ghostHabitId, date: "2025-10-01" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    // Verify the orphan entry is NOT in pull
    const pull = await api("GET", "/v1/sync/pull", { token });
    const found = pull.json.entries.find((e) => e.id === orphanEntryId);
    assert.equal(found, undefined, "entry for non-existent habit should be silently skipped");
  });
});

// ----------------------------------------------------------------

describe("Habit entries: DELETE date validation", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("DELETE /habits/:id/entries/:date with malformed date returns 400", async () => {
    const { json: created } = await api("POST", "/v1/habits", { token, body: { name: "Entry date check" } });
    const habitId = created.habit.id;

    const { status, json } = await api("DELETE", `/v1/habits/${habitId}/entries/not-a-date`, { token });
    assert.equal(status, 400);
    assert.ok(json.error, "error message should be present");
  });
});

// ----------------------------------------------------------------

describe("Habit archive/unarchive round-trip", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("PUT isArchived=true then false round-trips correctly", async () => {
    const { json: created } = await api("POST", "/v1/habits", { token, body: { name: "Archive test" } });
    const habitId = created.habit.id;

    // Archive
    const { json: archived } = await api("PUT", `/v1/habits/${habitId}`, { token, body: { isArchived: true } });
    assert.equal(archived.habit.is_archived, 1, "habit should be archived");

    // Unarchive
    const { json: unarchived } = await api("PUT", `/v1/habits/${habitId}`, { token, body: { isArchived: false } });
    assert.equal(unarchived.habit.is_archived, 0, "habit should be unarchived");

    // Verify via GET
    const { json: list } = await api("GET", "/v1/habits", { token });
    const found = list.habits.find((h) => h.id === habitId);
    assert.equal(found.is_archived, 0, "GET list should reflect unarchived state");
  });
});

// ----------------------------------------------------------------

describe("Habit entries: GET pagination and filter", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Entry pagination habit" } });
    habitId = json.habit.id;

    // Create 5 entries on consecutive dates
    for (let i = 1; i <= 5; i++) {
      await api("POST", `/v1/habits/${habitId}/entries`, {
        token,
        body: { date: `2025-11-0${i}` },
      });
    }
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /habits/:id/entries with ?offset skips entries correctly", async () => {
    const { json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { limit: "2", offset: "2" },
    });
    assert.equal(json.entries.length, 2, "should return 2 entries");
    assert.equal(json.pagination.offset, 2);
    assert.equal(json.pagination.total, 5);
    // Entries are ordered by date; offset 2 should start from the 3rd date
    assert.equal(json.entries[0].date, "2025-11-03");
  });

  it("GET /habits/:id/entries with only ?from (no ?to) returns all entries", async () => {
    // The route does `if (from && to)` — passing only `from` falls through to unfiltered query
    const { json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { from: "2025-11-03" },
    });
    // Without ?to, the filter is not applied — all 5 entries are returned
    assert.equal(json.pagination.total, 5, "unfiltered query returns all entries when ?to is absent");
  });
});

// ----------------------------------------------------------------

describe("POST /habits with client-provided id", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST /habits with client-provided id returns that id", async () => {
    const clientId = crypto.randomUUID();
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { id: clientId, name: "Custom ID habit" },
    });
    assert.equal(status, 201);
    assert.equal(json.habit.id, clientId, "returned habit should use client-provided id");

    // Verify it's retrievable by that id
    const { json: list } = await api("GET", "/v1/habits", { token });
    const found = list.habits.find((h) => h.id === clientId);
    assert.ok(found, "habit with client-provided id should be findable in list");
  });

  it("POST /habits with duplicate client-provided id returns 409", async () => {
    const clientId = crypto.randomUUID();

    // First create succeeds
    const first = await api("POST", "/v1/habits", { token, body: { id: clientId, name: "Original" } });
    assert.equal(first.status, 201);

    // Second create with same id should fail gracefully
    const second = await api("POST", "/v1/habits", { token, body: { id: clientId, name: "Duplicate" } });
    assert.equal(second.status, 409, "duplicate habit id should return 409, not 500");
    assert.ok(second.json.error, "error message should be present");
  });
});

// ----------------------------------------------------------------

describe("Auth: logout invalidates Bearer session", () => {
  it("POST /auth/logout invalidates the session token for Bearer-authenticated clients", async () => {
    const user = createTestUser();
    const token = createTestSession(user.userId);

    // Verify authenticated access works before logout
    const before = await api("GET", "/v1/habits", { token });
    assert.equal(before.status, 200, "should be accessible before logout");

    // Logout using the Bearer token
    const logoutResp = await api("POST", "/v1/auth/logout", { token });
    assert.equal(logoutResp.status, 200);
    assert.equal(logoutResp.json.ok, true);

    // After logout, the Bearer token must no longer work
    const after = await api("GET", "/v1/habits", { token });
    assert.equal(after.status, 401, "token should be rejected after logout");

    // Cleanup
    db.prepare("DELETE FROM users WHERE id = ?").run(user.userId);
  });
});

// ----------------------------------------------------------------

describe("Stats: zero entries", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Never done" } });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /habits/:id/stats returns all zeros for a habit with no entries", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/stats`, { token });
    assert.equal(status, 200);
    assert.equal(json.currentStreak, 0);
    assert.equal(json.bestStreak, 0);
    assert.equal(json.completionRate, 0);
    assert.equal(json.totalEntries, 0);
  });
});

// ----------------------------------------------------------------

describe("Habit entries: GET 404", () => {
  it("GET /habits/:id/entries returns 404 for nonexistent habit", async () => {
    const user = createTestUser();
    const token = createTestSession(user.userId);

    const { status } = await api("GET", "/v1/habits/nonexistent-habit-id/entries", { token });
    assert.equal(status, 404);

    // Cleanup
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(user.userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(user.userId);
  });
});

// ----------------------------------------------------------------

describe("GET /habits: empty list for fresh user", () => {
  it("returns empty habits array and zero pagination totals", async () => {
    const user = createTestUser();
    const token = createTestSession(user.userId);

    const { status, json } = await api("GET", "/v1/habits", { token });
    assert.equal(status, 200);
    assert.ok(Array.isArray(json.habits), "habits should be an array");
    assert.equal(json.habits.length, 0, "fresh user should have no habits");
    assert.equal(json.pagination.total, 0);
    assert.equal(json.pagination.hasMore, false);
    assert.equal(json.pagination.offset, 0);

    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(user.userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(user.userId);
  });
});

// ----------------------------------------------------------------

describe("Auth: GET /session with expired Bearer token", () => {
  it("returns status 200 with null user (not 401)", async () => {
    const user = createTestUser();
    const userId = user.userId;

    // Insert an already-expired session
    const rawToken = crypto.randomBytes(32).toString("hex");
    const tokenHash = hashToken(rawToken);
    const expiredAt = Date.now() - 5000; // 5 seconds in the past
    db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)").run(
      userId, tokenHash, expiredAt,
    );

    // /session is a public endpoint — it returns {user: null} for expired/missing tokens, not 401
    const { status, json } = await api("GET", "/v1/auth/session", { token: rawToken });
    assert.equal(status, 200, "GET /session should return 200 even for expired token");
    assert.equal(json.user, null, "expired token should yield null user");

    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });
});

// ----------------------------------------------------------------

describe("Sync: full and incremental pull for user with no habits", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("full pull returns empty arrays", async () => {
    const { status, json } = await api("GET", "/v1/sync/pull", { token });
    assert.equal(status, 200);
    assert.ok(Array.isArray(json.habits));
    assert.equal(json.habits.length, 0);
    assert.ok(Array.isArray(json.entries));
    assert.equal(json.entries.length, 0);
    assert.ok(Array.isArray(json.deletedHabitIds));
    assert.equal(json.deletedHabitIds.length, 0);
    assert.ok(Array.isArray(json.deletedEntryIds));
    assert.equal(json.deletedEntryIds.length, 0);
    assert.ok(json.serverTime, "serverTime should be present");
  });

  it("incremental pull with ?since also returns empty arrays", async () => {
    const since = new Date(Date.now() - 60000).toISOString(); // 1 minute ago
    const { status, json } = await api("GET", "/v1/sync/pull", { token, query: { since } });
    assert.equal(status, 200);
    assert.equal(json.habits.length, 0);
    assert.equal(json.entries.length, 0);
    assert.equal(json.deletedHabitIds.length, 0);
    assert.equal(json.deletedEntryIds.length, 0);
  });
});

describe("Habit entries: GET with only ?to (no ?from)", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    ({ userId } = createTestUser());
    token = createTestSession(userId);
    const h = await api("POST", "/v1/habits", { token, body: { name: "Only-to filter habit" } });
    habitId = h.json.habit.id;
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: "2025-01-10" } });
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: "2025-02-10" } });
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: "2025-03-10" } });
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /habits/:id/entries with only ?to (no ?from) returns all entries", async () => {
    // The route only applies the date range filter when BOTH from AND to are present
    const { status, json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { to: "2025-01-31" },
    });
    assert.equal(status, 200);
    // ?to alone is ignored — all 3 entries are returned
    assert.equal(json.pagination.total, 3);
  });
});

describe("POST /habits: name boundary at 100 characters", () => {
  let token;
  let userId;

  before(() => {
    ({ userId } = createTestUser());
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST /habits with name of exactly 100 characters is accepted", async () => {
    const name = "A".repeat(100);
    assert.equal(name.length, 100);
    const { status, json } = await api("POST", "/v1/habits", { token, body: { name } });
    assert.equal(status, 201);
    assert.equal(json.habit.name, name);
    db.prepare("DELETE FROM habits WHERE id = ?").run(json.habit.id);
  });

  it("POST /habits with name of exactly 101 characters is rejected", async () => {
    const name = "A".repeat(101);
    assert.equal(name.length, 101);
    const { status } = await api("POST", "/v1/habits", { token, body: { name } });
    assert.equal(status, 400);
  });
});

describe("Sync: sortOrder round-trip via push/pull", () => {
  let token;
  let userId;

  before(() => {
    ({ userId } = createTestUser());
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("push habit with sortOrder=7; pull returns sortOrder=7", async () => {
    const habitId = crypto.randomUUID();
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Sort-order habit", sortOrder: 7 }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const { json } = await api("GET", "/v1/sync/pull", { token });
    const habit = json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "habit should exist in pull");
    assert.equal(habit.sortOrder, 7);

    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
  });
});

describe("Stats: totalEntries counts entries outside the 30-day window", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    ({ userId } = createTestUser());
    token = createTestSession(userId);
    const h = await api("POST", "/v1/habits", { token, body: { name: "Old entries habit" } });
    habitId = h.json.habit.id;
    // Insert two old entries directly (well outside the 30-day window)
    db.prepare("INSERT INTO habit_entries (id, habit_id, date, created_at) VALUES (?, ?, ?, ?)").run(
      crypto.randomUUID(), habitId, "2020-01-01", new Date().toISOString(),
    );
    db.prepare("INSERT INTO habit_entries (id, habit_id, date, created_at) VALUES (?, ?, ?, ?)").run(
      crypto.randomUUID(), habitId, "2020-01-02", new Date().toISOString(),
    );
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("totalEntries reflects all-time entries, not just the 30-day window", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/stats`, { token });
    assert.equal(status, 200);
    // totalEntries = 2 (both old entries), completionRate = 0 (none within 30 days)
    assert.equal(json.totalEntries, 2);
    assert.equal(json.completionRate, 0);
    assert.equal(json.currentStreak, 0);
  });
});

// ----------------------------------------------------------------

describe("Login page: /login endpoint", () => {
  it("GET /login returns 200 and text/html content-type", async () => {
    const res = await fetch(`${BASE}/login`);
    assert.equal(res.status, 200);
    const ct = res.headers.get("content-type") || "";
    assert.ok(ct.includes("text/html"), `Expected text/html, got: ${ct}`);
  });

  it("GET /login with no token shows error message", async () => {
    const res = await fetch(`${BASE}/login`);
    const text = await res.text();
    assert.ok(text.includes("No login token found"), "should show error when token absent");
  });

  it("GET /login?token=abc123 renders token in page", async () => {
    const res = await fetch(`${BASE}/login?token=abc123`);
    const text = await res.text();
    assert.ok(text.includes("abc123"), "page should contain the token value");
  });

  it("GET /login escapes XSS in token query param", async () => {
    const xss = '<script>alert(1)</script>';
    const res = await fetch(`${BASE}/login?token=${encodeURIComponent(xss)}`);
    const text = await res.text();
    assert.ok(!text.includes("<script>"), "raw <script> tag must not appear in response");
    assert.ok(text.includes("&lt;script&gt;"), "< and > must be HTML-escaped");
  });
});

// ----------------------------------------------------------------

describe("PUT /habits/:id: note field clearing", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const { json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Note clearing test", note: "original note" },
    });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("PUT without note key preserves existing note", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { emoji: "🔥" },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.note, "original note", "note should be unchanged when key absent");
  });

  it("PUT with note: null explicitly clears the note", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { note: null },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.note, null, "note should be null after explicit clear");
  });
});
