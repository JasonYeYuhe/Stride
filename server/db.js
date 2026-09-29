// @ts-check
const Database = require("better-sqlite3");
const path = require("path");

/** @typedef {{ name: string, type: string, notnull: number, dflt_value: string|null, pk: number }} PragmaColumn */

const { canonicalizeIds } = require("./migrations/canonicalizeIds");
const db = new Database(path.join(__dirname, "stride.db"));

db.pragma("journal_mode = WAL");
db.pragma("foreign_keys = ON");

db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    email      TEXT UNIQUE NOT NULL,
    tier       TEXT NOT NULL DEFAULT 'free',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );

  CREATE TABLE IF NOT EXISTS magic_link_tokens (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER NOT NULL,
    token_hash  TEXT UNIQUE NOT NULL,
    expires_at  INTEGER NOT NULL,
    used_at     TEXT,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
  );

  CREATE TABLE IF NOT EXISTS sessions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER NOT NULL,
    token_hash  TEXT UNIQUE NOT NULL,
    expires_at  INTEGER NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
  );

  CREATE TABLE IF NOT EXISTS habits (
    id          TEXT PRIMARY KEY,
    user_id     INTEGER NOT NULL,
    name        TEXT NOT NULL,
    emoji       TEXT NOT NULL DEFAULT '⭐',
    color_hex   TEXT NOT NULL DEFAULT '#34C759',
    is_archived INTEGER NOT NULL DEFAULT 0,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    reminder_enabled INTEGER NOT NULL DEFAULT 0,
    reminder_hour    INTEGER NOT NULL DEFAULT 20,
    reminder_minute  INTEGER NOT NULL DEFAULT 0,
    note        TEXT,
    kind            TEXT NOT NULL DEFAULT 'binary',
    target_value    REAL NOT NULL DEFAULT 1,
    unit            TEXT,
    schedule_kind   TEXT NOT NULL DEFAULT 'daily',
    times_per_week  INTEGER NOT NULL DEFAULT 7,
    active_days_mask INTEGER NOT NULL DEFAULT 127,
    group_id        TEXT,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS habit_entries (
    id        TEXT PRIMARY KEY,
    habit_id  TEXT NOT NULL,
    date      TEXT NOT NULL,
    note      TEXT,
    value     REAL NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    FOREIGN KEY (habit_id) REFERENCES habits(id) ON DELETE CASCADE,
    UNIQUE(habit_id, date)
  );

  CREATE TABLE IF NOT EXISTS habit_groups (
    id          TEXT PRIMARY KEY,
    user_id     INTEGER NOT NULL,
    name        TEXT NOT NULL,
    color_hex   TEXT NOT NULL DEFAULT '#34C759',
    sort_order  REAL NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
  );

  -- Tombstones track deletions so other devices can pick them up on pull
  CREATE TABLE IF NOT EXISTS deletion_tombstones (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL,
    entity_type TEXT NOT NULL,  -- 'habit', 'entry' or 'group'
    entity_id  TEXT NOT NULL,
    deleted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    -- An 'entry' row's habit and day, copied from the row it deleted (E2E S4, routes/sync.js
    -- pull). NULL on habit and group rows, on rows from before the 1.3.1 server, and when the
    -- server no longer held the entry. Added by migrateIfNeeded on an existing database.
    habit_id   TEXT,
    entry_date TEXT,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
  );

  -- Per-account "re-upload everything" requests, set by ops/request-snapshot.js and answered
  -- by the account's next push or pull from a 1.3.1+ app (409 snapshot_required, one-shot).
  -- Answering stamps answered_at / answered_client rather than deleting the row, so support
  -- can see whether and to which build it went out. Support use only: see routes/sync.js.
  CREATE TABLE IF NOT EXISTS sync_snapshot_requests (
    user_id         INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    requested_at    TEXT NOT NULL,
    note            TEXT,
    answered_at     TEXT,
    answered_client TEXT
  );

  -- Hourly usage counters flushed by metrics.js (see its header for what they decide).
  -- hour is UTC 'YYYY-MM-DDTHH'; flushes add to the row, never overwrite it. Kept 400 days
  -- (sweepStaleData), because the logs they are also written to rotate after ~30.
  CREATE TABLE IF NOT EXISTS usage_counters (
    hour  TEXT NOT NULL,
    name  TEXT NOT NULL,
    value INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (hour, name)
  );

  -- Which app builds each account syncs from: one row per (account, client), first and last
  -- seen. Written by metrics.js at flush time, not per request. A legacy app (no or malformed
  -- X-Stride-Client) is platform 'legacy', version '', build 0 — not NULL, which SQLite treats
  -- as distinct in a key, so every flush would add a row instead of updating the one there.
  -- Goes with the account (ON DELETE CASCADE): it is about a person, not about the fleet.
  CREATE TABLE IF NOT EXISTS user_clients (
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    platform   TEXT NOT NULL,
    version    TEXT NOT NULL,
    build      INTEGER NOT NULL,
    first_seen TEXT NOT NULL,
    last_seen  TEXT NOT NULL,
    PRIMARY KEY (user_id, platform, version, build)
  );
