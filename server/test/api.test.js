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

// ----------------------------------------------------------------

describe("POST /habits: name validation", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST /habits with missing name returns 400", async () => {
    const { status, json } = await api("POST", "/v1/habits", { token, body: {} });
    assert.equal(status, 400);
    assert.match(json.error, /name/i);
  });

  it("POST /habits with empty name returns 400", async () => {
    const { status, json } = await api("POST", "/v1/habits", { token, body: { name: "" } });
    assert.equal(status, 400);
    assert.match(json.error, /name/i);
  });

  it("POST /habits with whitespace-only name returns 400", async () => {
    const { status, json } = await api("POST", "/v1/habits", { token, body: { name: "   " } });
    assert.equal(status, 400);
    assert.match(json.error, /name/i);
  });
});

// ----------------------------------------------------------------

describe("GET /habits/:id/entries: limit clamping", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Limit clamp test" } });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /habits/:id/entries clamps limit to maximum of 500", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { limit: "9999" },
    });
    assert.equal(status, 200);
    assert.equal(json.pagination.limit, 500, "limit should be capped at 500");
  });

  it("GET /habits/:id/entries treats limit=0 as default (100)", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { limit: "0" },
    });
    assert.equal(status, 200);
    assert.equal(json.pagination.limit, 100, "limit=0 is falsy and falls back to default of 100");
  });
});

// ----------------------------------------------------------------

describe("Stats: currentStreak from yesterday only", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Yesterday only" } });
    habitId = json.habit.id;

    // Insert one entry for yesterday, nothing today
    const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: yesterday } });
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("currentStreak is 1 when only yesterday has an entry", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/stats`, { token });
    assert.equal(status, 200);
    assert.equal(json.currentStreak, 1, "streak should be 1 when only yesterday is completed");
    assert.equal(json.bestStreak, 1);
    assert.equal(json.totalEntries, 1);
  });
});

// ----------------------------------------------------------------

describe("DELETE /habits/:id: cascade-deletes entries", () => {
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

  it("deleting a habit removes all its entries from the database", async () => {
    // Create habit
    const { json: createJson } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Cascade test habit", emoji: "🗑️", colorHex: "#FF0000" },
    });
    const habitId = createJson.habit.id;

    // Add 3 entries directly in DB for speed
    const now = new Date().toISOString();
    for (const date of ["2026-01-01", "2026-01-02", "2026-01-03"]) {
      db.prepare("INSERT INTO habit_entries (id, habit_id, date, created_at) VALUES (?, ?, ?, ?)").run(
        crypto.randomUUID(), habitId, date, now
      );
    }

    // Verify entries exist before delete
    const before = db.prepare("SELECT COUNT(*) as n FROM habit_entries WHERE habit_id = ?").get(habitId);
    assert.equal(before.n, 3, "should have 3 entries before delete");

    // Delete the habit
    const { status } = await api("DELETE", `/v1/habits/${habitId}`, { token });
    assert.equal(status, 200);

    // Entries should be cascade-deleted
    const after = db.prepare("SELECT COUNT(*) as n FROM habit_entries WHERE habit_id = ?").get(habitId);
    assert.equal(after.n, 0, "entries should be cascade-deleted when habit is deleted");
  });
});

// ----------------------------------------------------------------

describe("Auth: expired magic link token", () => {
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

  it("verify with an expired magic link token returns 400", async () => {
    const rawToken = crypto.randomBytes(32).toString("hex");
    const tokenHash = hashToken(rawToken);
    // expires_at is 1 second in the past — token is expired
    const expiredAt = Date.now() - 1000;
    db.prepare(
      "INSERT INTO magic_link_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)"
    ).run(userId, tokenHash, expiredAt);

    const { status, json } = await api("POST", "/v1/auth/verify", { body: { token: rawToken } });
    assert.equal(status, 400);
    assert.ok(json.error, "should return an error message");
  });
});

// ----------------------------------------------------------------

describe("Stats: completionRate uses 30-day window for old habits", () => {
  let token;
  let userId;
  let habitId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    // Create habit 60 days ago
    habitId = crypto.randomUUID();
    const habitCreatedAt = new Date(Date.now() - 60 * 86400000).toISOString();
    db.prepare(
      "INSERT INTO habits (id, user_id, name, emoji, color_hex, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    ).run(habitId, userId, "Old habit", "⭐", "#34C759", 0, habitCreatedAt, habitCreatedAt);

    // Add 2 entries: today and yesterday
    const today = new Date().toISOString().slice(0, 10);
    const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    const now = new Date().toISOString();
    db.prepare("INSERT INTO habit_entries (id, habit_id, date, created_at) VALUES (?, ?, ?, ?)").run(
      crypto.randomUUID(), habitId, today, now
    );
    db.prepare("INSERT INTO habit_entries (id, habit_id, date, created_at) VALUES (?, ?, ?, ?)").run(
      crypto.randomUUID(), habitId, yesterday, now
    );
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("completionRate is based on 30-day window, not habit age", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/stats`, { token });
    assert.equal(status, 200);

    // With 30-day window: 2 entries / ~31 days ≈ 0.065
    // With 60-day window: 2 entries / ~61 days ≈ 0.033
    // The rate should be significantly higher than the 60-day rate
    const sixtydayRate = Math.round((2 / 61) * 1000) / 1000;
    assert.ok(
      json.completionRate > sixtydayRate,
      `completionRate ${json.completionRate} should exceed 60-day rate ${sixtydayRate} (30-day window expected)`
    );
    assert.ok(json.completionRate > 0, "completionRate should be positive");
    assert.ok(json.completionRate <= 1, "completionRate should not exceed 1");
    assert.equal(json.totalEntries, 2);
  });
});

// ----------------------------------------------------------------

describe("Habit entries: DELETE for nonexistent habit returns 404", () => {
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

  it("DELETE /habits/:id/entries/:date returns 404 when habit does not exist", async () => {
    const fakeId = crypto.randomUUID();
    const { status, json } = await api("DELETE", `/v1/habits/${fakeId}/entries/2025-01-01`, { token });
    assert.equal(status, 404);
    assert.ok(json.error, "error message should be present");
  });
});

// ----------------------------------------------------------------

describe("POST /habits: reminderEnabled=true defaults hour and minute", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST /habits with reminderEnabled=true stores default hour=20 and minute=0 when omitted", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Reminder defaults test", reminderEnabled: true },
    });
    assert.equal(status, 201);
    assert.equal(json.habit.reminder_enabled, 1);
    assert.equal(json.habit.reminder_hour, 20);
    assert.equal(json.habit.reminder_minute, 0);
  });
});

// ----------------------------------------------------------------

describe("Sync: empty push body", () => {
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

  it("POST /sync/push with empty body {} returns ok:true", async () => {
    const { status, json } = await api("POST", "/v1/sync/push", { token, body: {} });
    assert.equal(status, 200);
    assert.equal(json.ok, true);
  });
});

// ----------------------------------------------------------------

describe("GET /habits: negative limit clamped to 1", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /habits with limit=-5 returns pagination.limit of 1", async () => {
    await api("POST", "/v1/habits", { token, body: { name: "Negative limit test" } });
    const { status, json } = await api("GET", "/v1/habits", { token, query: { limit: "-5" } });
    assert.equal(status, 200);
    assert.equal(json.pagination.limit, 1);
  });
});

// ----------------------------------------------------------------

describe("PUT /habits/:id: explicit null reminderHour leaves value unchanged", () => {
  let token;
  let userId;
  let habitId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const created = db.prepare(
      "INSERT INTO habits (id, user_id, name, emoji, color_hex, sort_order, reminder_enabled, reminder_hour, reminder_minute, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    ).run(
      crypto.randomUUID(), userId, "Null hour test", "⭐", "#34C759", 0, 1, 9, 30,
      new Date().toISOString(), new Date().toISOString()
    );
    const h = db.prepare("SELECT id FROM habits WHERE user_id = ? AND name = ?").get(userId, "Null hour test");
    habitId = h.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("PUT with reminderHour:null leaves reminder_hour unchanged", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { reminderHour: null },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.reminder_hour, 9, "reminder_hour should remain 9 when null is sent");
  });
});

describe("GET /habits/:id/entries: same-day date range", () => {
  let token;
  let userId;
  let habitId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const now = new Date().toISOString();
    habitId = crypto.randomUUID();
    db.prepare(
      "INSERT INTO habits (id, user_id, name, emoji, color_hex, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    ).run(habitId, userId, "Range test", "⭐", "#34C759", 0, now, now);
    db.prepare("INSERT INTO habit_entries (id, habit_id, date, created_at) VALUES (?, ?, ?, ?)").run(
      crypto.randomUUID(), habitId, "2025-03-10", now
    );
    db.prepare("INSERT INTO habit_entries (id, habit_id, date, created_at) VALUES (?, ?, ?, ?)").run(
      crypto.randomUUID(), habitId, "2025-03-11", now
    );
    db.prepare("INSERT INTO habit_entries (id, habit_id, date, created_at) VALUES (?, ?, ?, ?)").run(
      crypto.randomUUID(), habitId, "2025-03-12", now
    );
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("from=to same-day range returns exactly that day's entry", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { from: "2025-03-11", to: "2025-03-11" },
    });
    assert.equal(status, 200);
    assert.equal(json.entries.length, 1, "should return exactly one entry");
    assert.equal(json.entries[0].date, "2025-03-11");
    assert.equal(json.pagination.total, 1);
  });

  it("reversed range (from > to) returns empty entries gracefully", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { from: "2025-03-12", to: "2025-03-10" },
    });
    assert.equal(status, 200);
    assert.equal(json.entries.length, 0, "reversed range should return empty results");
    assert.equal(json.pagination.total, 0);
  });
});

