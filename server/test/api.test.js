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
