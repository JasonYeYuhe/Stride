// @ts-check
// Test accounts and fault injection for scripts/sync_rehearsal.sh, straight into the
// THROWAWAY database of the rehearsal's local server — the same inserts as the server suite's
// createTestUser / createTestSession (server/test/api.test.js), so no magic-link email is ever
// involved. It refuses any database that is not under the rehearsal's temp directory: the
// server hard-codes <dir>/stride.db, and server/stride.db (or a production copy) must never
// gain a test account or a trigger.
//
//   node accounts.js <serverDir> create            → {"userId":…, "email":…, "token":…}
//   node accounts.js <serverDir> row-error-trigger → installs the row_error injection (below)
//   node accounts.js <serverDir> request-snapshot <userId> → arms 409 snapshot_required, as
//                                                   ops/request-snapshot.js does for support
//   node accounts.js <serverDir> revoke-session <token>    → the session is gone server-side
"use strict";
const path = require("node:path");
const crypto = require("node:crypto");

const [serverDir, command, arg] = process.argv.slice(2);
const rehearsalRoot = process.env.STRIDE_REHEARSAL_ROOT;
if (!serverDir || !command || !rehearsalRoot) {
  console.error("usage: STRIDE_REHEARSAL_ROOT=<tmp> node accounts.js <serverDir> create|row-error-trigger|request-snapshot <userId>|revoke-session <token>");
  process.exit(64);
}
const resolved = path.resolve(serverDir);
if (!resolved.startsWith(path.resolve(rehearsalRoot) + path.sep)) {
  console.error(`refusing ${resolved}: not under the rehearsal's temp directory`);
  process.exit(64);
}

const Database = require(path.join(resolved, "node_modules", "better-sqlite3"));
const db = new Database(path.join(resolved, "stride.db"));
db.pragma("journal_mode = WAL");
db.pragma("busy_timeout = 5000");

switch (command) {
  case "create": {
    const email = `rehearsal-${crypto.randomUUID()}@stride-test.local`;
    db.prepare("INSERT INTO users (email) VALUES (?)").run(email);
    const user = /** @type {{ id: number }} */ (db.prepare("SELECT id FROM users WHERE email = ?").get(email));
    const token = crypto.randomBytes(32).toString("hex");
    const tokenHash = crypto.createHash("sha256").update(token).digest("hex");
    db.prepare("INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)")
      .run(user.id, tokenHash, Date.now() + 24 * 60 * 60 * 1000);
    process.stdout.write(JSON.stringify({ userId: user.id, email, token }));
    break;
  }
  case "row-error-trigger": {
    // A real SQLite refusal inside the push transaction, for one marked entry: RAISE(ABORT)
    // fails with SQLITE_CONSTRAINT_TRIGGER, which routes/sync.js isRowError() catches per row
    // and answers `row_error` — the path a constraint violation on production takes. Only an
    // INSERT carrying the marker note is refused, so an edit of the note lifts it, as an edit
    // lifts the hold on the device.
    db.exec(`CREATE TRIGGER IF NOT EXISTS rehearsal_row_error BEFORE INSERT ON habit_entries
             WHEN NEW.note = 'REHEARSAL_ROW_ERROR'
             BEGIN SELECT RAISE(ABORT, 'rehearsal: injected row_error'); END;`);
    process.stdout.write("{}");
    break;
  }
  case "request-snapshot": {
    // The row ops/request-snapshot.js writes: the account's next push or pull from a 1.3.1+
    // app is answered 409 snapshot_required, once.
    const userId = Number(arg);
    if (!Number.isSafeInteger(userId)) { console.error("request-snapshot needs a user id"); process.exit(64); }
    db.prepare(`INSERT INTO sync_snapshot_requests (user_id, requested_at, note) VALUES (?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET requested_at = excluded.requested_at,
                  note = excluded.note, answered_at = NULL, answered_client = NULL`)
      .run(userId, new Date().toISOString(), "sync rehearsal");
    process.stdout.write("{}");
    break;
  }
  case "revoke-session": {
    // What a sign-out elsewhere or an expiry does: the token no longer names a session.
    if (!arg) { console.error("revoke-session needs a token"); process.exit(64); }
    const tokenHash = crypto.createHash("sha256").update(arg).digest("hex");
    const { changes } = db.prepare("DELETE FROM sessions WHERE token_hash = ?").run(tokenHash);
    process.stdout.write(JSON.stringify({ revoked: changes }));
    break;
  }
  default:
    console.error(`unknown command ${command}`);
    process.exit(64);
}
db.close();