describe("Auth: request-link with null email", () => {
  it("POST /auth/request-link with null email returns 400", async () => {
    const { status, json } = await api("POST", "/v1/auth/request-link", { body: { email: null } });
    assert.equal(status, 400);
    assert.ok(json.error, "should return an error message");
  });
});

describe("Habit entries: future date accepted", () => {
  let token;
  let userId;
  let habitId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const now = new Date().toISOString();
    habitId = crypto.randomUUID();
    db.prepare(
      "INSERT INTO habits (id, user_id, name, emoji, color_hex, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    ).run(habitId, userId, "Future entry test", "⭐", "#34C759", 0, now, now);
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST /habits/:id/entries with a future date is accepted (no future-date restriction)", async () => {
    const futureDate = "2099-12-31";
    const { status, json } = await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { date: futureDate },
    });
    assert.equal(status, 201);
    assert.equal(json.entry.date, futureDate);
    assert.equal(json.entry.habit_id, habitId);
  });
});

describe("Sync pull incremental: entry note included in ?since response", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)", userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("incremental pull with ?since includes entry note field", async () => {
    const habitId = crypto.randomUUID();
    const entryId = crypto.randomUUID();
    const beforePush = new Date(Date.now() - 2000).toISOString();

    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Note test habit", sortOrder: 0 }],
        entries: [{ id: entryId, habitId, date: "2025-07-15", note: "my entry note" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const { status, json } = await api("GET", "/v1/sync/pull", {
      token,
      query: { since: beforePush },
    });
    assert.equal(status, 200);
    const entry = json.entries.find((e) => e.id === entryId);
    assert.ok(entry, "entry should appear in incremental pull");
    assert.equal(entry.note, "my entry note", "entry note must be included in incremental pull response");

    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
  });
});

// ----------------------------------------------------------------

describe("Auth: verify with falsy non-string token", () => {
  it("POST /v1/auth/verify with explicit null token returns 400", async () => {
    const { status, json } = await api("POST", "/v1/auth/verify", {
      body: { token: null },
    });
    assert.equal(status, 400);
    assert.ok(json.error, "should return error message");
  });

  it("POST /v1/auth/verify with numeric token is rejected (400 or 429 if rate-limited)", async () => {
    const { status, json } = await api("POST", "/v1/auth/verify", {
      body: { token: 0 },
    });
    // 400 = validation rejection; 429 = rate-limited (verifyLimiter has no test bypass)
    assert.ok(status === 400 || status === 429, `expected 400 or 429, got ${status}`);
    assert.ok(json.error, "should return error message");
  });
});

// ----------------------------------------------------------------

describe("Habit entries: GET with offset beyond total", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Offset test habit" } });
    habitId = json.habit.id;

    // Insert 3 entries
    for (let i = 1; i <= 3; i++) {
      await api("POST", `/v1/habits/${habitId}/entries`, {
        token,
        body: { date: `2025-12-0${i}` },
      });
    }
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /habits/:id/entries with offset beyond total returns empty list and hasMore=false", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { offset: "10" },
    });
    assert.equal(status, 200);
    assert.equal(json.entries.length, 0, "no entries at offset beyond total");
    assert.equal(json.pagination.total, 3, "total should still reflect all entries");
    assert.equal(json.pagination.hasMore, false, "hasMore must be false when offset exceeds total");
  });
});

// ----------------------------------------------------------------

describe("Sync push: entry note update via re-push", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)", userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("sync push updates entry note when same habit+date pushed again with new note", async () => {
    const habitId = crypto.randomUUID();
    const entryId = crypto.randomUUID();

    // First push: entry with note "original"
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Note update habit", sortOrder: 0 }],
        entries: [{ id: entryId, habitId, date: "2025-12-10", note: "original note" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Second push: same habit+date with updated note (ON CONFLICT DO UPDATE SET note = excluded.note)
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [],
        entries: [{ id: crypto.randomUUID(), habitId, date: "2025-12-10", note: "updated note" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    const entry = pull.json.entries.find((e) => e.habitId === habitId && e.date === "2025-12-10");
    assert.ok(entry, "entry should exist in pull");
    assert.equal(entry.note, "updated note", "note should be updated by second sync push");

    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
  });
});

// ----------------------------------------------------------------

describe("POST /habits: note as empty string", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST /habits with note as empty string stores empty string (not null)", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Empty note habit", note: "" },
    });
    assert.equal(status, 201);
    // "" ?? null = "" (empty string, not null), so note is stored as ""
    assert.equal(json.habit.note, "", "note should be stored as empty string, not null");
  });
});

// ----------------------------------------------------------------

describe("Sync: full pull returns habit and entry notes", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("full pull includes habit note pushed via sync", async () => {
    const habitId = crypto.randomUUID();
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Noted habit", sortOrder: 0, note: "my habit note" }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const { status, json } = await api("GET", "/v1/sync/pull", { token });
    assert.equal(status, 200);
    const habit = json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "habit should appear in full pull");
    assert.equal(habit.note, "my habit note", "habit note must be included in full pull response");
  });

  it("full pull includes entry note pushed via sync", async () => {
    const habitId = crypto.randomUUID();
    const entryId = crypto.randomUUID();
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Entry-note habit", sortOrder: 1 }],
        entries: [{ id: entryId, habitId, date: "2025-08-01", note: "entry note text" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const { status, json } = await api("GET", "/v1/sync/pull", { token });
    assert.equal(status, 200);
    const entry = json.entries.find((e) => e.id === entryId);
    assert.ok(entry, "entry should appear in full pull");
    assert.equal(entry.note, "entry note text", "entry note must be included in full pull response");
  });
});

// ----------------------------------------------------------------

describe("Auth: session fields include tier and created_at", () => {
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

  it("GET /v1/auth/session includes tier and created_at", async () => {
    const { status, json } = await api("GET", "/v1/auth/session", { token });
    assert.equal(status, 200);
    assert.ok(json.user, "user should be non-null");
    assert.equal(json.user.tier, "free", "default tier should be free");
    assert.ok(json.user.created_at, "created_at should be present");
    assert.match(json.user.created_at, /^\d{4}-\d{2}-\d{2}/, "created_at should be ISO8601");
  });
});

// ----------------------------------------------------------------

describe("Sync push: entry for non-owned habit is silently skipped", () => {
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

    habitAId = crypto.randomUUID();
    await api("POST", "/v1/sync/push", {
      token: userAToken,
      body: {
        habits: [{ id: habitAId, name: "User A habit", sortOrder: 0 }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitAId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userAId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userBId);
  });

  it("user B entry for user A habit is silently dropped", async () => {
    const entryId = crypto.randomUUID();
    const { status, json } = await api("POST", "/v1/sync/push", {
      token: userBToken,
      body: {
        habits: [],
        entries: [{ id: entryId, habitId: habitAId, date: "2025-08-02", note: null }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    const entry = db.prepare("SELECT id FROM habit_entries WHERE id = ?").get(entryId);
    assert.equal(entry, undefined, "entry for non-owned habit must be silently skipped");
  });
});

// ----------------------------------------------------------------

describe("Auth: logout without session token returns 200", () => {
  it("POST /v1/auth/logout with no token returns 200 ok", async () => {
    const { status, json } = await api("POST", "/v1/auth/logout");
    assert.equal(status, 200);
    assert.equal(json.ok, true);
  });
});

// ----------------------------------------------------------------

describe("POST /habits: non-integer reminderHour/Minute rejected", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST /habits with reminderEnabled:true and float reminderHour returns 400", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Float Hour Habit", reminderEnabled: true, reminderHour: 8.5, reminderMinute: 0 },
    });
    assert.equal(status, 400);
    assert.match(json.error, /reminderHour/);
  });

  it("POST /habits with reminderEnabled:true and float reminderMinute returns 400", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Float Minute Habit", reminderEnabled: true, reminderHour: 8, reminderMinute: 30.5 },
    });
    assert.equal(status, 400);
    assert.match(json.error, /reminderMinute/);
  });
});

// ----------------------------------------------------------------

describe("PUT /habits/:id: non-integer reminderHour rejected", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const { json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Float PUT test", reminderEnabled: true, reminderHour: 8, reminderMinute: 0 },
    });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("PUT /habits/:id with float reminderHour returns 400", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { reminderHour: 9.9 },
    });
    assert.equal(status, 400);
    assert.match(json.error, /reminderHour/);
  });

  it("PUT /habits/:id with float reminderMinute returns 400", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { reminderMinute: 30.5 },
    });
    assert.equal(status, 400);
    assert.match(json.error, /reminderMinute/);
  });

  it("PUT /habits/:id with reminderHour=24 (out of range) returns 400", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { reminderHour: 24 },
    });
    assert.equal(status, 400);
    assert.match(json.error, /reminderHour/);
  });

  it("PUT /habits/:id with reminderMinute=60 (out of range) returns 400", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { reminderMinute: 60 },
    });
    assert.equal(status, 400);
    assert.match(json.error, /reminderMinute/);
  });

  it("PUT /habits/:id with reminderHour=-1 (negative) returns 400", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { reminderHour: -1 },
    });
    assert.equal(status, 400);
    assert.match(json.error, /reminderHour/);
  });

  it("PUT /habits/:id with reminderEnabled:false disables reminder", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { reminderEnabled: false },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.reminder_enabled, 0, "reminderEnabled:false should set reminder_enabled to 0");
  });
});

