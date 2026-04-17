// @ts-check
const Database = require("better-sqlite3");
const path = require("path");

/** @typedef {{ name: string, type: string, notnull: number, dflt_value: string|null, pk: number }} PragmaColumn */

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
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    FOREIGN KEY (user_id) REFERENCES users(id)
  );

  CREATE TABLE IF NOT EXISTS habit_entries (
    id        TEXT PRIMARY KEY,
    habit_id  TEXT NOT NULL,
    date      TEXT NOT NULL,
    note      TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    FOREIGN KEY (habit_id) REFERENCES habits(id) ON DELETE CASCADE,
    UNIQUE(habit_id, date)
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

  CREATE INDEX IF NOT EXISTS idx_habits_user ON habits(user_id);
  CREATE INDEX IF NOT EXISTS idx_entries_habit ON habit_entries(habit_id);
  CREATE INDEX IF NOT EXISTS idx_entries_date ON habit_entries(date);
  CREATE INDEX IF NOT EXISTS idx_tombstones_user ON deletion_tombstones(user_id);
  CREATE INDEX IF NOT EXISTS idx_tombstones_deleted_at ON deletion_tombstones(deleted_at);
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

  const entryCols = db.prepare("PRAGMA table_info(habit_entries)").all().map((c) => /** @type {PragmaColumn} */ (c).name);
  if (!entryCols.includes("note")) {
    db.exec("ALTER TABLE habit_entries ADD COLUMN note TEXT");
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
});
migrateIfNeeded();

module.exports = db;