`);

// Migrate existing databases: add new columns if missing
const migrateIfNeeded = db.transaction(() => {
  // Add reusable flag for demo/review magic link tokens
  const mlCols = db.prepare("PRAGMA table_info(magic_link_tokens)").all().map((c) => /** @type {PragmaColumn} */ (c).name);
  if (!mlCols.includes("is_reusable")) {
    db.exec("ALTER TABLE magic_link_tokens ADD COLUMN is_reusable INTEGER NOT NULL DEFAULT 0");
  }

  const habitCols = db.prepare("PRAGMA table_info(habits)").all().map((c) => /** @type {PragmaColumn} */ (c).name);
  if (!habitCols.includes("reminder_enabled")) {
    db.exec("ALTER TABLE habits ADD COLUMN reminder_enabled INTEGER NOT NULL DEFAULT 0");
  }
  if (!habitCols.includes("reminder_hour")) {
    db.exec("ALTER TABLE habits ADD COLUMN reminder_hour INTEGER NOT NULL DEFAULT 20");
  }
  if (!habitCols.includes("reminder_minute")) {
    db.exec("ALTER TABLE habits ADD COLUMN reminder_minute INTEGER NOT NULL DEFAULT 0");
  }
  if (!habitCols.includes("note")) {
    db.exec("ALTER TABLE habits ADD COLUMN note TEXT");
  }

  // v2: quantitative + scheduling + grouping columns on habits
  const v2HabitCols = {
    kind: "ALTER TABLE habits ADD COLUMN kind TEXT NOT NULL DEFAULT 'binary'",
    target_value: "ALTER TABLE habits ADD COLUMN target_value REAL NOT NULL DEFAULT 1",
    unit: "ALTER TABLE habits ADD COLUMN unit TEXT",
    schedule_kind: "ALTER TABLE habits ADD COLUMN schedule_kind TEXT NOT NULL DEFAULT 'daily'",
    times_per_week: "ALTER TABLE habits ADD COLUMN times_per_week INTEGER NOT NULL DEFAULT 7",
    active_days_mask: "ALTER TABLE habits ADD COLUMN active_days_mask INTEGER NOT NULL DEFAULT 127",
    group_id: "ALTER TABLE habits ADD COLUMN group_id TEXT",
  };
  for (const [col, sql] of Object.entries(v2HabitCols)) {
    if (!habitCols.includes(col)) db.exec(sql);
  }

  const entryCols = db.prepare("PRAGMA table_info(habit_entries)").all().map((c) => /** @type {PragmaColumn} */ (c).name);
  if (!entryCols.includes("note")) {
    db.exec("ALTER TABLE habit_entries ADD COLUMN note TEXT");
  }
  if (!entryCols.includes("updated_at")) {
    // SQLite forbids a non-constant default in ALTER TABLE ADD COLUMN (the fresh
    // CREATE TABLE uses DEFAULT (strftime(...)), which is only legal there). Add
    // the column nullable and backfill from created_at; every insert path sets
    // updated_at explicitly, so the missing NOT NULL/default isn't observable.
    db.exec("ALTER TABLE habit_entries ADD COLUMN updated_at TEXT");
    db.exec("UPDATE habit_entries SET updated_at = created_at");
  }
  if (!entryCols.includes("value")) {
    db.exec("ALTER TABLE habit_entries ADD COLUMN value REAL NOT NULL DEFAULT 1");
  }

  // Convert legacy space-separated timestamps (YYYY-MM-DD HH:MM:SS) to ISO8601.
  // Only touches rows that have the old format (contain a space but no 'T').
  db.exec(`
    UPDATE habits SET
      created_at = REPLACE(created_at, ' ', 'T') || 'Z',
      updated_at = REPLACE(updated_at, ' ', 'T') || 'Z'
    WHERE created_at LIKE '%-%-% %:%:%' AND created_at NOT LIKE '%T%';

    UPDATE habit_entries SET
      created_at = REPLACE(created_at, ' ', 'T') || 'Z'
    WHERE created_at LIKE '%-%-% %:%:%' AND created_at NOT LIKE '%T%';

    UPDATE deletion_tombstones SET
      deleted_at = REPLACE(deleted_at, ' ', 'T') || 'Z'
    WHERE deleted_at LIKE '%-%-% %:%:%' AND deleted_at NOT LIKE '%T%';
  `);

  // seed-demo.js inserted entries without updated_at, and on a database upgraded from before
  // that column existed it is nullable, so production's demo check-ins had none: invisible to
  // every ?since pull, and (below) no edit time to compare against.
  db.exec("UPDATE habit_entries SET updated_at = created_at WHERE updated_at IS NULL");

  // Edit time, kept apart from change time — see "Two clocks" in routes/sync.js. Backfilled
  // from updated_at, which for habits and groups already WAS the device's edit time, and
  // normalised to toISOString() format so string comparison orders it correctly.
  for (const table of ["habits", "habit_entries", "habit_groups"]) {
    const cols = db.prepare(`PRAGMA table_info(${table})`).all().map((c) => /** @type {PragmaColumn} */ (c).name);
    if (!cols.includes("client_updated_at")) {
      db.exec(`ALTER TABLE ${table} ADD COLUMN client_updated_at TEXT`);
      db.exec(`UPDATE ${table} SET client_updated_at = COALESCE(strftime('%Y-%m-%dT%H:%M:%fZ', updated_at), updated_at)`);
    }
  }

  // sync_snapshot_requests first shipped (unreleased) without the answered_* columns, which
  // any dev or rehearsal database created from that code still lacks.
  const snapCols = db.prepare("PRAGMA table_info(sync_snapshot_requests)").all().map((c) => /** @type {PragmaColumn} */ (c).name);
  if (!snapCols.includes("answered_at")) db.exec("ALTER TABLE sync_snapshot_requests ADD COLUMN answered_at TEXT");
  if (!snapCols.includes("answered_client")) db.exec("ALTER TABLE sync_snapshot_requests ADD COLUMN answered_client TEXT");

  // E2E S4 (the 1.3.1 server): an entry tombstone names the deleted row's habit and day, so a
  // pull can hold the deletion back from an app below 1.3.1 when the same response carries that
  // day's replacement (routes/sync.js). Nullable with no default, so this is additive: every
  // existing tombstone keeps NULL, which the pull treats exactly as before. Before
  // canonicalizeIds, which upper-cases habit_id along with the ids it mirrors.
  const tombCols = db.prepare("PRAGMA table_info(deletion_tombstones)").all().map((c) => /** @type {PragmaColumn} */ (c).name);
  if (!tombCols.includes("habit_id")) db.exec("ALTER TABLE deletion_tombstones ADD COLUMN habit_id TEXT");
  if (!tombCols.includes("entry_date")) db.exec("ALTER TABLE deletion_tombstones ADD COLUMN entry_date TEXT");

  // Upper-case every stored id so server-generated (lower-case) ids match what the apps
  // send. See migrations/canonicalizeIds.js — it needs this surrounding transaction.
  canonicalizeIds(db);
});
migrateIfNeeded();

// Indexes are created AFTER migrations so they can reference columns that
// migrateIfNeeded() adds on upgraded databases (e.g. habit_entries.updated_at).
// On a fresh DB these columns already exist from the CREATE TABLE above; on a
// pre-v2 DB the migration adds them first. Defining idx_entries_habit_updated in
// the initial schema block fails with "no such column: updated_at" against an
// existing pre-v2 database.
db.exec(`
  CREATE INDEX IF NOT EXISTS idx_habits_user ON habits(user_id);
  CREATE INDEX IF NOT EXISTS idx_entries_habit ON habit_entries(habit_id);
  CREATE INDEX IF NOT EXISTS idx_entries_date ON habit_entries(date);
  -- Serves the incremental ?since pull (WHERE habit_id IN (...) AND updated_at > ?)
  CREATE INDEX IF NOT EXISTS idx_entries_habit_updated ON habit_entries(habit_id, updated_at);
  CREATE INDEX IF NOT EXISTS idx_tombstones_user ON deletion_tombstones(user_id);
  CREATE INDEX IF NOT EXISTS idx_tombstones_deleted_at ON deletion_tombstones(deleted_at);
  CREATE INDEX IF NOT EXISTS idx_groups_user ON habit_groups(user_id);
  -- Serve expiry sweeps
  CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
  CREATE INDEX IF NOT EXISTS idx_magic_expires ON magic_link_tokens(expires_at);