// ----------------------------------------------------------------

describe("Sync push: cross-user entry deletion isolation", () => {
  let userAToken;
  let userAId;
  let userBToken;
  let userBId;
  let habitAId;
  let entryAId;

  before(async () => {
    const userA = createTestUser();
    userAId = userA.userId;
    userAToken = createTestSession(userAId);

    const userB = createTestUser();
    userBId = userB.userId;
    userBToken = createTestSession(userBId);

    habitAId = crypto.randomUUID();
    entryAId = crypto.randomUUID();

    // Create user A's habit and entry via sync push
    await api("POST", "/v1/sync/push", {
      token: userAToken,
      body: {
        habits: [{ id: habitAId, name: "User A habit", sortOrder: 0 }],
        entries: [{ id: entryAId, habitId: habitAId, date: "2025-06-15" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitAId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userAId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userBId);
  });

  it("user B deletedEntryIds cannot delete user A's entry", async () => {
    const { status, json } = await api("POST", "/v1/sync/push", {
      token: userBToken,
      body: {
        habits: [],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [entryAId],
      },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    const entry = db.prepare("SELECT id FROM habit_entries WHERE id = ?").get(entryAId);
    assert.ok(entry, "user B should not be able to delete user A's entry");
  });
});

// ----------------------------------------------------------------

describe("Sync push: non-existent deletedEntryIds is a silent no-op", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("push with non-existent entry id in deletedEntryIds returns ok and does not error", async () => {
    const fakeEntryId = crypto.randomUUID();
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [fakeEntryId],
      },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);
  });
});

// ----------------------------------------------------------------

describe("Sync: full pull returns empty deletion arrays even when tombstones exist", () => {
  let token;
  let userId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    // Push then delete a habit — creates a tombstone
    const habitId = crypto.randomUUID();
    const entryId = crypto.randomUUID();
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Will be deleted", sortOrder: 0 }],
        entries: [{ id: entryId, habitId, date: "2025-07-04" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [],
        entries: [],
        deletedHabitIds: [habitId],
        deletedEntryIds: [entryId],
      },
    });
  });

  after(() => {
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("full pull (no ?since) returns empty deletedHabitIds and deletedEntryIds even with tombstones", async () => {
    const { status, json } = await api("GET", "/v1/sync/pull", { token });
    assert.equal(status, 200);
    assert.ok(Array.isArray(json.deletedHabitIds), "deletedHabitIds should be an array");
    assert.ok(Array.isArray(json.deletedEntryIds), "deletedEntryIds should be an array");
    assert.equal(json.deletedHabitIds.length, 0, "full pull should never include tombstones");
    assert.equal(json.deletedEntryIds.length, 0, "full pull should never include tombstones");
    assert.ok(json.serverTime, "serverTime should be present");
  });
});

// ----------------------------------------------------------------

describe("Sync: ?since=empty string falls through to full pull", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    habitId = crypto.randomUUID();
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Full pull fallback habit", sortOrder: 0 }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("?since= empty string returns all habits (treated as full pull)", async () => {
    const { status, json } = await api("GET", "/v1/sync/pull", {
      token,
      query: { since: "" },
    });
    assert.equal(status, 200);
    const found = json.habits.find((h) => h.id === habitId);
    assert.ok(found, "habit should appear when since='' falls through to full pull");
    assert.ok(json.serverTime, "serverTime should be present");
  });
});

// ----------------------------------------------------------------

describe("CRUD GET /habits/:id/entries: note field included", () => {
  let token;
  let userId;
  let habitId;
  let entryId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    habitId = crypto.randomUUID();
    entryId = crypto.randomUUID();
    // Push a habit + entry with a note via sync
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Note entry habit", sortOrder: 0 }],
        entries: [{ id: entryId, habitId, date: "2025-11-01", note: "crud note check" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /habits/:id/entries includes note field (note set via sync push)", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/entries`, { token });
    assert.equal(status, 200);
    assert.equal(json.entries.length, 1);
    assert.equal(json.entries[0].note, "crud note check", "note must appear in CRUD GET entries response");
  });

  it("GET /habits/:id/entries with only ?from returns all entries (no ?to filter)", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { from: "2025-01-01" },
    });
    assert.equal(status, 200);
    assert.equal(json.entries.length, 1, "only-from filter falls through to full list");
    assert.equal(json.entries[0].note, "crud note check");
  });
});

// ----------------------------------------------------------------

describe("CRUD GET /habits/:id/entries: note field in date range query", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    habitId = crypto.randomUUID();
    // Push habit + entry with note via sync
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Range note habit", sortOrder: 0 }],
        entries: [{ id: crypto.randomUUID(), habitId, date: "2025-09-15", note: "range note" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /habits/:id/entries?from=&to= includes note field in range query", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { from: "2025-09-01", to: "2025-09-30" },
    });
    assert.equal(status, 200);
    assert.equal(json.entries.length, 1);
    assert.equal(json.entries[0].note, "range note", "note must appear in range-filtered CRUD GET entries response");
  });
});

// ----------------------------------------------------------------

describe("PUT /habits/:id: empty body preserves all fields", () => {
  let token;
  let userId;
  let habitId;
  let originalName;
  let originalEmoji;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Preserve test", emoji: "🌟", colorHex: "#FF6B35", note: "keep me" },
    });
    habitId = json.habit.id;
    originalName = json.habit.name;
    originalEmoji = json.habit.emoji;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("PUT with empty body {} returns 200 and preserves all fields", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: {},
    });
    assert.equal(status, 200);
    assert.equal(json.habit.name, originalName, "name must be preserved");
    assert.equal(json.habit.emoji, originalEmoji, "emoji must be preserved");
    assert.equal(json.habit.color_hex, "#FF6B35", "color_hex must be preserved");
    assert.equal(json.habit.note, "keep me", "note must be preserved when not in body");
    assert.equal(json.habit.is_archived, 0, "is_archived must be preserved");
  });
});

// ----------------------------------------------------------------

