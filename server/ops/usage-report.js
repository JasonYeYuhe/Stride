#!/usr/bin/env node
// @ts-check
/**
 * usage-report.js — who still runs which app, and which compatibility shims are still hit.
 *
 * Usage (on the host, from /root/stride-server, or on a laptop against a production copy):
 *   node ops/usage-report.js [--days N] [--db path/to/stride.db]
 *
 * Reads what metrics.js has flushed (hourly, and on every restart), so it trails the live
 * process by up to an hour. Three sections:
 *   1. Active accounts per client version over the last 7 / 28 / 56 days, from user_clients
 *      (accounts that synced from that build; `legacy` = no X-Stride-Client, i.e. <= 1.2.3).
 *   2. Accounts still on a client that is legacy or older than 1.3.1 — both "their most recent
 *      client is" (the brief's number) and "any of their clients is" (the one that gates the
 *      426 floor: one forgotten iPad on 1.2.3 still pushes full snapshots and would resurrect
 *      swept tombstones). Account ids only; look an id up by hand if support needs the email.
 *   3. Counter totals per UTC day for the last N days (default 56 — the M6 gate's eight
 *      weeks), from usage_counters.
 *
 * These numbers, not a date, decide when the snake_case shim, the legacy mounts, the 426
 * floor and tombstone sweeping can go (see metrics.js).
 *
 * Opens the database read-only and directly, not through ./db: it runs no migrations, so it
 * is safe on a production copy and cannot change the live file.
 */

const path = require("path");
const Database = require("better-sqlite3");

const USAGE = "usage: node ops/usage-report.js [--days N] [--db path/to/stride.db]";
const WINDOWS = [7, 28, 56];
/** The first version that pushes incrementally and handles every M0 contract. */
const CURRENT_FLOOR = [1, 3, 1];

/** @typedef {{ user_id: number, platform: string, version: string, build: number, first_seen: string, last_seen: string }} UserClientRow */

/** @param {string} version "1.3.1" or "" (legacy) @returns {boolean} */
function beforeFloor(version) {
  if (!version) return true;
  const parts = version.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    const a = parts[i] ?? 0;
    if (a !== CURRENT_FLOOR[i]) return a < CURRENT_FLOOR[i];
  }
  return false;
}

/** @param {UserClientRow} r */
const clientName = (r) => (r.platform === "legacy" ? "legacy" : `${r.platform}/${r.version}`);

/** @param {string[]} argv */
function parseArgs(argv) {
  const opts = { days: 56, db: path.join(__dirname, "..", "stride.db") };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--days") opts.days = Number(argv[++i]);
    else if (a === "--db") opts.db = argv[++i];
    else return null;
  }
  if (!Number.isInteger(opts.days) || opts.days < 1 || !opts.db) return null;
  return opts;
}

/** @param {number} days */
const since = (days) => new Date(Date.now() - days * 86400000).toISOString();

/** @param {import('better-sqlite3').Database} db */
function reportClients(db) {
  const rows = /** @type {UserClientRow[]} */ (db.prepare(
    "SELECT user_id, platform, version, build, first_seen, last_seen FROM user_clients WHERE last_seen >= ?",
  ).all(since(Math.max(...WINDOWS))));

  console.log(`Active accounts by client (distinct accounts that synced from it)`);
  /** @type {Map<string, Set<number>[]>} */
  const byClient = new Map();
  const anyClient = WINDOWS.map(() => new Set());
  const cutoffs = WINDOWS.map(since);
  for (const r of rows) {
    const name = clientName(r);
    if (!byClient.has(name)) byClient.set(name, WINDOWS.map(() => new Set()));
    cutoffs.forEach((cutoff, i) => {
      if (r.last_seen >= cutoff) { byClient.get(name)[i].add(r.user_id); anyClient[i].add(r.user_id); }
    });
  }
  const header = ["client".padEnd(20), ...WINDOWS.map((d) => `${d}d`.padStart(6))].join("");
  console.log(`  ${header}`);
  const names = [...byClient.keys()].sort();
  if (names.length === 0) console.log("  (no sync recorded yet)");
  for (const name of names) {
    console.log(`  ${name.padEnd(20)}${byClient.get(name).map((s) => String(s.size).padStart(6)).join("")}`);
  }
  console.log(`  ${"(any client)".padEnd(20)}${anyClient.map((s) => String(s.size).padStart(6)).join("")}`);

  const floor = CURRENT_FLOOR.join(".");
  console.log(`\nAccounts on a legacy or < ${floor} client (last ${Math.max(...WINDOWS)} days)`);
  /** @type {Map<number, UserClientRow>} */
  const latest = new Map();
  const anyOld = new Set();
  for (const r of rows) {
    const cur = latest.get(r.user_id);
    if (!cur || r.last_seen > cur.last_seen) latest.set(r.user_id, r);
    if (beforeFloor(r.version)) anyOld.add(r.user_id);
  }
  const latestOld = [...latest.values()].filter((r) => beforeFloor(r.version)).map((r) => r.user_id);
  /** @param {Iterable<number>} ids */
  const list = (ids) => {
    const all = [...ids].sort((a, b) => a - b);
    return all.length === 0 ? "" : `  ids: ${all.slice(0, 50).join(", ")}${all.length > 50 ? `, … (${all.length - 50} more)` : ""}`;
  };
  console.log(`  most recent client is:  ${latestOld.length}${list(latestOld)}`);
  console.log(`  any client is:          ${anyOld.size}${list(anyOld)}`);
}

/** @param {import('better-sqlite3').Database} db @param {number} days */
function reportCounters(db, days) {
  const rows = /** @type {{ day: string, name: string, total: number }[]} */ (db.prepare(`
    SELECT substr(hour, 1, 10) AS day, name, SUM(value) AS total
    FROM usage_counters WHERE hour >= ?
    GROUP BY day, name ORDER BY day DESC, name
  `).all(since(days).slice(0, 13)));

  console.log(`\nCounters by UTC day (last ${days} days)`);
  if (rows.length === 0) console.log("  (none recorded)");
  let day = "";
  for (const r of rows) {
    if (r.day !== day) { day = r.day; console.log(`  ${day}`); }
    console.log(`    ${r.name.padEnd(40)} ${String(r.total).padStart(8)}`);
  }
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (!opts) { console.error(USAGE); return 2; }
  let db;
  try {
    db = new Database(opts.db, { readonly: true, fileMustExist: true });
  } catch (err) {
    console.error(`Cannot open ${opts.db}: ${err.message}`);
    return 1;
  }
  try {
    const tables = new Set(db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all()
      .map((t) => /** @type {{ name: string }} */ (t).name));
    if (!tables.has("usage_counters") || !tables.has("user_clients")) {
      console.error(`${opts.db} has no usage tables yet: deploy the server that contains metrics.js first.`);
      return 1;
    }
    console.log(`Stride usage report — ${new Date().toISOString()} — ${opts.db}\n`);
    reportClients(db);
    reportCounters(db, opts.days);
    return 0;
  } finally {
    db.close();
  }
}

process.exit(main());