`);

/** How long metrics.js's usage_counters and user_clients rows are kept. */
const USAGE_RETENTION_DAYS = 400;

/** How long an answered snapshot request stays visible to `ops/request-snapshot.js --list`. */
const ANSWERED_SNAPSHOT_RETENTION_DAYS = 90;

/**
 * Garbage-collect expired sessions and magic links.
 *
 * Deletion tombstones are NOT swept unless a caller asks (`tombstoneRetentionDays`). They
 * were swept after 90 days until 1.3, and every sweep was a resurrection window: an app up to
 * 1.3.0 that pulls with a cursor older than the oldest remaining tombstone never learns about
 * the deletions that were swept, keeps those rows, and pushes them straight back in its next
 * full snapshot — a habit deleted on the phone reappears from the iPad that was in a drawer
 * for four months. Those apps have no way to be told their cursor is too old: the
 * `cursor_expired` 409 is gated on an X-Stride-Client header >= 1.3.1, which <= 1.2.3 does not
 * send and 1.3.0 sends below the gate (it has no handler either). A tombstone is ~100 bytes,
 * so keeping all of them costs nothing.
 *
 * What turns sweeping back on: a 426 minimum-version floor that retires every app <= 1.3.0,
 * i.e. a floor of at least 1.3.1 (decided from the usage report's < 1.3.1 cohort, not a date).
 * After that, sweep at CURSOR_RETENTION_DAYS (365, routes/sync.js) — every client left handles
 * cursor_expired.
 *
 * Also drops usage counters and client-cohort rows (metrics.js) older than
 * USAGE_RETENTION_DAYS: long enough to compare a year against the year before, short enough
 * that a departed user's app version does not sit here forever. And snapshot requests answered
 * more than ANSWERED_SNAPSHOT_RETENTION_DAYS ago (pending ones stay until answered or cleared).
 *
 * @param {{ tombstoneRetentionDays?: number }} [opts] retention in days; omit to keep all tombstones
 * @returns {{ tombstones: number, sessions: number, magicLinks: number, usageCounters: number, userClients: number, snapshotRequests: number }}
 */
function sweepStaleData(opts = {}) {
  const retentionDays = opts.tombstoneRetentionDays;
  const nowMs = Date.now();

  const sweep = db.transaction(() => {
    const t = retentionDays === undefined
      ? { changes: 0 }
      : db.prepare("DELETE FROM deletion_tombstones WHERE deleted_at < ?")
        .run(new Date(nowMs - retentionDays * 86400000).toISOString());
    const s = db.prepare("DELETE FROM sessions WHERE expires_at < ?").run(nowMs);
    // Expired magic links, plus single-use links that were already consumed > 1 day ago.
    const m = db.prepare(
      "DELETE FROM magic_link_tokens WHERE expires_at < ? OR (is_reusable = 0 AND used_at IS NOT NULL)"
    ).run(nowMs);
    const usageCutoff = new Date(nowMs - USAGE_RETENTION_DAYS * 86400000).toISOString();
    // usage_counters.hour is 'YYYY-MM-DDTHH', a prefix of toISOString(), so it compares as one.
    const u = db.prepare("DELETE FROM usage_counters WHERE hour < ?").run(usageCutoff.slice(0, 13));
    const c = db.prepare("DELETE FROM user_clients WHERE last_seen < ?").run(usageCutoff);
    const r = db.prepare("DELETE FROM sync_snapshot_requests WHERE answered_at < ?")
      .run(new Date(nowMs - ANSWERED_SNAPSHOT_RETENTION_DAYS * 86400000).toISOString());
    return {
      tombstones: t.changes, sessions: s.changes, magicLinks: m.changes,
      usageCounters: u.changes, userClients: c.changes, snapshotRequests: r.changes,
    };
  });

  return sweep();
}

/** @type {any} */ (db).sweepStaleData = sweepStaleData;

module.exports = db;