describe("GET /habits/:id/entries: zero entries returns empty array", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Zero entries habit" } });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /habits/:id/entries for habit with no entries returns empty list and correct pagination", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/entries`, { token });
    assert.equal(status, 200);
    assert.deepEqual(json.entries, [], "entries should be empty array");
    assert.equal(json.pagination.total, 0, "total should be 0");
    assert.equal(json.pagination.hasMore, false, "hasMore should be false");
    assert.equal(json.pagination.limit, 100, "default limit should be 100");
    assert.equal(json.pagination.offset, 0, "default offset should be 0");
  });
});

// ----------------------------------------------------------------

describe("Sync push: entry for self-deleted habit is silently dropped", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("push entry for a habit the user previously deleted returns ok:true without error", async () => {
    const habitId = crypto.randomUUID();

    // Push a habit, then delete it
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Soon deleted", sortOrder: 0 }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
    await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [], entries: [], deletedHabitIds: [habitId], deletedEntryIds: [] },
    });

    // Now push an entry for the (now-deleted) habit — stale client data scenario
    const staleEntryId = crypto.randomUUID();
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [],
        entries: [{ id: staleEntryId, habitId, date: "2025-06-01" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true, "should return ok:true even with stale entry for deleted habit");

    // Verify the stale entry was NOT inserted
    const entry = db.prepare("SELECT id FROM habit_entries WHERE id = ?").get(staleEntryId);
    assert.equal(entry, undefined, "entry for deleted habit should not be persisted");
  });
});

// ----------------------------------------------------------------

describe("PUT /habits/:id: boundary reminder values accepted", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Boundary reminder" } });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("PUT with reminderHour=23 and reminderMinute=59 (max boundary) is accepted", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { reminderEnabled: true, reminderHour: 23, reminderMinute: 59 },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.reminder_enabled, 1);
    assert.equal(json.habit.reminder_hour, 23);
    assert.equal(json.habit.reminder_minute, 59);
  });

  it("PUT with reminderHour=0 and reminderMinute=0 (min boundary) is accepted", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { reminderEnabled: true, reminderHour: 0, reminderMinute: 0 },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.reminder_hour, 0);
    assert.equal(json.habit.reminder_minute, 0);
  });
});

// ----------------------------------------------------------------

describe("Auth: delete-account without session returns 401", () => {
  it("POST /v1/auth/delete-account without token returns 401", async () => {
    const { status } = await api("POST", "/v1/auth/delete-account", { body: {} });
    assert.equal(status, 401);
  });
});

// ----------------------------------------------------------------

describe("Auth: request-link with missing email field", () => {
  it("POST /v1/auth/request-link with empty body returns 400", async () => {
    const { status, json } = await api("POST", "/v1/auth/request-link", { body: {} });
    assert.equal(status, 400);
    assert.ok(json.error, "should return an error message");
  });
});

// ----------------------------------------------------------------

describe("GET /login: HTML entity escaping for & and \" chars", () => {
  it("GET /login escapes & in token query param", async () => {
    const res = await fetch(`${BASE}/login?token=${encodeURIComponent("abc&def")}`);
    const text = await res.text();
    assert.ok(!text.includes("abc&def"), "raw & must not appear unescaped");
    assert.ok(text.includes("abc&amp;def"), "& must be escaped as &amp;");
  });

  it("GET /login escapes double-quote in token query param", async () => {
    const rawToken = 'tok"end';
    const res = await fetch(`${BASE}/login?token=${encodeURIComponent(rawToken)}`);
    const text = await res.text();
    assert.ok(!text.includes(rawToken), 'raw token with " must not appear verbatim');
    assert.ok(text.includes("tok&quot;end"), '\" must be escaped as &quot;');
  });
});

// ----------------------------------------------------------------

describe("express.json body size limit", () => {
  it("POST /v1/auth/request-link with >10kb body returns 413", async () => {
    // express.json({ limit: "10kb" }) — oversized payload must be rejected
    const bigBody = JSON.stringify({ email: "x".repeat(12 * 1024) });
    const res = await fetch(`${BASE}/v1/auth/request-link`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: bigBody,
    });
    assert.equal(res.status, 413, "oversized JSON body must be rejected with 413");
  });
});

// ----------------------------------------------------------------

describe("CORS: disallowed origin is rejected", () => {
  it("request from disallowed origin receives no Access-Control-Allow-Origin header", async () => {
    const res = await fetch(`${BASE}/health`, {
      headers: { Origin: "https://evil.example.com" },
    });
    // CORS rejection means the header is absent (not that the request itself fails)
    const allowOrigin = res.headers.get("access-control-allow-origin");
    assert.ok(
      !allowOrigin || allowOrigin !== "https://evil.example.com",
      "disallowed origin must not be reflected in Access-Control-Allow-Origin",
    );
  });
});

// ----------------------------------------------------------------

describe("Legacy routes (without /v1/ prefix)", () => {
  it("GET /habits returns same response as GET /v1/habits for authenticated user", async () => {
    const { userId } = createTestUser();
    const token = createTestSession(userId);

    const v1 = await api("GET", "/v1/habits", { token });
    const legacy = await api("GET", "/habits", { token });

    assert.equal(legacy.status, v1.status, "legacy /habits status must match /v1/habits");
    assert.deepEqual(legacy.json, v1.json, "legacy /habits body must match /v1/habits");
  });
});

// ----------------------------------------------------------------

describe("CRUD POST /habits/:id/entries: note field", () => {
  let token;
  let habitId;

  before(async () => {
    const { userId } = createTestUser();
    token = createTestSession(userId);
    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Note entry test" } });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
  });

  it("POST with note persists and returns note in response", async () => {
    const { status, json } = await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { date: "2025-09-01", note: "walked 5km" },
    });
    assert.equal(status, 201);
    assert.equal(json.entry.note, "walked 5km", "response must include the provided note");
  });

  it("GET /entries returns note from CRUD-created entry", async () => {
    const { json } = await api("GET", `/v1/habits/${habitId}/entries`, { token });
    const entry = json.entries.find((e) => e.date === "2025-09-01");
    assert.ok(entry, "entry must be present");
    assert.equal(entry.note, "walked 5km", "GET must return the note stored via CRUD POST");
  });

  it("POST without note stores null note", async () => {
    const { status, json } = await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { date: "2025-09-02" },
    });
    assert.equal(status, 201);
    assert.equal(json.entry.note, null, "note must be null when not provided");
  });

  it("POST with note: null stores null note", async () => {
    const { status, json } = await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { date: "2025-09-03", note: null },
    });
    assert.equal(status, 201);
    assert.equal(json.entry.note, null, "explicitly null note must be stored as null");
  });
});

// ----------------------------------------------------------------

describe("POST /habits: name with leading/trailing whitespace is trimmed", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    if (habitId) db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST with '  Walk Daily  ' stores name as 'Walk Daily'", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "  Walk Daily  " },
    });
    assert.equal(status, 201);
    assert.equal(json.habit.name, "Walk Daily", "stored name must be trimmed");
    habitId = json.habit.id;

    // Verify the trimmed name is returned in list
    const { json: listJson } = await api("GET", "/v1/habits", { token });
    const found = listJson.habits.find((h) => h.id === habitId);
    assert.ok(found, "habit must appear in list");
    assert.equal(found.name, "Walk Daily", "list must return trimmed name");
  });
});

// ----------------------------------------------------------------

describe("PUT /habits/:id: name with leading/trailing whitespace is trimmed", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Original Name" } });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("PUT with '  Updated Name  ' stores name as 'Updated Name'", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { name: "  Updated Name  " },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.name, "Updated Name", "stored name must be trimmed on update");
  });
});

// ----------------------------------------------------------------

describe("GET /habits: limit=0 falls back to default (50)", () => {
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

  it("GET /habits with limit=0 uses default limit of 50", async () => {
    const { status, json } = await api("GET", "/v1/habits", {
      token,
      query: { limit: "0" },
    });
    assert.equal(status, 200);
    assert.equal(json.pagination.limit, 50, "limit=0 must fall back to default 50");
  });
});

// ----------------------------------------------------------------

describe("PUT /habits/:id: reminderEnabled=true only preserves stored hour/minute", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    // Create habit with explicit reminder hour/minute
    const { json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Reminder test", reminderEnabled: true, reminderHour: 7, reminderMinute: 30 },
    });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("PUT with only reminderEnabled=false does not change stored hour/minute", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { reminderEnabled: false },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.reminder_enabled, 0, "reminder must be disabled");
    assert.equal(json.habit.reminder_hour, 7, "hour must be preserved from creation");
    assert.equal(json.habit.reminder_minute, 30, "minute must be preserved from creation");
  });

  it("PUT with reminderEnabled=true (no hour/minute) re-enables without changing stored values", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { reminderEnabled: true },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.reminder_enabled, 1, "reminder must be re-enabled");
    assert.equal(json.habit.reminder_hour, 7, "hour must still be 7 (unchanged by enable-only PUT)");
    assert.equal(json.habit.reminder_minute, 30, "minute must still be 30 (unchanged by enable-only PUT)");
  });
});

// ----------------------------------------------------------------

describe("PUT /habits/:id: colorHex-only update", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const created = await api("POST", "/v1/habits", {
      token,
      body: { name: "ColorHex Test Habit", emoji: "🎨", colorHex: "#FF0000" },
    });
    habitId = created.json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("PUT with only colorHex updates color_hex and preserves name and emoji", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { colorHex: "#0000FF" },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.color_hex, "#0000FF", "color_hex should be updated");
    assert.equal(json.habit.name, "ColorHex Test Habit", "name should be unchanged");
    assert.equal(json.habit.emoji, "🎨", "emoji should be unchanged");
  });
});

// ----------------------------------------------------------------

describe("PUT /habits/:id: emoji-only update", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const created = await api("POST", "/v1/habits", {
      token,
      body: { name: "Emoji Test Habit", emoji: "⭐", colorHex: "#34C759" },
    });
    habitId = created.json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("PUT with only emoji updates emoji and preserves name and color_hex", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { emoji: "🔥" },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.emoji, "🔥", "emoji should be updated");
    assert.equal(json.habit.name, "Emoji Test Habit", "name should be unchanged");
    assert.equal(json.habit.color_hex, "#34C759", "color_hex should be unchanged");
  });
});

// ----------------------------------------------------------------

describe("POST /habits: cross-user UUID collision returns 409", () => {
  let userAToken;
  let userAId;
  let userBToken;
  let userBId;
  let sharedId;

  before(async () => {
    const userA = createTestUser();
    userAId = userA.userId;
    userAToken = createTestSession(userAId);

    const userB = createTestUser();
    userBId = userB.userId;
    userBToken = createTestSession(userBId);

    // User A creates a habit with a specific UUID
    sharedId = crypto.randomUUID();
    await api("POST", "/v1/habits", {
      token: userAToken,
      body: { id: sharedId, name: "User A habit" },
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

  it("user B POST /habits with same UUID as user A returns 409", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token: userBToken,
      body: { id: sharedId, name: "User B colliding habit" },
    });
    assert.equal(status, 409, "duplicate UUID across users should return 409");
    assert.ok(json.error, "error message should be present");
  });
});

// ----------------------------------------------------------------

describe("DELETE /habits/:id/entries/:date: no tombstone on no-op delete", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const created = await api("POST", "/v1/habits", {
      token,
      body: { name: "No-tombstone habit" },
    });
    habitId = created.json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("DELETE for non-existent entry date does not create a tombstone", async () => {
    const sinceBefore = new Date().toISOString();

    // Delete a date that was never checked in
    const { status, json } = await api("DELETE", `/v1/habits/${habitId}/entries/2020-06-15`, { token });
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    // Incremental pull must return empty deletedEntryIds (no tombstone created)
    const pull = await api("GET", `/v1/sync/pull?since=${encodeURIComponent(sinceBefore)}`, { token });
    assert.equal(pull.status, 200);
    assert.equal(pull.json.deletedEntryIds.length, 0, "no tombstone should exist for a never-created entry");
  });
});

// ----------------------------------------------------------------

describe("Sync push: malformed habit with null name is silently skipped", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("sync push with null name habit does not crash (returns ok:true, habit is skipped)", async () => {
    const nullNameId = crypto.randomUUID();
    const validId = crypto.randomUUID();
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [
          { id: nullNameId, name: null, sortOrder: 0 },
          { id: validId, name: "Valid habit after null", sortOrder: 1 },
        ],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    const pull = await api("GET", "/v1/sync/pull", { token });
    const ids = pull.json.habits.map((h) => h.id);
    assert.ok(!ids.includes(nullNameId), "malformed habit (null name) must not be inserted");
    assert.ok(ids.includes(validId), "valid habit after null-name one must still be inserted");
  });

  it("sync push with missing id in habit is silently skipped", async () => {
    const validId = crypto.randomUUID();
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [
          { name: "No id habit", sortOrder: 0 },
          { id: validId, name: "After no-id habit", sortOrder: 1 },
        ],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    const pull = await api("GET", "/v1/sync/pull", { token });
    const validHabit = pull.json.habits.find((h) => h.id === validId);
    assert.ok(validHabit, "valid habit after no-id one must be inserted");
  });
});

// ----------------------------------------------------------------

describe("Sync push: malformed entry with null date is silently skipped", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("sync push with null date entry does not crash (returns ok:true, entry is skipped)", async () => {
    const habitId = crypto.randomUUID();
    const nullDateEntryId = crypto.randomUUID();
    const validEntryId = crypto.randomUUID();

    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Test habit for null date entry", sortOrder: 0 }],
        entries: [
          { id: nullDateEntryId, habitId, date: null },
          { id: validEntryId, habitId, date: "2025-11-15" },
        ],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    const pull = await api("GET", "/v1/sync/pull", { token });
    const entryIds = pull.json.entries.map((e) => e.id);
    assert.ok(!entryIds.includes(nullDateEntryId), "entry with null date must be skipped");
    assert.ok(entryIds.includes(validEntryId), "valid entry after null-date one must be inserted");
  });
});

// ----------------------------------------------------------------

describe("Sync pull incremental: habit note included in ?since response", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("incremental pull with ?since includes habit note field", async () => {
    const habitId = crypto.randomUUID();
    const beforePush = new Date(Date.now() - 2000).toISOString();

    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Habit note incremental test", sortOrder: 0, note: "incremental habit note" }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const { status, json } = await api("GET", "/v1/sync/pull", {
      token,
      query: { since: beforePush },
    });
    assert.equal(status, 200);
    const habit = json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "habit should appear in incremental pull");
    assert.equal(habit.note, "incremental habit note", "habit note must be included in incremental pull response");

    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
  });
});

// ----------------------------------------------------------------

describe("Sync push: habit note update via re-push", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("sync push updates habit note when same habit pushed again with new note", async () => {
    const habitId = crypto.randomUUID();
    const now = new Date().toISOString();

    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Note update habit", sortOrder: 0, note: "original note", updatedAt: now }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const later = new Date(Date.now() + 1000).toISOString();
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Note update habit", sortOrder: 0, note: "updated note", updatedAt: later }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const { status, json } = await api("GET", "/v1/sync/pull", { token });
    assert.equal(status, 200);
    const habit = json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "habit should exist in full pull");
    assert.equal(habit.note, "updated note", "habit note should be updated by second sync push");

    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
  });
});

// ----------------------------------------------------------------

describe("Sync pull: duplicate tombstones de-duplicated (retry-safe deletion)", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("pushing same deletedHabitId twice yields no duplicate in incremental pull response", async () => {
    const habitId = crypto.randomUUID();
    const beforePush = new Date(Date.now() - 1000).toISOString();

    // Push the same deletion twice (simulating a client retry)
    for (let i = 0; i < 2; i++) {
      await api("POST", "/v1/sync/push", {
        token,
        body: { habits: [], entries: [], deletedHabitIds: [habitId], deletedEntryIds: [] },
      });
    }

    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: beforePush } });
    assert.equal(pull.status, 200);
    const ids = pull.json.deletedHabitIds;
    assert.ok(Array.isArray(ids), "deletedHabitIds should be an array");
    const occurrences = ids.filter((id) => id === habitId).length;
    assert.equal(occurrences, 1, "duplicate tombstones from retry should be de-duplicated to one entry");
  });

  it("pushing same deletedEntryId twice yields no duplicate in incremental pull response", async () => {
    const entryId = crypto.randomUUID();
    const beforePush = new Date(Date.now() - 1000).toISOString();

    // Push the same entry deletion twice (simulating a client retry)
    for (let i = 0; i < 2; i++) {
      await api("POST", "/v1/sync/push", {
        token,
        body: { habits: [], entries: [], deletedHabitIds: [], deletedEntryIds: [entryId] },
      });
    }

    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: beforePush } });
    assert.equal(pull.status, 200);
    const ids = pull.json.deletedEntryIds;
    assert.ok(Array.isArray(ids), "deletedEntryIds should be an array");
    const occurrences = ids.filter((id) => id === entryId).length;
    assert.equal(occurrences, 1, "duplicate entry tombstones from retry should be de-duplicated to one entry");
  });
});

// ----------------------------------------------------------------

describe("Sync push: null array fields are treated as empty arrays", () => {
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

  it("POST /sync/push with habits: null returns ok:true (no crash)", async () => {
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: { habits: null, entries: [], deletedHabitIds: [], deletedEntryIds: [] },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);
  });

  it("POST /sync/push with entries: null returns ok:true (no crash)", async () => {
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [], entries: null, deletedHabitIds: [], deletedEntryIds: [] },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);
  });

  it("POST /sync/push with deletedHabitIds: null returns ok:true (no crash)", async () => {
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [], entries: [], deletedHabitIds: null, deletedEntryIds: [] },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);
  });

  it("POST /sync/push with deletedEntryIds: null returns ok:true (no crash)", async () => {
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [], entries: [], deletedHabitIds: [], deletedEntryIds: null },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);
  });
});

// ----------------------------------------------------------------

describe("CRUD DELETE habit-with-entries: no individual entry tombstones in sync pull", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("deleting a habit via CRUD creates habit tombstone but NOT entry tombstones", async () => {
    const habitId = crypto.randomUUID();
    const entry1Id = crypto.randomUUID();
    const entry2Id = crypto.randomUUID();

    // Create habit + entries via sync push
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Tombstone entry test", sortOrder: 0 }],
        entries: [
          { id: entry1Id, habitId, date: "2026-01-10" },
          { id: entry2Id, habitId, date: "2026-01-11" },
        ],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const sinceBeforeDelete = new Date(Date.now() - 500).toISOString();

    // Delete the habit via CRUD route
    const { status } = await api("DELETE", `/v1/habits/${habitId}`, { token });
    assert.equal(status, 200);

    // Incremental pull should include habit tombstone but NO entry tombstones
    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: sinceBeforeDelete } });
    assert.equal(pull.status, 200);
    assert.ok(pull.json.deletedHabitIds.includes(habitId), "habit tombstone should appear in deletedHabitIds");
    assert.equal(pull.json.deletedEntryIds.length, 0, "no individual entry tombstones when whole habit is deleted");
  });
});

// ----------------------------------------------------------------

describe("Stats: completionRate rounds to 3 decimal places", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("2 entries in a 7-day window gives completionRate=0.286", async () => {
    const habitId = crypto.randomUUID();
    const sixDaysAgo = new Date(Date.now() - 6 * 86400000).toISOString();
    const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    const twoDaysAgo = new Date(Date.now() - 2 * 86400000).toISOString().slice(0, 10);

    // Push habit with createdAt = 6 days ago so effectiveStart = 6 days ago (7-day window)
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Rate rounding test", createdAt: sixDaysAgo, updatedAt: sixDaysAgo }],
        entries: [
          { id: crypto.randomUUID(), habitId, date: yesterday },
          { id: crypto.randomUUID(), habitId, date: twoDaysAgo },
        ],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const { status, json } = await api("GET", `/v1/habits/${habitId}/stats`, { token });
    assert.equal(status, 200);
    // totalDays = 7, completedInRange = 2 → 2/7 ≈ 0.2857… → rounded to 0.286
    assert.equal(json.completionRate, 0.286, "completionRate should be rounded to 3 decimal places");
    assert.equal(json.totalEntries, 2);
  });
});

// ----------------------------------------------------------------

describe("Sync pull ?since: strict > boundary — habit with updated_at === since is not returned", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("incremental pull with since=updated_at does NOT include the habit (strict >)", async () => {
    const habitId = crypto.randomUUID();
    const updatedAt = "2026-01-10T12:00:00.000Z";

    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Boundary habit", updatedAt }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Pull with since = exact updated_at value — strict > means this habit should NOT appear
    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: updatedAt } });
    assert.equal(pull.status, 200);
    const found = pull.json.habits.find((h) => h.id === habitId);
    assert.equal(found, undefined, "habit with updated_at === since should not appear in incremental pull");
  });
});

// ----------------------------------------------------------------

describe("Sync push: createdAt preserved on re-push (ON CONFLICT does not update created_at)", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("re-pushing the same habit with a newer createdAt does not change the stored createdAt", async () => {
    const habitId = crypto.randomUUID();
    const originalCreatedAt = "2025-01-10T00:00:00.000Z";
    const newerCreatedAt = "2026-03-01T00:00:00.000Z";

    // First push: establish createdAt
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "CreatedAt test", createdAt: originalCreatedAt, updatedAt: originalCreatedAt }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Second push: same id, different name and newer createdAt
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Updated name", createdAt: newerCreatedAt, updatedAt: new Date().toISOString() }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Full pull: verify createdAt is still the original
    const pull = await api("GET", "/v1/sync/pull", { token });
    assert.equal(pull.status, 200);
    const habit = pull.json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "habit should exist in pull");
    assert.equal(habit.name, "Updated name", "name should be updated");
    assert.equal(habit.createdAt, originalCreatedAt, "createdAt must not be overwritten by re-push");
  });
});

// ----------------------------------------------------------------

describe("Sync push: omitting updatedAt uses server time (habit visible in subsequent incremental pull)", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("habit pushed without updatedAt uses server time and appears in incremental pull", async () => {
    const habitId = crypto.randomUUID();
    const beforePush = new Date(Date.now() - 1000).toISOString();

    // Push habit without providing updatedAt — server should assign current time
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "No updatedAt test" }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Incremental pull since 1s before push — habit should appear (server-assigned updated_at)
    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: beforePush } });
    assert.equal(pull.status, 200);
    const found = pull.json.habits.find((h) => h.id === habitId);
    assert.ok(found, "habit pushed without updatedAt should appear in incremental pull (server uses current time)");
  });
});

// ----------------------------------------------------------------

describe("Sync push: entry with null habitId is silently skipped", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("sync push with null habitId entry does not crash and entry is skipped", async () => {
    const habitId = crypto.randomUUID();
    const validEntryId = crypto.randomUUID();
    const badEntryId = crypto.randomUUID();

    // First push the habit
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Habit for null-habitId test", sortOrder: 0 }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Push entries: one with null habitId (should be skipped), one valid
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [],
        entries: [
          { id: badEntryId, habitId: null, date: "2026-03-01" },
          { id: validEntryId, habitId, date: "2026-03-01" },
        ],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    assert.equal(status, 200);
    assert.equal(json.ok, true, "sync push with null habitId entry should return ok:true");

    // Valid entry should be stored; bad entry should be absent
    const entries = db.prepare("SELECT id FROM habit_entries WHERE habit_id = ?").all(habitId);
    const entryIds = entries.map((e) => e.id);
    assert.ok(entryIds.includes(validEntryId), "valid entry must be inserted");
    assert.ok(!entryIds.includes(badEntryId), "entry with null habitId must be skipped");
  });
});

// ----------------------------------------------------------------

describe("Sync push: entry in both entries[] and deletedEntryIds[] — delete wins", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("entry listed in both entries[] and deletedEntryIds[] is not upserted (delete wins)", async () => {
    const habitId = crypto.randomUUID();
    const entryId = crypto.randomUUID();

    // Push habit first
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Conflict-resolution test habit", sortOrder: 0 }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Push entry in BOTH entries[] and deletedEntryIds[] simultaneously (offline conflict)
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [],
        entries: [{ id: entryId, habitId, date: "2026-04-01" }],
        deletedHabitIds: [],
        deletedEntryIds: [entryId],
      },
    });

    assert.equal(status, 200);
    assert.equal(json.ok, true);

    // Entry must NOT be upserted because it was in deletedEntryIds (delete wins)
    const stored = db.prepare("SELECT id FROM habit_entries WHERE id = ?").get(entryId);
    assert.equal(stored, undefined, "entry in both entries[] and deletedEntryIds[] must not be stored");

    // Tombstone must exist for the entry
    const tombstone = db.prepare(
      "SELECT id FROM deletion_tombstones WHERE user_id = ? AND entity_type = 'entry' AND entity_id = ?"
    ).get(userId, entryId);
    assert.ok(tombstone, "tombstone must be created for the deleted entry");
  });
});

// ----------------------------------------------------------------

describe("Sync push deletedHabitIds: cascade-deletes entries, only habit tombstone created", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("deleting habit via sync push cascades to entries and creates only habit tombstone", async () => {
    const habitId = crypto.randomUUID();
    const entry1Id = crypto.randomUUID();
    const entry2Id = crypto.randomUUID();

    // Push habit with entries
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Habit to delete via push", sortOrder: 0 }],
        entries: [
          { id: entry1Id, habitId, date: "2026-02-01" },
          { id: entry2Id, habitId, date: "2026-02-02" },
        ],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Verify entries exist before deletion
    const beforeCount = db.prepare("SELECT COUNT(*) as n FROM habit_entries WHERE habit_id = ?").get(habitId);
    assert.equal(beforeCount.n, 2, "should have 2 entries before deletion");

    const sinceBeforeDelete = new Date(Date.now() - 500).toISOString();

    // Delete habit via sync push deletedHabitIds
    const { status } = await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [], entries: [], deletedHabitIds: [habitId], deletedEntryIds: [] },
    });
    assert.equal(status, 200);

    // Entries must be cascade-deleted
    const afterCount = db.prepare("SELECT COUNT(*) as n FROM habit_entries WHERE habit_id = ?").get(habitId);
    assert.equal(afterCount.n, 0, "entries must be cascade-deleted when habit is deleted via sync push");

    // Incremental pull: habit tombstone present, NO entry tombstones
    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: sinceBeforeDelete } });
    assert.equal(pull.status, 200);
    assert.ok(pull.json.deletedHabitIds.includes(habitId), "habit tombstone should appear in deletedHabitIds");
    assert.equal(pull.json.deletedEntryIds.length, 0, "no entry tombstones when habit deleted via sync push");
  });
});

// ----------------------------------------------------------------

describe("PUT /habits/:id: note as empty string stores '' not null", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const { json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Empty note PUT test", note: "original" },
    });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("PUT with note:'' stores empty string, GET list returns ''", async () => {
    const put = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { note: "" },
    });
    assert.equal(put.status, 200);
    assert.equal(put.json.habit.note, "", "PUT response note should be empty string");

    const list = await api("GET", "/v1/habits", { token });
    const found = list.json.habits.find((h) => h.id === habitId);
    assert.ok(found, "habit should appear in list");
    assert.equal(found.note, "", "GET list note should be empty string, not null");
  });
});

// ----------------------------------------------------------------

describe("GET /habits: archived habits appear in list and total", () => {
  let token;
  let userId;
  let archivedId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Archive me" },
    });
    archivedId = json.habit.id;

    await api("PUT", `/v1/habits/${archivedId}`, {
      token,
      body: { isArchived: true },
    });
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("archived habit still appears in GET /habits list", async () => {
    const { status, json } = await api("GET", "/v1/habits", { token });
    assert.equal(status, 200);
    const found = json.habits.find((h) => h.id === archivedId);
    assert.ok(found, "archived habit should be in list");
    assert.equal(found.is_archived, 1, "is_archived should be 1");
    assert.equal(json.pagination.total, 1, "total should include archived habit");
  });
});

// ----------------------------------------------------------------

describe("Sync push + pull: empty-string note normalizes to null", () => {
  let token;
  let userId;
  let habitId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    habitId = crypto.randomUUID();
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("push note:'' stored as empty string; pull returns note:null via || normalization", async () => {
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Empty note sync", note: "" }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // DB should store ""
    const row = db.prepare("SELECT note FROM habits WHERE id = ?").get(habitId);
    assert.equal(row.note, "", "DB stores empty string as stored");

    // Sync pull normalizes "" to null via `row.note || null`
    const pull = await api("GET", "/v1/sync/pull", { token });
    assert.equal(pull.status, 200);
    const h = pull.json.habits.find((x) => x.id === habitId);
    assert.ok(h, "habit should appear in pull");
    assert.equal(h.note, null, "sync pull normalizes empty string to null");
  });
});

// ----------------------------------------------------------------

describe("POST /habits: empty-string emoji falls back to default ⭐", () => {
  let token;
  let habitId;

  before(async () => {
    const { userId } = createTestUser();
    token = createTestSession(userId);
    const { json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Emoji fallback test", emoji: "" },
    });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
  });

  it("empty-string emoji is stored as default ⭐", async () => {
    const { json } = await api("GET", "/v1/habits", { token });
    const habit = json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "habit must exist");
    assert.equal(habit.emoji, "⭐", "empty emoji must fall back to ⭐");
  });
});

// ----------------------------------------------------------------

describe("POST /habits: empty-string colorHex falls back to default #34C759", () => {
  let token;
  let habitId;

  before(async () => {
    const { userId } = createTestUser();
    token = createTestSession(userId);
    const { json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "ColorHex fallback test", colorHex: "" },
    });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
  });

  it("empty-string colorHex is stored as default #34C759", async () => {
    const { json } = await api("GET", "/v1/habits", { token });
    const habit = json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "habit must exist");
    assert.equal(habit.color_hex, "#34C759", "empty colorHex must fall back to #34C759");
  });
});

// ----------------------------------------------------------------

describe("Sync push: empty-string emoji falls back to default ⭐", () => {
  let token;
  let userId;
  let habitId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    habitId = crypto.randomUUID();
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("habit pushed with emoji:'' is stored with default ⭐", async () => {
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Sync emoji fallback", emoji: "", colorHex: "#FF0000" }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    const h = pull.json.habits.find((x) => x.id === habitId);
    assert.ok(h, "habit must appear in pull");
    assert.equal(h.emoji, "⭐", "empty-string emoji must fall back to ⭐ in sync pull");
  });
});

// ----------------------------------------------------------------

describe("Sync push: empty-string colorHex falls back to default #34C759", () => {
  let token;
  let userId;
  let habitId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    habitId = crypto.randomUUID();
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("habit pushed with colorHex:'' is stored with default #34C759", async () => {
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Sync colorHex fallback", emoji: "🏃", colorHex: "" }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    const h = pull.json.habits.find((x) => x.id === habitId);
    assert.ok(h, "habit must appear in pull");
    assert.equal(h.colorHex, "#34C759", "empty-string colorHex must fall back to #34C759 in sync pull");
  });
});

// ----------------------------------------------------------------

describe("Sync: entry note update visible in incremental pull (updated_at)", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("re-pushing an entry with updated note is visible in subsequent incremental pull", async () => {
    const habitId = crypto.randomUUID();
    const entryId = crypto.randomUUID();

    // Initial push: habit + entry with "original" note
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Note update sync test", sortOrder: 0 }],
        entries: [{ id: entryId, habitId, date: "2025-11-05", note: "original note" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Wait briefly to ensure the second push's updated_at is strictly > sinceAfterFirstPush
    await new Promise((resolve) => setTimeout(resolve, 5));
    const sinceAfterFirstPush = new Date().toISOString();
    await new Promise((resolve) => setTimeout(resolve, 5));

    // Re-push the same habit+date with an updated note (ON CONFLICT triggers updated_at)
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [],
        entries: [{ id: crypto.randomUUID(), habitId, date: "2025-11-05", note: "updated note" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Incremental pull: only changes since after the first push
    const pull = await api("GET", "/v1/sync/pull", {
      token,
      query: { since: sinceAfterFirstPush },
    });
    assert.equal(pull.status, 200);

    const entry = pull.json.entries.find((e) => e.habitId === habitId && e.date === "2025-11-05");
    assert.ok(entry, "updated entry must appear in incremental pull");
    assert.equal(entry.note, "updated note", "incremental pull must return the updated note value");
  });
});

// ----------------------------------------------------------------

describe("Habit API: created_at and updated_at timestamp fields", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST /habits response includes ISO8601 created_at and updated_at", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Timestamp test habit" },
    });
    assert.equal(status, 201);
    assert.ok(json.habit.created_at, "created_at must be present in POST response");
    assert.ok(json.habit.updated_at, "updated_at must be present in POST response");
    assert.match(json.habit.created_at, /^\d{4}-\d{2}-\d{2}T/, "created_at must be ISO8601");
    assert.match(json.habit.updated_at, /^\d{4}-\d{2}-\d{2}T/, "updated_at must be ISO8601");
  });

  it("POST /habits: created_at equals updated_at immediately after creation", async () => {
    const { json } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Equality timestamp habit" },
    });
    assert.equal(json.habit.created_at, json.habit.updated_at, "created_at and updated_at should be equal right after creation");
  });

  it("PUT /habits/:id updates updated_at but preserves created_at", async () => {
    const created = await api("POST", "/v1/habits", { token, body: { name: "Preserve createdAt habit" } });
    const habitId = created.json.habit.id;
    const originalCreatedAt = created.json.habit.created_at;

    // Wait a tick to ensure updated_at will differ from created_at
    await new Promise((resolve) => setTimeout(resolve, 5));

    const { json } = await api("PUT", `/v1/habits/${habitId}`, { token, body: { name: "Renamed habit" } });
    assert.equal(json.habit.created_at, originalCreatedAt, "created_at must not change on PUT");
    assert.ok(json.habit.updated_at >= originalCreatedAt, "updated_at must be >= created_at after PUT");
    assert.match(json.habit.updated_at, /^\d{4}-\d{2}-\d{2}T/, "updated_at must remain ISO8601 after PUT");
  });

  it("GET /habits list includes created_at and updated_at for each habit", async () => {
    const { json } = await api("GET", "/v1/habits", { token });
    assert.ok(json.habits.length > 0, "at least one habit should exist");
    for (const habit of json.habits) {
      assert.ok(habit.created_at, `habit ${habit.id} must have created_at in GET list`);
      assert.ok(habit.updated_at, `habit ${habit.id} must have updated_at in GET list`);
      assert.match(habit.created_at, /^\d{4}-\d{2}-\d{2}T/, "created_at must be ISO8601 in GET list");
      assert.match(habit.updated_at, /^\d{4}-\d{2}-\d{2}T/, "updated_at must be ISO8601 in GET list");
    }
  });

  it("PUT /habits/:id response includes created_at and updated_at", async () => {
    const created = await api("POST", "/v1/habits", { token, body: { name: "PUT timestamp check habit" } });
    const habitId = created.json.habit.id;

    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, { token, body: { name: "Updated name" } });
    assert.equal(status, 200);
    assert.ok(json.habit.created_at, "created_at must be present in PUT response");
    assert.ok(json.habit.updated_at, "updated_at must be present in PUT response");
    assert.match(json.habit.created_at, /^\d{4}-\d{2}-\d{2}T/, "created_at must be ISO8601 in PUT response");
    assert.match(json.habit.updated_at, /^\d{4}-\d{2}-\d{2}T/, "updated_at must be ISO8601 in PUT response");
  });
});

// ----------------------------------------------------------------

describe("Cookie-based authentication", () => {
  it("POST /v1/auth/logout sends Set-Cookie clear header (exercises clearSessionCookie)", async () => {
    const { userId } = createTestUser();
    const rawToken = crypto.randomBytes(32).toString("hex");
    const tokenHash = hashToken(rawToken);
    db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)")
      .run(userId, tokenHash, Date.now() + 1000 * 60 * 60);

    const cookieHeader = `stride_session=${encodeURIComponent(rawToken)}`;
    const res = await fetch(`${BASE}/v1/auth/logout`, {
      method: "POST",
      headers: { Cookie: cookieHeader },
    });
    assert.equal(res.status, 200);
    const setCookie = res.headers.get("set-cookie");
    assert.ok(setCookie, "Set-Cookie header should be present on logout");
    assert.ok(setCookie.includes("stride_session="), "Set-Cookie should name stride_session");
    assert.ok(setCookie.includes("Max-Age=0"), "Set-Cookie should clear cookie with Max-Age=0");

    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("cookie session authenticates GET /v1/habits (exercises getSessionUser + parseCookies)", async () => {
    const { userId } = createTestUser();
    const rawToken = crypto.randomBytes(32).toString("hex");
    const tokenHash = hashToken(rawToken);
    db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)")
      .run(userId, tokenHash, Date.now() + 1000 * 60 * 60);

    const cookieHeader = `stride_session=${encodeURIComponent(rawToken)}`;
    const res = await fetch(`${BASE}/v1/habits`, { headers: { Cookie: cookieHeader } });
    assert.equal(res.status, 200);
    const json = await res.json();
    assert.ok("habits" in json, "response should contain habits array");

    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /v1/auth/session with cookie returns user details", async () => {
    const { userId, email } = createTestUser();
    const rawToken = crypto.randomBytes(32).toString("hex");
    const tokenHash = hashToken(rawToken);
    db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)")
      .run(userId, tokenHash, Date.now() + 1000 * 60 * 60);

    const cookieHeader = `stride_session=${encodeURIComponent(rawToken)}`;
    const res = await fetch(`${BASE}/v1/auth/session`, { headers: { Cookie: cookieHeader } });
    assert.equal(res.status, 200);
    const json = await res.json();
    assert.ok(json.user, "user should be non-null with a valid cookie session");
    assert.equal(json.user.email, email);
    assert.ok(json.user.id, "user.id should be present");
    assert.ok(json.user.tier, "user.tier should be present");

    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("POST /v1/auth/logout with cookie clears session (exercises clearSession cookie path)", async () => {
    const { userId } = createTestUser();
    const rawToken = crypto.randomBytes(32).toString("hex");
    const tokenHash = hashToken(rawToken);
    db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)")
      .run(userId, tokenHash, Date.now() + 1000 * 60 * 60);

    const cookieHeader = `stride_session=${encodeURIComponent(rawToken)}`;

    const logoutRes = await fetch(`${BASE}/v1/auth/logout`, {
      method: "POST",
      headers: { Cookie: cookieHeader },
    });
    assert.equal(logoutRes.status, 200);

    // Session should be invalidated — subsequent cookie request returns 401
    const afterRes = await fetch(`${BASE}/v1/habits`, { headers: { Cookie: cookieHeader } });
    assert.equal(afterRes.status, 401, "cookie session should be invalidated after logout");

    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });
});

// ----------------------------------------------------------------

describe("POST /habits: sort_order auto-assignment is per-user, not global", () => {
  let userAToken;
  let userAId;
  let userBToken;
  let userBId;

  before(async () => {
    const a = createTestUser();
    userAId = a.userId;
    userAToken = createTestSession(userAId);

    const b = createTestUser();
    userBId = b.userId;
    userBToken = createTestSession(userBId);

    // User A creates 3 habits → sort_order 0, 1, 2
    await api("POST", "/v1/habits", { token: userAToken, body: { name: "A1" } });
    await api("POST", "/v1/habits", { token: userAToken, body: { name: "A2" } });
    await api("POST", "/v1/habits", { token: userAToken, body: { name: "A3" } });
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userAId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userBId);
  });

  it("user B's first habit gets sort_order 0, unaffected by user A's habits (sort_orders 0/1/2)", async () => {
    const { status, json } = await api("POST", "/v1/habits", {
      token: userBToken,
      body: { name: "B first habit" },
    });
    assert.equal(status, 201);
    assert.equal(json.habit.sort_order, 0, "sort_order must be 0 for user B's first habit, independent of user A's 3 habits");
  });
});

// ----------------------------------------------------------------

describe("Stats: future-only entries — currentStreak and completionRate exclude future dates", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    // Habit created >30 days ago so effectiveStart = thirtyDaysAgo
    const longAgo = new Date(Date.now() - 31 * 86400000).toISOString();
    habitId = crypto.randomUUID();
    db.prepare(
      "INSERT INTO habits (id, user_id, name, emoji, color_hex, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    ).run(habitId, userId, "Future-only habit", "⭐", "#34C759", 0, longAgo, longAgo);

    // Only entry is far in the future
    await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { date: "2099-12-31" },
    });
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("currentStreak=0 and completionRate=0 when all entries are future; totalEntries=1 and bestStreak=1", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/stats`, { token });
    assert.equal(status, 200);
    assert.equal(json.currentStreak, 0, "future entries do not count toward currentStreak");
    assert.equal(json.completionRate, 0, "future entries are excluded from 30-day completionRate window");
    assert.equal(json.totalEntries, 1, "totalEntries includes all entries, including future");
    assert.equal(json.bestStreak, 1, "bestStreak counts the one future entry as a streak of 1");
  });
});

