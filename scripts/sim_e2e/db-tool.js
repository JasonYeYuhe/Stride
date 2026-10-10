// @ts-check
// Accounts and read-only queries against a sim_e2e server COPY's throwaway database — the node
// half of login-token.sh, account.sh, session.sh and sql.sh. Never run it by hand on anything
// else: it refuses any database that is not <copy>/stride.db under $STRIDE_E2E_ROOT/servers/,
// so server/stride.db, a production copy or another tool's database can never gain an account,
// lose a session, or be queried by it.
//
//   node db-tool.js <copyDir> login-token <email>   stdout: the RAW token; stderr: {"userId","email"}
//   node db-tool.js <copyDir> lookup <id|email>     stdout: {"userId","email","sessions"} (exit 3: none)
//   node db-tool.js <copyDir> revoke-user <id|email> stdout: {"userId","email","revokedSessions"}
//   node db-tool.js <copyDir> sql "<SELECT …>" [--json]
//
// login-token writes exactly what server/auth.js createMagicLinkToken writes: the user (trimmed,
// lower-cased, INSERT OR IGNORE), and a magic_link_tokens row holding the sha256 of a 32-byte
// random hex token, expiring in 30 minutes (MAGIC_LINK_TTL_MS), single-use (is_reusable 0).
// The app's "I have a login token" field takes the raw token, as it does an emailed one.
// (Same inserts as scripts/sync_rehearsal/accounts.js and the server suite's helpers.)
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const MAGIC_LINK_TTL_MS = 1000 * 60 * 30; // server/auth.js

const [copyDir, command, arg, flag] = process.argv.slice(2);
const root = process.env.STRIDE_E2E_ROOT;

/** @param {string} msg @param {number} [code] @returns {never} */
function fail(msg, code = 64) {
  console.error(`db-tool: ${msg}`);
  process.exit(code);
}

if (!copyDir || !command || !root) {
  fail("usage: STRIDE_E2E_ROOT=<root> node db-tool.js <copyDir> login-token|lookup|revoke-user|sql …");
}

// The guard: resolved paths, so a symlink cannot point it elsewhere.
const serversRoot = fs.realpathSync(path.join(root, "servers"));
const copy = fs.realpathSync(copyDir);
if (!copy.startsWith(serversRoot + path.sep)) fail(`refusing ${copy}: not under ${serversRoot}`);
const dbPath = path.join(copy, "stride.db");
if (!fs.existsSync(dbPath)) fail(`no database at ${dbPath}: start the server once first`);
if (!fs.realpathSync(dbPath).startsWith(serversRoot + path.sep)) fail(`refusing ${dbPath}: resolves outside ${serversRoot}`);

const Database = require(path.join(copy, "node_modules", "better-sqlite3"));

/** @param {boolean} readonly */
function open(readonly) {
  const db = new Database(dbPath, { readonly, fileMustExist: true });
  db.pragma("busy_timeout = 5000");
  return db;
}

/** @param {any} db @param {string} who @returns {{ id: number, email: string } | undefined} */
function findUser(db, who) {
  if (/^\d+$/.test(who)) return db.prepare("SELECT id, email FROM users WHERE id = ?").get(Number(who));
  return db.prepare("SELECT id, email FROM users WHERE email = ?").get(who.trim().toLowerCase());
}

switch (command) {
  case "login-token": {
    if (!arg || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(arg.trim())) fail("login-token needs an email");
    const db = open(false);
    const email = arg.trim().toLowerCase();
    const token = crypto.randomBytes(32).toString("hex");
    const user = db.transaction(() => {
      db.prepare("INSERT OR IGNORE INTO users (email) VALUES (?)").run(email);
      const u = /** @type {{ id: number }} */ (db.prepare("SELECT id FROM users WHERE email = ?").get(email));
      db.prepare("INSERT INTO magic_link_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)")
        .run(u.id, crypto.createHash("sha256").update(token).digest("hex"), Date.now() + MAGIC_LINK_TTL_MS);
      return u;
    })();
    db.close();
    process.stdout.write(`${token}\n`);
    process.stderr.write(`${JSON.stringify({ userId: user.id, email })}\n`);
    break;
  }
  case "lookup": {
    if (!arg) fail("lookup needs a user id or email");
    const db = open(true);
    const user = findUser(db, arg);
    if (!user) { db.close(); fail(`no user ${arg}`, 3); }
    const { n } = /** @type {{ n: number }} */ (db.prepare("SELECT COUNT(*) AS n FROM sessions WHERE user_id = ? AND expires_at >= ?").get(user.id, Date.now()));
    db.close();
    process.stdout.write(`${JSON.stringify({ userId: user.id, email: user.email, sessions: n })}\n`);
    break;
  }
  case "revoke-user": {
    // What a sign-out on every device, or an expiry, leaves: the user's tokens name no session.
    if (!arg) fail("revoke-user needs a user id or email");
    const db = open(false);
    const user = findUser(db, arg);
    if (!user) { db.close(); fail(`no user ${arg}`, 3); }
    const { changes } = db.prepare("DELETE FROM sessions WHERE user_id = ?").run(user.id);
    db.close();
    process.stdout.write(`${JSON.stringify({ userId: user.id, email: user.email, revokedSessions: changes })}\n`);
    break;
  }
  case "sql": {
    if (!arg) fail('sql needs a statement, e.g. "SELECT id, email FROM users"');
    const db = open(true); // readonly: a write fails even if it gets past the reader check
    let stmt;
    try {
      stmt = db.prepare(arg);
    } catch (err) {
      fail(`sql: ${/** @type {Error} */ (err).message}`, 65);
    }
    if (!stmt.reader) fail("sql: read-only statements only (SELECT / PRAGMA / WITH … SELECT)", 65);
    const rows = stmt.all();
    if (flag === "--json") {
      for (const row of rows) process.stdout.write(`${JSON.stringify(row)}\n`);
    } else {
      const cols = stmt.columns().map((/** @type {{ name: string }} */ c) => c.name);
      process.stdout.write(`${cols.join("|")}\n`);
      for (const row of rows) {
        process.stdout.write(`${cols.map((c) => (row[c] === null ? "NULL" : String(row[c]))).join("|")}\n`);
      }
    }
    db.close();
    break;
  }
  default:
    fail(`unknown command ${command}`);
}
