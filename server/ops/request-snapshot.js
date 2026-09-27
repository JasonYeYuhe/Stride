#!/usr/bin/env node
// @ts-check
/**
 * request-snapshot.js — ask ONE account's next 1.3.1+ device to re-upload everything.
 *
 * Usage (on the host, from /root/stride-server):
 *   node ops/request-snapshot.js <email> [note]    set the request (re-arms an answered one)
 *   node ops/request-snapshot.js --clear <email>   withdraw it, pending or answered
 *   node ops/request-snapshot.js --list            show pending and answered requests
 *
 * For support: an account whose server copy is missing rows the user still has on a device.
 * The next push or pull from that account by an app >= 1.3.1 is answered
 * `409 snapshot_required`; that device marks every local row dirty and uploads them all.
 * One-shot: the request is then marked answered — when, and to which build — and not
 * answered again. Answered is not the same as repaired: the 409 can be lost on the way (a
 * timeout, the app suspended), so check the account's rows, and if the re-upload never came,
 * run this again for the email to re-arm it. Answered requests drop out of --list after 90
 * days (db.js sweepStaleData). Apps before 1.3.1 already push everything on every sync, never
 * see the 409 and leave the request pending for a newer device.
 *
 * Deliberately per account. A "everyone re-upload" switch would have every installed app
 * push its whole history in the same minute; to take load OFF the server, use the pause
 * switch (lib/syncPause.js) instead.
 *
 * Opens the database the way seed-demo.js does (./db, which also runs the idempotent
 * startup migrations), so it works with the server running (WAL).
 */

const db = require("../db");

const USAGE = "usage: node ops/request-snapshot.js <email> [note] | --clear <email> | --list";

/** Stored emails are trimmed and lower-cased (auth.js getOrCreateUser).
 * @param {string} email @returns {{ id: number, email: string } | undefined} */
function findUser(email) {
  return /** @type {any} */ (db.prepare("SELECT id, email FROM users WHERE email = ?").get(email.trim().toLowerCase()));
}

function main() {
  const [first, second, ...rest] = process.argv.slice(2);
  if (!first || first === "--help" || first === "-h") {
    console.log(USAGE);
    return first ? 0 : 2;
  }

  if (first === "--list") {
    const rows = /** @type {{ email: string, requested_at: string, note: string|null, answered_at: string|null, answered_client: string|null }[]} */ (db.prepare(`
      SELECT u.email, r.requested_at, r.note, r.answered_at, r.answered_client
      FROM sync_snapshot_requests r JOIN users u ON u.id = r.user_id
      ORDER BY r.requested_at
    `).all());
    if (rows.length === 0) console.log("No snapshot requests.");
    for (const r of rows) {
      const state = r.answered_at ? `answered ${r.answered_at} to ${r.answered_client}` : "pending";
      console.log(`${r.requested_at}  ${r.email}  ${state}${r.note ? `  — ${r.note}` : ""}`);
    }
    return 0;
  }

  if (first === "--clear") {
    if (!second) { console.error(USAGE); return 2; }
    const user = findUser(second);
    if (!user) { console.error(`No account for ${second}`); return 1; }
    const { changes } = db.prepare("DELETE FROM sync_snapshot_requests WHERE user_id = ?").run(user.id);
    console.log(changes ? `Cleared the snapshot request for ${user.email}.` : `${user.email} had no request.`);
    return 0;
  }

  if (first.startsWith("--")) { console.error(USAGE); return 2; }
  const user = findUser(first);
  if (!user) { console.error(`No account for ${first}`); return 1; }
  const note = [second, ...rest].filter(Boolean).join(" ") || null;
  db.prepare(`
    INSERT INTO sync_snapshot_requests (user_id, requested_at, note) VALUES (?, ?, ?)
    ON CONFLICT(user_id) DO UPDATE SET requested_at = excluded.requested_at, note = excluded.note,
      answered_at = NULL, answered_client = NULL
  `).run(user.id, new Date().toISOString(), note);
  console.log(`Snapshot requested for ${user.email} (user ${user.id}). ` +
    "Its next sync from an app >= 1.3.1 re-uploads everything; older apps are unaffected.");
  return 0;
}

const code = main();
db.close();
process.exit(code);