// ----------------------------------------------------------------

describe("Sync push: entry with cross-user habitId is silently skipped", () => {
  let userAToken;
  let userAId;
  let userBToken;
  let userBId;
  let habitAId;
  let entryBId;

  before(async () => {
    const userA = createTestUser();
    userAId = userA.userId;
    userAToken = createTestSession(userAId);

    const userB = createTestUser();
    userBId = userB.userId;
    userBToken = createTestSession(userBId);

    // User A creates a habit via sync push
    habitAId = crypto.randomUUID();
    await api("POST", "/v1/sync/push", {
      token: userAToken,
      body: {
        habits: [{ id: habitAId, name: "User A habit", sortOrder: 0 }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitAId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userAId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userBId);
  });

  it("user B pushes entry for user A's habitId — entry is not created", async () => {
    entryBId = crypto.randomUUID();
    const { status, json } = await api("POST", "/v1/sync/push", {
      token: userBToken,
      body: {
        habits: [],
        entries: [{ id: entryBId, habitId: habitAId, date: "2026-01-15" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
    // Push succeeds (200) but entry is silently skipped
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    const entry = db.prepare("SELECT id FROM habit_entries WHERE id = ?").get(entryBId);
    assert.equal(entry, undefined, "entry for another user's habit must not be persisted");
  });
});

// ----------------------------------------------------------------

describe("Sync push: habit with sortOrder=0 preserved on re-push", () => {
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

  it("push habit with sortOrder=0; pull returns sortOrder=0 (not reset to default)", async () => {
    const habitId = crypto.randomUUID();
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "First habit", sortOrder: 0 }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const { json } = await api("GET", "/v1/sync/pull", { token });
    const habit = json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "habit should exist in pull response");
    assert.equal(habit.sortOrder, 0, "sortOrder=0 must round-trip correctly; 0 must not be treated as falsy");

    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
  });
});

// ----------------------------------------------------------------

describe("GET /habits/:id/entries: only ?from (no ?to) returns all entries ignoring ?from", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "From-only filter test" } });
    habitId = json.habit.id;

    // Create 3 entries spanning different dates
    for (const date of ["2024-01-01", "2025-06-01", "2026-01-01"]) {
      await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date } });
    }
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("?from=2025-01-01 without ?to returns all 3 entries (date filter requires both bounds)", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { from: "2025-01-01" },
    });
    assert.equal(status, 200);
    // Server requires both ?from AND ?to to activate date filter; one bound alone is ignored
    assert.equal(json.pagination.total, 3, "all 3 entries returned when only ?from is provided");
    assert.equal(json.entries.length, 3);
  });
});

