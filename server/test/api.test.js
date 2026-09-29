const { describe, it, before, after } = require("node:test");
const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const crypto = require("node:crypto");
const http = require("node:http");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");
const Database = require("better-sqlite3");

const PORT = 3099;
const BASE = `http://localhost:${PORT}`;
const DB_PATH = path.join(__dirname, "..", "stride.db");

// Every server this suite spawns reads its sync pause flag from here, never from the default
// server/SYNC_PAUSED: a test that died between writing and removing that file would leave it
// in the tree, and the next rsync would carry it to production and pause every user.
const PAUSE_FILE = path.join(os.tmpdir(), `stride-test-SYNC_PAUSED-${process.pid}`);

/** The environment for a spawned test server: no inherited sync switches, pause flag outside the repo. */
function serverEnv(port, extra = {}) {
  const env = { ...process.env, PORT: String(port), NODE_ENV: "test", SYNC_PAUSE_FILE: PAUSE_FILE, ...extra };
  for (const k of ["SYNC_PAUSED", "SYNC_PAUSE_RETRY_AFTER_SECONDS", "SYNC_RATE_LIMIT_PER_MIN",
    "SYNC_AUTH_FAILURE_LIMIT_PER_15MIN", "GLOBAL_RATE_LIMIT_PER_15MIN", "STRIDE_TEST_HOOKS"]) {
    if (!(k in extra)) delete env[k];
  }
  // Empty rather than deleted: dotenv never overrides a variable that is present, so this also
  // wins over a server/.env. A shell with the production DSN or mail key exported must not
  // make the suite report its 500s to Sentry or send real mail from request-link.
  for (const k of ["SENTRY_DSN", "SENTRY_TRACES_SAMPLE_RATE", "RESEND_API_KEY"]) {
    if (!(k in extra)) env[k] = "";
  }
  return env;
}

// ---------- helpers ----------

let serverProcess;
/** Everything the main server wrote to stderr (console.warn / console.error). */
let serverStderr = "";
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
// 8s was too tight: on a loaded machine (or a slow CI box) node takes longer
// than that just to require express, and the whole suite then fails with a
// misleading "Server did not start" rather than a real assertion failure.
async function waitForServer(maxMs = Number(process.env.TEST_SERVER_START_TIMEOUT_MS || 60000), base = BASE) {
  const start = Date.now();
  while (Date.now() - start < maxMs) {
    try {
      const r = await fetch(`${base}/health`);
      if (r.ok) return;
    } catch {
      // not ready yet
    }
    await new Promise((r) => setTimeout(r, 150));
  }
  throw new Error(`Server did not start within ${maxMs}ms`);
}

/**
 * Run a script under server/ops and collect its exit status and output.
 *
 * Asynchronous on purpose. spawnSync blocks this process's event loop for as long as the
 * script runs (seconds on a loaded machine), so fetch's keep-alive timer cannot retire an idle
 * socket the server has meanwhile closed (5 s keep-alive); the next request reuses it and
 * dies with ECONNRESET. That is how the snapshot-request tests flaked.
 * @returns {Promise<{ status: number, stdout: string, stderr: string }>}
 */
function runScript(script, args = [], { env } = {}) {
  const { execFile } = require("node:child_process");
  return new Promise((resolve) => {
    execFile(process.execPath, [script, ...args], { encoding: "utf8", env: env ?? process.env }, (err, stdout, stderr) => {
      resolve({ status: err ? (typeof err.code === "number" ? err.code : 1) : 0, stdout, stderr });
    });
  });
}

// ---------- lifecycle ----------

before(async () => {
  // Open db connection for test helpers
  db = new Database(DB_PATH);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");

  // Spawn the server
  fs.rmSync(PAUSE_FILE, { force: true });
  serverProcess = spawn(process.execPath, [path.join(__dirname, "..", "index.js")], {
    env: serverEnv(PORT),
    stdio: "pipe",
  });

  serverProcess.stderr.on("data", (d) => { serverStderr += d; process.stderr.write(d); });

  await waitForServer();
});

after(() => {
  fs.rmSync(PAUSE_FILE, { force: true });
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

    // Pull with since = the row's stored change time — strict > means this habit should NOT
    // appear. That is the server's own clock, not the pushed updatedAt: the feed used to run
    // on the device's edit time, which is how offline edits went missing (see "Two clocks").
    const stored = db.prepare("SELECT updated_at FROM habits WHERE id = ?").get(habitId).updated_at;
    assert.notEqual(stored, updatedAt, "the feed time is the server's, not the client's edit time");
    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: stored } });
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
    // Whole seconds on the wire: shipped apps can't parse fractional seconds.
    assert.equal(habit.createdAt, originalCreatedAt.replace(".000Z", "Z"), "createdAt must not be overwritten by re-push");
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

describe("Sync push: tombstoned habit is not resurrected by stale push from another device", () => {
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

  it("re-pushing a previously-tombstoned habit does not resurrect it in full pull", async () => {
    const habitId = crypto.randomUUID();

    // Push habit, then delete it (tombstone recorded)
    await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [{ id: habitId, name: "Ghost Habit", sortOrder: 0 }], entries: [], deletedHabitIds: [], deletedEntryIds: [] },
    });
    await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [], entries: [], deletedHabitIds: [habitId], deletedEntryIds: [] },
    });

    // Stale device B re-pushes the habit without knowing it was deleted
    await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [{ id: habitId, name: "Ghost Habit", sortOrder: 0 }], entries: [], deletedHabitIds: [], deletedEntryIds: [] },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    const found = pull.json.habits.find((h) => h.id === habitId);
    assert.equal(found, undefined, "tombstoned habit must not be resurrected by stale push");
  });

  it("tombstone is preserved in incremental pull after stale re-push", async () => {
    const habitId = crypto.randomUUID();

    await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [{ id: habitId, name: "Ghost Habit 2", sortOrder: 0 }], entries: [], deletedHabitIds: [], deletedEntryIds: [] },
    });
    const beforeDelete = new Date(Date.now() - 1000).toISOString();
    await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [], entries: [], deletedHabitIds: [habitId], deletedEntryIds: [] },
    });

    // Stale re-push
    await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [{ id: habitId, name: "Ghost Habit 2", sortOrder: 0 }], entries: [], deletedHabitIds: [], deletedEntryIds: [] },
    });

    const incremental = await api("GET", `/v1/sync/pull?since=${beforeDelete}`, { token });
    assert.ok(incremental.json.deletedHabitIds.includes(habitId), "tombstone still present in incremental pull after stale re-push");
  });
});

describe("Sync push: tombstoned entry is not resurrected by stale push from another device", () => {
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

  it("re-pushing a previously-tombstoned entry does not resurrect it in full pull", async () => {
    const habitId = crypto.randomUUID();
    const entryId = crypto.randomUUID();

    // Push habit + entry, then tombstone the entry
    await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [{ id: habitId, name: "Active Habit", sortOrder: 0 }], entries: [], deletedHabitIds: [], deletedEntryIds: [] },
    });
    await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [], entries: [{ id: entryId, habitId, date: "2025-07-15" }], deletedHabitIds: [], deletedEntryIds: [] },
    });
    await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [], entries: [], deletedHabitIds: [], deletedEntryIds: [entryId] },
    });

    // Stale device re-pushes the entry
    await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [], entries: [{ id: entryId, habitId, date: "2025-07-15" }], deletedHabitIds: [], deletedEntryIds: [] },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    const found = pull.json.entries.find((e) => e.id === entryId);
    assert.equal(found, undefined, "tombstoned entry must not be resurrected by stale push");
  });
});

// ----------------------------------------------------------------

describe("Sync pull incremental: tombstone deleted_at === since is not returned (strict >)", () => {
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

  it("tombstone with deleted_at === since does not appear in incremental pull (strict >)", async () => {
    const habitId = crypto.randomUUID();
    const entryId = crypto.randomUUID();

    // Push habit + entry
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Boundary tombstone habit", sortOrder: 0 }],
        entries: [{ id: entryId, habitId, date: "2025-11-01" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Delete the habit via sync push — server creates tombstone with current time
    await api("POST", "/v1/sync/push", {
      token,
      body: { habits: [], entries: [], deletedHabitIds: [habitId], deletedEntryIds: [] },
    });

    // Read the exact deleted_at timestamp from the DB
    const tombstone = db.prepare(
      "SELECT deleted_at FROM deletion_tombstones WHERE user_id = ? AND entity_type = 'habit' AND entity_id = ?"
    ).get(userId, habitId);
    assert.ok(tombstone, "tombstone should exist");

    // Pull with since = exact deleted_at value — strict > means this tombstone should NOT appear
    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: tombstone.deleted_at } });
    assert.equal(pull.status, 200);
    assert.ok(Array.isArray(pull.json.deletedHabitIds), "deletedHabitIds should be an array");
    assert.equal(
      pull.json.deletedHabitIds.includes(habitId),
      false,
      "tombstone with deleted_at === since must not appear in incremental pull (strict >)"
    );
  });
});

// ----------------------------------------------------------------

describe("Sync pull incremental: tombstones are user-scoped (cross-user isolation)", () => {
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

    // User A pushes a habit + entry
    await api("POST", "/v1/sync/push", {
      token: userAToken,
      body: {
        habits: [{ id: habitAId, name: "User A habit to delete", sortOrder: 0 }],
        entries: [{ id: entryAId, habitId: habitAId, date: "2025-12-01" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });
  });

  after(() => {
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userAId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userBId);
  });

  it("user B incremental pull does not include user A's deleted habit in deletedHabitIds", async () => {
    const beforeDelete = new Date(Date.now() - 1000).toISOString();

    // User A deletes their habit
    await api("POST", "/v1/sync/push", {
      token: userAToken,
      body: { habits: [], entries: [], deletedHabitIds: [habitAId], deletedEntryIds: [] },
    });

    // User B incremental pull — should NOT contain user A's tombstone
    const pull = await api("GET", "/v1/sync/pull", { token: userBToken, query: { since: beforeDelete } });
    assert.equal(pull.status, 200);
    assert.ok(Array.isArray(pull.json.deletedHabitIds), "deletedHabitIds should be an array");
    assert.equal(
      pull.json.deletedHabitIds.includes(habitAId),
      false,
      "user B should not see user A's deletion tombstone in pull"
    );
  });

  it("user B incremental pull does not include user A's deleted entry in deletedEntryIds", async () => {
    const beforeDelete = new Date(Date.now() - 1000).toISOString();

    // User A deletes their entry (via re-push after habit is already tombstoned — but entry tombstone was already created above)
    // Insert entry tombstone directly for user A to test isolation
    const isolatedEntryId = crypto.randomUUID();
    db.prepare(
      "INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, 'entry', ?, ?)"
    ).run(userAId, isolatedEntryId, new Date().toISOString());

    const pull = await api("GET", "/v1/sync/pull", { token: userBToken, query: { since: beforeDelete } });
    assert.equal(pull.status, 200);
    assert.ok(Array.isArray(pull.json.deletedEntryIds), "deletedEntryIds should be an array");
    assert.equal(
      pull.json.deletedEntryIds.includes(isolatedEntryId),
      false,
      "user B should not see user A's entry deletion tombstone in pull"
    );
  });
});

// ----------------------------------------------------------------

describe("Sync push: entry with note:'' normalizes to null in pull response", () => {
  let token;
  let userId;
  let habitId;
  let entryId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    habitId = crypto.randomUUID();
    entryId = crypto.randomUUID();
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("push entry with note:'' stores empty string in DB; pull normalizes to null", async () => {
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Entry empty-note habit", sortOrder: 0 }],
        entries: [{ id: entryId, habitId, date: "2026-01-10", note: "" }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // DB should store empty string as-is (e.note ?? null keeps "")
    const row = db.prepare("SELECT note FROM habit_entries WHERE id = ?").get(entryId);
    assert.equal(row.note, "", "DB must store the empty string note for entries");

    // Full pull normalizes "" to null via `row.note || null`
    const pull = await api("GET", "/v1/sync/pull", { token });
    assert.equal(pull.status, 200);
    const entry = pull.json.entries.find((e) => e.id === entryId);
    assert.ok(entry, "entry must appear in pull");
    assert.equal(entry.note, null, "pull must normalize empty-string entry note to null");
  });
});

// ----------------------------------------------------------------

describe("Sync push: entry for a habit deleted in same push is silently skipped", () => {
  let token;
  let userId;

  before(async () => {
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

  it("entry referencing a habit deleted in the same push is not created", async () => {
    const habitId = crypto.randomUUID();
    const entryId = crypto.randomUUID();

    // First push: create the habit
    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "Habit to be deleted", sortOrder: 0 }],
        entries: [],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    // Second push: delete the habit AND send an entry for it in the same request
    const { status, json } = await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [],
        entries: [{ id: entryId, habitId, date: "2026-02-15" }],
        deletedHabitIds: [habitId],
        deletedEntryIds: [],
      },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    // Entry must NOT be stored (habit was deleted before entries are processed)
    const stored = db.prepare("SELECT id FROM habit_entries WHERE id = ?").get(entryId);
    assert.equal(stored, undefined, "entry for same-push deleted habit must not be created");

    // Habit tombstone must exist
    const tombstone = db.prepare(
      "SELECT id FROM deletion_tombstones WHERE user_id = ? AND entity_type = 'habit' AND entity_id = ?"
    ).get(userId, habitId);
    assert.ok(tombstone, "habit tombstone must be created");

    // Full pull must not contain the habit or the entry
    const pull = await api("GET", "/v1/sync/pull", { token });
    assert.equal(pull.json.habits.find((h) => h.id === habitId), undefined, "deleted habit must not appear in pull");
    assert.equal(pull.json.entries.find((e) => e.id === entryId), undefined, "entry for deleted habit must not appear in pull");
  });
});

// ----------------------------------------------------------------

describe("Sync push: entry note with CJK characters is preserved round-trip", () => {
  let token;
  let userId;
  let habitId;
  let entryId;

  before(() => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    habitId = crypto.randomUUID();
    entryId = crypto.randomUUID();
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("push entry with Chinese note; pull returns note without corruption", async () => {
    const cjkNote = "今日完成冥想🧘 感觉很好";

    await api("POST", "/v1/sync/push", {
      token,
      body: {
        habits: [{ id: habitId, name: "CJK entry note habit", sortOrder: 0 }],
        entries: [{ id: entryId, habitId, date: "2026-03-01", note: cjkNote }],
        deletedHabitIds: [],
        deletedEntryIds: [],
      },
    });

    const pull = await api("GET", "/v1/sync/pull", { token });
    assert.equal(pull.status, 200);
    const entry = pull.json.entries.find((e) => e.id === entryId);
    assert.ok(entry, "entry with CJK note must appear in pull");
    assert.equal(entry.note, cjkNote, "CJK entry note must not be corrupted in push/pull round-trip");
  });
});

// ----------------------------------------------------------------

describe("CRUD DELETE entry: tombstone appears in incremental sync pull", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const h = await api("POST", "/v1/habits", { token, body: { name: "Entry tombstone CRUD test" } });
    habitId = h.json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("deleting an existing entry via CRUD route creates a tombstone visible in incremental sync pull", async () => {
    const entryId = crypto.randomUUID();
    const date = "2026-03-20";

    await api("POST", `/v1/habits/${habitId}/entries`, {
      token,
      body: { id: entryId, date },
    });

    const sinceBefore = new Date(Date.now() - 500).toISOString();

    const del = await api("DELETE", `/v1/habits/${habitId}/entries/${date}`, { token });
    assert.equal(del.status, 200);

    const pull = await api("GET", "/v1/sync/pull", { token, query: { since: sinceBefore } });
    assert.equal(pull.status, 200);
    assert.ok(
      pull.json.deletedEntryIds.includes(entryId),
      "entry tombstone should appear in deletedEntryIds after CRUD deletion",
    );
    assert.equal(pull.json.deletedHabitIds.length, 0, "habit tombstone must not be created");
  });
});

// ----------------------------------------------------------------

describe("GET /habits/:id/entries: date-range filter with pagination — hasMore is accurate", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const h = await api("POST", "/v1/habits", { token, body: { name: "Date range pagination test" } });
    habitId = h.json.habit.id;
    // 4 entries inside range, 1 outside
    for (const d of ["2025-12-01", "2025-12-02", "2025-12-03", "2025-12-04"]) {
      await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: d } });
    }
    await api("POST", `/v1/habits/${habitId}/entries`, { token, body: { date: "2025-11-30" } });
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("hasMore=true when date-range total exceeds page limit", async () => {
    const { json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { from: "2025-12-01", to: "2025-12-04", limit: "2", offset: "0" },
    });
    assert.equal(json.entries.length, 2, "only 2 returned (page 1)");
    assert.equal(json.pagination.total, 4, "total reflects filtered count, not all-time count");
    assert.equal(json.pagination.hasMore, true, "hasMore=true: 4 filtered entries with limit=2");
  });

  it("hasMore=false on last page within date range", async () => {
    const { json } = await api("GET", `/v1/habits/${habitId}/entries`, {
      token,
      query: { from: "2025-12-01", to: "2025-12-04", limit: "2", offset: "2" },
    });
    assert.equal(json.entries.length, 2, "last page returns remaining 2 entries");
    assert.equal(json.pagination.hasMore, false, "hasMore=false on last page");
  });
});

// ----------------------------------------------------------------

describe("PUT /habits/:id: emoji='' stores empty string (unlike POST which falls back to default ⭐)", () => {
  let token;
  let userId;
  let habitId;

  before(async () => {
    const user = createTestUser();
    userId = user.userId;
    token = createTestSession(userId);
    const h = await api("POST", "/v1/habits", { token, body: { name: "Emoji clear test", emoji: "🏃" } });
    habitId = h.json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habits WHERE id = ?").run(habitId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("PUT with emoji:'' stores '' (COALESCE treats empty string as non-null; POST uses || fallback)", async () => {
    const { status, json } = await api("PUT", `/v1/habits/${habitId}`, {
      token,
      body: { emoji: "" },
    });
    assert.equal(status, 200);
    assert.equal(json.habit.emoji, "", "PUT stores '' as-is without default fallback");
  });
});

// ----------------------------------------------------------------

describe("Auth: delete-account removes magic_link_tokens (CASCADE)", () => {
  it("pending magic link token is cleaned up when its user is deleted", () => {
    // Create user and insert a pending (unused) magic link token
    const { userId } = createTestUser();
    const token = createTestSession(userId);
    const rawToken = crypto.randomBytes(32).toString("hex");
    const tokenHash = hashToken(rawToken);
    db.prepare(
      "INSERT INTO magic_link_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)"
    ).run(userId, tokenHash, Date.now() + 1000 * 60 * 30);

    // Verify it exists
    const before = db.prepare("SELECT id FROM magic_link_tokens WHERE user_id = ?").get(userId);
    assert.ok(before, "magic link token should exist before delete-account");

    // Delete the user (simulates delete-account path — CASCADE should remove token)
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);

    // Token must be gone via ON DELETE CASCADE
    const after = db.prepare("SELECT id FROM magic_link_tokens WHERE user_id = ?").get(userId);
    assert.equal(after, undefined, "magic_link_tokens must be CASCADE-deleted when user is removed");
  });
});

// ----------------------------------------------------------------

describe("GET /habits: non-numeric ?limit string falls back to default 50", () => {
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

  it("limit='abc' is parsed as NaN and falls back to 50 via || operator", async () => {
    const { status, json } = await api("GET", "/v1/habits", {
      token,
      query: { limit: "abc" },
    });
    assert.equal(status, 200);
    assert.equal(json.pagination.limit, 50, "non-numeric limit should fall back to default 50");
  });
});

// ----------------------------------------------------------------

describe("Auth: non-Bearer Authorization header is rejected as unauthenticated", () => {
  it("Authorization: Token <valid-token> returns 401 (only 'Bearer ' prefix is accepted)", async () => {
    // Create a valid session token, but send it with wrong scheme
    const { userId } = createTestUser();
    const rawToken = crypto.randomBytes(32).toString("hex");
    const tokenHash = hashToken(rawToken);
    db.prepare(
      "INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)"
    ).run(userId, tokenHash, Date.now() + 1000 * 60 * 60 * 24);

    const res = await fetch(`${BASE}/v1/habits`, {
      headers: { Authorization: `Token ${rawToken}` },
    });
    const json = await res.json().catch(() => null);

    // Cleanup
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);

    assert.equal(res.status, 401, "non-Bearer scheme must not authenticate");
    assert.ok(json && json.error, "should return error body");
  });
});

// ----------------------------------------------------------------

describe("Auth: /v1/auth/verify with empty-string token is rejected (falsy guard, not typeof guard)", () => {
  it("token:'' is rejected with 400 'Missing token' (or 429 if rate-limited)", async () => {
    const { status, json } = await api("POST", "/v1/auth/verify", {
      body: { token: "" },
    });
    // 400 = validation rejection from the !token branch in routes/auth.js;
    // 429 = verifyLimiter exhausted (verifyLimiter has no test bypass — sibling
    // test at line 3180 uses the same tolerance).
    assert.ok(status === 400 || status === 429, `expected 400 or 429, got ${status}`);
    assert.ok(json && json.error, "should return error body");
    if (status === 400) {
      assert.equal(json.error, "Missing token", "400 must come from the !token branch, not typeof");
    }
  });
});

// ----------------------------------------------------------------

describe("Auth: delete-account invalidates the Bearer session token (CASCADE on sessions)", () => {
  it("after delete-account, the same Bearer token returns 401 on /v1/habits", async () => {
    const { userId } = createTestUser();
    const token = createTestSession(userId);

    // Token works before delete-account
    const before = await api("GET", "/v1/habits", { token });
    assert.equal(before.status, 200, "token should be valid before delete-account");

    // Delete the account
    const del = await api("POST", "/v1/auth/delete-account", { token });
    assert.equal(del.status, 200);

    // Same token must now be rejected — sessions row was CASCADE-deleted with the user
    const after = await api("GET", "/v1/habits", { token });
    assert.equal(after.status, 401, "Bearer token must be unauthenticated after delete-account");
    assert.ok(after.json && after.json.error, "should return error body");
  });
});

// ----------------------------------------------------------------

describe("Auth: delete-account physically removes habits and habit_entries (no orphans)", () => {
  it("habits and habit_entries rows for the deleted user are gone (no FK CASCADE — explicit cleanup)", async () => {
    const { userId } = createTestUser();
    const token = createTestSession(userId);

    // Create two habits, each with one entry, so we exercise the multi-id IN-clause path
    const { json: h1 } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Cleanup habit 1" },
    });
    const { json: h2 } = await api("POST", "/v1/habits", {
      token,
      body: { name: "Cleanup habit 2" },
    });
    const habitId1 = h1.habit.id;
    const habitId2 = h2.habit.id;

    await api("POST", `/v1/habits/${habitId1}/entries`, { token, body: { date: "2025-09-01" } });
    await api("POST", `/v1/habits/${habitId2}/entries`, { token, body: { date: "2025-09-02" } });

    // Verify rows exist before delete-account
    const habitsBefore = db.prepare("SELECT id FROM habits WHERE user_id = ?").all(userId);
    assert.equal(habitsBefore.length, 2, "two habits should exist before delete-account");
    const entriesBefore = db
      .prepare("SELECT id FROM habit_entries WHERE habit_id IN (?, ?)")
      .all(habitId1, habitId2);
    assert.equal(entriesBefore.length, 2, "two entries should exist before delete-account");

    // Delete the account
    const { status } = await api("POST", "/v1/auth/delete-account", { token });
    assert.equal(status, 200);

    // Habits don't have ON DELETE CASCADE on user_id, so the explicit cleanup in
    // deleteUserAccount() is what prevents orphan rows. Verify both tables are empty.
    const habitsAfter = db.prepare("SELECT id FROM habits WHERE user_id = ?").all(userId);
    assert.equal(habitsAfter.length, 0, "all habits must be removed when account is deleted");
    const entriesAfter = db
      .prepare("SELECT id FROM habit_entries WHERE habit_id IN (?, ?)")
      .all(habitId1, habitId2);
    assert.equal(entriesAfter.length, 0, "all habit_entries must be removed when account is deleted");
  });
});

// ----------------------------------------------------------------

describe("CRUD: user B cannot DELETE entry on user A's habit (404 + no tombstone in either user)", () => {
  let userAToken, userAId, habitAId, entryDate;
  let userBToken, userBId;

  before(async () => {
    const userA = createTestUser();
    userAId = userA.userId;
    userAToken = createTestSession(userAId);

    const userB = createTestUser();
    userBId = userB.userId;
    userBToken = createTestSession(userBId);

    const { json: hJson } = await api("POST", "/v1/habits", {
      token: userAToken,
      body: { name: "User A entry-delete-isolation habit" },
    });
    habitAId = hJson.habit.id;

    entryDate = "2026-03-10";
    await api("POST", `/v1/habits/${habitAId}/entries`, {
      token: userAToken,
      body: { date: entryDate },
    });
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userAId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM sessions WHERE user_id IN (?, ?)").run(userAId, userBId);
    db.prepare("DELETE FROM users WHERE id IN (?, ?)").run(userAId, userBId);
  });

  it("user B's DELETE on user A's entry returns 404, leaves entry intact, creates no tombstone", async () => {
    // Sanity: entry exists in user A's habit
    const before = db
      .prepare("SELECT id FROM habit_entries WHERE habit_id = ? AND date = ?")
      .get(habitAId, entryDate);
    assert.ok(before, "entry should exist before cross-user DELETE attempt");

    // User B attempts to delete user A's entry — habit-ownership check must reject as 404
    const { status, json } = await api(
      "DELETE",
      `/v1/habits/${habitAId}/entries/${entryDate}`,
      { token: userBToken },
    );
    assert.equal(status, 404, "user B must get 404 for user A's habit (no leak of habit existence)");
    assert.ok(json && json.error, "should return error body");

    // Entry must still exist
    const after = db
      .prepare("SELECT id FROM habit_entries WHERE habit_id = ? AND date = ?")
      .get(habitAId, entryDate);
    assert.ok(after, "entry must remain after failed cross-user DELETE");
    assert.equal(after.id, before.id, "same entry id (not recreated)");

    // Critically: NO tombstone should have been inserted in EITHER user's row.
    // The route returns 404 before the transaction block runs.
    const aTombs = db
      .prepare("SELECT COUNT(*) AS c FROM deletion_tombstones WHERE user_id = ?")
      .get(userAId);
    assert.equal(aTombs.c, 0, "no tombstone in user A's row (entry was not actually deleted)");
    const bTombs = db
      .prepare("SELECT COUNT(*) AS c FROM deletion_tombstones WHERE user_id = ?")
      .get(userBId);
    assert.equal(bTombs.c, 0, "no junk tombstone in user B's row from rejected request");
  });
});

// ----------------------------------------------------------------

describe("Sync push: deletedHabitIds with cross-user habit_id does not delete the other user's habit", () => {
  let userAToken, userAId, habitAId;
  let userBToken, userBId;

  before(async () => {
    const userA = createTestUser();
    userAId = userA.userId;
    userAToken = createTestSession(userAId);

    const userB = createTestUser();
    userBId = userB.userId;
    userBToken = createTestSession(userBId);

    const { json } = await api("POST", "/v1/habits", {
      token: userAToken,
      body: { name: "User A sync-isolation habit" },
    });
    habitAId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userAId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM sessions WHERE user_id IN (?, ?)").run(userAId, userBId);
    db.prepare("DELETE FROM users WHERE id IN (?, ?)").run(userAId, userBId);
  });

  it("user B push deletedHabitIds=[habitAId] returns 200 but user A's habit is NOT deleted", async () => {
    // Sanity: habit exists for user A
    const before = db.prepare("SELECT id FROM habits WHERE id = ? AND user_id = ?").get(habitAId, userAId);
    assert.ok(before, "user A's habit should exist before cross-user push attempt");

    // User B tries to delete user A's habit by including its id in deletedHabitIds.
    // The DELETE statement is scoped: `DELETE FROM habits WHERE id = ? AND user_id = ?`
    // with user_id = userBId, so it must not affect user A's row.
    const { status, json } = await api("POST", "/v1/sync/push", {
      token: userBToken,
      body: { deletedHabitIds: [habitAId] },
    });
    assert.equal(status, 200, "push itself succeeds (no-op delete on cross-user row)");
    assert.equal(json.ok, true);

    // User A's habit must still be present
    const after = db.prepare("SELECT id, name FROM habits WHERE id = ? AND user_id = ?").get(habitAId, userAId);
    assert.ok(after, "user A's habit must remain after user B's hostile push");
    assert.equal(after.name, "User A sync-isolation habit", "name unchanged");

    // User A's incremental pull must NOT see this habit_id in deletedHabitIds —
    // tombstones live under user_id, so user B's tombstone is invisible to A.
    const sinceBefore = "2020-01-01T00:00:00Z";
    const pull = await api(
      "GET",
      `/v1/sync/pull?since=${encodeURIComponent(sinceBefore)}`,
      { token: userAToken },
    );
    assert.equal(pull.status, 200);
    assert.ok(
      !pull.json.deletedHabitIds.includes(habitAId),
      "user A must not see their own habit_id in deletedHabitIds — tombstones are user-scoped",
    );
  });
});

// ----------------------------------------------------------------

