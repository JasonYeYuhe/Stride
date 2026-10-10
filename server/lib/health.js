// @ts-check

/**
 * What GET /health proves about the database.
 *
 * It used to run `SELECT 1`, which only proves that a connection object exists: SQLite
 * answers it without opening a single table page. A server started against the wrong file
 * (an empty stride.db re-created in the wrong directory, a restore that copied the wrong
 * backup) or with a damaged table answered 200 while every sign-in and sync failed — and
 * /health is exactly what the uptime monitor and the deploy check (DEPLOY.md step 5) read.
 *
 * So it reads one row's worth of each table every request path needs: users + sessions
 * (sign-in, every authenticated call), habits + habit_entries (sync). `LIMIT 1` without an
 * ORDER BY reads the first leaf page of each b-tree — O(1) however big the table grows, which
 * matters because the monitor hits it every minute. A missing table fails at prepare, a
 * damaged first page or a locked file at run; both throw, and index.js answers 503.
 * Prepared per call on purpose: a statement cached at startup would hide a table dropped
 * afterwards until SQLite re-prepared it.
 */

const HEALTH_QUERY = `
  SELECT
    (SELECT 1 FROM users LIMIT 1)         AS users,
    (SELECT 1 FROM sessions LIMIT 1)      AS sessions,
    (SELECT 1 FROM habits LIMIT 1)        AS habits,
    (SELECT 1 FROM habit_entries LIMIT 1) AS habit_entries
`;

/**
 * Throws when the database cannot serve sign-in and sync; returns nothing otherwise. An empty
 * table is healthy (a fresh install has no users) — the check is that it exists and reads.
 * @param {import('better-sqlite3').Database} db
 */
function checkDatabase(db) {
  db.prepare(HEALTH_QUERY).get();
}

module.exports = { checkDatabase, HEALTH_QUERY };