// ----------------------------------------------------------------

describe("Sync push: reminderHour=0 (midnight) preserved via full pull", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("push habit with reminderHour=0; pull returns reminderHour=0 not 20 (nullish coalescing ?? not ||)", async () => {
    const habitId = crypto.randomUUID();
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{
          id: habitId,
          name: "Midnight reminder habit",
          reminderEnabled: true,
          reminderHour: 0,
          reminderMinute: 30,
        }],
        entries: [], deletedHabitIds: [], deletedEntryIds: [],
      },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    const habit = pull.json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "habit should exist in pull");
    assert.equal(habit.reminderHour, 0, "reminderHour=0 (midnight) must not be coerced to default 20");
    assert.equal(habit.reminderMinute, 30, "reminderMinute=30 should be preserved");
    assert.equal(habit.reminderEnabled, true);
  });
});

// ----------------------------------------------------------------

describe("Sync push: omitted reminderHour defaults to 20 in pull", () => {
  let token;
  let userId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("push habit without reminderHour field; pull returns reminderHour=20 (server default)", async () => {
    const habitId = crypto.randomUUID();
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{
          id: habitId,
          name: "Default hour habit",
          reminderEnabled: true,
          // reminderHour intentionally omitted — server should default to 20 via ?? 20
          reminderMinute: 15,
        }],
        entries: [], deletedHabitIds: [], deletedEntryIds: [],
      },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    const habit = pull.json.habits.find((h) => h.id === habitId);
    assert.ok(habit, "habit should exist in pull");
    assert.equal(habit.reminderHour, 20, "omitted reminderHour should fall back to default 20");
    assert.equal(habit.reminderMinute, 15);
  });
});