describe("Sync push: deletedEntryIds with cross-user entry_id does not delete the other user's entry", () => {
  let userAToken, userAId, habitAId, entryAId;
  let userBToken, userBId;

  before(async () => {
    const userA = createTestUser();
    userAId = userA.userId;
    userAToken = createTestSession(userAId);

    const userB = createTestUser();
    userBId = userB.userId;
    userBToken = createTestSession(userBId);

    const { json: hJson } = await api("POST", "/v1/habits", {
      token: userAToken,
      body: { name: "User A entry-sync-isolation habit" },
    });
    habitAId = hJson.habit.id;

    const { json: eJson } = await api("POST", `/v1/habits/${habitAId}/entries`, {
      token: userAToken,
      body: { date: "2026-03-15" },
    });
    entryAId = eJson.entry.id;
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userAId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userBId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userAId);
    db.prepare("DELETE FROM sessions WHERE user_id IN (?, ?)").run(userAId, userBId);
    db.prepare("DELETE FROM users WHERE id IN (?, ?)").run(userAId, userBId);
  });

  it("user B push deletedEntryIds=[entryAId] returns 200 but user A's entry is NOT deleted", async () => {
    // Sanity: entry exists under user A's habit
    const before = db.prepare("SELECT id FROM habit_entries WHERE id = ?").get(entryAId);
    assert.ok(before, "user A's entry should exist before cross-user push attempt");

    // User B pushes a delete for user A's entry id. The route uses:
    //   DELETE FROM habit_entries WHERE id = ? AND habit_id IN (SELECT id FROM habits WHERE user_id = ?)
    // with user_id = userBId, so the subquery returns no habits owned by B that match,
    // and the DELETE must affect 0 rows.
    const { status, json } = await api("POST", "/v1/sync/push", {
      token: userBToken,
      body: { deletedEntryIds: [entryAId] },
    });
    assert.equal(status, 200);
    assert.equal(json.ok, true);

    // User A's entry must still be present
    const after = db.prepare("SELECT id, habit_id, date FROM habit_entries WHERE id = ?").get(entryAId);
    assert.ok(after, "user A's entry must remain after user B's hostile push");
    assert.equal(after.habit_id, habitAId, "still attached to the same habit");
    assert.equal(after.date, "2026-03-15", "date unchanged");

    // User A's incremental pull must NOT see this entry_id in deletedEntryIds.
    const sinceBefore = "2020-01-01T00:00:00Z";
    const pull = await api(
      "GET",
      `/v1/sync/pull?since=${encodeURIComponent(sinceBefore)}`,
      { token: userAToken },
    );
    assert.equal(pull.status, 200);
    assert.ok(
      !pull.json.deletedEntryIds.includes(entryAId),
      "user A must not see their own entry_id in deletedEntryIds — tombstones are user-scoped",
    );
  });
});

// ----------------------------------------------------------------

