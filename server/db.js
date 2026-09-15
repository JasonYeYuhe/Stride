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
    entity_type TEXT NOT NULL,  -- 'habit' or 'entry'
    entity_id  TEXT NOT NULL,
    deleted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
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

/**
 * Garbage-collect stale rows so unbounded tables (tombstones, expired
 * sessions / magic links) don't grow forever and slow down sync pulls.
 *
 * Tombstones are retained for `tombstoneRetentionDays` (default 90) — longer
 * than any plausible client offline window — so a device that's been offline
 * for weeks still learns about deletions on its next incremental pull.
 *
 * @param {{ tombstoneRetentionDays?: number }} [opts]
 * @returns {{ tombstones: number, sessions: number, magicLinks: number }}
 */
function sweepStaleData(opts = {}) {
  const retentionDays = opts.tombstoneRetentionDays ?? 90;
  const cutoffIso = new Date(Date.now() - retentionDays * 86400000).toISOString();
  const nowMs = Date.now();

  const sweep = db.transaction(() => {
    const t = db.prepare("DELETE FROM deletion_tombstones WHERE deleted_at < ?").run(cutoffIso);
    const s = db.prepare("DELETE FROM sessions WHERE expires_at < ?").run(nowMs);
    // Expired magic links, plus single-use links that were already consumed > 1 day ago.
    const m = db.prepare(
      "DELETE FROM magic_link_tokens WHERE expires_at < ? OR (is_reusable = 0 AND used_at IS NOT NULL)"
    ).run(nowMs);
    return { tombstones: t.changes, sessions: s.changes, magicLinks: m.changes };
  });

  return sweep();
}

/** @type {any} */ (db).sweepStaleData = sweepStaleData;

module.exports = db;