// ----------------------------------------------------------------

describe("Stats: currentStreak=2 when today and yesterday both have entries", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Two-day streak" } });
    habitId = json.habit.id;

    const today = new Date().toISOString().slice(0, 10);
    const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: today } });
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: yesterday } });
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("currentStreak is exactly 2 with entries for today and yesterday", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/stats`, { token });
    assert.equal(status, 200);
    assert.equal(json.currentStreak, 2, "today + yesterday = streak of 2");
    assert.equal(json.bestStreak, 2);
    assert.equal(json.totalEntries, 2);
  });
});

// ----------------------------------------------------------------

describe("Auth: delete-account removes deletion_tombstones (CASCADE)", () => {
  it("tombstones are gone after delete-account", async () => {
    const { userId } = createTestUser();
    const token = createTestSession(userId);

    // Create a habit, an entry, then delete the entry to generate a tombstone
    const { json: created } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Tombstone cleanup habit" },
    });
    const habitId = created.habit.id;
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: "2025-08-01" } });
    await api("DELETE", `/v1/habits/${habitId}/entries/2025-08-01`, { token });

    // Verify tombstone exists before account deletion
    const before = db.prepare(
      "SELECT id FROM deletion_tombstones WHERE user_id = ?",
    ).all(userId);
    assert.ok(before.length > 0, "tombstone should exist before account deletion");

    // Delete account
    const { status } = await api("POST", "/v1/auth/delete-account", { token });
    assert.equal(status, 200);

    // Tombstones for this user should be gone (ON DELETE CASCADE on user_id)
    const after = db.prepare(
      "SELECT id FROM deletion_tombstones WHERE user_id = ?",
    ).all(userId);
    assert.equal(after.length, 0, "all tombstones must be removed when account is deleted");
  });
});

// ----------------------------------------------------------------

describe("Stats: bestStreak counts today + tomorrow (future extends consecutive streak)", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);

    const { json } = await api("POST", "/v1/habits", { token, body: { name: "Future streak habit" } });
    habitId = json.habit.id;

    const today = new Date().toISOString().slice(0, 10);
    const tomorrow = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: today } });
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: tomorrow } });
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("bestStreak=2 with today+tomorrow; currentStreak=1 (backward from today, no yesterday)", async () => {
    const { status, json } = await api("GET", `/v1/habits/${habitId}/stats`, { token });
    assert.equal(status, 200);
    assert.equal(json.currentStreak, 1, "currentStreak counts backward from today — tomorrow has no effect");
    assert.equal(json.bestStreak, 2, "bestStreak includes future consecutive entry");
    assert.equal(json.totalEntries, 2, "totalEntries counts all entries including future");
  });
});

// ----------------------------------------------------------------

describe("Sync push: reminderEnabled toggle false → true via re-push", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    habitId = crypto.randomUUID();
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("re-pushing habit with reminderEnabled:true enables reminder after it was false", async () => {
    // First push: reminderEnabled false
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Reminder toggle habit", reminderEnabled: false, reminderHour: 8, reminderMinute: 0 }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const before = await api("GET", "/v1/sync/pull", { token });
    const h1 = before.json.habits.find((h) => h.id === habitId);
    assert.ok(h1, "habit should appear in pull after first push");
    assert.equal(h1.reminderEnabled, false, "reminderEnabled should be false after first push");

    // Re-push: toggle reminderEnabled to true
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Reminder toggle habit", reminderEnabled: true, reminderHour: 8, reminderMinute: 0 }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const after = await api("GET", "/v1/sync/pull", { token });
    const h2 = after.json.habits.find((h) => h.id === habitId);
    assert.ok(h2, "habit should appear in pull after re-push");
    assert.equal(h2.reminderEnabled, true, "reminderEnabled must be true after re-push with true");
    assert.equal(h2.reminderHour, 8, "reminderHour should be preserved during toggle");
  });
});