describe("Sync push: habit_id in both deletedHabitIds and habits[] of same push — delete wins (blockedHabits set)", () => {
  let userToken, userId, habitId;

  before(async () => {
    const u = createTestUser();
    userId = u.userId;
    userToken = createTestSession(userId);

    // Seed a habit so it actually exists pre-push
    const { json } = await api("POST", "/v1/habits", {
      token: userToken,
      body: { name: "Same-push delete-vs-upsert" },
    });
    habitId = json.habit.id;
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("habit pushed in both deletedHabitIds and habits[] is deleted, NOT resurrected (blockedHabits guard)", async () => {
    // Sanity: habit exists
    const before = db.prepare("SELECT id FROM habits WHERE id = ? AND user_id = ?").get(habitId, userId);
    assert.ok(before, "seeded habit should exist before same-push test");

    // Capture sync time BEFORE the push so the tombstone (deleted_at = now during push)
    // is strictly greater than `since`.
    const sinceBefore = new Date(Date.now() - 60_000).toISOString();

    // Push includes the same habit id in BOTH deletedHabitIds and habits[].
    // sync.js processes deletedHabitIds first (lines 79-83), adds id to blockedHabits set,
    // then iterates habits[] and skips any id present in blockedHabits (line 92).
    const pushBody = {
      deletedHabitIds: [habitId],
      habits: [{
        id: habitId,
        name: "Should-not-resurrect",
        emoji: "💀",
        colorHex: "#FF0000",
        sortOrder: 0,
      }],
    };
    const { status, json } = await api("POST", "/v1/sync/push", {
      token: userToken,
      body: pushBody,
    });
    assert.equal(status, 200, "push succeeds (200)");
    assert.equal(json.ok, true);

    // Habit must be GONE from DB (delete ran, upsert was blocked)
    const after = db.prepare("SELECT id, name FROM habits WHERE id = ? AND user_id = ?").get(habitId, userId);
    assert.equal(after, undefined, "habit must be absent after same-push delete+upsert (blockedHabits prevented resurrection)");

    // Full pull must NOT include this habit
    const full = await api("GET", "/v1/sync/pull", { token: userToken });
    assert.equal(full.status, 200);
    const stillPresent = full.json.habits.some((h) => h.id === habitId);
    assert.equal(stillPresent, false, "deleted habit must not appear in full pull");

    // Incremental pull (since strictly before tombstone) must include the tombstone
    const incr = await api(
      "GET",
      `/v1/sync/pull?since=${encodeURIComponent(sinceBefore)}`,
      { token: userToken },
    );
    assert.equal(incr.status, 200);
    assert.ok(
      incr.json.deletedHabitIds.includes(habitId),
      "tombstone for the deleted habit must be visible in incremental pull",
    );
    assert.equal(
      incr.json.habits.find((h) => h.id === habitId),
      undefined,
      "deleted habit must NOT appear in incremental pull's habits[] (delete won, upsert was skipped)",
    );
  });
});

// ----------------------------------------------------------------

describe("Sync pull (full): deletedHabitIds and deletedEntryIds are always empty arrays even when tombstones exist", () => {
  let userToken, userId, habitId;

  before(async () => {
    const u = createTestUser();
    userId = u.userId;
    userToken = createTestSession(userId);

    // Create habit, then delete it to generate a real tombstone in this user's row
    const { json } = await api("POST", "/v1/habits", {
      token: userToken,
      body: { name: "Tombstone for full-pull suppression test" },
    });
    habitId = json.habit.id;

    await api("POST", "/v1/sync/push", {
      token: userToken,
      body: { deletedHabitIds: [habitId] },
    });
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("GET /v1/sync/pull (no since) returns empty deleted*Ids even when tombstones exist for this user", async () => {
    // Sanity: tombstone really exists in DB
    const tombCount = db
      .prepare("SELECT COUNT(*) AS c FROM deletion_tombstones WHERE user_id = ? AND entity_type = 'habit'")
      .get(userId).c;
    assert.equal(tombCount, 1, "exactly one habit tombstone should exist for this user");

    // Full pull (no since param) — sync.js hardcodes deletedHabitIds=[] and deletedEntryIds=[]
    // because clients reconcile against the full habits/entries set, not deltas.
    const { status, json } = await api("GET", "/v1/sync/pull", { token: userToken });
    assert.equal(status, 200);
    assert.deepEqual(json.deletedHabitIds, [], "full pull must return empty deletedHabitIds even when tombstones exist");
    assert.deepEqual(json.deletedEntryIds, [], "full pull must return empty deletedEntryIds even when tombstones exist");

    // serverTime should still be present in the full-pull response
    assert.ok(typeof json.serverTime === "string" && json.serverTime.length > 0, "full pull includes serverTime");
  });
});

// ----------------------------------------------------------------

describe("Sync push: habit with name='' is silently skipped (server-side !h.name guard, no 4xx)", () => {
  let userToken, userId;
  const blankNameId = `00000000-0000-4000-8000-${Date.now().toString(16).padStart(12, "0")}`;

  before(() => {
    const u = createTestUser();
    userId = u.userId;
    userToken = createTestSession(userId);
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("push with habits=[{ id, name:'' }] returns 200 and does NOT insert the row", async () => {
    // Sanity: this synthetic id is not yet in DB
    const before = db
      .prepare("SELECT id FROM habits WHERE id = ? AND user_id = ?")
      .get(blankNameId, userId);
    assert.equal(before, undefined, "synthetic blank-name habit id must not exist before push");

    // sync.js line 91: `if (!h.id || !h.name) continue;` — '' is falsy, so this row is skipped.
    // Distinct from POST /habits which returns 400 for missing/empty name.
    const { status, json } = await api("POST", "/v1/sync/push", {
      token: userToken,
      body: {
        habits: [{
          id: blankNameId,
          name: "",
          emoji: "🧪",
          colorHex: "#888888",
          sortOrder: 0,
        }],
      },
    });
    assert.equal(status, 200, "push silently succeeds (no 4xx) for invalid rows");
    assert.equal(json.ok, true);

    // The row must not have been inserted
    const after = db
      .prepare("SELECT id FROM habits WHERE id = ? AND user_id = ?")
      .get(blankNameId, userId);
    assert.equal(after, undefined, "blank-name habit must not be inserted (silently dropped by !h.name guard)");

    // Full pull must not include it
    const full = await api("GET", "/v1/sync/pull", { token: userToken });
    assert.equal(full.status, 200);
    const found = full.json.habits.some((h) => h.id === blankNameId);
    assert.equal(found, false, "blank-name habit must not appear in full pull");
  });
});

// ---------- tombstone / expiry GC (sweepStaleData) ----------

describe("sweepStaleData GC", () => {
  // Same DB file as the running server (WAL gives cross-connection read-your-writes
  // after the sweep's transaction commits).
  const appDb = require("../db");

  // Opt-in since M0: the default sweep keeps every tombstone (see db.js and the
  // "M0 sweepStaleData keeps tombstones unless asked" test). Passing a retention is how
  // sweeping comes back once a minimum-version floor has retired the <= 1.2.3 apps.
  it("deletes tombstones older than an explicitly passed retention window, keeps recent ones", () => {
    const { userId } = createTestUser();
    const oldIso = new Date(Date.now() - 200 * 86400000).toISOString(); // 200 days ago
    const freshIso = new Date().toISOString();
    db.prepare(
      "INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, 'habit', ?, ?)"
    ).run(userId, "old-tomb", oldIso);
    db.prepare(
      "INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, 'habit', ?, ?)"
    ).run(userId, "fresh-tomb", freshIso);

    appDb.sweepStaleData({ tombstoneRetentionDays: 90, belowCursorHorizon: true });

    const old = db.prepare("SELECT 1 FROM deletion_tombstones WHERE entity_id = ?").get("old-tomb");
    const fresh = db.prepare("SELECT 1 FROM deletion_tombstones WHERE entity_id = ?").get("fresh-tomb");
    assert.equal(old, undefined, "tombstone older than retention window is swept");
    assert.ok(fresh, "recent tombstone is retained");
  });

  it("deletes expired sessions but keeps valid ones", () => {
    const { userId } = createTestUser();
    const expiredHash = hashToken(crypto.randomBytes(32).toString("hex"));
    const validHash = hashToken(crypto.randomBytes(32).toString("hex"));
    db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)")
      .run(userId, expiredHash, Date.now() - 1000);
    db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)")
      .run(userId, validHash, Date.now() + 86400000);

    appDb.sweepStaleData();

    assert.equal(db.prepare("SELECT 1 FROM sessions WHERE token_hash = ?").get(expiredHash), undefined);
    assert.ok(db.prepare("SELECT 1 FROM sessions WHERE token_hash = ?").get(validHash));
  });
});

// ---------- multi-device last-write-wins on habit upsert ----------

describe("Sync push LWW: stale device cannot clobber a newer edit", () => {
  let userToken, userId, habitId;
  before(() => {
    const u = createTestUser();
    userId = u.userId;
    userToken = createTestSession(userId);
    habitId = crypto.randomUUID();
  });
  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  const T1 = "2026-01-01T00:00:00.000Z";
  const T2 = "2026-06-01T00:00:00.000Z";
  const T3 = "2026-12-01T00:00:00.000Z";
  const h = (name, updatedAt) => ({
    id: habitId, name, emoji: "⭐", colorHex: "#34C759",
    isArchived: false, sortOrder: 0, createdAt: T1, updatedAt,
  });

  it("newer push applies, then an older push is ignored", async () => {
    let r = await api("POST", "/v1/sync/push", { token: userToken, body: { habits: [h("New", T2)] } });
    assert.equal(r.status, 200);

    // Stale device pushes older data for the same habit
    r = await api("POST", "/v1/sync/push", { token: userToken, body: { habits: [h("Old", T1)] } });
    assert.equal(r.status, 200, "push still returns ok (no error)");

    const pull = await api("GET", "/v1/sync/pull", { token: userToken });
    const found = pull.json.habits.find((x) => x.id === habitId);
    assert.equal(found.name, "New", "older push must NOT overwrite the newer name");
  });

  it("a strictly newer push does overwrite", async () => {
    const r = await api("POST", "/v1/sync/push", { token: userToken, body: { habits: [h("Newest", T3)] } });
    assert.equal(r.status, 200);
    const pull = await api("GET", "/v1/sync/pull", { token: userToken });
    const found = pull.json.habits.find((x) => x.id === habitId);
    assert.equal(found.name, "Newest", "newer push must overwrite");
  });
});

// ---------- v2: quantitative + scheduling + grouping round-trip ----------

describe("Sync v2 fields round-trip (count habit, schedule, group, entry value)", () => {
  let token, userId, habitId, groupId;
  before(() => {
    const u = createTestUser();
    userId = u.userId;
    token = createTestSession(userId);
    habitId = crypto.randomUUID();
    groupId = crypto.randomUUID();
  });
  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM habit_groups WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("pushes and pulls back count habit + group + entry value", async () => {
    const push = await api("POST", "/v1/sync/push", { token, body: {
      groups: [{ id: groupId, name: "Health", colorHex: "#FF0000", sortOrder: 2,
        createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z" }],
      habits: [{ id: habitId, name: "Water", emoji: "💧", colorHex: "#007AFF",
        isArchived: false, sortOrder: 1,
        kind: "count", targetValue: 8, unit: "glasses",
        scheduleKind: "timesPerWeek", timesPerWeek: 5, activeDaysMask: 62,
        groupId,
        createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-06-01T00:00:00.000Z" }],
      entries: [{ id: crypto.randomUUID(), habitId, date: "2026-06-05", value: 5,
        createdAt: "2026-06-05T00:00:00.000Z" }],
    }});
    assert.equal(push.status, 200);

    const pull = await api("GET", "/v1/sync/pull", { token });
    assert.equal(pull.status, 200);

    const h = pull.json.habits.find((x) => x.id === habitId);
    assert.ok(h, "habit returned");
    assert.equal(h.kind, "count");
    assert.equal(h.targetValue, 8);
    assert.equal(h.unit, "glasses");
    assert.equal(h.scheduleKind, "timesPerWeek");
    assert.equal(h.timesPerWeek, 5);
    assert.equal(h.activeDaysMask, 62);
    assert.equal(h.groupId, groupId);

    const g = pull.json.groups.find((x) => x.id === groupId);
    assert.ok(g, "group returned");
    assert.equal(g.name, "Health");
    assert.equal(g.colorHex, "#FF0000");
    assert.equal(g.sortOrder, 2);

    const e = pull.json.entries.find((x) => x.habitId === habitId);
    assert.ok(e, "entry returned");
    assert.equal(e.value, 5);
  });

  it("a deleted group is tombstoned and dropped from referencing habits on next device", async () => {
    let r = await api("POST", "/v1/sync/push", { token, body: { deletedGroupIds: [groupId] } });
    assert.equal(r.status, 200);
    const pull = await api("GET", "/v1/sync/pull", { token });
    assert.ok(!pull.json.groups.some((x) => x.id === groupId), "group removed from full pull");
  });
});

// ---------------------------------------------------------------------------
// REGRESSION: the exact bytes shipped clients put on the wire.
//
// Every iOS/macOS build up to and including 1.2.1 encodes with
// JSONEncoder.keyEncodingStrategy = .convertToSnakeCase, so it sends
// `habit_id` / `deleted_habit_ids` / `color_hex`, while these routes were
// written against camelCase. Nothing tested that seam: the suite above pushes
// camelCase, i.e. the server's own assumption on both sides, so 278 green tests
// coexisted with a push path that silently discarded every check-in, reset habit
// fields to defaults, and never propagated a deletion — after which the client's
// full-pull reconciliation deleted the user's local records because the server
// had none. The payloads below are copied verbatim from a real JSONEncoder run.
// ---------------------------------------------------------------------------
describe("Wire-format contract: snake_case payload from shipped (<=1.2.1) clients", () => {
  let token, userId, habitId, entryId, groupId;
  before(() => {
    const u = createTestUser();
    userId = u.userId;
    token = createTestSession(userId);
    habitId = crypto.randomUUID().toUpperCase();
    entryId = crypto.randomUUID().toUpperCase();
    groupId = crypto.randomUUID().toUpperCase();
  });
  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM habit_groups WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("stores the check-in instead of silently dropping it (the data-loss bug)", async () => {
    const push = await api("POST", "/v1/sync/push", { token, body: {
      groups: [{ id: groupId, name: "Health", color_hex: "#FF0000", sort_order: 2,
        created_at: "2026-01-01T00:00:00.000Z", updated_at: "2026-01-01T00:00:00.000Z" }],
      habits: [{ id: habitId, name: "Morning Run", emoji: "\u{1F3C3}", color_hex: "#FF3B30",
        is_archived: false, sort_order: 3,
        reminder_enabled: true, reminder_hour: 7, reminder_minute: 30, note: "keep it up",
        kind: "count", target_value: 5, unit: "km",
        schedule_kind: "specificDays", times_per_week: 3, active_days_mask: 42,
        group_id: groupId,
        created_at: "2026-01-01T00:00:00.000Z", updated_at: "2026-06-01T00:00:00.000Z" }],
      entries: [{ id: entryId, habit_id: habitId, date: "2026-06-05", value: 5,
        created_at: "2026-06-05T00:00:00.000Z" }],
      deleted_habit_ids: [], deleted_entry_ids: [], deleted_group_ids: [],
    }});
    assert.equal(push.status, 200);

    const pull = await api("GET", "/v1/sync/pull", { token });
    assert.equal(pull.status, 200);

    const e = pull.json.entries.find((x) => x.id === entryId);
    assert.ok(e, "the check-in reached the server (was dropped by the !e.habitId guard)");
    assert.equal(e.habitId, habitId);
    assert.equal(e.value, 5);
  });

  it("keeps every habit field instead of resetting it to a server default", async () => {
    const pull = await api("GET", "/v1/sync/pull", { token });
    const h = pull.json.habits.find((x) => x.id === habitId);
    assert.ok(h, "habit returned");
    assert.equal(h.colorHex, "#FF3B30", "colorHex must not fall back to #34C759");
    assert.equal(h.sortOrder, 3);
    assert.equal(h.reminderEnabled, true);
    assert.equal(h.reminderHour, 7);
    assert.equal(h.reminderMinute, 30);
    assert.equal(h.kind, "count");
    assert.equal(h.targetValue, 5);
    assert.equal(h.unit, "km");
    assert.equal(h.scheduleKind, "specificDays", "must not fall back to 'daily'");
    assert.equal(h.timesPerWeek, 3, "must not fall back to 7");
    assert.equal(h.activeDaysMask, 42, "must not fall back to 127");
    assert.equal(h.groupId, groupId, "group membership must not be cleared");
  });

  it("propagates a deletion sent as deleted_habit_ids", async () => {
    const r = await api("POST", "/v1/sync/push", { token, body: {
      habits: [], entries: [], groups: [],
      deleted_habit_ids: [habitId], deleted_entry_ids: [], deleted_group_ids: [],
    }});
    assert.equal(r.status, 200);
    const pull = await api("GET", "/v1/sync/pull", { token });
    assert.ok(!pull.json.habits.some((x) => x.id === habitId), "habit deleted on server");
  });

  it("still accepts the camelCase form that fixed (>=1.2.2) clients send", async () => {
    const id = crypto.randomUUID().toUpperCase();
    const eid = crypto.randomUUID().toUpperCase();
    const push = await api("POST", "/v1/sync/push", { token, body: {
      habits: [{ id, name: "Read", emoji: "\u{1F4D6}", colorHex: "#00FF00", isArchived: false,
        sortOrder: 9, kind: "binary", targetValue: 1, scheduleKind: "daily",
        timesPerWeek: 7, activeDaysMask: 127,
        createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-06-01T00:00:00.000Z" }],
      entries: [{ id: eid, habitId: id, date: "2026-06-06", value: 1,
        createdAt: "2026-06-06T00:00:00.000Z" }],
    }});
    assert.equal(push.status, 200);
    const pull = await api("GET", "/v1/sync/pull", { token });
    const h = pull.json.habits.find((x) => x.id === id);
    assert.ok(h, "camelCase habit stored");
    assert.equal(h.colorHex, "#00FF00");
    assert.equal(h.sortOrder, 9);
    assert.ok(pull.json.entries.some((x) => x.id === eid), "camelCase entry stored");
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(id);
    db.prepare("DELETE FROM habits WHERE id = ?").run(id);
  });
});

// ---------------------------------------------------------------------------
// REGRESSION: the sync body limit.
//
// SyncService.pushLocal sends a FULL SNAPSHOT of every habit and every check-in
// on every sync, so the payload grows without bound. Against the old global
// 10kb cap that meant 3 habits + ~53 entries (10,627 B measured) returned 413,
// and because sync() awaits pushLocal BEFORE pullRemote a 413 killed both
// directions permanently — the client just resent a larger payload next time.
// The sync routes now mount their own 5mb parser ABOVE the global one; ordering
// is load-bearing, since body-parser lets the first parser to run win.
// ---------------------------------------------------------------------------
describe("Sync body limit: a large full-snapshot push is accepted", () => {
  let token, userId, habitId;
  before(() => {
    const u = createTestUser();
    userId = u.userId;
    token = createTestSession(userId);
    habitId = crypto.randomUUID().toUpperCase();
  });
  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id = ?").run(habitId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("accepts a year of check-ins (well past the old 10kb ceiling)", async () => {
    const entries = [];
    const start = new Date("2026-01-01T00:00:00.000Z");
    for (let i = 0; i < 365; i++) {
      const d = new Date(start.getTime() + i * 86400000).toISOString().slice(0, 10);
      entries.push({ id: crypto.randomUUID().toUpperCase(), habitId, date: d, value: 1,
        createdAt: `${d}T00:00:00.000Z` });
    }
    const body = {
      habits: [{ id: habitId, name: "Morning Run", emoji: "\u{1F3C3}", colorHex: "#FF3B30",
        isArchived: false, sortOrder: 1, kind: "binary", targetValue: 1, scheduleKind: "daily",
        timesPerWeek: 7, activeDaysMask: 127,
        createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-06-01T00:00:00.000Z" }],
      entries, deletedHabitIds: [], deletedEntryIds: [], deletedGroupIds: [],
    };
    assert.ok(JSON.stringify(body).length > 10 * 1024,
      "the fixture must exceed the old 10kb cap or this test proves nothing");

    const push = await api("POST", "/v1/sync/push", { token, body });
    assert.equal(push.status, 200, "a full-snapshot push must not 413");

    const pull = await api("GET", "/v1/sync/pull", { token });
    assert.equal(pull.json.entries.filter((e) => e.habitId === habitId).length, 365);
  });

  it("still caps every other route, so the unauthenticated endpoints stay protected", async () => {
    const r = await api("POST", "/v1/auth/request-link", { body: { email: "x".repeat(20000) + "@y.com" } });
    assert.equal(r.status, 413, "non-sync routes must keep the 10kb limit");
  });
});

// ---------------------------------------------------------------------------
// REGRESSION: server-generated ids were lower case, the apps' are upper case.
//
// crypto.randomUUID() is lower case; Swift's UUID.uuidString is upper case; the id
// columns compare with BINARY collation. The App Review demo account (seeded here)
// therefore had lower-case ids that shipped clients matched against nothing, and a
// client that normalised them would push them back upper case and get every habit
// and check-in inserted twice. migrations/canonicalizeIds.js upper-cases stored ids
// at startup; these tests run it against rows written the way seed-demo.js used to.
// ---------------------------------------------------------------------------
describe("Id canonicalisation: stored ids are upper case, like the apps'", () => {
  const { canonicalizeIds } = require("../migrations/canonicalizeIds");
  let fk, token, userId;
  const lower = () => crypto.randomUUID().toLowerCase();
  const groupId = lower(), habitId = lower(), entryA = lower(), entryB = lower(), goneEntry = lower();

  before(() => {
    // Own connection with foreign keys on, as db.js has, so a re-key that orphans an
    // entry fails here the way it would in production.
    fk = new Database(DB_PATH);
    fk.pragma("foreign_keys = ON");
    const u = createTestUser();
    userId = u.userId;
    token = createTestSession(userId);

    fk.prepare("INSERT INTO habit_groups (id, user_id, name) VALUES (?, ?, 'Morning')").run(groupId, userId);
    fk.prepare("INSERT INTO habits (id, user_id, name, group_id) VALUES (?, ?, 'Read', ?)").run(habitId, userId, groupId);
    fk.prepare("INSERT INTO habit_entries (id, habit_id, date, created_at, updated_at) VALUES (?, ?, '2026-09-01', '2026-09-01T08:00:00.000Z', '2026-09-01T08:00:00.000Z')").run(entryA, habitId);
    fk.prepare("INSERT INTO habit_entries (id, habit_id, date, created_at, updated_at) VALUES (?, ?, '2026-09-02', '2026-09-02T08:00:00.000Z', '2026-09-02T08:00:00.000Z')").run(entryB, habitId);
    // An entry tombstone names its row's habit (E2E S4), a copy of habit_entries.habit_id.
    fk.prepare("INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at, habit_id, entry_date) VALUES (?, 'entry', ?, '2026-09-03T08:00:00.000Z', ?, '2026-09-03')").run(userId, goneEntry, habitId);
  });

  after(() => {
    fk.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userId);
    fk.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    fk.prepare("DELETE FROM habit_groups WHERE user_id = ?").run(userId);
    fk.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    fk.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    fk.prepare("DELETE FROM users WHERE id = ?").run(userId);
    fk.close();
  });

  it("refuses to run outside a transaction", () => {
    assert.throws(() => canonicalizeIds(fk), /inside a transaction/);
  });

  it("upper-cases every id and keeps the check-ins attached to their habit", () => {
    const result = fk.transaction(() => canonicalizeIds(fk))();
    assert.equal(result.changed, true, `expected a re-key, got ${JSON.stringify(result)}`);

    const habit = fk.prepare("SELECT id, group_id FROM habits WHERE user_id = ?").get(userId);
    assert.equal(habit.id, habitId.toUpperCase());
    assert.equal(habit.group_id, groupId.toUpperCase());
    assert.equal(fk.prepare("SELECT id FROM habit_groups WHERE user_id = ?").get(userId).id, groupId.toUpperCase());

    const entries = fk.prepare("SELECT id, habit_id FROM habit_entries WHERE habit_id = ? ORDER BY date").all(habitId.toUpperCase());
    assert.deepEqual(entries.map((e) => e.id), [entryA.toUpperCase(), entryB.toUpperCase()]);

    const tomb = fk.prepare("SELECT entity_id, habit_id FROM deletion_tombstones WHERE user_id = ?").get(userId);
    assert.equal(tomb.entity_id, goneEntry.toUpperCase());
    assert.equal(tomb.habit_id, habitId.toUpperCase(), "the tombstone's habit id changes case with the entries' (the pull compares them)");

    assert.deepEqual(fk.pragma("foreign_key_check"), [], "no entry may be left pointing at the old habit id");
  });

  it("is idempotent", () => {
    const again = fk.transaction(() => canonicalizeIds(fk))();
    assert.deepEqual(again, { lowercase: 0, twins: 0, changed: false });
  });

  it("an app pushing the same habit and check-ins back updates them rather than duplicating", async () => {
    const H = habitId.toUpperCase();
    const body = {
      habits: [{ id: H, name: "Read", emoji: "\u{1F4D6}", colorHex: "#34C759", isArchived: false, sortOrder: 0,
        kind: "binary", targetValue: 1, scheduleKind: "daily", timesPerWeek: 7, activeDaysMask: 127,
        groupId: groupId.toUpperCase(), createdAt: "2026-09-01T00:00:00.000Z", updatedAt: "2026-09-10T00:00:00.000Z" }],
      entries: [
        { id: entryA.toUpperCase(), habitId: H, date: "2026-09-01", value: 1, createdAt: "2026-09-01T08:00:00.000Z" },
        { id: entryB.toUpperCase(), habitId: H, date: "2026-09-02", value: 1, createdAt: "2026-09-02T08:00:00.000Z" },
      ],
      groups: [{ id: groupId.toUpperCase(), name: "Morning", sortOrder: 0,
        createdAt: "2026-09-01T00:00:00.000Z", updatedAt: "2026-09-10T00:00:00.000Z" }],
      deletedHabitIds: [], deletedEntryIds: [], deletedGroupIds: [],
    };
    const push = await api("POST", "/v1/sync/push", { token, body });
    assert.equal(push.status, 200);

    assert.equal(fk.prepare("SELECT count(*) AS n FROM habits WHERE user_id = ?").get(userId).n, 1);
    assert.equal(fk.prepare("SELECT count(*) AS n FROM habit_groups WHERE user_id = ?").get(userId).n, 1);
    assert.equal(fk.prepare("SELECT count(*) AS n FROM habit_entries WHERE habit_id = ?").get(H).n, 2);

    const pull = await api("GET", "/v1/sync/pull", { token });
    assert.deepEqual(pull.json.habits.map((h) => h.id), [H]);
    assert.ok(pull.json.entries.every((e) => e.habitId === H && e.id === e.id.toUpperCase()));
  });

  it("changes nothing when a lower-case id already has an upper-case twin", () => {
    const twin = lower();
    fk.prepare("INSERT INTO habits (id, user_id, name) VALUES (?, ?, 'Twin lower')").run(twin, userId);
    fk.prepare("INSERT INTO habits (id, user_id, name) VALUES (?, ?, 'Twin upper')").run(twin.toUpperCase(), userId);
    try {
      const result = fk.transaction(() => canonicalizeIds(fk))();
      assert.equal(result.changed, false);
      assert.ok(result.twins >= 1);
      assert.equal(fk.prepare("SELECT count(*) AS n FROM habits WHERE id IN (?, ?)").get(twin, twin.toUpperCase()).n, 2,
        "both rows must survive untouched; startup must never throw or merge");
    } finally {
      fk.prepare("DELETE FROM habits WHERE id IN (?, ?)").run(twin, twin.toUpperCase());
    }
  });

  it("the REST create route now generates upper-case ids", async () => {
    const r = await api("POST", "/v1/habits", { token, body: { name: "Generated" } });
    assert.equal(r.status, 201);
    assert.match(r.json.habit.id, /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/);
  });
});

// ---------------------------------------------------------------------------
// REGRESSION: one timestamp column was doing two jobs (see "Two clocks" in routes/sync.js).
//
// - Entries had no last-write-wins guard, so a device pushing a stale count overwrote a
//   newer one — every client pushes its full snapshot on every sync.
// - Habits stored the device's edit time as the change-feed time, so an edit made offline
//   and pushed later sorted before the cursor of devices that synced in between, and never
//   reached them.
// - Timestamps went out with milliseconds, which no shipped app can parse.
// - A ?since without milliseconds sorted after rows written later in the same second.
// ---------------------------------------------------------------------------
describe("Sync: last write wins by edit time; the change feed runs on server time", () => {
  let token, userId;
  const uuid = () => crypto.randomUUID().toUpperCase();
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const H = uuid();
  const habit = (over = {}) => ({
    id: H, name: "Water", emoji: "\u{1F4A7}", colorHex: "#007AFF", isArchived: false, sortOrder: 0,
    kind: "count", targetValue: 8, scheduleKind: "daily", timesPerWeek: 7, activeDaysMask: 127,
    createdAt: "2026-09-01T00:00:00Z", updatedAt: "2026-09-01T00:00:00Z", ...over,
  });
  const entry = (id, date, value, updatedAt) => ({
    id, habitId: H, date, value, createdAt: `${date}T00:00:00Z`, ...(updatedAt ? { updatedAt } : {}),
  });
  const push = (body) => api("POST", "/v1/sync/push", { token, body: {
    habits: [], entries: [], groups: [], deletedHabitIds: [], deletedEntryIds: [], deletedGroupIds: [], ...body,
  } });
  const pull = async (since) => (await api("GET", "/v1/sync/pull", { token, query: since ? { since } : undefined })).json;

  before(async () => {
    const u = createTestUser();
    userId = u.userId;
    token = createTestSession(userId);
    assert.equal((await push({ habits: [habit()] })).status, 200);
  });

  after(() => {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  });

  it("a device coming back online with an older count can't overwrite a newer one", async () => {
    const id = uuid();
    await push({ entries: [entry(id, "2026-09-10", 2, "2026-09-10T09:00:00Z")] });   // iPad, morning
    await push({ entries: [entry(id, "2026-09-10", 8, "2026-09-10T18:00:00Z")] });   // phone, evening
    const stale = await push({ entries: [entry(id, "2026-09-10", 2, "2026-09-10T09:00:00Z")] });  // iPad again
    assert.equal(stale.status, 200);

    const e = (await pull()).entries.find((x) => x.date === "2026-09-10");
    assert.equal(e.value, 8, "the phone's later 8/8 must survive the iPad's stale 2/8");
    assert.equal(e.updatedAt, "2026-09-10T18:00:00Z");
  });

  it("a newer edit from any device still wins", async () => {
    const id = (await pull()).entries.find((x) => x.date === "2026-09-10").id;
    await push({ entries: [entry(id, "2026-09-10", 9, "2026-09-10T19:00:00Z")] });
    assert.equal((await pull()).entries.find((x) => x.date === "2026-09-10").value, 9);
  });

  it("apps before 1.2.3 send no entry updatedAt and keep last-push-wins", async () => {
    const id = (await pull()).entries.find((x) => x.date === "2026-09-10").id;
    await push({ entries: [entry(id, "2026-09-10", 3)] });
    assert.equal((await pull()).entries.find((x) => x.date === "2026-09-10").value, 3);
  });

  it("an edit made offline and pushed later reaches a device that synced in between", async () => {
    const cursor = (await pull()).serverTime;   // device B syncs now
    await sleep(5);
    // Device A renamed the habit and logged a day on Sept 2, offline, and only now pushes.
    const offlineEntry = uuid();
    await push({
      habits: [habit({ name: "Water (renamed offline)", updatedAt: "2026-09-02T00:00:00Z" })],
      entries: [entry(offlineEntry, "2026-09-02", 8, "2026-09-02T21:00:00Z")],
    });

    const inc = await pull(cursor);
    assert.deepEqual(inc.habits.map((h) => h.name), ["Water (renamed offline)"],
      "was []: the habit's feed time was Sept 2, before device B's cursor");
    assert.ok(inc.entries.some((e) => e.id === offlineEntry));
    assert.equal(inc.habits[0].updatedAt, "2026-09-02T00:00:00Z", "apps still receive the edit time, which is what they compare");
  });

  it("re-pushing an unchanged snapshot doesn't put the whole dataset back in the feed", async () => {
    const snapshot = await pull();
    await sleep(5);
    assert.equal((await push({ habits: snapshot.habits, entries: snapshot.entries })).status, 200);

    const inc = await pull(snapshot.serverTime);
    assert.deepEqual(inc.habits, []);
    assert.deepEqual(inc.entries, []);
  });

  it("a device holding a different id for the same day gets the server's id back", async () => {
    const first = uuid(), second = uuid();
    await push({ entries: [entry(first, "2026-09-11", 8, "2026-09-11T20:00:00Z")] });
    const cursor = (await pull()).serverTime;
    await sleep(5);
    // Another device checked in that day too, earlier, under its own id.
    await push({ entries: [entry(second, "2026-09-11", 1, "2026-09-11T08:00:00Z")] });

    const e = (await pull(cursor)).entries.find((x) => x.date === "2026-09-11");
    assert.ok(e, "the row must come back so that device can adopt the server's id");
    assert.equal(e.id, first);
    assert.equal(e.value, 8);
  });

  it("timestamps go out without fractional seconds, so shipped apps can parse them", async () => {
    const made = await api("POST", "/v1/habits", { token, body: { name: "Stamped by the server" } });
    assert.equal(made.status, 201);
    const all = await pull();
    const wholeSeconds = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
    for (const h of all.habits) {
      assert.match(h.createdAt, wholeSeconds);
      assert.match(h.updatedAt, wholeSeconds);
    }
    for (const e of all.entries) {
      assert.match(e.createdAt, wholeSeconds);
      assert.match(e.updatedAt, wholeSeconds);
    }
    assert.ok(all.habits.some((h) => h.id === made.json.habit.id));
  });

  it("a ?since without milliseconds still returns rows written later in that same second", async () => {
    db.prepare("UPDATE habits SET updated_at = '2030-01-01T10:00:00.500Z' WHERE id = ?").run(H);
    const inc = await pull("2030-01-01T10:00:00Z");
    assert.ok(inc.habits.some((h) => h.id === H), "'…00Z' sorts after '…00.500Z' as a string");
  });
});

// ---------------------------------------------------------------------------
// REGRESSION: the magic-link email pointed at a host that does not exist.
//
// FRONTEND_ORIGIN defaulted to https://stride.colorarchive.me, which has no DNS record —
// the only A record is stride-api. /login (which shows the token for copy-paste, and does
// not consume it) is served by THIS process, so a user following a dead link had no way to
// finish signing in: the app asks for a token they can never see. Production sets the
// variable correctly; the default is the trap.
// ---------------------------------------------------------------------------
describe("Magic-link emails point at a host this server actually serves", () => {
  const origins = require("../origins");

  it("the default origin is the API host, not the host with no DNS record", () => {
    assert.equal(origins.DEFAULT_ORIGIN, "https://stride-api.colorarchive.me");
    assert.ok(!origins.DEFAULT_ORIGIN.includes("//stride.colorarchive.me"));
  });

  it("the emailed link is /login on the configured origin, with the token escaped", () => {
    const url = new URL(origins.loginUrl("a b/c?d=e"));
    assert.equal(url.origin, new URL(origins.frontendOrigin).origin);
    assert.equal(url.pathname, "/login");
    assert.equal(url.searchParams.get("token"), "a b/c?d=e");
  });

  it("that path is served by this process, so the link resolves to a real page", async () => {
    const res = await fetch(`${BASE}/login?token=probe-token`);
    assert.equal(res.status, 200);
    assert.match(await res.text(), /probe-token/, "the page shows the token to copy");
  });

  it("CORS and the email link read the same origin, so they cannot drift apart", () => {
    const index = require("node:fs").readFileSync(path.join(__dirname, "..", "index.js"), "utf8");
    const auth = require("node:fs").readFileSync(path.join(__dirname, "..", "routes", "auth.js"), "utf8");
    assert.match(index, /origins\.frontendOrigin/);
    assert.match(auth, /origins\.loginUrl\(/);
    assert.ok(!/stride\.colorarchive\.me/.test(index + auth), "no hardcoded origin left");
  });
});

// ===========================================================================
// M0 — the server half of the incremental-push contract (DEV-PLAN-1.3.md).
//
// From 1.3.1 a device pushes only the rows it changed, in chunks, and treats a row as synced
// once a push response accepts it. Everything below is what that client will rely on, and
// every shipped client (<= 1.2.1 snake_case, 1.2.2/1.2.3 camelCase full snapshots, no
// X-Stride-Client header) must keep getting exactly what it gets today.
// ===========================================================================

const m0 = {
  uuid: () => crypto.randomUUID().toUpperCase(),
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
  V131: "ios/1.3.1(19)",
  V130: "ios/1.3.0(18)",

  /** Like api(), plus an X-Stride-Client header, response headers and another base URL. */
  async req(method, urlPath, { token, body, query, client, base = BASE } = {}) {
    let url = `${base}${urlPath}`;
    if (query) url += `?${new URLSearchParams(query).toString()}`;
    const headers = {};
    if (token) headers["Authorization"] = `Bearer ${token}`;
    if (client) headers["X-Stride-Client"] = client;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const res = await fetch(url, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    const json = await res.json().catch(() => null);
    return { status: res.status, json, headers: res.headers };
  },

  /** A 1.3.1-style push: all six arrays always present, whatever the chunk carries.
   * `client: null` sends no X-Stride-Client header (a shipped app). */
  push(token, body, { client = "ios/1.3.1(19)", base } = {}) {
    return m0.req("POST", "/v1/sync/push", { token, client, base, body: {
      habits: [], entries: [], groups: [], deletedHabitIds: [], deletedEntryIds: [], deletedGroupIds: [], ...body,
    } });
  },

  user() {
    const { userId, email } = createTestUser();
    return { userId, email, token: createTestSession(userId) };
  },

  cleanup(userId) {
    db.prepare("DELETE FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)").run(userId);
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM habit_groups WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sync_snapshot_requests WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
  },

  /** Every row's server change time (`updated_at`), keyed "table:id". */
  clocks(userId) {
    const out = {};
    for (const r of db.prepare("SELECT id, updated_at FROM habits WHERE user_id = ?").all(userId)) out[`h:${r.id}`] = r.updated_at;
    for (const r of db.prepare("SELECT id, updated_at FROM habit_groups WHERE user_id = ?").all(userId)) out[`g:${r.id}`] = r.updated_at;
    for (const r of db.prepare(
      "SELECT id, updated_at FROM habit_entries WHERE habit_id IN (SELECT id FROM habits WHERE user_id = ?)",
    ).all(userId)) out[`e:${r.id}`] = r.updated_at;
    return out;
  },

  habit: (id, over = {}) => ({
    id, name: "Water", emoji: "\u{1F4A7}", colorHex: "#007AFF", isArchived: false, sortOrder: 0,
    reminderEnabled: false, reminderHour: 20, reminderMinute: 0,
    kind: "count", targetValue: 8, scheduleKind: "daily", timesPerWeek: 7, activeDaysMask: 127,
    createdAt: "2026-09-01T00:00:00Z", updatedAt: "2026-09-01T00:00:00Z", ...over,
  }),
  entry: (id, habitId, date, over = {}) => ({
    id, habitId, date, value: 1, createdAt: `${date}T00:00:00Z`, updatedAt: `${date}T12:00:00Z`, ...over,
  }),
  group: (id, over = {}) => ({
    id, name: "Health", colorHex: "#FF9500", sortOrder: 1,
    createdAt: "2026-09-01T00:00:00Z", updatedAt: "2026-09-01T00:00:00Z", ...over,
  }),

  /**
   * The body 1.2.3 sends, built from what that device holds — i.e. what it last pulled.
   *
   * Derived from v1.2.3's SyncService.pushLocal and Shared/SyncModels.swift: synthesized
   * Encodable drops nil optionals (encodeIfPresent), so `note`, `unit` and `groupId` are
   * ABSENT rather than null when unset; all six arrays are always present; timestamps are
   * whole-second ISO8601 (SyncTimestamp.string); an entry's createdAt is its day
   * (`record.date`, midnight UTC) and its updatedAt is `record.updatedAt ?? record.date`; a
   * habit's and a group's updatedAt is `updatedAt ?? createdAt`. No X-Stride-Client header.
   */
  snapshot123(pulled, deletions = {}) {
    const present = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== null && v !== undefined));
    return {
      habits: pulled.habits.map((h) => present({
        id: h.id, name: h.name, emoji: h.emoji, colorHex: h.colorHex, isArchived: h.isArchived,
        sortOrder: h.sortOrder, reminderEnabled: h.reminderEnabled, reminderHour: h.reminderHour,
        reminderMinute: h.reminderMinute, note: h.note, kind: h.kind, targetValue: h.targetValue,
        unit: h.unit, scheduleKind: h.scheduleKind, timesPerWeek: h.timesPerWeek,
        activeDaysMask: h.activeDaysMask, groupId: h.groupId,
        createdAt: h.createdAt, updatedAt: h.updatedAt ?? h.createdAt,
      })),
      entries: pulled.entries.map((e) => present({
        id: e.id, habitId: e.habitId, date: e.date, note: e.note, value: e.value,
        createdAt: `${e.date}T00:00:00Z`, updatedAt: e.updatedAt ?? `${e.date}T00:00:00Z`,
      })),
      groups: (pulled.groups ?? []).map((g) => ({
        id: g.id, name: g.name, colorHex: g.colorHex, sortOrder: g.sortOrder,
        createdAt: g.createdAt, updatedAt: g.updatedAt ?? g.createdAt,
      })),
      deletedHabitIds: deletions.habits ?? [],
      deletedEntryIds: deletions.entries ?? [],
      deletedGroupIds: deletions.groups ?? [],
    };
  },

  /**
   * The two error-body shapes (lib/clientVersion.js errorBody). A shipped app (no or malformed
   * X-Stride-Client) shows `error` verbatim in Settings, so it must get the sentence there and
   * the code in `code`; an app that sends the header gets the code in `error` and the sentence
   * in `message`. `code` is in both, so a client can always match on it.
   */
  assertErrorShape(json, code, client) {
    const legacy = !client || !require("../lib/clientVersion").parseClientHeader(client);
    if (legacy) {
      assert.equal(json.code, code, JSON.stringify(json));
      assert.notEqual(json.error, code, "a shipped app would show the bare code");
      assert.match(json.error, / /, "a sentence, not a code");
      assert.equal(json.message, undefined);
    } else {
      assert.equal(json.error, code, JSON.stringify(json));
      assert.equal(json.code, code);
      assert.equal(typeof json.message, "string");
      assert.match(json.message, / /);
    }
  },

  /** Spawn another server (own env, own in-memory rate-limit store) on the same database. */
  async spawnServer(port, env) {
    const proc = spawn(process.execPath, [path.join(__dirname, "..", "index.js")], {
      env: serverEnv(port, env), stdio: "pipe",
    });
    proc.stderr.on("data", (d) => process.stderr.write(d));
    await waitForServer(undefined, `http://localhost:${port}`);
    return proc;
  },
  async stopServer(proc) {
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) return;
    await new Promise((resolve) => { proc.once("exit", resolve); proc.kill("SIGTERM"); });
  },
};

describe("M0 push response: applied counts and skipped ids", () => {
  let a, b;
  const HB = m0.uuid(), GB = m0.uuid(), EB = m0.uuid();
  before(async () => {
    a = m0.user();
    b = m0.user();
    // User B owns a habit, a group and an entry that A will try to write to.
    const r = await m0.push(b.token, {
      groups: [m0.group(GB, { name: "B's group" })],
      habits: [m0.habit(HB, { name: "B's habit" })],
      entries: [m0.entry(EB, HB, "2026-09-05")],
    });
    assert.equal(r.status, 200);
  });
  after(() => { m0.cleanup(a.userId); m0.cleanup(b.userId); });

  it("a clean push applies every row and skips none", async () => {
    const H1 = m0.uuid(), H2 = m0.uuid(), G1 = m0.uuid();
    const r = await m0.push(a.token, {
      groups: [m0.group(G1)],
      habits: [m0.habit(H1, { groupId: G1 }), m0.habit(H2, { name: "Read" })],
      entries: [m0.entry(m0.uuid(), H1, "2026-09-01"), m0.entry(m0.uuid(), H1, "2026-09-02"), m0.entry(m0.uuid(), H2, "2026-09-02")],
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json, {
      ok: true,
      applied: { habits: 2, entries: 3, groups: 1 },
      skipped: { habits: [], entries: [], groups: [] },
      skippedReasons: { habits: {}, entries: {}, groups: {} },
    });
  });

  it("shipped clients get the same body — they decode only `ok`, the rest is additive", async () => {
    const r = await api("POST", "/v1/sync/push", { token: a.token, body: { habits: [m0.habit(m0.uuid())] } });
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
    assert.deepEqual(r.json.applied, { habits: 1, entries: 0, groups: 0 });
  });

  it("an entry for an unknown habit is 200 with its id in skipped.entries", async () => {
    const H = m0.uuid(), E = m0.uuid(), orphan = m0.uuid();
    const r = await m0.push(a.token, {
      habits: [m0.habit(H)],
      entries: [m0.entry(E, H, "2026-09-03"), m0.entry(orphan, m0.uuid(), "2026-09-03")],
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skipped.entries, [orphan]);
    assert.deepEqual(r.json.skippedReasons.entries, { [orphan]: "unknown_habit" });
    assert.deepEqual(r.json.applied, { habits: 1, entries: 1, groups: 0 });
    assert.equal(db.prepare("SELECT 1 FROM habit_entries WHERE id = ?").get(orphan), undefined);
  });

  it("an entry whose habit exists only in the NEXT chunk is skipped, then applies once the habit lands", async () => {
    const H = m0.uuid(), E = m0.uuid();
    let r = await m0.push(a.token, { entries: [m0.entry(E, H, "2026-09-04")] });
    assert.deepEqual(r.json.skipped.entries, [E]);
    r = await m0.push(a.token, { habits: [m0.habit(H)] });
    r = await m0.push(a.token, { entries: [m0.entry(E, H, "2026-09-04")] });
    assert.deepEqual(r.json.skipped.entries, []);
    assert.equal(r.json.applied.entries, 1);
  });

  it("tombstoned ids — from an earlier push or this one — are skipped", async () => {
    const H = m0.uuid(), Hdead = m0.uuid(), Gdead = m0.uuid(), Edead = m0.uuid(), Hnow = m0.uuid();
    await m0.push(a.token, {
      groups: [m0.group(Gdead)], habits: [m0.habit(H), m0.habit(Hdead)],
      entries: [m0.entry(Edead, H, "2026-09-06")],
    });
    await m0.push(a.token, { deletedHabitIds: [Hdead], deletedEntryIds: [Edead], deletedGroupIds: [Gdead] });

    // A stale device re-sends all three, plus a habit it deletes in the same push.
    const r = await m0.push(a.token, {
      groups: [m0.group(Gdead)],
      habits: [m0.habit(Hdead), m0.habit(Hnow)],
      entries: [m0.entry(Edead, H, "2026-09-06")],
      deletedHabitIds: [Hnow],
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skipped.groups, [Gdead]);
    assert.deepEqual(new Set(r.json.skipped.habits), new Set([Hdead, Hnow]));
    assert.deepEqual(r.json.skipped.entries, [Edead]);
    assert.deepEqual(r.json.applied, { habits: 0, entries: 0, groups: 0 });
    assert.deepEqual(r.json.skippedReasons, {
      habits: { [Hdead]: "tombstoned", [Hnow]: "tombstoned" },
      entries: { [Edead]: "tombstoned" },
      groups: { [Gdead]: "tombstoned" },
    });
  });

  it("skippedReasons tells an entry to drop from one to retry, per case of 'not this account's habit'", async () => {
    const H = m0.uuid(), Hdel = m0.uuid(), Hbad = m0.uuid(), Hlater = m0.uuid();
    await m0.push(a.token, { habits: [m0.habit(H), m0.habit(Hdel)] });
    await m0.push(a.token, { deletedHabitIds: [Hdel] });
    const E = { del: m0.uuid(), theirs: m0.uuid(), bad: m0.uuid(), later: m0.uuid(), missing: m0.uuid() };
    const r = await m0.push(a.token, {
      habits: [m0.habit(Hbad, { name: "" })],
      entries: [
        m0.entry(E.del, Hdel, "2026-09-13"),        // its habit was deleted: drop it
        m0.entry(E.theirs, HB, "2026-09-13"),       // its habit is B's: needs new ids
        m0.entry(E.bad, Hbad, "2026-09-13"),        // its habit was refused in this push: retry
        m0.entry(E.later, Hlater, "2026-09-13"),    // its habit has not landed yet: retry
        { ...m0.entry(E.missing, H, "2026-09-13"), date: undefined },
      ],
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skippedReasons, {
      habits: { [Hbad]: "missing_field" },
      entries: {
        [E.del]: "tombstoned_habit", [E.theirs]: "not_owned_habit", [E.bad]: "skipped_habit",
        [E.later]: "unknown_habit", [E.missing]: "missing_field",
      },
      groups: {},
    });
    assert.deepEqual(r.json.skipped.entries, [E.del, E.theirs, E.bad, E.later, E.missing], "ids stay in push order");
  });

  it("keep-and-merge into another account: every row reads not_owned, never a silent drop", async () => {
    // The reviewers' repro: B pushes, as a 1.3.1 device signed into A, the habit and entries
    // it holds from B's account. Nothing may look like "acknowledge and forget".
    const E2 = m0.uuid();
    const r = await m0.push(a.token, {
      habits: [m0.habit(HB)],
      entries: [m0.entry(EB, HB, "2026-09-05"), m0.entry(E2, HB, "2026-09-06")],
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skippedReasons.habits, { [HB]: "not_owned" });
    assert.deepEqual(r.json.skippedReasons.entries, { [EB]: "not_owned_habit", [E2]: "not_owned_habit" });
  });

  it("a habit or group id that belongs to another account is skipped and left untouched", async () => {
    const before = { ...m0.clocks(b.userId) };
    const r = await m0.push(a.token, {
      groups: [m0.group(GB, { name: "hijacked", updatedAt: "2030-01-01T00:00:00Z" })],
      habits: [m0.habit(HB, { name: "hijacked", updatedAt: "2030-01-01T00:00:00Z" })],
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skipped.habits, [HB]);
    assert.deepEqual(r.json.skipped.groups, [GB]);
    assert.deepEqual(r.json.applied, { habits: 0, entries: 0, groups: 0 });
    assert.equal(db.prepare("SELECT name FROM habits WHERE id = ?").get(HB).name, "B's habit");
    assert.equal(db.prepare("SELECT name FROM habit_groups WHERE id = ?").get(GB).name, "B's group");
    assert.deepEqual(m0.clocks(b.userId), before, "B's rows must not even move in the change feed");
  });

  it("a row SQLite refuses is skipped; the rest of the push still applies (200, not 500)", async () => {
    const H = m0.uuid(), E = m0.uuid(), Enew = m0.uuid();
    await m0.push(a.token, { habits: [m0.habit(H)], entries: [m0.entry(E, H, "2026-09-07")] });

    // The same entry id for a different day: the (habit_id, date) upsert does not cover the
    // primary key, so SQLite raises a constraint error. It used to abort the whole push.
    // And an entry id that is another account's row, the same way.
    const r = await m0.push(a.token, {
      habits: [m0.habit(H, { name: "Renamed", updatedAt: "2026-09-08T00:00:00Z" })],
      entries: [
        m0.entry(E, H, "2026-09-08"),
        m0.entry(EB, H, "2026-09-09"),
        m0.entry(Enew, H, "2026-09-10"),
      ],
    });
    assert.equal(r.status, 200);
    assert.deepEqual(new Set(r.json.skipped.entries), new Set([E, EB]));
    assert.deepEqual(r.json.skippedReasons.entries, { [E]: "row_error", [EB]: "row_error" });
    assert.deepEqual(r.json.applied, { habits: 1, entries: 1, groups: 0 });
    assert.equal(db.prepare("SELECT name FROM habits WHERE id = ?").get(H).name, "Renamed");
    assert.equal(db.prepare("SELECT date FROM habit_entries WHERE id = ?").get(E).date, "2026-09-07");
    assert.ok(db.prepare("SELECT 1 FROM habit_entries WHERE id = ?").get(Enew));
    const theirs = db.prepare("SELECT habit_id, date FROM habit_entries WHERE id = ?").get(EB);
    assert.deepEqual({ ...theirs }, { habit_id: HB, date: "2026-09-05" }, "B's entry is untouched");
  });

  it("a value SQLite cannot bind (an object where a string belongs) is skipped, not a 500", async () => {
    const H = m0.uuid(), bad = m0.uuid();
    const r = await m0.push(a.token, {
      habits: [m0.habit(bad, { note: { nested: true } }), m0.habit(H)],
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skipped.habits, [bad]);
    assert.equal(r.json.applied.habits, 1);
  });

  it("row-error ids reach the log quoted and cut, a few lines per request, never a forged line", async () => {
    const forged = "[2026-09-27T00:00:00.000Z] INFO POST /v1/auth/verify 200 1ms client=ios/9.9(1) FORGED";
    const evil = `EVIL\n${forged}`;
    const logBefore = serverStderr.length;
    const r = await m0.push(a.token, {
      habits: [evil, ...Array.from({ length: 7 }, (_, i) => `BAD-${i}-${"x".repeat(200)}`)]
        .map((id) => m0.habit(id, { note: { nested: true } })),
    });
    assert.equal(r.status, 200);
    assert.equal(r.json.skipped.habits.length, 8);
    assert.equal(r.json.skippedReasons.habits[evil], "row_error");
    let log = "";
    for (let i = 0; i < 50 && !/3 more row\(s\) on row errors/.test(log); i++) {
      await m0.sleep(100);
      log = serverStderr.slice(logBefore);
    }
    assert.match(log, /skipped 3 more row\(s\) on row errors/);
    assert.ok(!log.split("\n").some((line) => line.startsWith(forged)), "the id's newline must not start a line");
    assert.ok(log.includes(JSON.stringify(evil.slice(0, 64))), "the id is logged JSON-quoted, cut at 64");
    const skippedLines = log.split("\n").filter((l) => l.includes("skipped habits"));
    assert.equal(skippedLines.length, 5);
    assert.ok(skippedLines.every((l) => l.length < 400), "ids are cut");
  });

  it("a row with an id but a missing required field is skipped; rows with no id are only counted", async () => {
    const H = m0.uuid(), nameless = m0.uuid(), dateless = m0.uuid();
    await m0.push(a.token, { habits: [m0.habit(H)] });
    const r = await m0.push(a.token, {
      habits: [{ ...m0.habit(nameless), name: "" }, null, { name: "no id" }, "junk"],
      entries: [{ ...m0.entry(dateless, H, "2026-09-11"), date: undefined }, { habitId: H, date: "2026-09-11" }],
      deletedEntryIds: [42, { id: "x" }],
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skipped, { habits: [nameless], entries: [dateless], groups: [] });
    assert.deepEqual(r.json.applied, { habits: 0, entries: 0, groups: 0 });
  });

  it("LWW-older and identical rows count as applied: the server holds a version at least as new", async () => {
    const H = m0.uuid(), E = m0.uuid();
    await m0.push(a.token, {
      habits: [m0.habit(H, { updatedAt: "2026-09-12T00:00:00Z" })],
      entries: [m0.entry(E, H, "2026-09-12", { value: 5, updatedAt: "2026-09-12T18:00:00Z" })],
    });
    const older = await m0.push(a.token, {
      habits: [m0.habit(H, { name: "stale", updatedAt: "2026-09-10T00:00:00Z" })],
      entries: [m0.entry(E, H, "2026-09-12", { value: 2, updatedAt: "2026-09-12T08:00:00Z" })],
    });
    assert.deepEqual(older.json.applied, { habits: 1, entries: 1, groups: 0 });
    assert.deepEqual(older.json.skipped, { habits: [], entries: [], groups: [] });
    assert.equal(db.prepare("SELECT value FROM habit_entries WHERE id = ?").get(E).value, 5, "the newer edit stays");
  });
});

describe("M0 push: an incremental chunk moves only the rows it changes", () => {
  let u;
  const H1 = m0.uuid(), H2 = m0.uuid(), G = m0.uuid(), E1 = m0.uuid(), E2 = m0.uuid(), E3 = m0.uuid();
  before(async () => {
    u = m0.user();
    const r = await m0.push(u.token, {
      groups: [m0.group(G)],
      habits: [m0.habit(H1, { groupId: G }), m0.habit(H2, { name: "Read", kind: "binary", targetValue: 1 })],
      entries: [m0.entry(E1, H1, "2026-09-01", { value: 3 }), m0.entry(E2, H1, "2026-09-02"), m0.entry(E3, H2, "2026-09-02")],
    });
    assert.equal(r.status, 200);
  });
  after(() => m0.cleanup(u.userId));

  it("an entries-only push leaves every other row's updated_at untouched", async () => {
    const before = m0.clocks(u.userId);
    await m0.sleep(5);
    const r = await m0.push(u.token, {
      entries: [m0.entry(E1, H1, "2026-09-01", { value: 6, updatedAt: "2026-09-01T20:00:00Z" })],
    });
    assert.deepEqual(r.json.applied, { habits: 0, entries: 1, groups: 0 });
    const after = m0.clocks(u.userId);
    assert.notEqual(after[`e:${E1}`], before[`e:${E1}`], "the edited entry enters the feed");
    for (const key of Object.keys(before)) {
      if (key !== `e:${E1}`) assert.equal(after[key], before[key], `${key} must not move`);
    }
  });

  it("the identical chunk re-sent changes no updated_at anywhere", async () => {
    const before = m0.clocks(u.userId);
    await m0.sleep(5);
    const r = await m0.push(u.token, {
      entries: [m0.entry(E1, H1, "2026-09-01", { value: 6, updatedAt: "2026-09-01T20:00:00Z" })],
    });
    assert.deepEqual(r.json.applied, { habits: 0, entries: 1, groups: 0 }, "still acknowledged");
    assert.deepEqual(m0.clocks(u.userId), before);
  });
});

describe("M0 mixed fleet: a 1.2.3 full snapshot after a 1.3.1 incremental push bumps nothing", () => {
  let u;
  const H = m0.uuid(), H2 = m0.uuid(), G = m0.uuid(), E = m0.uuid(), E2 = m0.uuid();
  before(async () => {
    u = m0.user();
    // Both devices start from the same state, written by the 1.2.3 phone: habits with no
    // note/unit (omitted keys), one in a group, two check-ins.
    const seed = m0.snapshot123({
      habits: [
        { ...m0.habit(H), note: null, unit: null, groupId: G },
        { ...m0.habit(H2, { name: "Stretch", kind: "binary", targetValue: 1 }), note: "morning", unit: null, groupId: null },
      ],
      entries: [
        { id: E, habitId: H, date: "2026-09-10", value: 3, note: null, updatedAt: "2026-09-10T09:00:00Z" },
        { id: E2, habitId: H2, date: "2026-09-10", value: 1, note: "felt good", updatedAt: null },
      ],
      groups: [m0.group(G)],
    });
    const r = await api("POST", "/v1/sync/push", { token: u.token, body: seed });
    assert.equal(r.status, 200);
  });
  after(() => m0.cleanup(u.userId));

  it("the fixture really is 1.2.3-shaped (omitted optionals, whole seconds, all six arrays)", async () => {
    const pulled = (await api("GET", "/v1/sync/pull", { token: u.token })).json;
    const body = m0.snapshot123(pulled);
    assert.deepEqual(Object.keys(body).sort(),
      ["deletedEntryIds", "deletedGroupIds", "deletedHabitIds", "entries", "groups", "habits"]);
    const h = body.habits.find((x) => x.id === H);
    assert.ok(!("note" in h) && !("unit" in h), "nil optionals are absent, not null");
    assert.equal(h.groupId, G);
    assert.ok(!("note" in body.entries.find((x) => x.id === E)));
    for (const t of [h.createdAt, h.updatedAt, ...body.entries.map((e) => e.updatedAt)]) {
      assert.match(t, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/, "whole-second timestamps");
    }
  });

  it("the 1.2.3 phone pulls the 1.3.1 iPad's edit and pushes its snapshot back: nothing moves", async () => {
    // iPad on 1.3.1 logs a new value: one entry, nothing else.
    const inc = await m0.push(u.token, {
      entries: [{ id: E, habitId: H, date: "2026-09-10", value: 7, createdAt: "2026-09-10T00:00:00Z", updatedAt: "2026-09-10T21:00:00Z" }],
    });
    assert.deepEqual(inc.json.applied, { habits: 0, entries: 1, groups: 0 });

    const clocksAfterIncremental = m0.clocks(u.userId);
    const pulled = (await api("GET", "/v1/sync/pull", { token: u.token })).json;
    const cursor = pulled.serverTime;
    await m0.sleep(5);

    // The phone applies what it pulled and, like every 1.2.3 sync, pushes everything it has.
    const snap = await api("POST", "/v1/sync/push", { token: u.token, body: m0.snapshot123(pulled) });
    assert.equal(snap.status, 200);
    assert.deepEqual(snap.json.applied, { habits: 2, entries: 2, groups: 1 });

    assert.deepEqual(m0.clocks(u.userId), clocksAfterIncremental, "no updated_at may move");
    const feed = (await api("GET", "/v1/sync/pull", { token: u.token, query: { since: cursor } })).json;
    assert.deepEqual([feed.habits.length, feed.entries.length, feed.groups.length], [0, 0, 0],
      "the snapshot must not put the account back into every device's incremental pull");
    assert.equal(db.prepare("SELECT value FROM habit_entries WHERE id = ?").get(E).value, 7);
  });
});

describe("M0 race: a 1.2.3 snapshot and a 1.3.1 incremental push for the same entry", () => {
  let u;
  const H = m0.uuid();
  before(async () => {
    u = m0.user();
    await m0.push(u.token, { habits: [m0.habit(H)] });
  });
  after(() => m0.cleanup(u.userId));

  /** Fire both pushes at once, in the given order, and return the entry the server kept. */
  async function race(date, snapshotEdit, incrementalEdit, snapshotFirst) {
    const E = m0.uuid();
    const snapshot = () => api("POST", "/v1/sync/push", { token: u.token, body: m0.snapshot123({
      habits: [{ ...m0.habit(H), note: null, unit: null, groupId: null }],
      entries: [{ id: E, habitId: H, date, note: null, ...snapshotEdit }],
      groups: [],
    }) });
    const incremental = () => m0.push(u.token, {
      entries: [{ id: E, habitId: H, date, createdAt: `${date}T00:00:00Z`, ...incrementalEdit }],
    });
    const results = await Promise.all(snapshotFirst ? [snapshot(), incremental()] : [incremental(), snapshot()]);
    for (const r of results) assert.equal(r.status, 200);
    const row = db.prepare("SELECT value, client_updated_at FROM habit_entries WHERE habit_id = ? AND date = ?").get(H, date);
    return { value: row.value, editedAt: row.client_updated_at };
  }

  for (const snapshotFirst of [true, false]) {
    const order = snapshotFirst ? "snapshot arrives first" : "incremental arrives first";
    it(`the newer edit wins when it is the 1.3.1 device's (${order})`, async () => {
      const kept = await race(snapshotFirst ? "2026-08-01" : "2026-08-02",
        { value: 2, updatedAt: "2026-08-01T08:00:00Z" },
        { value: 9, updatedAt: "2026-08-01T20:00:00Z" }, snapshotFirst);
      assert.deepEqual(kept, { value: 9, editedAt: "2026-08-01T20:00:00.000Z" });
    });
    it(`the newer edit wins when it is the 1.2.3 device's (${order})`, async () => {
      const kept = await race(snapshotFirst ? "2026-08-03" : "2026-08-04",
        { value: 4, updatedAt: "2026-08-03T22:00:00Z" },
        { value: 1, updatedAt: "2026-08-03T07:00:00Z" }, snapshotFirst);
      assert.deepEqual(kept, { value: 4, editedAt: "2026-08-03T22:00:00.000Z" });
    });
  }
});

describe("M0 pull totals", () => {
  let u, cursor;
  const H1 = m0.uuid(), H2 = m0.uuid(), G = m0.uuid();
  before(async () => {
    u = m0.user();
    cursor = new Date(Date.now() - 1000).toISOString();
  });
  after(() => m0.cleanup(u.userId));

  it("habits in one request, their entries in the next: a full pull returns all of them", async () => {
    let r = await m0.push(u.token, { groups: [m0.group(G)], habits: [m0.habit(H1, { groupId: G }), m0.habit(H2)] });
    assert.deepEqual(r.json.applied, { habits: 2, entries: 0, groups: 1 });
    const entries = [];
    for (let d = 1; d <= 5; d++) entries.push(m0.entry(m0.uuid(), d % 2 ? H1 : H2, `2026-07-0${d}`));
    r = await m0.push(u.token, { entries });
    assert.deepEqual(r.json.applied, { habits: 0, entries: 5, groups: 0 });

    const full = await m0.req("GET", "/v1/sync/pull", { token: u.token, client: m0.V131 });
    assert.equal(full.status, 200);
    assert.equal(full.json.habits.length, 2);
    assert.equal(full.json.entries.length, 5);
    assert.equal(full.json.groups.length, 1);
  });

  it("a full pull's totals equal its arrays' lengths", async () => {
    const { json } = await api("GET", "/v1/sync/pull", { token: u.token });
    assert.deepEqual(json.totals, { habits: json.habits.length, entries: json.entries.length, groups: json.groups.length });
    assert.deepEqual(json.totals, { habits: 2, entries: 5, groups: 1 });
  });

  it("an incremental pull carries the account's totals, not the page's", async () => {
    const serverTime = (await api("GET", "/v1/sync/pull", { token: u.token })).json.serverTime;
    await m0.sleep(5);
    await m0.push(u.token, { entries: [m0.entry(m0.uuid(), H1, "2026-07-09")] });
    const { json } = await api("GET", "/v1/sync/pull", { token: u.token, query: { since: serverTime } });
    assert.equal(json.entries.length, 1);
    assert.equal(json.habits.length, 0);
    assert.deepEqual(json.totals, { habits: 2, entries: 6, groups: 1 });
    assert.ok(cursor < serverTime);
  });

  it("totals count only this account's rows", async () => {
    const other = m0.user();
    try {
      await m0.push(other.token, { habits: [m0.habit(m0.uuid())] });
      const { json } = await api("GET", "/v1/sync/pull", { token: other.token });
      assert.deepEqual(json.totals, { habits: 1, entries: 0, groups: 0 });
    } finally {
      m0.cleanup(other.userId);
    }
  });
});

describe("M0 X-Stride-Client parsing", () => {
  const { parseClientHeader } = require("../lib/clientVersion");

  it("reads platform, version and build", () => {
    assert.deepEqual(parseClientHeader("ios/1.3.1(19)"),
      { platform: "ios", version: "1.3.1", build: 19, parts: [1, 3, 1] });
    assert.deepEqual(parseClientHeader("macos/1.4(22)"),
      { platform: "macos", version: "1.4.0", build: 22, parts: [1, 4, 0] });
  });

  it("anything else is a legacy client", () => {
    for (const h of [undefined, "", "ios/1.3.1", "ios 1.3.1(19)", "Stride/1.3.1(19)", "ios/1.3.1(19) extra",
      "ios/1.3.1-beta(19)", "ios/v1.3.1(19)", "watchos/1.3.1(19)", "IOS/1.3.1(19)", `ios/1.3.1(${"9".repeat(80)})`]) {
      assert.equal(parseClientHeader(h), null, String(h));
    }
  });
});

describe("M0 cursor_expired is gated on the client header", () => {
  let u;
  const daysAgo = (n) => new Date(Date.now() - n * 86400000).toISOString();
  before(() => { u = m0.user(); });
  after(() => m0.cleanup(u.userId));

  const pull = (since, client) =>
    m0.req("GET", "/v1/sync/pull", { token: u.token, client, query: since ? { since } : undefined });

  it("since = 400 days ago from ios/1.3.1(19) → 409 cursor_expired", async () => {
    const r = await pull(daysAgo(400), "ios/1.3.1(19)");
    assert.equal(r.status, 409);
    assert.equal(r.json.error, "cursor_expired");
    assert.equal(r.json.retentionDays, 365);
    assert.equal(typeof r.json.message, "string");
  });

  it("… and from macos/1.3.1(19), and from a later version", async () => {
    assert.equal((await pull(daysAgo(400), "macos/1.3.1(19)")).status, 409);
    assert.equal((await pull(daysAgo(400), "ios/1.4(25)")).status, 409);
  });

  it("… on the legacy /sync mount too", async () => {
    const r = await m0.req("GET", "/sync/pull", { token: u.token, client: m0.V131, query: { since: daysAgo(400) } });
    assert.equal(r.status, 409);
  });

  it("ios/1.3.0(18), no header and a malformed header all get 200 as today", async () => {
    for (const client of ["ios/1.3.0(18)", undefined, "ios/1.3.1", "garbage"]) {
      const r = await pull(daysAgo(400), client);
      assert.equal(r.status, 200, String(client));
      assert.ok(Array.isArray(r.json.habits));
    }
  });

  it("a recent cursor, or none at all, is never refused", async () => {
    assert.equal((await pull(daysAgo(30), m0.V131)).status, 200);
    assert.equal((await pull(undefined, m0.V131)).status, 200);
  });

  it("the edge is retention minus the 10-day grace (355 days)", async () => {
    assert.equal((await pull(daysAgo(354), m0.V131)).status, 200);
    assert.equal((await pull(daysAgo(356), m0.V131)).status, 409);
  });
});

describe("M0 row caps (1.3.1+) and payload validation (everyone)", () => {
  let u;
  before(() => { u = m0.user(); });
  after(() => m0.cleanup(u.userId));

  const ids = (n) => Array.from({ length: n }, () => m0.uuid());
  const orphanEntries = (n) => ids(n).map((id) => ({ id, habitId: "NO-SUCH-HABIT", date: "2026-01-01" }));

  it("a 1.3.1 chunk over a cap is 400 too_many_rows, naming the limits", async () => {
    const cases = [
      { entries: orphanEntries(5001) },
      { habits: ids(501).map((id) => m0.habit(id)) },
      { groups: ids(201).map((id) => m0.group(id)) },
    ];
    for (const body of cases) {
      const r = await m0.push(u.token, body);
      assert.equal(r.status, 400, Object.keys(body)[0]);
      m0.assertErrorShape(r.json, "too_many_rows", m0.V131);
      assert.deepEqual(r.json.limits, { habits: 500, entries: 5000, groups: 200 });
    }
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM habit_groups WHERE user_id = ?").get(u.userId).n, 0,
      "nothing from a refused chunk is written");
  });

  it("deletion lists are not capped: a habit's deletion queues one id per check-in", async () => {
    // SettingsView queues a deletedEntryId for every record of a deleted habit, and M2 sends
    // all deletions in its first chunk; a cap would 400 that chunk forever.
    const r = await m0.push(u.token, { deletedEntryIds: ids(6000), deletedHabitIds: ids(5001), deletedGroupIds: ids(5001) });
    assert.equal(r.status, 200);
    assert.equal(r.json.ok, true);
  });

  it("exactly at the cap is fine", async () => {
    const r = await m0.push(u.token, { entries: orphanEntries(5000) });
    assert.equal(r.status, 200);
    assert.equal(r.json.skipped.entries.length, 5000);
  });

  it("clients that cannot chunk get no caps: no header, and 1.3.0 (still a full snapshot)", async () => {
    for (const client of [null, m0.V130]) {
      const r = await m0.push(u.token, { entries: orphanEntries(5001) }, { client });
      assert.equal(r.status, 200, String(client));
      assert.equal(r.json.ok, true);
    }
  });

  it("a present-but-non-array field is 400 invalid_payload for every client, not a 500", async () => {
    const cases = [{ habits: {} }, { entries: "x" }, { groups: 3 }, { deletedHabitIds: "abc" },
      { deleted_entry_ids: 5 }, { deletedGroupIds: { id: 1 } }];
    for (const body of cases) {
      // A malformed header is a shipped app as far as the body shape goes, too.
      for (const client of [undefined, "ios/1.3.1-beta(19)", m0.V130, m0.V131]) {
        const r = await m0.req("POST", "/v1/sync/push", { token: u.token, client, body });
        assert.equal(r.status, 400, `${JSON.stringify(body)} ${client}`);
        m0.assertErrorShape(r.json, "invalid_payload", client);
      }
    }
  });

  it("a repeated ?since is 400 invalid_payload, not a 500", async () => {
    const res = await fetch(`${BASE}/v1/sync/pull?since=2026-01-01T00:00:00Z&since=2026-02-01T00:00:00Z`, {
      headers: { Authorization: `Bearer ${u.token}` },
    });
    assert.equal(res.status, 400);
    m0.assertErrorShape(await res.json(), "invalid_payload", undefined);
  });
});

describe("M0 snapshot request: per account, one-shot, 1.3.1+ only", () => {
  let u, bystander;
  const script = path.join(__dirname, "..", "ops", "request-snapshot.js");
  const ops = (...args) => runScript(script, args, { env: serverEnv(PORT) });
  const flagged = (userId) => Boolean(db.prepare("SELECT 1 FROM sync_snapshot_requests WHERE user_id = ? AND answered_at IS NULL").get(userId));
  const request = (userId) => db.prepare("SELECT * FROM sync_snapshot_requests WHERE user_id = ?").get(userId);

  before(() => { u = m0.user(); bystander = m0.user(); });
  after(() => { m0.cleanup(u.userId); m0.cleanup(bystander.userId); });

  it("ops/request-snapshot.js sets, lists and clears the request by email", async () => {
    let r = await ops(u.email.toUpperCase(), "support ticket 12");
    assert.equal(r.status, 0, r.stderr);
    assert.ok(flagged(u.userId));
    assert.equal(db.prepare("SELECT note FROM sync_snapshot_requests WHERE user_id = ?").get(u.userId).note, "support ticket 12");
    r = await ops("--list");
    assert.equal(r.status, 0);
    assert.match(r.stdout, new RegExp(u.email.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    r = await ops("--clear", u.email);
    assert.equal(r.status, 0);
    assert.ok(!flagged(u.userId));
    assert.equal((await ops("nobody@stride-test.local")).status, 1, "an unknown email is an error, not a silent no-op");
  });

  it("legacy clients and 1.3.0 are never answered 409 and do not consume the flag", async () => {
    assert.equal((await ops(u.email)).status, 0);
    for (const client of [null, m0.V130]) {
      assert.equal((await m0.push(u.token, {}, { client })).status, 200);
      assert.equal((await m0.req("GET", "/v1/sync/pull", { token: u.token, client })).status, 200);
    }
    assert.ok(flagged(u.userId), "still waiting for a device that can act on it");
  });

  it("the first 1.3.1 request gets 409 snapshot_required, once", async () => {
    const first = await m0.push(u.token, { entries: [] });
    assert.equal(first.status, 409);
    assert.equal(first.json.error, "snapshot_required");
    assert.equal(typeof first.json.message, "string");
    assert.ok(!flagged(u.userId), "consumed");
    assert.equal((await m0.push(u.token, {})).status, 200);
  });

  it("answering keeps a durable record: --list shows when and to which build, and re-running re-arms it", async () => {
    // The 409 can be lost on the way; a deleted row would leave support believing the repair ran.
    const row = request(u.userId);
    assert.ok(row, "the answered request is kept");
    assert.equal(row.answered_client, m0.V131);
    assert.ok(row.answered_at >= row.requested_at);
    const list = await ops("--list");
    assert.match(list.stdout, new RegExp(`answered ${row.answered_at} to ios/1\\.3\\.1\\(19\\)`));

    assert.equal((await ops(u.email, "again")).status, 0);
    assert.ok(flagged(u.userId), "re-armed");
    assert.equal(request(u.userId).answered_client, null);
    assert.equal((await m0.push(u.token, {})).status, 409);
    assert.equal((await m0.push(u.token, {})).status, 200);
  });

  it("a pull consumes it too; other accounts are never affected", async () => {
    assert.equal((await ops(u.email)).status, 0);
    assert.equal((await m0.req("GET", "/v1/sync/pull", { token: bystander.token, client: m0.V131 })).status, 200);
    const r = await m0.req("GET", "/v1/sync/pull", { token: u.token, client: m0.V131 });
    assert.equal(r.status, 409);
    assert.equal(r.json.error, "snapshot_required");
    assert.equal((await m0.req("GET", "/v1/sync/pull", { token: u.token, client: m0.V131 })).status, 200);
  });

  it("sweepStaleData drops requests answered over 90 days ago and keeps pending ones", () => {
    const appDb = require("../db");
    const old = new Date(Date.now() - 91 * 86400000).toISOString();
    db.prepare("UPDATE sync_snapshot_requests SET answered_at = ? WHERE user_id = ?").run(old, u.userId);
    db.prepare("INSERT INTO sync_snapshot_requests (user_id, requested_at) VALUES (?, ?)").run(bystander.userId, old);
    assert.ok(appDb.sweepStaleData().snapshotRequests >= 1);
    assert.equal(request(u.userId), undefined);
    assert.ok(flagged(bystander.userId), "a pending request is never swept");
  });
});

describe("M0 sync pause switch (flag file, read per request)", () => {
  let u;
  before(() => { u = m0.user(); });
  after(() => { fs.rmSync(PAUSE_FILE, { force: true }); m0.cleanup(u.userId); });

  it("flag file on → 503 sync_paused with Retry-After from the file, before auth, on both mounts", async () => {
    fs.writeFileSync(PAUSE_FILE, "120\n");
    for (const [method, p, token, client] of [
      ["GET", "/v1/sync/pull", u.token, undefined], ["POST", "/v1/sync/push", u.token, m0.V131],
      ["GET", "/v1/sync/pull", undefined, m0.V130], ["POST", "/sync/push", undefined, undefined],
    ]) {
      const r = await m0.req(method, p, { token, client, body: method === "POST" ? {} : undefined });
      assert.equal(r.status, 503, `${method} ${p} ${token ? "auth" : "no auth"}`);
      m0.assertErrorShape(r.json, "sync_paused", client);
      assert.equal(r.json.retryAfterSeconds, 120);
      assert.equal(r.headers.get("retry-after"), "120");
    }
    assert.equal((await api("GET", "/health")).status, 200, "only sync is paused");
    assert.equal((await api("GET", "/v1/habits", { token: u.token })).status, 200);
  });

  it("an empty flag file pauses with the default Retry-After (900 s)", async () => {
    fs.writeFileSync(PAUSE_FILE, "");
    const r = await api("GET", "/v1/sync/pull", { token: u.token });
    assert.equal(r.status, 503);
    assert.equal(r.json.retryAfterSeconds, 900);
  });

  it("flag removed → sync answers normally again, no restart", async () => {
    fs.rmSync(PAUSE_FILE, { force: true });
    assert.equal((await api("GET", "/v1/sync/pull", { token: u.token })).status, 200);
    assert.equal((await api("GET", "/v1/sync/pull")).status, 401);
  });

  it("no test run can leave the default flag file in the tree", () => {
    assert.ok(!fs.existsSync(path.join(__dirname, "..", "SYNC_PAUSED")));
  });
});

describe("M0 sync pause switch (environment variable, second server)", () => {
  const PORT2 = 3098, BASE2 = `http://localhost:${PORT2}`;
  let proc, u;
  before(async () => {
    u = m0.user();
    proc = await m0.spawnServer(PORT2, { SYNC_PAUSED: "1", SYNC_PAUSE_RETRY_AFTER_SECONDS: "42" });
  });
  after(async () => { await m0.stopServer(proc); m0.cleanup(u.userId); });

  it("SYNC_PAUSED=1 pauses every sync request, with SYNC_PAUSE_RETRY_AFTER_SECONDS", async () => {
    for (const token of [u.token, undefined]) {
      const r = await m0.req("GET", "/v1/sync/pull", { token, base: BASE2, client: m0.V131 });
      assert.equal(r.status, 503);
      m0.assertErrorShape(r.json, "sync_paused", m0.V131);
      assert.equal(r.json.retryAfterSeconds, 42);
      assert.equal(r.headers.get("retry-after"), "42");
    }
    assert.equal((await m0.req("GET", "/health", { base: BASE2 })).status, 200);
  });
});

describe("M0 rate limits (second server with limits switched on)", () => {
  const PORT2 = 3098, BASE2 = `http://localhost:${PORT2}`;
  let proc, a, b;
  before(async () => {
    a = m0.user();
    b = m0.user();
    // waitForServer's /health probe spends one of the 5 global requests.
    proc = await m0.spawnServer(PORT2, {
      SYNC_RATE_LIMIT_PER_MIN: "3", GLOBAL_RATE_LIMIT_PER_15MIN: "5", SYNC_AUTH_FAILURE_LIMIT_PER_15MIN: "2",
    });
  });
  after(async () => { await m0.stopServer(proc); m0.cleanup(a.userId); m0.cleanup(b.userId); });

  it("the sync limit is per account: A exhausts it, B from the same IP still gets through", async () => {
    for (let i = 0; i < 3; i++) {
      assert.equal((await m0.req("GET", "/v1/sync/pull", { token: a.token, base: BASE2 })).status, 200);
    }
    const limited = await m0.req("GET", "/v1/sync/pull", { token: a.token, base: BASE2 });
    assert.equal(limited.status, 429);
    // A shipped app shows `error` in Settings: it gets the same sentence the old limiter sent.
    m0.assertErrorShape(limited.json, "rate_limited", undefined);
    assert.equal(limited.json.error, "Too many sync requests, please try again later");
    assert.ok(Number.isInteger(limited.json.retryAfterSeconds) && limited.json.retryAfterSeconds > 0);
    assert.ok(Number(limited.headers.get("retry-after")) > 0);
    const limited131 = await m0.req("GET", "/v1/sync/pull", { token: a.token, base: BASE2, client: m0.V131 });
    assert.equal(limited131.status, 429);
    m0.assertErrorShape(limited131.json, "rate_limited", m0.V131);

    assert.equal((await m0.req("POST", "/sync/push", { token: a.token, base: BASE2, body: {} })).status, 429,
      "the legacy mount shares the account's bucket");
    assert.equal((await m0.req("GET", "/v1/sync/pull", { token: b.token, base: BASE2 })).status, 200);
  });

  it("sync requests are exempt from the global per-IP limiter, which still guards everything else", async () => {
    // 7 sync requests above already passed a global limit of 5 (1 spent on /health).
    for (let i = 0; i < 4; i++) {
      const r = await m0.req("GET", "/v1/auth/session", { base: BASE2 });
      assert.notEqual(r.status, 429, `non-sync request ${i + 2} of 5`);
    }
    assert.equal((await m0.req("GET", "/v1/auth/session", { base: BASE2 })).status, 429, "the 6th is over the global limit");
    assert.equal((await m0.req("GET", "/v1/sync/pull", { token: b.token, base: BASE2 })).status, 200,
      "and sync still is not");
  });

  it("sync requests without a valid session are limited per IP; signed-in ones from that IP are not", async () => {
    // Exempt from the global limiter, and never reaching the per-account one, these had no
    // limit at all: token guessing on /v1/sync ran free.
    assert.equal((await m0.req("GET", "/v1/sync/pull", { base: BASE2 })).status, 401);
    assert.equal((await m0.req("POST", "/sync/push", { token: "not-a-token", base: BASE2, body: {} })).status, 401);
    const limited = await m0.req("GET", "/v1/sync/pull", { token: "still-not-a-token", base: BASE2, client: m0.V131 });
    assert.equal(limited.status, 429);
    m0.assertErrorShape(limited.json, "rate_limited", m0.V131);
    assert.ok(Number(limited.headers.get("retry-after")) > 0);
    assert.equal((await m0.req("GET", "/v1/sync/pull", { token: b.token, base: BASE2 })).status, 200,
      "a signed-in device behind the same address is not in that bucket");
  });
});

describe("sweepStaleData never sweeps a tombstone a cursor may still need (data-safety-1 v2)", () => {
  const appDb = require("../db");
  let userId;
  before(() => { userId = createTestUser().userId; });
  after(() => m0.cleanup(userId));

  it("refuses a retention under 365 days unless the caller says belowCursorHorizon, and sweeps nothing", () => {
    const tomb = m0.uuid();
    db.prepare("INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, 'entry', ?, ?)")
      .run(userId, tomb, new Date(Date.now() - 200 * 86400000).toISOString());
    for (const days of [0, 90, 364]) {
      assert.throws(() => appDb.sweepStaleData({ tombstoneRetentionDays: days }), /kept at least 365 days/);
    }
    assert.ok(db.prepare("SELECT 1 FROM deletion_tombstones WHERE entity_id = ?").get(tomb), "nothing swept");
  });

  it("sweeps at 365 days and more: a 400-day-old tombstone goes, a 200-day-old one stays", () => {
    const old = m0.uuid();
    const young = m0.uuid();
    const insert = db.prepare("INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, 'entry', ?, ?)");
    insert.run(userId, old, new Date(Date.now() - 400 * 86400000).toISOString());
    insert.run(userId, young, new Date(Date.now() - 200 * 86400000).toISOString());
    appDb.sweepStaleData({ tombstoneRetentionDays: 365 });
    assert.equal(db.prepare("SELECT 1 FROM deletion_tombstones WHERE entity_id = ?").get(old), undefined, "older than 365 days: swept");
    assert.ok(db.prepare("SELECT 1 FROM deletion_tombstones WHERE entity_id = ?").get(young), "younger: kept");
  });
});

describe("M0 sweepStaleData keeps tombstones unless asked", () => {
  const appDb = require("../db");
  let userId;
  before(() => { userId = createTestUser().userId; });
  after(() => m0.cleanup(userId));

  it("a 400-day-old tombstone survives the default sweep; expired sessions still go", () => {
    const tomb = m0.uuid();
    db.prepare("INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, 'entry', ?, ?)")
      .run(userId, tomb, new Date(Date.now() - 400 * 86400000).toISOString());
    const expired = hashToken(crypto.randomBytes(32).toString("hex"));
    db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)").run(userId, expired, Date.now() - 1000);

    const swept = appDb.sweepStaleData();
    assert.equal(swept.tombstones, 0);
    assert.ok(db.prepare("SELECT 1 FROM deletion_tombstones WHERE entity_id = ?").get(tomb), "tombstone kept");
    assert.equal(db.prepare("SELECT 1 FROM sessions WHERE token_hash = ?").get(expired), undefined, "session swept");
  });
});

describe("M0 request log carries the sync row counts", () => {
  const { formatStats } = require("../logger");
  it("renders counters as key=value, nested objects as a:1,b:2", () => {
    assert.equal(
      formatStats({ user: 7, in: { habits: 0, entries: 3 }, applied: { habits: 0, entries: 2 } }),
      " sync user=7 in=habits:0,entries:3 applied=habits:0,entries:2",
    );
    assert.equal(formatStats(undefined), "");
  });
});

// ---------- M0 (A2): sliding sessions, AASA, usage counters, client in the log ----------

describe("M0 sliding sessions (Bearer)", () => {
  const DAY = 86400000;
  let userId;
  before(() => { userId = createTestUser().userId; });
  after(() => m0.cleanup(userId));

  /** A Bearer session expiring at `expiresAt`, as if it had been created 30 days before that. */
  const session = (expiresAt) => {
    const token = crypto.randomBytes(32).toString("hex");
    db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)").run(userId, hashToken(token), expiresAt);
    return token;
  };
  const expiry = (token) => db.prepare("SELECT expires_at FROM sessions WHERE token_hash = ?").get(hashToken(token))?.expires_at;

  it("day 29 of 30: a request extends the session to ~now + 30 days", async () => {
    const token = session(Date.now() + 1 * DAY);
    const t0 = Date.now();
    assert.equal((await api("GET", "/v1/sync/pull", { token })).status, 200);
    const t1 = Date.now();
    const e = expiry(token);
    assert.ok(e >= t0 + 30 * DAY && e <= t1 + 30 * DAY, `expires_at ${e} not ~now+30d`);
  });

  it("day 31, never used since sign-in: 401, and the session row is deleted", async () => {
    const token = session(Date.now() - 1 * DAY);
    assert.equal((await api("GET", "/v1/sync/pull", { token })).status, 401);
    assert.equal(expiry(token), undefined);
  });

  it("a session extended at day 29 is still valid at day 44 (it would have died at day 30)", async () => {
    const token = session(Date.now() + 1 * DAY);
    assert.equal((await api("GET", "/v1/sync/pull", { token })).status, 200);   // day 29: extended
    // 15 days pass: move the expiry back instead of the clock forward.
    db.prepare("UPDATE sessions SET expires_at = expires_at - ? WHERE token_hash = ?").run(15 * DAY, hashToken(token));
    assert.equal((await api("GET", "/v1/sync/pull", { token })).status, 200);   // day 44
    assert.ok(expiry(token) > Date.now());
  });

  it("a session with more than 15 days left is not written", async () => {
    const fixed = Date.now() + 20 * DAY;
    const token = session(fixed);
    for (let i = 0; i < 3; i++) assert.equal((await api("GET", "/v1/sync/pull", { token })).status, 200);
    assert.equal((await api("GET", "/v1/auth/session", { token })).json.user.id, userId);
    assert.equal(expiry(token), fixed, "expires_at unchanged");
  });
});

describe("M0 apple-app-site-association (universal link for the magic link)", () => {
  const AASA = '{"applinks":{"details":[{"appIDs":["KHMK6Q3L3K.yyh.stride.habittracker"],"components":[{"/":"/login","?":{"token":"*"}}]}]}}';
  const url = `${BASE}/.well-known/apple-app-site-association`;

  it("GET: 200, exactly application/json, exactly the expected body, no redirect", async () => {
    const res = await fetch(url, { redirect: "manual" });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/json");
    assert.equal(await res.text(), AASA);
  });

  it("HEAD (curl -sI): 200 application/json", async () => {
    const res = await fetch(url, { method: "HEAD", redirect: "manual" });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/json");
  });

  it("needs no auth, and a bad Bearer token does not turn it into a 401", async () => {
    const res = await fetch(url, { headers: { Authorization: "Bearer not-a-session" }, redirect: "manual" });
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), JSON.parse(AASA));
  });
});

describe("M0 usage counters (metrics.js, in process)", () => {
  const metrics = require("../metrics");
  const appDb = require("../db");
  const counter = (name) => db.prepare("SELECT COALESCE(SUM(value), 0) AS n FROM usage_counters WHERE name = ?").get(name).n;
  /** Enough of an Express request for metrics.js. */
  const fakeReq = (client, user) => ({ get: (h) => (h.toLowerCase() === "x-stride-client" ? client : undefined), user });
  const run = (mw, req) => new Promise((resolve) => mw(req, {}, resolve));
  let userId;
  const name = `test.${m0.uuid()}`;
  before(() => { userId = createTestUser().userId; metrics.flush(); });
  after(() => {
    db.prepare("DELETE FROM usage_counters WHERE name = ? OR name LIKE 'client.ios/0.0.%(777000)'").run(name);
    m0.cleanup(userId);
  });

  it("flush persists counts and adds to the stored row, never overwrites it", () => {
    metrics.count(name, 3);
    const flushed = metrics.flush();
    assert.equal(flushed.counters[metrics.hourKey()][name], 3);
    assert.equal(counter(name), 3);
    metrics.count(name);
    metrics.count(name);
    metrics.flush();
    assert.equal(counter(name), 5);
    assert.equal(metrics.flush(), null, "nothing left to flush");
  });

  it("client labels: parsed header, 'legacy' when absent or malformed, capped per hour into 'other'", async () => {
    const mw = metrics.countRequests();
    const req = fakeReq("ios/1.3.1(19)");
    assert.equal(metrics.clientLabel(req), "ios/1.3.1(19)");
    assert.equal(metrics.clientLabel(fakeReq(undefined)), "legacy");
    assert.equal(metrics.clientLabel(fakeReq("ios/1.3.1-beta(19)")), "legacy");

    const N = metrics.MAX_CLIENT_LABELS_PER_HOUR + 10;
    for (let i = 0; i < N; i++) await run(mw, fakeReq(`ios/0.0.${i}(777000)`));
    const flushed = metrics.flush();
    let total = 0;
    for (const bucket of Object.values(flushed.counters)) {
      const labels = Object.keys(bucket).filter((k) => k.startsWith("client.") && k !== "client.other");
      assert.ok(labels.length <= metrics.MAX_CLIENT_LABELS_PER_HOUR);
      for (const [k, v] of Object.entries(bucket)) if (k.startsWith("client.")) total += v;
    }
    assert.equal(total, N, "every request counted, under its label or 'other'");
    if (Object.keys(flushed.counters).length === 1) {
      assert.equal(Object.values(flushed.counters)[0]["client.other"], 10);
    }
  });

  it("the cohort: one user_clients row per account and client, first/last seen, legacy included", async () => {
    const user = { id: userId };
    await run(metrics.noteSyncClient, fakeReq("macos/1.3.0(18)", user));
    await run(metrics.noteSyncClient, fakeReq("macos/1.3.0(18)", user));
    await run(metrics.noteSyncClient, fakeReq(undefined, user));
    await run(metrics.noteSyncClient, fakeReq("ios/1.3.1(19)", undefined));   // no account: not recorded
    assert.equal(metrics.flush().userClients, 2);
    const rows = db.prepare("SELECT platform, version, build, first_seen, last_seen FROM user_clients WHERE user_id = ? ORDER BY platform").all(userId);
    assert.deepEqual(rows.map((r) => [r.platform, r.version, r.build]), [["legacy", "", 0], ["macos", "1.3.0", 18]]);
    const before = rows[1];
    assert.ok(before.first_seen <= before.last_seen);

    await run(metrics.noteSyncClient, fakeReq("macos/1.3.0(18)", user));
    metrics.flush();
    const after = db.prepare("SELECT first_seen, last_seen FROM user_clients WHERE user_id = ? AND platform = 'macos'").get(userId);
    assert.equal(after.first_seen, before.first_seen, "first_seen kept");
    assert.ok(after.last_seen >= before.last_seen, "last_seen moved");
  });

  it("one account cannot flood the cohort by varying its build number", async () => {
    const user = { id: userId };
    const dropped = () => db.prepare("SELECT COALESCE(SUM(value), 0) AS n FROM usage_counters WHERE name = 'user_clients_dropped'").get().n;
    const droppedBefore = dropped();
    const rowsBefore = db.prepare("SELECT COUNT(*) AS n FROM user_clients WHERE user_id = ?").get(userId).n;
    const N = metrics.MAX_CLIENTS_PER_ACCOUNT_PER_FLUSH + 6;
    for (let i = 0; i < N; i++) await run(metrics.noteSyncClient, fakeReq(`ios/1.3.1(${900000 + i})`, user));
    // Another account in the same hour is still recorded.
    const other = createTestUser().userId;
    await run(metrics.noteSyncClient, fakeReq("ios/1.3.1(19)", { id: other }));
    assert.equal(metrics.flush().userClients, metrics.MAX_CLIENTS_PER_ACCOUNT_PER_FLUSH + 1);
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM user_clients WHERE user_id = ?").get(userId).n - rowsBefore,
      metrics.MAX_CLIENTS_PER_ACCOUNT_PER_FLUSH);
    assert.equal(dropped() - droppedBefore, 6);
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM user_clients WHERE user_id = ?").get(other).n, 1);
    db.prepare("DELETE FROM user_clients WHERE user_id = ? AND build >= 900000").run(userId);
    m0.cleanup(other);
  });

  it("an account deleted before the flush does not fail it (foreign key), and its rows go with it", async () => {
    const gone = createTestUser().userId;
    await run(metrics.noteSyncClient, fakeReq("ios/1.3.1(19)", { id: gone }));
    metrics.count(name);
    db.prepare("DELETE FROM users WHERE id = ?").run(gone);
    assert.ok(metrics.flush(), "flush succeeded");
    assert.equal(counter(name), 6, "the rest of the flush landed");
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM user_clients WHERE user_id = ?").get(gone).n, 0);

    await run(metrics.noteSyncClient, fakeReq("ios/1.3.1(19)", { id: userId }));
    metrics.flush();
    db.prepare("DELETE FROM users WHERE id = ?").run(userId);
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM user_clients WHERE user_id = ?").get(userId).n, 0, "ON DELETE CASCADE");
  });

  it("sweepStaleData prunes counters and cohort rows older than 400 days, keeps newer ones", () => {
    const keepUser = createTestUser().userId;
    const hourAgo = (days) => new Date(Date.now() - days * 86400000).toISOString().slice(0, 13);
    const iso = (days) => new Date(Date.now() - days * 86400000).toISOString();
    db.prepare("INSERT INTO usage_counters (hour, name, value) VALUES (?, ?, 1), (?, ?, 1)")
      .run(hourAgo(401), name, hourAgo(399), name);
    db.prepare("INSERT INTO user_clients VALUES (?, 'legacy', '', 0, ?, ?), (?, 'ios', '1.3.0', 18, ?, ?)")
      .run(keepUser, iso(500), iso(401), keepUser, iso(500), iso(399));
    const swept = appDb.sweepStaleData();
    assert.ok(swept.usageCounters >= 1 && swept.userClients >= 1);
    assert.deepEqual(db.prepare("SELECT hour FROM usage_counters WHERE name = ? AND hour < ?").all(name, hourAgo(1)).map((r) => r.hour), [hourAgo(399)]);
    assert.deepEqual(db.prepare("SELECT platform FROM user_clients WHERE user_id = ?").all(keepUser).map((r) => r.platform), ["ios"]);
    m0.cleanup(keepUser);
  });
});

describe("M0 usage counters from real requests, flushed on SIGTERM (second server)", () => {
  // A second server because what is under test is the running process: the hooks in the
  // routes, and the flush in shutdown() that keeps a deploy from losing the hour's counts.
  const PORT2 = 3098, BASE2 = `http://localhost:${PORT2}`;
  const BUILD = 100000 + crypto.randomInt(800000);
  const CLIENT = `ios/1.3.1(${BUILD})`;
  const NAMES = [
    "snake_fallback.colorHex", "snake_fallback.sortOrder", "snake_fallback.habitId",
    "snake_fallback.deletedEntryIds", "habit_without_kind",
    "mount./sync", "mount./auth", "mount./habits", "mount./v1/habits", `client.${CLIENT}`,
  ];
  const totals = () => Object.fromEntries(NAMES.map((n) =>
    [n, db.prepare("SELECT COALESCE(SUM(value), 0) AS n FROM usage_counters WHERE name = ?").get(n).n]));
  let proc, u, before0, after0, stdout = "";

  before(async () => {
    u = m0.user();
    before0 = totals();
    proc = await m0.spawnServer(PORT2, {});
    proc.stdout.on("data", (d) => { stdout += d; });
    const HID = m0.uuid();
    // A <= 1.2.1-shaped push: snake_case keys, no header, and a habit with no `kind`.
    const push = await m0.req("POST", "/sync/push", { token: u.token, base: BASE2, body: {
      habits: [{ id: HID, name: "Old app", color_hex: "#FF0000", sort_order: 2 }],
      entries: [{ id: m0.uuid(), habit_id: HID, date: "2026-09-20" }],
      deleted_entry_ids: [],
    } });
    assert.equal(push.status, 200);
    assert.equal(push.json.applied.entries, 1, "snake_case still applies");
    assert.equal((await m0.req("GET", "/auth/session", { token: u.token, base: BASE2 })).status, 200);
    assert.equal((await m0.req("GET", "/habits", { token: u.token, base: BASE2 })).status, 200);
    assert.equal((await m0.req("GET", "/v1/habits", { token: u.token, base: BASE2 })).status, 200);
    for (let i = 0; i < 3; i++) {
      assert.equal((await m0.req("GET", "/v1/sync/pull", { token: u.token, base: BASE2, client: CLIENT })).status, 200);
    }
    await m0.stopServer(proc);
    after0 = totals();
  });
  after(async () => { await m0.stopServer(proc); m0.cleanup(u.userId); });

  it("counts snake_case fallbacks per key, habits without kind, and legacy-mount hits", () => {
    const delta = Object.fromEntries(NAMES.map((n) => [n, after0[n] - before0[n]]));
    assert.deepEqual(delta, {
      "snake_fallback.colorHex": 1, "snake_fallback.sortOrder": 1, "snake_fallback.habitId": 1,
      "snake_fallback.deletedEntryIds": 1, "habit_without_kind": 1,
      "mount./sync": 1, "mount./auth": 1, "mount./habits": 1, "mount./v1/habits": 1,
      [`client.${CLIENT}`]: 3,
    });
  });

  it("records the account's cohort: the legacy app and the 1.3.1 build", () => {
    const rows = db.prepare("SELECT platform, version, build FROM user_clients WHERE user_id = ? ORDER BY platform").all(u.userId);
    assert.deepEqual(rows.map((r) => [r.platform, r.version, r.build]), [["ios", "1.3.1", BUILD], ["legacy", "", 0]]);
  });

  it("logs one parseable [metrics] line on shutdown, and the client on every request line", () => {
    const lines = stdout.split("\n").filter((l) => l.startsWith("[metrics] "));
    assert.equal(lines.length, 1, stdout);
    const flushed = JSON.parse(lines[0].slice("[metrics] ".length));
    const hours = Object.values(flushed.counters);
    assert.equal(hours.reduce((n, b) => n + (b[`client.${CLIENT}`] ?? 0), 0), 3);
    assert.equal(flushed.userClients, 2);
    assert.match(stdout, new RegExp(`GET /v1/sync/pull 200 \\d+ms client=ios/1\\.3\\.1\\(${BUILD}\\) sync user=`));
    assert.match(stdout, /POST \/sync\/push 200 \d+ms client=- sync user=/);
  });

  it("ops/usage-report.js runs against this database and shows the cohort and the counters", async () => {
    const script = path.join(__dirname, "..", "ops", "usage-report.js");
    const r = await runScript(script);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /Active accounts by client/);
    assert.match(r.stdout, /\n {2}ios\/1\.3\.1 +\d+ +\d+ +\d+\n/);
    assert.match(r.stdout, /\n {2}legacy +\d+ +\d+ +\d+\n/);
    assert.match(r.stdout, /legacy or < 1\.3\.1/);
    assert.match(r.stdout, new RegExp(`client\\.ios/1\\.3\\.1\\(${BUILD}\\) +3\\n`));
    assert.equal((await runScript(script, ["--days", "0"])).status, 2);
    assert.equal((await runScript(script, ["--db", path.join(os.tmpdir(), `no-such-${m0.uuid()}.db`)])).status, 1);
  });
});

describe("M0 request log: X-Stride-Client, sanitised", () => {
  const { sanitizeClientHeader } = require("../logger");
  it("passes a well-formed header, '-' when absent, replaces anything else, caps at 40", () => {
    assert.equal(sanitizeClientHeader("ios/1.3.1(19)"), "ios/1.3.1(19)");
    assert.equal(sanitizeClientHeader("macos/1.3.0(18)"), "macos/1.3.0(18)");
    assert.equal(sanitizeClientHeader(undefined), "-");
    assert.equal(sanitizeClientHeader(""), "-");
    assert.equal(sanitizeClientHeader("ios/1.3.1 (19)\n[x] INFO forged"), "ios/1.3.1_(19)__x__INFO_forged");
    assert.equal(sanitizeClientHeader("a".repeat(100)), "a".repeat(40));
    assert.equal(sanitizeClientHeader("é日本"), "___");
  });
});

describe("Push bounds: a number no app can produce is skipped as invalid_value", () => {
  // Every shipped app (<= 1.2.3) traps on `Int(value)` past 9.2e18 or at infinity, and fails the
  // decode of a whole pull on a fractional or huge Int field. The server stored such rows and
  // handed them to every device on the account; routes/sync.js PUSH_BOUNDS stops that.
  let a;
  before(() => { a = m0.user(); });
  after(() => { m0.cleanup(a.userId); });

  const toSnake = (k) => k.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase());
  const snakeRow = (row) => Object.fromEntries(Object.entries(row).map(([k, v]) => [toSnake(k), v]));

  /** POST a body with literal numbers JSON.stringify cannot write (`1e999` parses to Infinity). */
  async function pushRaw(token, body, { client = m0.V131, literals = {} } = {}) {
    let text = JSON.stringify({
      habits: [], entries: [], groups: [], deletedHabitIds: [], deletedEntryIds: [], deletedGroupIds: [], ...body,
    });
    for (const [marker, literal] of Object.entries(literals)) text = text.split(JSON.stringify(marker)).join(literal);
    const headers = { "Authorization": `Bearer ${token}`, "Content-Type": "application/json" };
    if (client) headers["X-Stride-Client"] = client;
    const res = await fetch(`${BASE}/v1/sync/push`, { method: "POST", headers, body: text });
    return { status: res.status, json: await res.json().catch(() => null) };
  }

  const habitColumn = {
    sortOrder: "sort_order", targetValue: "target_value", reminderHour: "reminder_hour",
    reminderMinute: "reminder_minute", timesPerWeek: "times_per_week", activeDaysMask: "active_days_mask",
  };
  // Each field: values an app can write (or a 1.3.0 restore can bring back), then values none can.
  const habitCases = {
    targetValue: { ok: [0, 1, 8, 2.5, 1000, 5000, 1e9, -1, -0.5, -1e9], bad: [1e9 + 1, -1e9 - 1, 1e19, -1e19, "8", true] },
    sortOrder: { ok: [0, 3000, 1790000000, -5, 1e15, -1e15], bad: [2.5, 1e15 + 1, -1e15 - 1, 1e19, "0"] },
    reminderHour: { ok: [0, 20, 23], bad: [-1, 24, 7.5, 1e19, "20"] },
    reminderMinute: { ok: [0, 30, 59], bad: [-1, 60, 0.5, "0"] },
    timesPerWeek: { ok: [1, 3, 7], bad: [0, 8, 3.5, -1, 1e19] },
    activeDaysMask: { ok: [0, 62, 127], bad: [-1, 128, 1.5, 1e19] },
  };

  for (const [key, { ok, bad }] of Object.entries(habitCases)) {
    for (const casing of ["camelCase", "snake_case"]) {
      it(`habit ${key} (${casing}): ${ok.map((v) => JSON.stringify(v)).join(", ")} apply; ${bad.map((v) => JSON.stringify(v)).join(", ")} are invalid_value`, async () => {
        const rows = [...ok, ...bad].map((v) => ({ id: m0.uuid(), v }));
        const habits = rows.map(({ id, v }) => {
          const row = m0.habit(id, { [key]: v });
          return casing === "snake_case" ? snakeRow(row) : row;
        });
        // snake_case is what <= 1.2.1 sends, with no header.
        const r = await m0.push(a.token, { habits }, { client: casing === "snake_case" ? null : m0.V131 });
        assert.equal(r.status, 200);
        assert.equal(r.json.applied.habits, ok.length);
        const badIds = rows.slice(ok.length).map((x) => x.id);
        assert.deepEqual(r.json.skippedReasons.habits,
          Object.fromEntries(badIds.map((id) => [id, "invalid_value"])));
        for (const { id, v } of rows.slice(0, ok.length)) {
          assert.equal(db.prepare(`SELECT ${habitColumn[key]} AS v FROM habits WHERE id = ?`).get(id).v, v, `${key}=${v}`);
        }
        for (const id of badIds) assert.equal(db.prepare("SELECT 1 FROM habits WHERE id = ?").get(id), undefined);
      });
    }
  }

  // Negatives apply: a 1.3.0 restore accepts them (DataBackup.checkAmount, ±1e9), and refusing
  // one made the next full pull delete the restored row on that device.
  it("entry value: within ±1e9 apply (fractions and negatives too); past ±1e9 and non-numbers are invalid_value", async () => {
    const H = m0.uuid();
    await m0.push(a.token, { habits: [m0.habit(H)] });
    const ok = [0, 1, 2.5, 8, 1500, 1e9, -1, -0.5, -1e9];
    const bad = [1e9 + 1, -1e9 - 1, 1e19, -1e19, "1", false];
    const rows = [...ok, ...bad].map((v, i) => ({ id: m0.uuid(), v, date: `2026-08-${String(i + 1).padStart(2, "0")}` }));
    const r = await m0.push(a.token, { entries: rows.map(({ id, v, date }) => m0.entry(id, H, date, { value: v })) });
    assert.equal(r.status, 200);
    assert.equal(r.json.applied.entries, ok.length);
    assert.deepEqual(r.json.skippedReasons.entries,
      Object.fromEntries(rows.slice(ok.length).map(({ id }) => [id, "invalid_value"])));
    for (const { id, v } of rows.slice(0, ok.length)) {
      assert.equal(db.prepare("SELECT value FROM habit_entries WHERE id = ?").get(id).value, v);
    }
  });

  it("group sortOrder: finite within ±1e15, fractions allowed (a Double in the apps), in both casings", async () => {
    const ok = [0, 1, 2.5, -3, 1e15], bad = [1e15 + 1, 1e19, -1e19, "0"];
    const rows = [...ok, ...bad].map((v) => ({ id: m0.uuid(), v }));
    for (const casing of ["camelCase", "snake_case"]) {
      const ids = rows.map(({ id }) => `${id}-${casing}`);
      const groups = rows.map(({ v }, i) => {
        const g = m0.group(ids[i], { sortOrder: v });
        return casing === "snake_case" ? snakeRow(g) : g;
      });
      const r = await m0.push(a.token, { groups }, { client: casing === "snake_case" ? null : m0.V131 });
      assert.equal(r.status, 200);
      assert.equal(r.json.applied.groups, ok.length, casing);
      assert.deepEqual(r.json.skippedReasons.groups,
        Object.fromEntries(ids.slice(ok.length).map((id) => [id, "invalid_value"])), casing);
      rows.slice(0, ok.length).forEach(({ v }, i) => {
        assert.equal(db.prepare("SELECT sort_order AS v FROM habit_groups WHERE id = ?").get(ids[i]).v, v);
      });
    }
  });

  it("1e999 and -1e999 (±Infinity once parsed) are invalid_value for value, targetValue and sortOrder, not a 500", async () => {
    const H = m0.uuid(), Hinf = m0.uuid(), Hneg = m0.uuid(), E = m0.uuid(), Einf = m0.uuid(), Eneg = m0.uuid();
    const r = await pushRaw(a.token, {
      habits: [m0.habit(H), m0.habit(Hinf, { targetValue: "__INF__" }), m0.habit(Hneg, { sortOrder: "__NEGINF__" })],
      entries: [
        m0.entry(E, H, "2026-07-01"),
        m0.entry(Einf, H, "2026-07-02", { value: "__INF__" }),
        m0.entry(Eneg, H, "2026-07-03", { value: "__NEGINF__" }),
      ],
    }, { literals: { __INF__: "1e999", __NEGINF__: "-1e999" } });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.applied, { habits: 1, entries: 1, groups: 0 });
    assert.deepEqual(r.json.skippedReasons, {
      habits: { [Hinf]: "invalid_value", [Hneg]: "invalid_value" },
      entries: { [Einf]: "invalid_value", [Eneg]: "invalid_value" },
      groups: {},
    });
  });

  it("absent and null numbers still take the column defaults (apps before `kind` send no target)", async () => {
    const Habsent = m0.uuid(), Hnull = m0.uuid(), E = m0.uuid();
    const absent = m0.habit(Habsent);
    for (const k of Object.keys(habitColumn)) delete absent[k];
    const r = await m0.push(a.token, {
      habits: [absent, m0.habit(Hnull, Object.fromEntries(Object.keys(habitColumn).map((k) => [k, null])))],
      entries: [{ ...m0.entry(E, Habsent, "2026-07-04"), value: undefined }],
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.applied, { habits: 2, entries: 1, groups: 0 });
    for (const id of [Habsent, Hnull]) {
      const row = db.prepare(`SELECT sort_order, target_value, reminder_hour, reminder_minute, times_per_week,
        active_days_mask FROM habits WHERE id = ?`).get(id);
      assert.deepEqual({ ...row }, {
        sort_order: 0, target_value: 1, reminder_hour: 20, reminder_minute: 0, times_per_week: 7, active_days_mask: 127,
      });
    }
    assert.equal(db.prepare("SELECT value FROM habit_entries WHERE id = ?").get(E).value, 1);
  });

  it("an invalid edit of an existing row leaves the stored row, and the change feed, untouched", async () => {
    const H = m0.uuid(), E = m0.uuid();
    await m0.push(a.token, { habits: [m0.habit(H)], entries: [m0.entry(E, H, "2026-07-05", { value: 3 })] });
    const before = m0.clocks(a.userId);
    const r = await m0.push(a.token, {
      habits: [m0.habit(H, { name: "Renamed", targetValue: 1e19, updatedAt: "2030-01-01T00:00:00Z" })],
      entries: [m0.entry(E, H, "2026-07-05", { value: 1e19, updatedAt: "2030-01-01T00:00:00Z" })],
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skippedReasons.habits, { [H]: "invalid_value" });
    assert.deepEqual(r.json.skippedReasons.entries, { [E]: "invalid_value" });
    const h = db.prepare("SELECT name, target_value FROM habits WHERE id = ?").get(H);
    assert.deepEqual({ ...h }, { name: "Water", target_value: 8 });
    assert.equal(db.prepare("SELECT value FROM habit_entries WHERE id = ?").get(E).value, 3);
    assert.deepEqual(m0.clocks(a.userId), before);
  });

  it("drop reasons win: an invalid entry of a deleted habit reads tombstoned_habit; of a refused new habit, skipped_habit", async () => {
    const Hdel = m0.uuid(), Hbad = m0.uuid(), Edel = m0.uuid(), Ebad = m0.uuid();
    await m0.push(a.token, { habits: [m0.habit(Hdel)] });
    await m0.push(a.token, { deletedHabitIds: [Hdel] });
    const r = await m0.push(a.token, {
      habits: [m0.habit(Hbad, { timesPerWeek: 9 })],
      entries: [m0.entry(Edel, Hdel, "2026-07-06", { value: 1e19 }), m0.entry(Ebad, Hbad, "2026-07-06")],
    });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skippedReasons, {
      habits: { [Hbad]: "invalid_value" },
      entries: { [Edel]: "tombstoned_habit", [Ebad]: "skipped_habit" },
      groups: {},
    });
  });

  it("a legacy full snapshot (no header) with one bad row applies the rest, and the pull never serves the bad one", async () => {
    const b = m0.user();
    try {
      const G = m0.uuid(), H1 = m0.uuid(), H2 = m0.uuid(), Hbad = m0.uuid();
      const entries = [
        m0.entry(m0.uuid(), H1, "2026-09-20", { value: 8 }),
        m0.entry(m0.uuid(), H1, "2026-09-21", { value: 3 }),
        m0.entry(m0.uuid(), H2, "2026-09-21", { value: 1 }),
      ];
      const Ebad = m0.uuid(), EofBad = m0.uuid();
      // What a 1.2.3 phone sends: camelCase, everything, every time — here with one habit and one
      // check-in another client had corrupted before this server refused them.
      const r = await pushRaw(b.token, {
        groups: [m0.group(G)],
        habits: [
          m0.habit(H1, { sortOrder: 1790000000, groupId: G }),
          m0.habit(H2, { name: "Read", kind: "binary", targetValue: 1, sortOrder: 1790000001, scheduleKind: "timesPerWeek", timesPerWeek: 3 }),
          m0.habit(Hbad, { name: "Broken", targetValue: 1e19 }),
        ],
        entries: [...entries, m0.entry(Ebad, H1, "2026-09-22", { value: "__INF__" }), m0.entry(EofBad, Hbad, "2026-09-22")],
      }, { client: null, literals: { __INF__: "1e999" } });
      assert.equal(r.status, 200);
      assert.equal(r.json.ok, true);
      assert.deepEqual(r.json.applied, { habits: 2, entries: 3, groups: 1 });
      assert.deepEqual(r.json.skippedReasons, {
        habits: { [Hbad]: "invalid_value" },
        entries: { [Ebad]: "invalid_value", [EofBad]: "skipped_habit" },
        groups: {},
      });

      const pull = await m0.req("GET", "/v1/sync/pull", { token: b.token });
      assert.equal(pull.status, 200);
      assert.deepEqual(pull.json.habits.map((h) => h.id).sort(), [H1, H2].sort());
      assert.deepEqual(pull.json.entries.map((e) => e.value).sort((x, y) => x - y), [1, 3, 8]);
      for (const h of pull.json.habits) {
        assert.ok(Number.isInteger(h.sortOrder) && Number.isFinite(h.targetValue), JSON.stringify(h));
      }

      // The next snapshot — the same rows again, as 1.2.3 does on every sync — changes nothing.
      const clocks = m0.clocks(b.userId);
      const again = await pushRaw(b.token, {
        groups: [m0.group(G)],
        habits: [
          m0.habit(H1, { sortOrder: 1790000000, groupId: G }),
          m0.habit(H2, { name: "Read", kind: "binary", targetValue: 1, sortOrder: 1790000001, scheduleKind: "timesPerWeek", timesPerWeek: 3 }),
          m0.habit(Hbad, { name: "Broken", targetValue: 1e19 }),
        ],
        entries,
      }, { client: null });
      assert.equal(again.status, 200);
      assert.deepEqual(m0.clocks(b.userId), clocks);
    } finally {
      m0.cleanup(b.userId);
    }
  });
});

// ----------------------------------------------------------------
// Sentry: what may leave the process (lib/sentryScrub.js, index.js, routes/auth.js)
// ----------------------------------------------------------------

describe("Sentry scrubber: realistic @sentry/node 8.x events lose every secret", () => {
  const scrub = require("../lib/sentryScrub");
  const TOKEN = crypto.randomBytes(32).toString("hex");
  const EMAIL = "jason.private+stride@example.com";
  const IP = "203.0.113.77";
  const HABIT = "Therapy session — do not share";
  const NOTE = "private note about medication";
  /** The strings none of which may appear anywhere in what is sent. */
  const SECRETS = [TOKEN, EMAIL, IP, HABIT, NOTE, "stride_session=", "demo-review-token-2026"];
  const assertClean = (out) => {
    const text = JSON.stringify(out);
    for (const s of SECRETS) assert.ok(!text.includes(s), `leaked ${s}: ${text}`);
    assert.ok(!/Bearer\s+(?!\[Filtered\])/.test(text), `leaked a bearer credential: ${text}`);
  };

  /** A thrown error inside POST /v1/sync/push, as 8.x assembles it (RequestData from the
   * isolation scope's normalizedRequest, user from req.user, console breadcrumbs). */
  function pushErrorEvent() {
    const body = {
      habits: [{ id: "A1", name: HABIT, note: NOTE, kind: "binary" }],
      entries: [], groups: [], deletedHabitIds: [], deletedEntryIds: [], deletedGroupIds: [],
    };
    return {
      event_id: "0123456789abcdef0123456789abcdef",
      level: "error", platform: "node", environment: "production", server_name: "stride-vm",
      transaction: "POST /v1/sync/push",
      exception: { values: [{
        type: "SqliteError",
        value: `FOREIGN KEY constraint failed (session ${TOKEN}, account ${EMAIL})`,
        mechanism: { type: "generic", handled: true, data: { sessionToken: TOKEN } },
        stacktrace: { frames: [{
          filename: "/root/stride-server/routes/sync.js", function: "applyPush", lineno: 412,
          vars: { body, token: TOKEN, user: { id: 42, email: EMAIL } },
        }] },
      }] },
      request: {
        method: "POST",
        url: `https://stride-api.colorarchive.me/v1/sync/push?since=2026-09-01T00:00:00Z&token=${TOKEN}`,
        query_string: `since=2026-09-01T00:00:00Z&token=${TOKEN}`,
        headers: {
          host: "stride-api.colorarchive.me",
          authorization: `Bearer ${TOKEN}`,
          cookie: `stride_session=${TOKEN}`,
          "x-forwarded-for": IP, "x-real-ip": IP,
          "content-type": "application/json", "content-length": "412",
          "user-agent": "Stride/19 CFNetwork/3826 Darwin/25.0.0",
          "x-stride-client": "ios/1.3.1(19)",
        },
        cookies: { stride_session: TOKEN },
        data: JSON.stringify(body),
        env: { REMOTE_ADDR: IP },
      },
      user: { id: 42, email: EMAIL, ip_address: IP, username: EMAIL },
      contexts: {
        trace: {
          trace_id: "0123456789abcdef0123456789abcdef", span_id: "0123456789abcdef",
          data: { "http.target": `/v1/sync/push?token=${TOKEN}`, "url.query": `token=${TOKEN}`,
            "url.full": `https://stride-api.colorarchive.me/v1/sync/push?token=${TOKEN}` },
        },
        runtime: { name: "node", version: "v22.12.0" },
      },
      extra: { sessionToken: TOKEN, detail: `pushed by ${EMAIL}`, nested: { Authorization: `Bearer ${TOKEN}` } },
      tags: { area: "sync" },
      breadcrumbs: [
        { category: "console", level: "log",
          message: `[2026-09-28T01:00:00.000Z] INFO GET /login?token=${TOKEN} 200 3ms client=-`,
          data: { arguments: [`[2026-09-28T01:00:00.000Z] INFO GET /login?token=${TOKEN} 200 3ms client=-`], logger: "console" } },
        { category: "http", type: "http",
          data: { url: `https://api.resend.com/emails?to=${EMAIL}`, method: "POST", status_code: 422, "http.query": `to=${EMAIL}` } },
      ],
    };
  }

  it("a thrown error inside /v1/sync/push: no header, cookie, body, query, email, IP or token survives", () => {
    const out = scrub.scrubEvent(pushErrorEvent());
    assertClean(out);
    // What is kept is what debugging needs.
    assert.deepEqual(out.request, {
      method: "POST",
      url: "https://stride-api.colorarchive.me/v1/sync/push",
      headers: {
        "content-type": "application/json", "content-length": "412",
        "user-agent": "Stride/19 CFNetwork/3826 Darwin/25.0.0", "x-stride-client": "ios/1.3.1(19)",
      },
    });
    assert.deepEqual(out.user, { id: 42 });
    assert.equal(out.exception.values[0].type, "SqliteError");
    assert.match(out.exception.values[0].value, /^FOREIGN KEY constraint failed/);
    assert.equal(out.contexts.trace.trace_id, "0123456789abcdef0123456789abcdef", "32-hex trace ids are not tokens");
    assert.equal(out.tags.area, "sync");
    assert.equal(out.transaction, "POST /v1/sync/push");
    // The console line is gone entirely (it could be any account's — see the module comment);
    // the outgoing http breadcrumb stays, path only.
    assert.deepEqual(out.breadcrumbs.map((b) => b.category), ["http"]);
    assert.equal(out.breadcrumbs[0].data.url, "https://api.resend.com/emails");
    assert.equal(out.breadcrumbs[0].data.status_code, 422);
  });

  it("an /v1/auth/verify error: the token in the body (hex or a demo token) is dropped with the body", () => {
    for (const token of [TOKEN, "demo-review-token-2026"]) {
      const out = scrub.scrubEvent({
        level: "error",
        exception: { values: [{ type: "TypeError", value: "Cannot read properties of undefined (reading 'id')" }] },
        request: {
          method: "POST", url: "https://stride-api.colorarchive.me/v1/auth/verify",
          headers: { "content-type": "application/json", "x-forwarded-for": IP },
          data: { token }, query_string: "",
        },
      });
      assertClean(out);
      assert.deepEqual(out.request, {
        method: "POST", url: "https://stride-api.colorarchive.me/v1/auth/verify",
        headers: { "content-type": "application/json" },
      });
    }
  });

  it("a request-link failure: the address is gone from the body and from the provider's message", () => {
    const out = scrub.scrubEvent({
      level: "error",
      tags: { area: "magic-link" },
      exception: { values: [{ type: "Error", value: `Resend: The gmail.com domain is not verified (to: ${EMAIL}, link https://stride-api.colorarchive.me/login?token=${TOKEN})` }] },
      request: { method: "POST", url: "https://stride-api.colorarchive.me/v1/auth/request-link", data: `{"email":"${EMAIL}"}` },
    });
    assertClean(out);
    assert.equal(out.tags.area, "magic-link");
    assert.match(out.exception.values[0].value, /domain is not verified \(to: \[Filtered\], link https:\/\/stride-api\.colorarchive\.me\/login\?\[Filtered\]\)/);
  });

  it("beforeBreadcrumb: a URL carrying ?token= keeps only its path; a log line keeps only the path", () => {
    const http = scrub.scrubBreadcrumb({
      type: "http", category: "http",
      data: { url: `https://stride-api.colorarchive.me/login?token=${TOKEN}`, method: "GET", status_code: 200, "http.query": `token=${TOKEN}` },
    });
    assertClean(http);
    assert.equal(http.data.url, "https://stride-api.colorarchive.me/login");
    assert.equal(http.data.method, "GET");

    const log = scrub.scrubBreadcrumb({ category: "console", message: `request-link error: sending to ${EMAIL} Authorization: Bearer ${TOKEN}`, data: { arguments: [EMAIL] } });
    assertClean(log);
    assert.equal(log.message, "request-link error: sending to [Filtered] Authorization: Bearer [Filtered]");

    // …but the hook Sentry.init gets drops console lines outright: with no per-request scope
    // (index.js initializes after express) they are the whole process's log, other accounts'
    // `sync user=<id>` lines included. Reproduced 2026-09-28 against a fake ingest.
    const opts = scrub.sentryInitOptions({ SENTRY_DSN: "http://k@127.0.0.1:1/1", NODE_ENV: "production" });
    assert.equal(opts.beforeBreadcrumb({ category: "console", level: "log", message: "sync user=41 pull 200" }), null);
    assert.equal(opts.beforeBreadcrumb(http).data.url, "https://stride-api.colorarchive.me/login", "other breadcrumbs are kept");
  });

  it("routeTag: a 5xx is tagged with the route pattern — mount included, no id, no query", () => {
    // What index.js's error handler sees: req.route.path is the router's own pattern and
    // req.baseUrl is already "" (checked against express 4 on 2026-09-28).
    assert.equal(scrub.routeTag("PUT", "/v1/habits/8F2C-A1?x=1", "/:id"), "PUT /v1/habits/:id");
    assert.equal(scrub.routeTag("DELETE", "/habits/8F2C/entries/2026-09-01", "/:id/entries/:date"), "DELETE /habits/:id/entries/:date");
    assert.equal(scrub.routeTag("POST", "/v1/sync/push", "/push"), "POST /v1/sync/push");
    assert.equal(scrub.routeTag("GET", "/v1/habits/", "/"), "GET /v1/habits");
    assert.equal(scrub.routeTag("GET", `/login?token=${TOKEN}`, "/login"), "GET /login");
    assert.equal(scrub.routeTag("GET", `/nowhere/${TOKEN}?token=${TOKEN}`, undefined), "GET /nowhere/[Filtered]", "no route: the path, scrubbed");
  });

  it("an email address is redacted in any shape /auth/request-link accepts, not only ASCII", () => {
    // routes/auth.js accepts /^[^\s@]+@[^\s@]+\.[^\s@]+$/, so these are all addresses the
    // server would mail and a provider error could quote. The old ASCII-only pattern let the
    // first three through and left `o'` of the fourth (2026-09-28 review).
    const accepted = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    for (const address of ["josé@example.com", "user@bücher.de", "josé@bücher.de", "o'brien@example.com",
      '"quoted"@example.com', "用户@例子.中国", EMAIL]) {
      assert.ok(accepted.test(address), `request-link accepts ${address}`);
      const out = scrub.scrubString(`Resend validation_error: cannot send to ${address}, giving up`);
      assert.equal(out.includes("@"), false, `${address} -> ${out}`);
      for (const part of address.split("@")) assert.equal(out.includes(part.replace(/^["']|["']$/g, "")), false, `${address} -> ${out}`);
      assert.match(out, /^Resend validation_error: cannot send to \S*\[Filtered\], giving up$/, "the surrounding text survives");
    }
    assert.equal(scrub.scrubString("(to: o'brien@example.com)"), "(to: [Filtered])");
  });

  it("beforeSendTransaction: span descriptions and attributes lose query strings", () => {
    const out = scrub.scrubEvent({
      type: "transaction", transaction: "GET /login",
      contexts: { trace: { trace_id: "0123456789abcdef0123456789abcdef", data: { "http.target": `/login?token=${TOKEN}` } } },
      spans: [{ description: `GET https://api.resend.com/emails?to=${EMAIL}`, data: { "url.full": `https://x.test/login?token=${TOKEN}`, "http.query": `token=${TOKEN}` } }],
      request: { method: "GET", url: `https://stride-api.colorarchive.me/login?token=${TOKEN}` },
    });
    assertClean(out);
    assert.equal(out.spans[0].description, "GET https://api.resend.com/emails");
    assert.equal(out.request.url, "https://stride-api.colorarchive.me/login");
  });

  it("init options: tracing off unless SENTRY_TRACES_SAMPLE_RATE is a real rate, sendDefaultPii off, all three hooks set", () => {
    assert.equal(scrub.tracesSampleRate(undefined), 0);
    assert.equal(scrub.tracesSampleRate(""), 0);
    assert.equal(scrub.tracesSampleRate("abc"), 0, "never NaN");
    assert.equal(scrub.tracesSampleRate("2"), 0, "out of range");
    assert.equal(scrub.tracesSampleRate("0.05"), 0.05, "the override still works");
    const opts = scrub.sentryInitOptions({ SENTRY_DSN: "http://k@127.0.0.1:1/1", NODE_ENV: "production" });
    assert.equal(opts.tracesSampleRate, 0);
    assert.equal(opts.sendDefaultPii, false);
    for (const hook of ["beforeSend", "beforeSendTransaction", "beforeBreadcrumb"]) assert.equal(typeof opts[hook], "function", hook);
    assert.deepEqual(opts.integrations.map((i) => i.name), ["RequestData"]);
    assertClean(opts.beforeSend(pushErrorEvent()));
  });
});

describe("Sentry end to end: a real magic-link failure reaches a (local, fake) Sentry scrubbed and tagged", () => {
  // A second server with SENTRY_DSN pointing at a listener in this process, so the event goes
  // through the SDK's whole pipeline (integrations, scopes, beforeSend, the transport) and what
  // is asserted on is the envelope that would have left the machine. No external service.
  const http = require("node:http");
  const zlib = require("node:zlib");
  const PORT2 = 3098, BASE2 = `http://localhost:${PORT2}`;
  const TOKEN = crypto.randomBytes(32).toString("hex");
  const EMAIL = `e2e-${crypto.randomUUID()}@stride-test.local`;
  const IP = "198.51.100.23";
  const envelopes = [];
  let ingest, proc;

  before(async () => {
    ingest = http.createServer((req, res) => {
      const chunks = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", () => {
        let buf = Buffer.concat(chunks);
        if (req.headers["content-encoding"] === "gzip") buf = zlib.gunzipSync(buf);
        envelopes.push({ url: req.url, text: buf.toString("utf8") });
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end("{}");
      });
    });
    await new Promise((resolve) => ingest.listen(0, "127.0.0.1", resolve));
    const dsn = `http://publickey@127.0.0.1:${ingest.address().port}/1`;
    // RESEND_API_KEY stays empty (serverEnv), so sending the mail throws: the path under test.
    proc = await m0.spawnServer(PORT2, { SENTRY_DSN: dsn });
  });
  after(async () => {
    await m0.stopServer(proc);
    await new Promise((resolve) => ingest.close(resolve));
    const u = db.prepare("SELECT id FROM users WHERE email = ?").get(EMAIL);
    if (u) m0.cleanup(u.id);
  });

  it("request-link still answers 500, and exactly one error event arrives, area=magic-link, with no address, token or IP", async () => {
    // An unrelated request first. Its request-log line must not ride along on the magic-link
    // event: with Sentry.init after express there is no per-request scope, and console
    // breadcrumbs used to carry the whole process's recent log (2026-09-28 review).
    const MARKER = `unrelated-${crypto.randomUUID()}`;
    assert.equal((await fetch(`${BASE2}/${MARKER}`)).status, 404);
    const res = await fetch(`${BASE2}/v1/auth/request-link?token=${TOKEN}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json", Authorization: `Bearer ${TOKEN}`,
        Cookie: `stride_session=${TOKEN}`, "X-Forwarded-For": IP, "X-Stride-Client": "ios/1.3.1(19)",
      },
      body: JSON.stringify({ email: EMAIL }),
    });
    assert.equal(res.status, 500);
    assert.deepEqual(await res.json(), { error: "Failed to send login link" });

    const isEvent = (e) => e.text.split("\n").some((l) => /^\{"type":"event"/.test(l));
    const deadline = Date.now() + 15000;
    while (!envelopes.some(isEvent) && Date.now() < deadline) await m0.sleep(100);
    const events = envelopes.filter(isEvent);
    assert.equal(events.length, 1, `envelopes: ${envelopes.map((e) => e.text.slice(0, 200)).join("\n---\n")}`);

    const lines = events[0].text.split("\n").filter(Boolean);
    const event = JSON.parse(lines[lines.findIndex((l) => /^\{"type":"event"/.test(l)) + 1]);
    assert.equal(event.tags.area, "magic-link");
    assert.equal(event.level, "error");
    assert.ok(event.exception.values.some((v) => /Missing API key/.test(v.value)), JSON.stringify(event.exception));
    // What DEPLOY.md says an event carries: no request block and no user (no per-request
    // scope — if Sentry.init ever moves above require("express") these appear, and the
    // scrubber's allowlist, DEPLOY.md and this test all need revisiting), no console line.
    assert.equal(event.request, undefined, JSON.stringify(event.request));
    assert.equal(event.user, undefined, JSON.stringify(event.user));
    assert.deepEqual((event.breadcrumbs || []).filter((b) => b.category === "console"), []);
    for (const e of envelopes) {
      // (Not "request-link error" itself: ContextLines ships the source around each frame,
      // and that line of routes/auth.js is in it. The console filter above covers the log.)
      for (const s of [EMAIL, TOKEN, IP, "stride_session", MARKER]) {
        assert.ok(!e.text.includes(s), `envelope leaked ${s}: ${e.text}`);
      }
    }
  });

  it("a 400 (invalid email) is not reported", async () => {
    const before = envelopes.length;
    const r = await m0.req("POST", "/v1/auth/request-link", { base: BASE2, body: { email: "not-an-address" } });
    assert.equal(r.status, 400);
    await m0.sleep(1500);
    assert.equal(envelopes.slice(before).filter((e) => e.text.includes('"type":"event"')).length, 0);
  });
});

describe("/health reads the real tables (lib/health.js)", () => {
  const { checkDatabase } = require("../lib/health");
  const SCHEMA = [
    "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)",
    "CREATE TABLE sessions (id INTEGER PRIMARY KEY, user_id INTEGER)",
    "CREATE TABLE habits (id TEXT PRIMARY KEY, user_id INTEGER)",
    "CREATE TABLE habit_entries (id TEXT PRIMARY KEY, habit_id TEXT)",
  ];

  it("passes on the schema, empty or not", () => {
    const mem = new Database(":memory:");
    for (const s of SCHEMA) mem.exec(s);
    assert.doesNotThrow(() => checkDatabase(mem), "a fresh install has no rows and is healthy");
    mem.prepare("INSERT INTO users (email) VALUES ('a@b.c')").run();
    assert.doesNotThrow(() => checkDatabase(mem));
    mem.close();
  });

  it("fails on a database that answers SELECT 1 but lacks a table — what the old check called healthy", () => {
    for (const missing of ["users", "sessions", "habits", "habit_entries"]) {
      const mem = new Database(":memory:");
      for (const s of SCHEMA) if (!s.startsWith(`CREATE TABLE ${missing} `)) mem.exec(s);
      assert.doesNotThrow(() => mem.prepare("SELECT 1").get(), "the old check passes");
      assert.throws(() => checkDatabase(mem), new RegExp(`no such table: ${missing}`));
      mem.close();
    }
  });

  it("fails on a closed connection", () => {
    const mem = new Database(":memory:");
    for (const s of SCHEMA) mem.exec(s);
    mem.close();
    assert.throws(() => checkDatabase(mem));
  });

  it("stays O(1): each table is read with a LIMIT 1 scan, no sort, no full-table aggregate", () => {
    const mem = new Database(":memory:");
    for (const s of SCHEMA) mem.exec(s);
    const { HEALTH_QUERY } = require("../lib/health");
    const plan = mem.prepare(`EXPLAIN QUERY PLAN ${HEALTH_QUERY}`).all().map((r) => r.detail).join("\n");
    assert.doesNotMatch(plan, /TEMP B-TREE|ORDER BY/i, plan);
    assert.doesNotMatch(HEALTH_QUERY, /COUNT\(|ORDER BY/i);
    mem.close();
  });

  it("the running server still answers the shape the tests and rehearsal expect", async () => {
    const { status, json } = await api("GET", "/health");
    assert.equal(status, 200);
    assert.deepEqual(Object.keys(json).sort(), ["apiVersions", "ok", "uptime", "version"]);
    assert.equal(json.ok, true);
  });
});

describe("metrics flush after POST /v1/auth/delete-account in the same hour (second server)", () => {
  // The real sequence: an account syncs (noteSyncClient queues its user_clients row), deletes
  // itself through the API (the users row and its user_clients cascade away), and the next
  // flush — here the one in shutdown() — runs with that row still queued. Before the WHERE
  // EXISTS in metrics.js it hit the foreign key, the whole flush rolled back, and the counts
  // were kept for a next flush that would fail the same way.
  const PORT2 = 3098, BASE2 = `http://localhost:${PORT2}`;
  const BUILD = 100000 + crypto.randomInt(800000);
  const CLIENT = `ios/1.3.1(${BUILD})`;
  const count = (name) => db.prepare("SELECT COALESCE(SUM(value), 0) AS n FROM usage_counters WHERE name = ?").get(name).n;
  let proc, u, stdout = "", stderr = "", before0;

  before(async () => {
    u = m0.user();
    before0 = count(`client.${CLIENT}`);
    proc = await m0.spawnServer(PORT2, {});
    proc.stdout.on("data", (d) => { stdout += d; });
    proc.stderr.on("data", (d) => { stderr += d; });
    assert.equal((await m0.req("GET", "/v1/sync/pull", { token: u.token, base: BASE2, client: CLIENT })).status, 200);
    assert.equal((await m0.req("POST", "/v1/auth/delete-account", { token: u.token, base: BASE2, client: CLIENT })).status, 200);
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM users WHERE id = ?").get(u.userId).n, 0, "account gone");
    await m0.stopServer(proc);
  });
  after(async () => { await m0.stopServer(proc); m0.cleanup(u.userId); });

  it("the flush succeeds: the counters land, the deleted account's cohort row is skipped", () => {
    assert.doesNotMatch(stderr, /flush failed/);
    assert.equal(count(`client.${CLIENT}`) - before0, 2, "the pull and the delete-account request");
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM user_clients WHERE user_id = ?").get(u.userId).n, 0);
    const lines = stdout.split("\n").filter((l) => l.startsWith("[metrics] "));
    assert.equal(lines.length, 1, stdout);
    assert.equal(JSON.parse(lines[0].slice("[metrics] ".length)).userClients, 0, "counts rows written, not rows queued");
  });
});

describe("Magic link: a failed Resend send is a 500, not {ok:true} (email.js)", () => {
  // resend 3.x returns { data: null, error } instead of throwing, and this result was ignored:
  // a revoked key, an unverified domain or a Resend outage answered {ok:true} for mail that was
  // never sent — silently, on the only way to sign in. A fake Resend on RESEND_BASE_URL (read by
  // the SDK itself) drives the real SDK path; nothing leaves this process.
  const http = require("node:http");
  const PORT2 = 3098;
  const EMAIL = `resend-${crypto.randomUUID()}@stride-test.local`;
  let fake, proc, reply = { status: 200, body: { id: "fake-email-id" } };
  let stderr = "";

  before(async () => {
    fake = http.createServer((req, res) => {
      req.resume();
      req.on("end", () => {
        res.writeHead(reply.status, { "Content-Type": "application/json" });
        res.end(JSON.stringify(reply.body));
      });
    });
    await new Promise((resolve) => fake.listen(0, "127.0.0.1", resolve));
    proc = await m0.spawnServer(PORT2, {
      RESEND_API_KEY: "re_test_not_a_real_key",
      RESEND_BASE_URL: `http://127.0.0.1:${fake.address().port}`,
    });
    proc.stderr.on("data", (d) => { stderr += d.toString(); });
  });
  after(async () => {
    await m0.stopServer(proc);
    await new Promise((resolve) => fake.close(resolve));
    const u = db.prepare("SELECT id FROM users WHERE email = ?").get(EMAIL);
    if (u) m0.cleanup(u.id);
  });

  it("Resend answers 422 → request-link answers 500, and the log names the Resend error, not the address", async () => {
    reply = { status: 422, body: { name: "validation_error", message: "The stride.colorarchive.me domain is not verified." } };
    const r = await m0.req("POST", "/v1/auth/request-link", { base: `http://localhost:${PORT2}`, body: { email: EMAIL } });
    assert.equal(r.status, 500);
    assert.deepEqual(r.json, { error: "Failed to send login link" });
    await m0.sleep(200);
    assert.match(stderr, /Resend validation_error: The stride\.colorarchive\.me domain is not verified\./);
    assert.ok(!stderr.includes(EMAIL), "the recipient's address must not be logged");
  });

  it("Resend accepts the mail → request-link answers {ok:true}", async () => {
    reply = { status: 200, body: { id: "fake-email-id" } };
    const r = await m0.req("POST", "/v1/auth/request-link", { base: `http://localhost:${PORT2}`, body: { email: EMAIL } });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json, { ok: true });
  });
});

// ===========================================================================
// M2 — the server half of 1.3.1 (DEV-PLAN-1.3.md M2, "Millisecond edit stamps from 1.3.1" and
// "The LWW winner goes back to the device that lost"). Deployed before the 1.3.1 client is
// submitted, so every case here also pins what the shipped apps (no header, 1.3.0) keep getting.
// ===========================================================================

const m2 = {
  MS: /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/,
  WHOLE: /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/,
  pull: (token, client, since) => m0.req("GET", "/v1/sync/pull", { token, client, query: since ? { since } : undefined }),
  /** Every createdAt / updatedAt in a pull. */
  stamps: (json) => [...json.habits, ...json.entries, ...json.groups].flatMap((r) => [r.createdAt, r.updatedAt]),
};

describe("M2 millisecond pull: >= 1.3.1 gets milliseconds, 1.3.0 and header-less apps whole seconds", () => {
  let u;
  const H = m0.uuid(), H123 = m0.uuid(), E = m0.uuid(), G = m0.uuid();
  before(async () => {
    u = m0.user();
    const r = await m0.push(u.token, {
      groups: [m0.group(G, { createdAt: "2026-09-01T00:00:00.125Z", updatedAt: "2026-09-15T17:33:18.300Z" })],
      habits: [m0.habit(H, { groupId: G, createdAt: "2026-09-01T00:00:00.250Z", updatedAt: "2026-09-15T17:33:18.700Z" })],
      entries: [m0.entry(E, H, "2026-09-15", { createdAt: "2026-09-15T00:00:00Z", updatedAt: "2026-09-15T17:33:18.042Z" })],
    });
    assert.equal(r.status, 200);
    // A habit a 1.2.3 phone wrote: whole seconds on the wire.
    assert.equal((await api("POST", "/v1/sync/push", { token: u.token, body: m0.snapshot123({
      habits: [{ ...m0.habit(H123, { name: "Stretch", updatedAt: "2026-09-15T17:33:19Z" }), note: null, unit: null, groupId: null }],
      entries: [], groups: [],
    }) })).status, 200);
  });
  after(() => m0.cleanup(u.userId));

  for (const client of ["ios/1.3.1(19)", "macos/1.3.1(19)", "ios/1.4.0(30)"]) {
    it(`${client}: fixed-width milliseconds, exactly the stored instants`, async () => {
      const r = await m2.pull(u.token, client);
      assert.equal(r.status, 200);
      const h = r.json.habits.find((x) => x.id === H);
      assert.equal(h.updatedAt, "2026-09-15T17:33:18.700Z");
      assert.equal(h.createdAt, "2026-09-01T00:00:00.250Z");
      const e = r.json.entries.find((x) => x.id === E);
      assert.equal(e.updatedAt, "2026-09-15T17:33:18.042Z");
      assert.equal(e.createdAt, "2026-09-15T00:00:00.000Z", "a whole-second createdAt goes out as .000Z");
      const g = r.json.groups.find((x) => x.id === G);
      assert.deepEqual([g.createdAt, g.updatedAt], ["2026-09-01T00:00:00.125Z", "2026-09-15T17:33:18.300Z"]);
      assert.equal(r.json.habits.find((x) => x.id === H123).updatedAt, "2026-09-15T17:33:19.000Z",
        "a 1.2.3 phone's whole-second edit reads as .000Z");
      for (const t of m2.stamps(r.json)) assert.match(t, m2.MS);
    });
  }

  it("an incremental pull (?since) from 1.3.1 carries milliseconds too", async () => {
    const r = await m2.pull(u.token, m0.V131, "2026-01-01T00:00:00.000Z");
    assert.equal(r.status, 200);
    assert.ok(r.json.habits.length >= 2);
    for (const t of m2.stamps(r.json)) assert.match(t, m2.MS);
  });

  for (const [label, client] of [["ios/1.3.0(18)", m0.V130], ["no header", undefined], ["a malformed header", "ios/1.3.1-beta(19)"]]) {
    it(`${label}: whole seconds, the same instants truncated (a default ISO8601DateFormatter returns nil on a fraction)`, async () => {
      const ms = (await m2.pull(u.token, m0.V131)).json;
      const r = await m2.pull(u.token, client);
      assert.equal(r.status, 200);
      const h = r.json.habits.find((x) => x.id === H);
      assert.equal(h.updatedAt, "2026-09-15T17:33:18Z");
      assert.equal(h.createdAt, "2026-09-01T00:00:00Z");
      for (const t of m2.stamps(r.json)) assert.match(t, m2.WHOLE);
      assert.deepEqual(m2.stamps(r.json), m2.stamps(ms).map((t) => t.replace(/\.\d{3}Z$/, "Z")));
    });
  }
});

describe("M2 millisecond edit stamps: two edits in one second resolve by time, not push order", () => {
  let u;
  const H = m0.uuid();
  before(async () => {
    u = m0.user();
    assert.equal((await m0.push(u.token, { habits: [m0.habit(H)] })).status, 200);
  });
  after(() => m0.cleanup(u.userId));

  const stored = (date) => db.prepare("SELECT id, value, client_updated_at FROM habit_entries WHERE habit_id = ? AND date = ?").get(H, date);

  for (const laterFirst of [true, false]) {
    it(`an entry stamped :18.700 beats one stamped :18.300 (${laterFirst ? ":18.700 pushed first" : ":18.300 pushed first"})`, async () => {
      const date = laterFirst ? "2026-09-21" : "2026-09-22";
      const E = m0.uuid();
      const later = m0.entry(E, H, date, { value: 7, updatedAt: `${date}T10:00:18.700Z` });
      const earlier = m0.entry(E, H, date, { value: 3, updatedAt: `${date}T10:00:18.300Z` });
      for (const row of laterFirst ? [later, earlier] : [earlier, later]) {
        const r = await m0.push(u.token, { entries: [row] });
        assert.equal(r.status, 200);
        assert.deepEqual(r.json.skipped.entries, []);
      }
      assert.deepEqual({ ...stored(date) }, { id: E, value: 7, client_updated_at: `${date}T10:00:18.700Z` });
      const pulled = (await m2.pull(u.token, m0.V131)).json.entries.find((x) => x.id === E);
      assert.deepEqual([pulled.value, pulled.updatedAt], [7, `${date}T10:00:18.700Z`]);
    });
  }

  it("a whole-second push after a millisecond one compares as .000Z, not as the raw string", async () => {
    const date = "2026-09-23", E = m0.uuid();
    await m0.push(u.token, { entries: [m0.entry(E, H, date, { value: 7, updatedAt: `${date}T10:00:18.700Z` })] });
    // As raw strings "…:18Z" sorts AFTER "…:18.700Z" ('Z' > '.'), and would have won.
    const old = await api("POST", "/v1/sync/push", { token: u.token, body: m0.snapshot123({
      habits: [], groups: [], entries: [{ id: E, habitId: H, date, value: 1, note: null, updatedAt: `${date}T10:00:18Z` }],
    }) });
    assert.equal(old.status, 200);
    assert.deepEqual({ ...stored(date) }, { id: E, value: 7, client_updated_at: `${date}T10:00:18.700Z` });

    // A whole second later it is newer, and is stored in the same fixed-width form.
    await api("POST", "/v1/sync/push", { token: u.token, body: m0.snapshot123({
      habits: [], groups: [], entries: [{ id: E, habitId: H, date, value: 2, note: null, updatedAt: `${date}T10:00:19Z` }],
    }) });
    assert.deepEqual({ ...stored(date) }, { id: E, value: 2, client_updated_at: `${date}T10:00:19.000Z` });
  });
});

describe("M2 LWW re-feed: the winner goes back to the device that lost", () => {
  // The case: device A pulled the winner W (stamped :20), then made an edit L that its slow
  // clock stamped :10. The guard keeps W and answers `applied`, so A acknowledges L — and W's
  // updated_at is before A's cursor, so A's next pull would never bring W back.
  const kinds = {
    entries: {
      // One day per id: entries conflict on (habit, day), and each case below uses a fresh id.
      row: (id, habitId, stamp, v, day) => m0.entry(id, habitId, day, { value: v === "W" ? 8 : 2, note: v === "W" ? "evening" : null, updatedAt: stamp }),
      read: (json, id) => json.entries.find((x) => x.id === id),
      winner: (r) => r.value === 8 && r.note === "evening",
    },
    habits: {
      row: (id, _h, stamp, v) => m0.habit(id, { name: v === "W" ? "Water (renamed)" : "Water", targetValue: v === "W" ? 10 : 8, updatedAt: stamp }),
      read: (json, id) => json.habits.find((x) => x.id === id),
      winner: (r) => r.name === "Water (renamed)" && r.targetValue === 10,
    },
    groups: {
      row: (id, _h, stamp, v) => m0.group(id, { name: v === "W" ? "Health (renamed)" : "Health", sortOrder: v === "W" ? 5 : 1, updatedAt: stamp }),
      read: (json, id) => json.groups.find((x) => x.id === id),
      winner: (r) => r.name === "Health (renamed)" && r.sortOrder === 5,
    },
  };
  const W = "2026-09-24T10:00:20.000Z", L = "2026-09-24T10:00:10.000Z";

  for (const [kind, k] of Object.entries(kinds)) {
    describe(kind, () => {
      let u, H;
      const one = (row) => ({ [kind]: [row] });
      before(async () => {
        u = m0.user();
        H = m0.uuid();
        assert.equal((await m0.push(u.token, { habits: [m0.habit(H)] })).status, 200);
      });
      after(() => m0.cleanup(u.userId));

      it("a losing push with different values: applied, and the next pull since the cursor returns the winner", async () => {
        const id = m0.uuid(), day = "2026-09-24";
        assert.equal((await m0.push(u.token, one(k.row(id, H, W, "W", day)))).status, 200);
        const cursor = (await m2.pull(u.token, m0.V131)).json.serverTime;
        await m0.sleep(5);

        const lost = await m0.push(u.token, one(k.row(id, H, L, "L", day)));
        assert.equal(lost.status, 200);
        assert.equal(lost.json.applied[kind], 1, "the guard's keep still counts as applied");
        assert.deepEqual(lost.json.skipped[kind], []);

        const inc = (await m2.pull(u.token, m0.V131, cursor)).json;
        const back = k.read(inc, id);
        assert.ok(back, "was absent: the winner's updated_at was before the cursor");
        assert.ok(k.winner(back), JSON.stringify(back));
        assert.equal(back.updatedAt, W, "the winner keeps its own edit stamp");
      });

      it("the same losing stamp with the winner's values re-feeds nothing", async () => {
        const id = m0.uuid(), day = "2026-09-25";
        await m0.push(u.token, one(k.row(id, H, W, "W", day)));
        const before = m0.clocks(u.userId);
        await m0.sleep(5);
        assert.equal((await m0.push(u.token, one(k.row(id, H, L, "W", day)))).status, 200);
        assert.deepEqual(m0.clocks(u.userId), before, "no updated_at may move");
      });

      it("a whole-second echo of a millisecond row (1.3.0 snapshot) re-feeds nothing", async () => {
        const id = m0.uuid(), day = "2026-09-26";
        const ms = "2026-09-24T10:00:30.700Z";
        await m0.push(u.token, one(k.row(id, H, ms, "W", day)));
        const before = m0.clocks(u.userId);
        await m0.sleep(5);
        // What 1.3.0 pulls (whole seconds) and pushes straight back: :30.000 < :30.700, same values.
        const pulled = k.read((await m2.pull(u.token, m0.V130)).json, id);
        assert.equal(pulled.updatedAt, "2026-09-24T10:00:30Z");
        const echo = await m0.push(u.token, one(k.row(id, H, pulled.updatedAt, "W", day)), { client: m0.V130 });
        assert.equal(echo.status, 200);
        assert.deepEqual(m0.clocks(u.userId), before, "no updated_at may move");
      });
    });
  }

  describe("values are compared as an app holds them, so a device that pulled the winner is never re-fed", () => {
    let u;
    const H = m0.uuid();
    before(async () => {
      u = m0.user();
      assert.equal((await m0.push(u.token, { habits: [m0.habit(H)] })).status, 200);
    });
    after(() => m0.cleanup(u.userId));

    /** Push `rows` (if any) stamped with milliseconds, then echo what 1.2.3 would: the
     * whole-second pull, as it holds it, which is strictly older than every stored stamp. */
    async function echoMovesNothing(rows) {
      if (rows) assert.equal((await m0.push(u.token, rows)).status, 200);
      const before = m0.clocks(u.userId);
      await m0.sleep(5);
      const pulled = (await m2.pull(u.token)).json;
      const echo = await api("POST", "/v1/sync/push", { token: u.token, body: m0.snapshot123(pulled) });
      assert.equal(echo.status, 200);
      assert.deepEqual(echo.json.skipped, { habits: [], entries: [], groups: [] });
      assert.deepEqual(m0.clocks(u.userId), before, "no updated_at may move");
    }

    it("an empty note (served as null, echoed absent) is not a difference", async () => {
      const H2 = m0.uuid();
      await echoMovesNothing({
        habits: [m0.habit(H2, { note: "", unit: "", updatedAt: "2026-09-25T10:00:40.700Z" })],
        entries: [m0.entry(m0.uuid(), H, "2026-09-25", { note: "", updatedAt: "2026-09-25T10:00:40.700Z" })],
      });
    });

    it("a habit still pointing at a deleted group (pushed as null, stored as the id) is not a difference", async () => {
      const G = m0.uuid(), H3 = m0.uuid();
      await m0.push(u.token, { groups: [m0.group(G)], habits: [m0.habit(H3, { groupId: G, updatedAt: "2026-09-25T10:00:50.700Z" })] });
      await m0.push(u.token, { deletedGroupIds: [G] });
      assert.equal(db.prepare("SELECT group_id FROM habits WHERE id = ?").get(H3).group_id, G,
        "the stored habit keeps the reference (a group delete does not touch its habits)");
      // The device kept the reference too; the push drops it to null. Same thing, as an app holds it.
      // (No re-push at :50.700 first: at an equal stamp the guard would write the null.)
      await echoMovesNothing(null);
      assert.equal(db.prepare("SELECT group_id FROM habits WHERE id = ?").get(H3).group_id, G);
    });

    it("a 1.1 habit (no kind, schedule or group) is compared only on what that app holds", async () => {
      const H4 = m0.uuid();
      await m0.push(u.token, { habits: [m0.habit(H4, { kind: "count", targetValue: 12, updatedAt: "2026-09-25T10:00:55.700Z" })] });
      const before = m0.clocks(u.userId);
      await m0.sleep(5);
      const old = { id: H4, name: "Water", emoji: "\u{1F4A7}", colorHex: "#007AFF", isArchived: false, sortOrder: 0,
        reminderEnabled: false, reminderHour: 20, reminderMinute: 0, createdAt: "2026-09-01T00:00:00Z", updatedAt: "2026-09-25T10:00:55Z" };
      assert.equal((await api("POST", "/v1/sync/push", { token: u.token, body: { habits: [old], entries: [] } })).status, 200);
      assert.deepEqual(m0.clocks(u.userId), before, "it can never hold kind: re-feeding it would never end");

      // A difference it does hold (the name) still re-feeds.
      assert.equal((await api("POST", "/v1/sync/push", { token: u.token, body: { habits: [{ ...old, name: "Old name" }], entries: [] } })).status, 200);
      assert.notEqual(m0.clocks(u.userId)[`h:${H4}`], before[`h:${H4}`]);
      assert.equal(db.prepare("SELECT kind, target_value FROM habits WHERE id = ?").get(H4).kind, "count", "and the winner is untouched");
    });
  });

  describe("counted in metrics and on the request line (second server)", () => {
    const PORT2 = 3098, BASE2 = `http://localhost:${PORT2}`;
    const count = (name) => db.prepare("SELECT COALESCE(SUM(value), 0) AS n FROM usage_counters WHERE name = ?").get(name).n;
    let proc, u, stdout = "", before0;
    const H = m0.uuid(), E = m0.uuid();

    before(async () => {
      u = m0.user();
      before0 = count("lww_refeed.entries");
      proc = await m0.spawnServer(PORT2, {});
      proc.stdout.on("data", (d) => { stdout += d; });
      const push = (body) => m0.push(u.token, body, { base: BASE2 });
      assert.equal((await push({ habits: [m0.habit(H)], entries: [m0.entry(E, H, "2026-09-26", { value: 8, updatedAt: W })] })).status, 200);
      assert.equal((await push({ entries: [m0.entry(E, H, "2026-09-26", { value: 2, updatedAt: L })] })).status, 200);
      await m0.stopServer(proc);   // SIGTERM flushes the counters
    });
    after(async () => { await m0.stopServer(proc); m0.cleanup(u.userId); });

    it("refed= on the losing push's log line, and lww_refeed.entries in usage_counters", () => {
      const lines = stdout.split("\n").filter((l) => l.includes("POST /v1/sync/push"));
      assert.equal(lines.length, 2, stdout);
      assert.doesNotMatch(lines[0], /refed=/, "the winner's own push re-feeds nothing");
      assert.match(lines[1], / refed=habits:0,entries:1,groups:0(\s|$)/);
      assert.equal(count("lww_refeed.entries") - before0, 1);
    });
  });
});

describe("M2 aliases: an entry written onto another id's row for its day is named in the answer (>= 1.3.1)", () => {
  // Two devices checked the same day before either pulled the other's check-in. Entries conflict
  // on (habit_id, date) and the stored row keeps its id, so the second device's X is written (or
  // kept older) as the first device's Y, and answered `applied`. Before the alias it learnt Y only
  // from a later pull; an uncheck made before that pull queued X, the push deleted nothing, and the
  // next pull checked the day again (review data-safety-4).
  let u;
  const H = m0.uuid();
  before(async () => {
    u = m0.user();
    assert.equal((await m0.push(u.token, { habits: [m0.habit(H)] })).status, 200);
  });
  after(() => m0.cleanup(u.userId));

  const storedId = (day) => db.prepare("SELECT id FROM habit_entries WHERE habit_id = ? AND date = ?").get(H, day)?.id;

  /** The first device checks `day` in as Y (stamped 12:00); the second pushes it as X. */
  async function sameDay(day, { client = m0.V131, updatedAt } = {}) {
    const Y = m0.uuid(), X = m0.uuid();
    assert.equal((await m0.push(u.token, { entries: [m0.entry(Y, H, day)] })).status, 200);
    const r = await m0.push(u.token, { entries: [m0.entry(X, H, day, { value: 3, updatedAt })] }, { client });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.skipped.entries, [], "applied, as before");
    assert.equal(r.json.applied.entries, 1);
    assert.equal(storedId(day), Y, "the stored row keeps its id");
    return { X, Y, r };
  }

  it("1.3.1: a newer edit is written onto the stored row, and aliases names that row's id", async () => {
    const { X, Y, r } = await sameDay("2026-09-27", { updatedAt: "2026-09-27T13:00:00.000Z" });
    assert.deepEqual(r.json.aliases, { entries: { [X]: Y } });
    assert.equal(db.prepare("SELECT value FROM habit_entries WHERE id = ?").get(Y).value, 3);
  });

  it("1.3.1: an older edit the guard keeps is named too — the device holds that day under the wrong id either way", async () => {
    const { X, Y, r } = await sameDay("2026-09-28", { updatedAt: "2026-09-28T11:00:00.000Z" });
    assert.deepEqual(r.json.aliases, { entries: { [X]: Y } });
    assert.equal(db.prepare("SELECT value FROM habit_entries WHERE id = ?").get(Y).value, 1, "the newer edit stays");
  });

  it("1.3.1: a second id for one day in the same push is named after the first", async () => {
    const X1 = m0.uuid(), X2 = m0.uuid(), day = "2026-09-29";
    const r = await m0.push(u.token, { entries: [m0.entry(X1, H, day), m0.entry(X2, H, day)] });
    assert.equal(r.status, 200);
    assert.deepEqual(r.json.aliases, { entries: { [X2]: X1 } });
  });

  it("1.3.1: no aliases key when no entry landed on another id — a new row, the same id again, a skipped one", async () => {
    const E = m0.uuid(), gone = m0.uuid();
    const fresh = await m0.push(u.token, { entries: [m0.entry(E, H, "2026-09-30")] });
    assert.equal(fresh.status, 200);
    assert.equal(fresh.json.aliases, undefined);
    const again = await m0.push(u.token, { entries: [m0.entry(E, H, "2026-09-30", { value: 2, updatedAt: "2026-09-30T13:00:00.000Z" })] });
    assert.equal(again.json.aliases, undefined);
    await m0.push(u.token, { deletedEntryIds: [gone] });
    const skipped = await m0.push(u.token, { entries: [m0.entry(gone, H, "2026-09-30")] });
    assert.deepEqual(skipped.json.skippedReasons.entries, { [gone]: "tombstoned" });
    assert.equal(skipped.json.aliases, undefined);
  });

  for (const [label, client, day] of [["ios/1.3.0(18)", m0.V130, "2026-10-01"], ["no header", null, "2026-10-02"],
    ["a malformed header", "ios/1.3.1-beta(19)", "2026-10-03"]]) {
    it(`${label}: the same push is answered without aliases (the key is 1.3.1's)`, async () => {
      const { r } = await sameDay(day, { client, updatedAt: `${day}T13:00:00.000Z` });
      assert.equal(r.json.aliases, undefined);
      assert.deepEqual(Object.keys(r.json).sort(), ["applied", "ok", "skipped", "skippedReasons"]);
    });
  }

  it("what the alias is for: deleting the stored id takes the day, and a pull since does not bring it back", async () => {
    const day = "2026-10-04";
    const cursor = (await m2.pull(u.token, m0.V131)).json.serverTime;
    await m0.sleep(5);
    const { X, Y, r } = await sameDay(day, { updatedAt: `${day}T13:00:00.000Z` });

    // The sent id deletes nothing: the pre-alias uncheck.
    assert.equal((await m0.push(u.token, { deletedEntryIds: [X] })).status, 200);
    assert.equal(storedId(day), Y);

    assert.equal((await m0.push(u.token, { deletedEntryIds: [r.json.aliases.entries[X]] })).status, 200);
    assert.equal(storedId(day), undefined);
    const inc = (await m2.pull(u.token, m0.V131, cursor)).json;
    assert.ok(!inc.entries.some((e) => e.date === day), JSON.stringify(inc.entries));
    assert.ok(inc.deletedEntryIds.includes(Y));
  });
});

// ----------------------------------------------------------------
// M2 `deletionsSince` (routes/sync.js, above listableDeletionsSince; review data-safety-1): a store
// 1.3.0 synced asks, with its first 1.3.1 full pull, for the account's deletions since the pull
// cursor 1.3.0 kept. One in the list was deleted elsewhere and goes quietly; a row the snapshot
// lacks that is not in a complete list is one the 1.3.0 server refused, and is sent again.

const dsn = {
  /** A pull as `client` asking for the deletions since `value` (undefined: not asking), plus `query`. */
  pull: (token, client, value, { query = {}, base } = {}) => m0.req("GET", "/v1/sync/pull", {
    token, client, base, query: value === undefined ? query : { ...query, deletionsSince: value },
  }),
  daysAgo: (n) => new Date(Date.now() - n * 86400000).toISOString(),
  sorted: (ids) => [...ids].sort(),
};

describe("M2 deletionsSince: a full pull lists the account's deletions since a time (>= 1.3.1)", () => {
  let u, other, since;
  const [G1, G2, H1, H2, HOLD] = [m0.uuid(), m0.uuid(), m0.uuid(), m0.uuid(), m0.uuid()];
  const [E1, EOLD, X, Y, THEIRS] = [m0.uuid(), m0.uuid(), m0.uuid(), m0.uuid(), m0.uuid()];
  before(async () => {
    u = m0.user();
    other = m0.user();
    assert.equal((await m0.push(u.token, {
      groups: [m0.group(G1), m0.group(G2, { name: "Evening" })],
      habits: [m0.habit(H1, { groupId: G1 }), m0.habit(H2, { name: "Read" }), m0.habit(HOLD, { name: "Old" })],
      entries: [m0.entry(E1, H2, "2026-09-01"), m0.entry(EOLD, H2, "2026-09-02"), m0.entry(X, H2, "2026-09-03")],
    })).status, 200);
    // Deleted before the time: already applied by the device that asks, never listed.
    assert.equal((await m0.push(u.token, { deletedHabitIds: [HOLD], deletedEntryIds: [EOLD] })).status, 200);
    await m0.sleep(5);
    since = (await m2.pull(u.token, m0.V131)).json.serverTime;   // what the old app kept as its cursor
    await m0.sleep(5);
    // After it: a habit, a check-in, a group, and a day unchecked and checked again in one push —
    // whose deletion an app below 1.3.1 would be spared on an incremental pull (E2E S4), but not here.
    assert.equal((await m0.push(u.token, {
      deletedHabitIds: [H1], deletedEntryIds: [E1, X], deletedGroupIds: [G1], entries: [m0.entry(Y, H2, "2026-09-03")],
    })).status, 200);
    assert.equal((await m0.push(other.token, { habits: [m0.habit(THEIRS)] })).status, 200);
    assert.equal((await m0.push(other.token, { deletedHabitIds: [THEIRS] })).status, 200);
  });
  after(() => { m0.cleanup(u.userId); m0.cleanup(other.userId); });

  it("lists every habit, entry and group this account deleted after the time — none from before it, none of another account's", async () => {
    const r = await dsn.pull(u.token, m0.V131, since);
    assert.equal(r.status, 200);
    const { deletionsSince } = r.json;
    assert.deepEqual(Object.keys(deletionsSince).sort(), ["complete", "entryIds", "groupIds", "habitIds"]);
    assert.equal(deletionsSince.complete, true);
    assert.deepEqual(dsn.sorted(deletionsSince.habitIds), [H1]);
    assert.deepEqual(dsn.sorted(deletionsSince.entryIds), dsn.sorted([E1, X]), "the re-checked day's deletion is listed too");
    assert.deepEqual(dsn.sorted(deletionsSince.groupIds), [G1]);
    // The rest is the full pull as ever: the snapshot, no deleted*Ids, totals equal to the arrays.
    assert.deepEqual(r.json.habits.map((h) => h.id), [H2]);
    assert.deepEqual(r.json.entries.map((e) => e.id), [Y]);
    assert.deepEqual(r.json.groups.map((g) => g.id), [G2]);
    assert.deepEqual([r.json.deletedHabitIds, r.json.deletedEntryIds, r.json.deletedGroupIds], [[], [], []]);
    assert.deepEqual(r.json.totals, { habits: 1, entries: 1, groups: 1 });
  });

  it("from any later version, on the legacy /sync mount too, and compared in the stored form", async () => {
    for (const client of ["macos/1.3.1(20)", "ios/1.4.0(30)"]) {
      assert.deepEqual(dsn.sorted((await dsn.pull(u.token, client, since)).json.deletionsSince.habitIds), [H1], client);
    }
    const legacy = await m0.req("GET", "/sync/pull", { token: u.token, client: m0.V131, query: { deletionsSince: since } });
    assert.deepEqual(dsn.sorted(legacy.json.deletionsSince.habitIds), [H1]);
    // A whole-second time is brought to toISOString()'s form before the string comparison, as
    // `since` is: "…:18Z" sorts after "…:18.500Z", and would miss the rest of its own second.
    const SAME_SECOND = m0.uuid();
    const at = new Date(Date.now() - 60000);
    at.setUTCMilliseconds(500);
    db.prepare("INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, 'habit', ?, ?)")
      .run(u.userId, SAME_SECOND, at.toISOString());
    try {
      const r = await dsn.pull(u.token, m0.V131, at.toISOString().replace(/\.\d{3}Z$/, "Z"));
      assert.equal(r.json.deletionsSince.complete, true);
      assert.ok(r.json.deletionsSince.habitIds.includes(SAME_SECOND));
    } finally {
      db.prepare("DELETE FROM deletion_tombstones WHERE entity_id = ?").run(SAME_SECOND);
    }
  });

  it("the edge is the cursor horizon, 355 days: inside it the list is complete; past it, or unreadable, complete false and no lists", async () => {
    // A deletion 300 days old: inside the horizon, so a time before it lists it.
    const ANCIENT = m0.uuid();
    db.prepare("INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, 'habit', ?, ?)")
      .run(u.userId, ANCIENT, dsn.daysAgo(300));
    const inside = (await dsn.pull(u.token, m0.V131, dsn.daysAgo(354))).json.deletionsSince;
    assert.equal(inside.complete, true);
    assert.deepEqual(dsn.sorted(inside.habitIds), dsn.sorted([ANCIENT, HOLD, H1]));
    for (const value of [dsn.daysAgo(356), dsn.daysAgo(400), "2020-01-01T00:00:00Z", "garbage", ""]) {
      const r = await dsn.pull(u.token, m0.V131, value);
      assert.equal(r.status, 200, value);
      assert.deepEqual(r.json.deletionsSince, { complete: false }, value);
      assert.deepEqual(r.json.habits.map((h) => h.id), [H2], "the snapshot is served all the same");
    }
    // Two values are not one timestamp.
    const repeated = await m0.req("GET", `/v1/sync/pull?deletionsSince=${encodeURIComponent(since)}&deletionsSince=${encodeURIComponent(since)}`,
      { token: u.token, client: m0.V131 });
    assert.equal(repeated.status, 200);
    assert.deepEqual(repeated.json.deletionsSince, { complete: false });
  });

  for (const [label, client] of [["ios/1.3.0(19)", "ios/1.3.0(19)"], ["no header (<= 1.2.3)", undefined],
    ["a malformed header", "ios/1.3.1-beta(19)"]]) {
    it(`${label}: the parameter is ignored, and the answer is the one it gets without it`, async () => {
      const asked = await dsn.pull(u.token, client, since);
      const plain = await dsn.pull(u.token, client, undefined);
      assert.equal(asked.status, 200);
      assert.equal("deletionsSince" in asked.json, false);
      assert.deepEqual({ ...asked.json, serverTime: "" }, { ...plain.json, serverTime: "" });
    });
  }

  it(">= 1.3.1: a full pull that does not ask has exactly the keys it always had, and an incremental pull that asks is answered as an incremental pull", async () => {
    const plain = await dsn.pull(u.token, m0.V131, undefined);
    assert.deepEqual(Object.keys(plain.json).sort(),
      ["deletedEntryIds", "deletedGroupIds", "deletedHabitIds", "entries", "groups", "habits", "serverTime", "totals"]);
    const incremental = await dsn.pull(u.token, m0.V131, dsn.daysAgo(30), { query: { since } });
    assert.equal(incremental.status, 200);
    assert.equal("deletionsSince" in incremental.json, false);
    assert.deepEqual(dsn.sorted(incremental.json.deletedHabitIds), [H1], "its own deletions, as ever");
  });
});

describe("M2 deletionsSince: listed in the snapshot's own read transaction (second server, statement spy)", () => {
  // The handler is synchronous, so no request to the same process can land between its reads;
  // another process can (seed-demo.js and the ops scripts write in WAL mode), at a moment no test
  // can time. So the second server runs with a preload that tags every SELECT with the
  // transaction it ran in: a list read outside the snapshot's transaction could miss a row
  // deleted between the two reads from both, and the app would send that row again.
  const PORT2 = 3098, BASE2 = `http://localhost:${PORT2}`;
  const spyFile = path.join(os.tmpdir(), `stride-test-tx-spy-${process.pid}.js`);
  const spyLog = path.join(os.tmpdir(), `stride-test-tx-spy-${process.pid}.log`);
  let proc, u, since;
  before(async () => {
    fs.writeFileSync(spyFile, `
      const Database = require(${JSON.stringify(require.resolve("better-sqlite3"))});
      const fs = require("fs");
      let seq = 0, current = 0;
      const transaction = Database.prototype.transaction;
      Database.prototype.transaction = function (fn) {
        return transaction.call(this, function (...args) {
          const outer = current;
          current = ++seq;
          try { return fn.apply(this, args); } finally { current = outer; }
        });
      };
      const prepare = Database.prototype.prepare;
      Database.prototype.prepare = function (sql) {
        const stmt = prepare.call(this, sql);
        if (/^\\s*SELECT/i.test(sql)) {
          for (const method of ["all", "get"]) {
            const run = stmt[method];
            stmt[method] = function (...args) {
              fs.appendFileSync(${JSON.stringify(spyLog)}, current + "\\t" + sql.replace(/\\s+/g, " ").trim() + "\\n");
              return run.apply(this, args);
            };
          }
        }
        return stmt;
      };`);
    u = m0.user();
    const H = m0.uuid();
    assert.equal((await m0.push(u.token, { habits: [m0.habit(H)] })).status, 200);
    since = new Date(Date.now() - 1000).toISOString();
    assert.equal((await m0.push(u.token, { deletedHabitIds: [H] })).status, 200);
    proc = await m0.spawnServer(PORT2, { NODE_OPTIONS: `--require ${spyFile}` });
  });
  after(async () => {
    await m0.stopServer(proc);
    m0.cleanup(u.userId);
    fs.rmSync(spyFile, { force: true });
    fs.rmSync(spyLog, { force: true });
  });

  it("the totals, the three snapshot arrays and the deletion list carry one transaction's tag", async () => {
    fs.rmSync(spyLog, { force: true });
    const r = await dsn.pull(u.token, m0.V131, since, { base: BASE2 });
    assert.equal(r.status, 200);
    assert.equal(r.json.deletionsSince.habitIds.length, 1, "the spy watched a pull that listed a deletion");
    const reads = fs.readFileSync(spyLog, "utf8").trim().split("\n").map((line) => {
      const [tag, sql] = line.split("\t");
      return { tag: Number(tag), sql };
    });
    const tagOf = (pattern) => {
      const hits = reads.filter((r) => pattern.test(r.sql));
      assert.equal(hits.length, 1, `one read matching ${pattern}: ${JSON.stringify(reads)}`);
      return hits[0].tag;
    };
    const list = tagOf(/FROM deletion_tombstones WHERE user_id = \? AND deleted_at > \?/);
    assert.ok(list > 0, "the list is read inside a transaction");
    for (const pattern of [/COUNT\(\*\) AS n FROM habits /, /COUNT\(\*\) AS n FROM habit_entries /,
      /COUNT\(\*\) AS n FROM habit_groups /, /AS updated_at FROM habits WHERE user_id = \?$/,
      /AS updated_at FROM habit_groups WHERE user_id = \?$/,
      /AS updated_at FROM habit_entries WHERE habit_id IN \(SELECT id FROM habits WHERE user_id = \?\)$/]) {
      assert.equal(tagOf(pattern), list, String(pattern));
    }
  });
});

// ----------------------------------------------------------------

describe("Test hooks: the swept-tombstone switch (rehearsal only, lib/testHooks.js)", () => {
  const { mountTestHooks, testHooksEnabled } = require("../lib/testHooks");
  const PORT2 = 3098, BASE2 = `http://localhost:${PORT2}`;
  const DAY = 86400000;
  const sweep = (base, body, headers = {}) => fetch(`${base}/__test/sweep-tombstones`, {
    method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body),
  });
  const tomb = (userId, id, deletedAt) => db.prepare(
    "INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, 'habit', ?, ?)",
  ).run(userId, id, deletedAt);
  const tombIds = (userId) => db.prepare("SELECT entity_id FROM deletion_tombstones WHERE user_id = ? ORDER BY entity_id")
    .all(userId).map((r) => r.entity_id);

  /** m0.spawnServer, but collecting stderr from the first byte: the mount warning is written
   * before listen(), so a listener added after the server answers /health would miss it. */
  async function spawnCollecting(env) {
    const proc = spawn(process.execPath, [path.join(__dirname, "..", "index.js")], {
      env: serverEnv(PORT2, env), stdio: "pipe",
    });
    const out = { proc, stderr: "" };
    proc.stderr.on("data", (d) => { out.stderr += d; process.stderr.write(d); });
    await waitForServer(undefined, BASE2);
    return out;
  }

  let u;
  const OLD = m0.uuid(), FRESH = m0.uuid();
  before(() => {
    u = m0.user();
    tomb(u.userId, OLD, new Date(Date.now() - 400 * DAY).toISOString());
    tomb(u.userId, FRESH, new Date().toISOString());
  });
  after(() => m0.cleanup(u.userId));

  it("mounts only for NODE_ENV exactly 'test' AND STRIDE_TEST_HOOKS exactly '1'", () => {
    const cases = [
      [{ NODE_ENV: "test", STRIDE_TEST_HOOKS: "1" }, true],
      [{ NODE_ENV: "production", STRIDE_TEST_HOOKS: "1" }, false],
      [{ STRIDE_TEST_HOOKS: "1" }, false],                       // pm2 lost NODE_ENV: fails closed
      [{ NODE_ENV: "development", STRIDE_TEST_HOOKS: "1" }, false],
      [{ NODE_ENV: "TEST", STRIDE_TEST_HOOKS: "1" }, false],
      [{ NODE_ENV: "test ", STRIDE_TEST_HOOKS: "1" }, false],
      [{ NODE_ENV: "test" }, false],
      [{ NODE_ENV: "test", STRIDE_TEST_HOOKS: "true" }, false],
      [{ NODE_ENV: "test", STRIDE_TEST_HOOKS: "0" }, false],
      [{ NODE_ENV: "test", STRIDE_TEST_HOOKS: "" }, false],
    ];
    const warn = console.warn;
    console.warn = () => {};
    try {
      for (const [env, expected] of cases) {
        assert.equal(testHooksEnabled(env), expected, JSON.stringify(env));
        const mounted = [];
        const app = /** @type {any} */ ({ use: (...a) => mounted.push(a[0]) });
        assert.equal(mountTestHooks(app, { sweepStaleData: () => assert.fail("never called at mount") }, env), expected);
        assert.deepEqual(mounted, expected ? ["/__test"] : [], JSON.stringify(env));
      }
    } finally {
      console.warn = warn;
    }
  });

  it("the suite's own server (NODE_ENV=test, no STRIDE_TEST_HOOKS) answers 404 and sweeps nothing", async () => {
    const r = await sweep(BASE, { olderThanDays: 0 });
    assert.equal(r.status, 404);
    assert.deepEqual(tombIds(u.userId), [OLD, FRESH].sort());
    assert.doesNotMatch(serverStderr, /\[test-hooks\]/);
  });

  describe("NODE_ENV=production with STRIDE_TEST_HOOKS=1 (second server)", () => {
    let server;
    before(async () => {
      // As scripts/rehearse_server.sh boots production code: no APM agent traffic from a test.
      server = await spawnCollecting({
        NODE_ENV: "production", STRIDE_TEST_HOOKS: "1", DD_TRACE_ENABLED: "false", FRONTEND_ORIGIN: "",
      });
    });
    after(async () => { await m0.stopServer(server && server.proc); });

    it("answers 404 — the same as an unknown path — and sweeps nothing", async () => {
      const r = await sweep(BASE2, { olderThanDays: 0 });
      assert.equal(r.status, 404);
      const unknown = await fetch(`${BASE2}/__test/no-such-route`, { method: "POST" });
      assert.equal(unknown.status, 404);
      assert.equal(await r.text().then((t) => t.replace("sweep-tombstones", "X")),
        await unknown.text().then((t) => t.replace("no-such-route", "X")), "indistinguishable from no route");
      assert.deepEqual(tombIds(u.userId), [OLD, FRESH].sort());
      assert.match(server.stderr, /\[config\] FRONTEND_ORIGIN/, "it really booted in production mode");
      assert.doesNotMatch(server.stderr, /\[test-hooks\]/);
    });
  });

  describe("NODE_ENV=test with STRIDE_TEST_HOOKS=1 (second server)", () => {
    let server;
    before(async () => {
      server = await spawnCollecting({ STRIDE_TEST_HOOKS: "1" });
    });
    after(async () => { await m0.stopServer(server && server.proc); });

    it("says so loudly in the server log", () => {
      assert.match(server.stderr, /\[test-hooks\] mounted \/__test/);
    });

    it("rejects a missing, negative or non-number olderThanDays with 400 and sweeps nothing", async () => {
      for (const body of [{}, { olderThanDays: -1 }, { olderThanDays: "0" }, { olderThanDays: null }]) {
        const r = await sweep(BASE2, body);
        assert.equal(r.status, 400, JSON.stringify(body));
      }
      assert.deepEqual(tombIds(u.userId), [OLD, FRESH].sort());
    });

    it("answers 404 to a request that came through a proxy, and to GET", async () => {
      assert.equal((await sweep(BASE2, { olderThanDays: 0 }, { "X-Forwarded-For": "203.0.113.7" })).status, 404);
      assert.equal((await sweep(BASE2, { olderThanDays: 0 }, { "X-Real-IP": "203.0.113.7" })).status, 404);
      assert.equal((await sweep(BASE2, { olderThanDays: 0 }, { Forwarded: "for=203.0.113.7" })).status, 404);
      assert.equal((await fetch(`${BASE2}/__test/sweep-tombstones`)).status, 404);
      assert.deepEqual(tombIds(u.userId), [OLD, FRESH].sort());
    });

    it("sweeps through the real sweepStaleData: older than the retention goes, newer stays", async () => {
      const r = await sweep(BASE2, { olderThanDays: 365 });
      assert.equal(r.status, 200);
      const json = await r.json();
      assert.equal(json.ok, true);
      assert.ok(json.swept.tombstones >= 1, JSON.stringify(json));
      for (const k of ["sessions", "magicLinks", "usageCounters", "userClients", "snapshotRequests"]) {
        assert.equal(typeof json.swept[k], "number", `sweepStaleData's own result: ${k}`);
      }
      assert.deepEqual(tombIds(u.userId), [FRESH]);
    });

    it("olderThanDays 0 sweeps every tombstone written before now — the rehearsal's value", async () => {
      await m0.sleep(5);
      const r = await sweep(BASE2, { olderThanDays: 0 });
      assert.equal(r.status, 200);
      assert.deepEqual(tombIds(u.userId), []);
    });
  });
});

// ===========================================================================
// E2E S4 — an app below 1.3.1 never gets an entry's deletion in the same pull as that day's
// replacement (routes/sync.js, above replacedEntryDeletions). Found end to end with the real
// 1.3.0 build 19: unchecking and re-checking a day on a 1.3.1 device deletes X and creates Y for
// the same habit and day. A 1.3.0 device pulling both applies the deletion to X — which stays in
// `habit.records`, a relationship with no inverse — then day-matches Y onto it, and Y is lost on
// save. Without the deletion it re-IDs its live X to Y. Apps >= 1.3.1 get both, unchanged.
// ===========================================================================

const s4 = {
  V130: "ios/1.3.0(19)",   // the build in App Review, the one the finding was made with
  V131: "ios/1.3.1(20)",
  /** An incremental pull as `client` (undefined: no header, an app <= 1.2.3). */
  pull: (token, client, since) => m0.req("GET", "/v1/sync/pull", { token, client, query: since ? { since } : undefined }),
  /** An entry id's tombstone rows, oldest first, as stored. */
  tombs: (id) => db.prepare(
    "SELECT habit_id, entry_date FROM deletion_tombstones WHERE entity_type = 'entry' AND entity_id = ? ORDER BY id",
  ).all(id).map((r) => ({ ...r })),
  ids: (rows) => rows.map((r) => r.id).sort(),
};

describe("E2E S4 push: an entry tombstone records the deleted row's habit and day, as stored", () => {
  let u, other;
  before(() => { u = m0.user(); other = m0.user(); });
  after(() => { m0.cleanup(u.userId); m0.cleanup(other.userId); });

  it("(g) a pushed deletion copies habit_id and date from the row it deletes, exactly as the row held them", async () => {
    const H = m0.uuid(), X = m0.uuid(), day = "2026-09-20";
    assert.equal((await m0.push(u.token, { habits: [m0.habit(H)], entries: [m0.entry(X, H, day)] })).status, 200);
    const row = { ...db.prepare("SELECT habit_id, date FROM habit_entries WHERE id = ?").get(X) };
    assert.deepEqual(row, { habit_id: H, date: day });

    assert.equal((await m0.push(u.token, { deletedEntryIds: [X] })).status, 200);
    assert.equal(db.prepare("SELECT 1 FROM habit_entries WHERE id = ?").get(X), undefined, "the row is deleted");
    assert.deepEqual(s4.tombs(X), [{ habit_id: row.habit_id, entry_date: row.date }]);
    assert.equal(db.prepare("SELECT typeof(entry_date) AS t FROM deletion_tombstones WHERE entity_id = ?").get(X).t, "text");
  });

  it("(g) NULL when the account holds no such row: a retry, never pushed, another account's, gone with its habit in the same push", async () => {
    const day = "2026-09-21";
    const HR = m0.uuid(), R = m0.uuid(), HC = m0.uuid(), XC = m0.uuid(), G = m0.uuid();
    assert.equal((await m0.push(u.token, {
      groups: [m0.group(G)], habits: [m0.habit(HR), m0.habit(HC)], entries: [m0.entry(R, HR, day), m0.entry(XC, HC, day)],
    })).status, 200);
    const HO = m0.uuid(), XO = m0.uuid();
    assert.equal((await m0.push(other.token, { habits: [m0.habit(HO)], entries: [m0.entry(XO, HO, day)] })).status, 200);

    // A retry: the second push lists an id the first one already deleted.
    for (let i = 0; i < 2; i++) assert.equal((await m0.push(u.token, { deletedEntryIds: [R] })).status, 200);
    assert.deepEqual(s4.tombs(R), [{ habit_id: HR, entry_date: day }, { habit_id: null, entry_date: null }]);

    // A habit deleted with its check-ins listed, as apps <= 1.3.0 send it: the habit goes first
    // and ON DELETE CASCADE takes XC before the entry loop reads it.
    const never = m0.uuid();
    const r = await m0.push(u.token, { deletedHabitIds: [HC], deletedGroupIds: [G], deletedEntryIds: [XC, never, XO] });
    assert.equal(r.status, 200);
    for (const id of [XC, never, XO]) assert.deepEqual(s4.tombs(id), [{ habit_id: null, entry_date: null }], id);
    assert.deepEqual({ ...db.prepare("SELECT habit_id, date FROM habit_entries WHERE id = ?").get(XO) }, { habit_id: HO, date: day },
      "another account's check-in is neither deleted nor described");
    for (const id of [HC, G]) {
      assert.deepEqual({ ...db.prepare("SELECT habit_id, entry_date FROM deletion_tombstones WHERE entity_id = ?").get(id) },
        { habit_id: null, entry_date: null }, "habit and group tombstones name no day");
    }
  });

  it("(g) the REST uncheck (DELETE /v1/habits/:id/entries/:date) records them too", async () => {
    const created = await api("POST", "/v1/habits", { token: u.token, body: { name: "Stretch" } });
    assert.equal(created.status, 201);
    const H = created.json.habit.id;
    const checked = await api("POST", `/v1/habits/${H}/entries`, { token: u.token, body: { date: "2026-09-22" } });
    assert.equal(checked.status, 201);
    assert.equal((await api("DELETE", `/v1/habits/${H}/entries/2026-09-22`, { token: u.token })).status, 200);
    assert.deepEqual(s4.tombs(checked.json.entry.id), [{ habit_id: H, entry_date: "2026-09-22" }]);
  });
});

describe("E2E S4 pull: the deletion of a re-checked day is held back from apps below 1.3.1", () => {
  let u;
  before(() => { u = m0.user(); });
  after(() => m0.cleanup(u.userId));

  /** A new habit checked on `day`, then pulled by the old device: its cursor. */
  async function checkedDay(day) {
    const H = m0.uuid(), X = m0.uuid();
    assert.equal((await m0.push(u.token, { habits: [m0.habit(H)], entries: [m0.entry(X, H, day)] })).status, 200);
    const cursor = (await m2.pull(u.token, s4.V130)).json.serverTime;
    await m0.sleep(5);
    return { H, X, cursor };
  }

  /** On a 1.3.1 device: uncheck `day` (delete X) and check it again (Y, a new id) with no sync
   * in between, pushed in one request or two. */
  async function uncheckRecheck({ H, X }, day, onePush) {
    const Y = m0.uuid();
    const y = m0.entry(Y, H, day, { updatedAt: `${day}T18:00:00.500Z` });
    if (onePush) {
      assert.equal((await m0.push(u.token, { deletedEntryIds: [X], entries: [y] }, { client: s4.V131 })).status, 200);
    } else {
      assert.equal((await m0.push(u.token, { deletedEntryIds: [X] }, { client: s4.V131 })).status, 200);
      await m0.sleep(5);
      assert.equal((await m0.push(u.token, { entries: [y] }, { client: s4.V131 })).status, 200);
    }
    return Y;
  }

  for (const [label, onePush, day] of [["in one push", true, "2026-09-27"], ["in two pushes", false, "2026-09-28"]]) {
    describe(`unchecked and re-checked ${label}, and one pull covers both`, () => {
      let c, Y;
      before(async () => {
        c = await checkedDay(day);
        Y = await uncheckRecheck(c, day, onePush);
      });

      for (const [app, client] of [["(a) ios/1.3.0(19)", s4.V130], ["(c) no header (<= 1.2.3)", undefined]]) {
        it(`${app}: carries Y and NOT X's deletion`, async () => {
          const r = await s4.pull(u.token, client, c.cursor);
          assert.equal(r.status, 200);
          assert.deepEqual(r.json.entries.map((e) => [e.id, e.habitId, e.date]), [[Y, c.H, day]]);
          assert.deepEqual(r.json.deletedEntryIds, [], "held back: the old app day-matches its live X and re-IDs it to Y");
        });
      }

      it("(b) ios/1.3.1(20): carries Y and X's deletion, as before", async () => {
        const r = await s4.pull(u.token, s4.V131, c.cursor);
        assert.equal(r.status, 200);
        assert.deepEqual(r.json.entries.map((e) => [e.id, e.habitId, e.date]), [[Y, c.H, day]]);
        assert.deepEqual(r.json.deletedEntryIds, [c.X]);
      });
    });
  }

  it("(d) an uncheck with no replacement is still sent — to 1.3.0 and to header-less apps", async () => {
    const c = await checkedDay("2026-09-25");
    assert.equal((await m0.push(u.token, { deletedEntryIds: [c.X] }, { client: s4.V131 })).status, 200);
    for (const client of [s4.V130, undefined]) {
      const r = await s4.pull(u.token, client, c.cursor);
      assert.equal(r.status, 200);
      assert.deepEqual(r.json.entries, []);
      assert.deepEqual(r.json.deletedEntryIds, [c.X], client ?? "no header");
    }
  });

  it("(d) in one pull: the re-checked day's deletion is held back, while a check-in on another day, or on that date for another habit, replaces nothing", async () => {
    const H = m0.uuid(), H2 = m0.uuid(), X1 = m0.uuid(), X2 = m0.uuid();
    const [D1, D2, D3] = ["2026-09-10", "2026-09-11", "2026-09-12"];
    assert.equal((await m0.push(u.token, {
      habits: [m0.habit(H), m0.habit(H2, { name: "Read" })], entries: [m0.entry(X1, H, D1), m0.entry(X2, H, D2)],
    })).status, 200);
    const cursor = (await m2.pull(u.token, s4.V130)).json.serverTime;
    await m0.sleep(5);
    const Y1 = m0.uuid(), V = m0.uuid(), W = m0.uuid();
    assert.equal((await m0.push(u.token, {
      deletedEntryIds: [X1, X2], entries: [m0.entry(Y1, H, D1), m0.entry(V, H2, D2), m0.entry(W, H, D3)],
    }, { client: s4.V131 })).status, 200);

    for (const client of [s4.V130, undefined]) {
      const old = await s4.pull(u.token, client, cursor);
      assert.deepEqual(s4.ids(old.json.entries), [Y1, V, W].sort());
      assert.deepEqual(old.json.deletedEntryIds, [X2], client ?? "no header");
    }
    const current = await s4.pull(u.token, s4.V131, cursor);
    assert.deepEqual([...current.json.deletedEntryIds].sort(), [X1, X2].sort());
  });

  it("(e) a tombstone that names no day — every row written before this server — is sent as before, replacement or not", async () => {
    const day = "2026-09-26";
    const c = await checkedDay(day);
    const Y = await uncheckRecheck(c, day, true);
    // What every tombstone on production reads as after the migration.
    db.prepare("UPDATE deletion_tombstones SET habit_id = NULL, entry_date = NULL WHERE entity_id = ?").run(c.X);
    for (const client of [s4.V130, undefined]) {
      const r = await s4.pull(u.token, client, c.cursor);
      assert.deepEqual(s4.ids(r.json.entries), [Y]);
      assert.deepEqual(r.json.deletedEntryIds, [c.X], client ?? "no header");
    }
  });

  it("a retried deletion (its second tombstone row is NULL: the row was already gone) is still held back", async () => {
    const day = "2026-09-24";
    const c = await checkedDay(day);
    assert.equal((await m0.push(u.token, { deletedEntryIds: [c.X] }, { client: s4.V131 })).status, 200);
    await m0.sleep(5);
    // That push's answer was lost, so the device sends it again — now with the re-check.
    const Y = m0.uuid();
    assert.equal((await m0.push(u.token, { deletedEntryIds: [c.X], entries: [m0.entry(Y, c.H, day)] }, { client: s4.V131 })).status, 200);
    assert.deepEqual(s4.tombs(c.X), [{ habit_id: c.H, entry_date: day }, { habit_id: null, entry_date: null }]);

    for (const client of [s4.V130, undefined]) {
      const r = await s4.pull(u.token, client, c.cursor);
      assert.deepEqual(s4.ids(r.json.entries), [Y]);
      assert.deepEqual(r.json.deletedEntryIds, [], "any row in the window that names the replaced day holds the id back");
    }
    assert.deepEqual((await s4.pull(u.token, s4.V131, c.cursor)).json.deletedEntryIds, [c.X], "one id, however many rows");
  });

  it("unchecked and re-checked twice before the pull (X, then Y, both replaced by Z): both deletions held back", async () => {
    const day = "2026-09-23";
    const c = await checkedDay(day);
    const Y = await uncheckRecheck(c, day, true);
    await m0.sleep(5);
    const Z = await uncheckRecheck({ H: c.H, X: Y }, day, true);
    const old = await s4.pull(u.token, s4.V130, c.cursor);
    assert.deepEqual(s4.ids(old.json.entries), [Z]);
    assert.deepEqual(old.json.deletedEntryIds, []);
    const current = await s4.pull(u.token, s4.V131, c.cursor);
    assert.deepEqual([...current.json.deletedEntryIds].sort(), [c.X, Y].sort());
  });

  it("a full pull is unchanged: no deletions for anyone, the replacement is simply there", async () => {
    const day = "2026-09-22";
    const c = await checkedDay(day);
    const Y = await uncheckRecheck(c, day, true);
    for (const client of [s4.V130, undefined, s4.V131]) {
      const r = await s4.pull(u.token, client);
      assert.deepEqual(r.json.deletedEntryIds, []);
      assert.ok(r.json.entries.some((e) => e.id === Y) && !r.json.entries.some((e) => e.id === c.X));
    }
  });
});

describe("E2E S4: withheld= on the pull's request line (second server)", () => {
  const PORT2 = 3098, BASE2 = `http://localhost:${PORT2}`;
  let proc, u, stdout = "";
  before(async () => {
    u = m0.user();
    proc = await m0.spawnServer(PORT2, {});
    proc.stdout.on("data", (d) => { stdout += d; });
    const H = m0.uuid(), X = m0.uuid(), Y = m0.uuid(), day = "2026-09-21";
    assert.equal((await m0.push(u.token, { habits: [m0.habit(H)], entries: [m0.entry(X, H, day)] }, { base: BASE2 })).status, 200);
    const since = (await m0.req("GET", "/v1/sync/pull", { token: u.token, base: BASE2 })).json.serverTime;
    await m0.sleep(5);
    assert.equal((await m0.push(u.token, { deletedEntryIds: [X], entries: [m0.entry(Y, H, day)] },
      { base: BASE2, client: s4.V131 })).status, 200);
    for (const client of [s4.V130, s4.V131]) {
      assert.equal((await m0.req("GET", "/v1/sync/pull", { token: u.token, base: BASE2, client, query: { since } })).status, 200);
    }
    await m0.stopServer(proc);
  });
  after(async () => { await m0.stopServer(proc); m0.cleanup(u.userId); });

  it("the 1.3.0 pull's line counts no deletion and says withheld=1; the 1.3.1 pull's sends it and says nothing more", () => {
    const lines = stdout.split("\n").filter((l) => l.includes("GET /v1/sync/pull?since="));
    assert.equal(lines.length, 2, stdout);
    assert.match(lines[0], /client=ios\/1\.3\.0\(19\) sync .* out=habits:0,entries:1,groups:0,deletions:0 withheld=1$/);
    assert.match(lines[1], /client=ios\/1\.3\.1\(20\) sync .* out=habits:0,entries:1,groups:0,deletions:1$/);
  });
});

describe("E2E S4 migration (f): an existing database gains the two columns, and a second run changes nothing", () => {
  // The table exactly as every server before 1.3.1 created it, and the users table its foreign
  // key needs; db.js creates everything else around them, as it does on any boot.
  const BEFORE = `
    CREATE TABLE users (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      email      TEXT UNIQUE NOT NULL,
      tier       TEXT NOT NULL DEFAULT 'free',
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    );
    CREATE TABLE deletion_tombstones (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id    INTEGER NOT NULL,
      entity_type TEXT NOT NULL,  -- 'habit' or 'entry'
      entity_id  TEXT NOT NULL,
      deleted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    );`;
  const ROWS = [
    ["habit", m0.uuid(), "2026-08-01T10:00:00.000Z"],
    ["entry", m0.uuid(), "2026-08-02T11:00:00.250Z"],
    ["entry", m0.uuid(), "2026-08-02T11:00:00.250Z"],
    ["group", m0.uuid(), "2026-08-03T12:00:00.000Z"],
  ];
  let dir;
  before(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "stride-s4-migration-"));
    // db.js opens the stride.db next to itself, so this copy migrates this directory's database.
    fs.copyFileSync(path.join(__dirname, "..", "db.js"), path.join(dir, "db.js"));
    fs.mkdirSync(path.join(dir, "migrations"));
    fs.copyFileSync(path.join(__dirname, "..", "migrations", "canonicalizeIds.js"), path.join(dir, "migrations", "canonicalizeIds.js"));
    const old = new Database(path.join(dir, "stride.db"));
    old.exec(BEFORE);
    const userId = old.prepare("INSERT INTO users (email) VALUES ('before-1.3.1@stride-test.local')").run().lastInsertRowid;
    const insert = old.prepare("INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, ?, ?, ?)");
    for (const [type, id, at] of ROWS) insert.run(userId, type, id, at);
    old.close();
  });
  after(() => { if (dir) fs.rmSync(dir, { recursive: true, force: true }); });

  it("runs twice without error; the columns come once; every tombstone is kept as it was, NULL in both", async () => {
    // better-sqlite3 from this server's node_modules, found through NODE_PATH: nothing is linked
    // into the temp directory, so removing it can never reach the real modules.
    const env = { ...process.env, NODE_PATH: path.join(__dirname, "..", "node_modules") };
    for (const run of [1, 2]) {
      const r = await runScript(path.join(dir, "db.js"), [], { env });
      assert.equal(r.status, 0, `run ${run}: ${r.stderr}`);
    }
    const migrated = new Database(path.join(dir, "stride.db"), { readonly: true });
    try {
      assert.deepEqual(migrated.prepare("PRAGMA table_info(deletion_tombstones)").all().map((c) => c.name),
        ["id", "user_id", "entity_type", "entity_id", "deleted_at", "habit_id", "entry_date"]);
      assert.deepEqual(
        migrated.prepare("SELECT entity_type, entity_id, deleted_at, habit_id, entry_date FROM deletion_tombstones ORDER BY id").all().map((r) => ({ ...r })),
        ROWS.map(([entity_type, entity_id, deleted_at]) => ({ entity_type, entity_id, deleted_at, habit_id: null, entry_date: null })));
      assert.equal(migrated.pragma("integrity_check", { simple: true }), "ok");
    } finally {
      migrated.close();
    }
  });
});

// ===========================================================================
// E2E S9 URL cache — API answers are never stored (index.js). The apps' default URLCache kept
// the /v1/auth/verify answer (the live sessionToken) and /v1/sync/pull bodies in
// Caches/Cache.db, and revalidated GET /v1/auth/session with Express's weak ETag into a 304.
//
// Conditional requests go through node:http, not fetch: fetch adds `Cache-Control: no-cache` to
// any request carrying If-None-Match (the Fetch spec), and Express answers such a request 200
// whatever the ETag — so a "never a 304" case would pass for the wrong reason.
// ===========================================================================

const s9 = {
  /** A GET with exactly these headers, through node:http (see above). */
  raw(urlPath, headers = {}, base = BASE) {
    return new Promise((resolve, reject) => {
      const req = http.request(`${base}${urlPath}`, { method: "GET", headers, agent: false }, (res) => {
        let body = "";
        res.setEncoding("utf8");
        res.on("data", (d) => { body += d; });
        res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, body }));
      });
      req.on("error", reject);
      req.end();
    });
  },
  /** @param {Headers} headers a fetch response's */
  assertNoStore(headers, what) {
    assert.equal(headers.get("cache-control"), "no-store", `${what}: Cache-Control`);
    assert.equal(headers.get("etag"), null, `${what}: no ETag`);
  },
  /** What a revalidating cache sends: the weak ETag it stored, `*` (which Express answers with a
   * 304 even when it sent no ETag), and a date. */
  CONDITIONAL: [
    { "If-None-Match": 'W/"4c-Yt0uS1bAIOgRUPXxX1K9k0h6vL0"' },
    { "If-None-Match": "*" },
    { "If-Modified-Since": new Date(Date.now() + 86400000).toUTCString() },
  ],
};

describe("E2E S9 URL cache: every API answer is Cache-Control: no-store, with no ETag, and never a 304", () => {
  let u;
  before(async () => {
    u = m0.user();
    const H = m0.uuid();
    assert.equal((await m0.push(u.token, { habits: [m0.habit(H)], entries: [m0.entry(m0.uuid(), H, "2026-09-28")] })).status, 200);
  });
  after(() => m0.cleanup(u.userId));

  it("GET /v1/auth/session — the request the app revalidated into a 304", async () => {
    const r = await m0.req("GET", "/v1/auth/session", { token: u.token, client: s4.V130 });
    assert.equal(r.status, 200);
    assert.equal(r.json.user.id, u.userId);
    s9.assertNoStore(r.headers, "session");
  });

  it("GET /v1/auth/session revalidated with a stored ETag, `*` or a date: a 200 with the body, never a 304", async () => {
    for (const cond of s9.CONDITIONAL) {
      const r = await s9.raw("/v1/auth/session", { Authorization: `Bearer ${u.token}`, ...cond });
      assert.equal(r.status, 200, JSON.stringify(cond));
      assert.equal(JSON.parse(r.body).user.id, u.userId);
      assert.equal(r.headers["cache-control"], "no-store");
      assert.equal(r.headers.etag, undefined);
    }
  });

  it("GET /v1/sync/pull, full and ?since, for every app: no-store, no ETag, never a 304", async () => {
    for (const client of [undefined, s4.V130, s4.V131]) {
      for (const since of [undefined, "2026-01-01T00:00:00.000Z"]) {
        const r = await m0.req("GET", "/v1/sync/pull", { token: u.token, client, query: since ? { since } : undefined });
        assert.equal(r.status, 200);
        assert.equal(r.json.entries.length, 1);
        s9.assertNoStore(r.headers, `pull ${client ?? "no header"} ${since ? "since" : "full"}`);
      }
    }
    for (const cond of s9.CONDITIONAL) {
      const r = await s9.raw("/v1/sync/pull", { Authorization: `Bearer ${u.token}`, ...cond });
      assert.equal(r.status, 200, JSON.stringify(cond));
      assert.equal(JSON.parse(r.body).entries.length, 1);
      assert.equal(r.headers["cache-control"], "no-store");
      assert.equal(r.headers.etag, undefined);
    }
  });

  it("the push, the REST routes and the legacy mounts (/sync, /auth, /habits)", async () => {
    s9.assertNoStore((await m0.push(u.token, {})).headers, "push");
    s9.assertNoStore((await m0.req("GET", "/sync/pull", { token: u.token })).headers, "legacy /sync/pull");
    s9.assertNoStore((await m0.req("GET", "/auth/session", { token: u.token })).headers, "legacy /auth/session");
    s9.assertNoStore((await m0.req("GET", "/v1/habits", { token: u.token })).headers, "/v1/habits");
    s9.assertNoStore((await m0.req("GET", "/habits", { token: u.token })).headers, "legacy /habits");
  });

  it("error answers too: 400, 401, 404, and the pause switch's 503 from before any session lookup", async () => {
    const bad = await m0.push(u.token, { habits: "not an array" });
    assert.equal(bad.status, 400);
    s9.assertNoStore(bad.headers, "400 invalid_payload");
    const unauthorized = await m0.req("GET", "/v1/sync/pull");
    assert.equal(unauthorized.status, 401);
    s9.assertNoStore(unauthorized.headers, "401");
    const missing = await m0.req("GET", "/v1/no-such-route", { token: u.token });
    assert.equal(missing.status, 404);
    s9.assertNoStore(missing.headers, "404");
    fs.writeFileSync(PAUSE_FILE, "120");
    try {
      const paused = await m0.req("GET", "/v1/sync/pull", { token: u.token });
      assert.equal(paused.status, 503);
      s9.assertNoStore(paused.headers, "503 sync_paused");
    } finally {
      fs.rmSync(PAUSE_FILE, { force: true });
    }
  });

  describe("POST /v1/auth/verify, the answer that holds the session token (second server: the verify limiter has no test bypass, and the suite spends the main server's)", () => {
    const PORT2 = 3098, BASE2 = `http://localhost:${PORT2}`;
    let proc, user;
    before(async () => {
      user = createTestUser();
      proc = await m0.spawnServer(PORT2, {});
    });
    after(async () => { await m0.stopServer(proc); m0.cleanup(user.userId); });

    it("200 with the sessionToken: no-store, no ETag — and a refused one the same", async () => {
      const raw = crypto.randomBytes(32).toString("hex");
      db.prepare("INSERT INTO magic_link_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)")
        .run(user.userId, hashToken(raw), Date.now() + 30 * 60000);
      const r = await m0.req("POST", "/v1/auth/verify", { base: BASE2, client: s4.V130, body: { token: raw } });
      assert.equal(r.status, 200);
      assert.equal(typeof r.json.sessionToken, "string");
      s9.assertNoStore(r.headers, "verify");
      const again = await m0.req("POST", "/v1/auth/verify", { base: BASE2, body: { token: raw } });
      assert.equal(again.status, 400, "single use");
      s9.assertNoStore(again.headers, "verify 400");
    });
  });
});

describe("E2E S9 URL cache: what is not an API answer keeps its caching", () => {
  it("the AASA file: exactly application/json and no Cache-Control from us (Apple's CDN caches it by its own rules), GET and HEAD", async () => {
    for (const method of ["GET", "HEAD"]) {
      const r = await fetch(`${BASE}/.well-known/apple-app-site-association`, { method, redirect: "manual" });
      assert.equal(r.status, 200);
      assert.equal(r.headers.get("content-type"), "application/json");
      assert.equal(r.headers.get("cache-control"), null, method);
    }
  });

  it("the legal pages keep express.static's ETag and Last-Modified, and still revalidate to a 304", async () => {
    const first = await s9.raw("/privacy");
    assert.equal(first.status, 200);
    assert.ok(first.headers.etag, "serve-static's own ETag: app.set('etag', false) does not reach it");
    assert.ok(first.headers["last-modified"]);
    assert.notEqual(first.headers["cache-control"], "no-store");
    assert.equal((await s9.raw("/privacy", { "If-None-Match": first.headers.etag })).status, 304);
  });

  it("/login, which shows a live login token: no-store", async () => {
    const r = await fetch(`${BASE}/login?token=${"ab".repeat(32)}`);
    assert.equal(r.status, 200);
    s9.assertNoStore(r.headers, "/login");
  });

  it("/health: 200 as before, with no ETag (the switch is app-wide)", async () => {
    const r = await fetch(`${BASE}/health`);
    assert.equal(r.status, 200);
    assert.equal(r.headers.get("etag"), null);
  });
});
