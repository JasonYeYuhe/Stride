#!/usr/bin/env node
/**
 * seed-demo.js — (re)create the App Review demo account: 8 habits with 90 days of history.
 *
 * DESTRUCTIVE. It deletes the account's habits, check-ins, tombstones, magic-link tokens and
 * sessions, and re-creates every habit under a new id: run while a review is open, it signs the
 * reviewer out and replaces everything on their device. Only when no review is open (DEPLOY.md
 * "App Review demo account top-up"). To add habits to the live account use
 * ops/demo-add-habits.js; ops/demo-topup.js keeps it current every night.
 *
 * Usage:  node seed-demo.js [--print-token]     (cwd = this directory, so dotenv reads .env)
 *
 * The login token. DEMO_TOKEN (set in the host's .env, so it stays stable across re-runs) is
 * installed and NEVER printed: it is already in .env and in the ASC review notes, and this output
 * reaches terminals and agent transcripts. Without DEMO_TOKEN a random token is generated, and
 * printed as the "  Token: <hex>" line only with --print-token or NODE_ENV=test (the sim kit's
 * throwaway copy, scripts/sim_e2e/seed-demo.sh, reads that line); otherwise the script refuses
 * before writing anything, so no token nobody has seen is ever installed.
 *
 * What it writes. The six habits seeded since 1.0, with their 30-day patterns from
 * ops/demo-topup.js's PATTERNS laid down three times, each day at its place in the calendar's
 * 30-day cycle (`patternIndex`, where the nightly top-up carries on), plus
 * ops/demo-add-habits.js's "Water" and "Stretch" through the same insert (`insertDemoHabit`):
 * every column the apps read (kind, target, unit, schedule, …), created_at CREATED_DAYS_BACK (91)
 * days back, ids from `demoHabitId` (so the top-up knows these habits from a reviewer's),
 * updated_at = client_updated_at = now, upper-case ids, and check-ins on the last 90 days up to
 * the entry-day cap, min(UTC today, America/Los_Angeles today) (RELEASE-1.4.1.md D13). Only
 * Read 30 Minutes and Journal are done on 25 of the last 30 days. On seed day they score at
 * least 0.86 and 0.79 whatever the date (0.890 and 0.883 where the cycle ends on the pattern's
 * last day, as HabitScoreTests has it), and while still at 25 of 30 at least 0.81 and 0.82 on
 * the two empty days before the next run: above gate 2's 0.75, where the 30 days seeded before
 * 1.4.1 scored 0.716 and 0.711.
 */

const crypto = require("crypto");
const { DEMO_EMAIL, PATTERNS, patternIndex, entryDayCap } = require("./ops/demo-topup");
const { HISTORY_DAYS, ADDED_HABITS, insertDemoHabit } = require("./ops/demo-add-habits");

/** One year. */
const TOKEN_LIFETIME_MS = 365 * 24 * 60 * 60 * 1000;

/** @typedef {import('./ops/demo-add-habits').DemoHabitDef} DemoHabitDef */

/**
 * A yes/no daily habit checked on the days its 30-day pattern says, at the calendar's place.
 * @param {string} name @param {string} emoji @param {string} color @returns {DemoHabitDef}
 */
function patternHabit(name, emoji, color) {
  const pattern = /** @type {number[]} */ (PATTERNS[name]);
  return {
    name, emoji, color,
    kind: "binary", target: 1, unit: null,
    schedule: "daily", timesPerWeek: 7, activeDaysMask: 127,
    day: (date) => (pattern[patternIndex(date, pattern.length)] ? { value: 1 } : null),
    notes: [],
  };
}

/** Every habit of the demo account, in sort order. @type {DemoHabitDef[]} */
const SEEDED_HABITS = [
  patternHabit("Morning Run",     "🏃", "#34C759"),
  patternHabit("Read 30 Minutes", "📚", "#007AFF"),
  patternHabit("Meditate",        "🧘", "#AF52DE"),
  patternHabit("Drink 8 Glasses", "💧", "#5AC8FA"),
  patternHabit("Practice Guitar", "🎸", "#FF9500"),
  patternHabit("Journal",         "📝", "#FF2D55"),
  ...ADDED_HABITS,
];

/**
 * Wipe and re-create the demo account in `db`, as of `now`, with login token `token`.
 * @param {import('better-sqlite3').Database} db
 * @param {{ token: string, now?: Date }} opts
 * @returns {{ userId: number, lines: string[], entries: number, from: string, to: string }}
 */
function seed(db, { token, now = new Date() }) {
  const tokenHash = crypto.createHash("sha256").update(token).digest("hex");
  const expiresAt = now.getTime() + TOKEN_LIFETIME_MS;
  /** @type {string[]} */
  const lines = [];

  return db.transaction(() => {
    // ── 1. Create or find demo user ──
    db.prepare("INSERT OR IGNORE INTO users (email) VALUES (?)").run(DEMO_EMAIL);
    const userId = /** @type {{ id: number }} */ (db.prepare("SELECT id FROM users WHERE email = ?").get(DEMO_EMAIL)).id;
    lines.push(`Demo user: ${DEMO_EMAIL} (id=${userId})`);

    // ── 2. Clear existing demo data ──
    const existingHabits = db.prepare("SELECT id FROM habits WHERE user_id = ?").all(userId).map((r) => /** @type {{ id: string }} */ (r).id);
    if (existingHabits.length > 0) {
      const ph = existingHabits.map(() => "?").join(",");
      db.prepare(`DELETE FROM habit_entries WHERE habit_id IN (${ph})`).run(...existingHabits);
    }
    db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
    db.prepare("DELETE FROM deletion_tombstones WHERE user_id = ?").run(userId);
    // Remove old demo tokens for this user
    db.prepare("DELETE FROM magic_link_tokens WHERE user_id = ?").run(userId);
    // Remove old sessions for this user
    db.prepare("DELETE FROM sessions WHERE user_id = ?").run(userId);

    // ── 3. Create reusable magic link token ──
    db.prepare(
      "INSERT INTO magic_link_tokens (user_id, token_hash, expires_at, is_reusable) VALUES (?, ?, ?, 1)"
    ).run(userId, tokenHash, expiresAt);
    lines.push(`Reusable magic link token created (expires: ${new Date(expiresAt).toISOString()})`);

    // ── 4. Create habits and their check-ins ──
    let entries = 0;
    let from = "", to = "";
    SEEDED_HABITS.forEach((def, sortOrder) => {
      const r = insertDemoHabit(db, userId, def, { now, sortOrder });
      entries += r.entries;
      if (!from || r.from < from) from = r.from;
      if (r.to > to) to = r.to;
      lines.push(`  Created habit: ${def.emoji} ${def.name} (${r.entries} check-ins${r.notes ? `, ${r.notes} notes` : ""})`);
    });
    lines.push(`  Created ${entries} habit entries across ${HISTORY_DAYS} days (${from}..${to}, capped at ${entryDayCap(now)})`);
    return { userId, lines, entries, from, to };
  })();
}

/**
 * Which token to install, and whether it may be printed (the header).
 * @param {NodeJS.ProcessEnv} env @param {string[]} argv
 * @returns {{ token: string, fromEnv: boolean, print: boolean } | { refuse: string }}
 */
function chooseToken(env, argv) {
  if (env.DEMO_TOKEN) return { token: env.DEMO_TOKEN, fromEnv: true, print: false };
  const print = argv.includes("--print-token") || env.NODE_ENV === "test";
  if (!print) {
    return { refuse: "DEMO_TOKEN is not set. Set it in .env (it is never printed), or pass --print-token to generate one and see it." };
  }
  return { token: crypto.randomBytes(24).toString("hex"), fromEnv: false, print: true };
}

function main() {
  require("dotenv").config();
  const choice = chooseToken(process.env, process.argv.slice(2));
  if ("refuse" in choice) {
    console.error(`seed-demo.js: ${choice.refuse} Nothing was written.`);
    return 2;
  }
  const db = require("./db");
  const { lines } = seed(db, { token: choice.token });
  for (const line of lines) console.log(line);

  // ── Done ──
  console.log("\n═══════════════════════════════════════════════");
  console.log("  Demo Account Ready for App Store Review");
  console.log("═══════════════════════════════════════════════");
  console.log(`  Email: ${DEMO_EMAIL}`);
  // The one line that carries the token, and only for a generated one (the header).
  if (choice.print) console.log(`  Token: ${choice.token}`);
  else console.log("  Token: DEMO_TOKEN from the environment (not printed)");
  console.log("");
  console.log("  Instructions for reviewer:");
  console.log('  1. Open Stride → tap "Log In"');
  console.log('  2. Tap "I have a login token"');
  console.log(`  3. Paste the token${choice.print ? " above" : " from the review notes"}`);
  console.log('  4. Tap "Log In"');
  console.log("═══════════════════════════════════════════════\n");
  return 0;
}

if (require.main === module) process.exitCode = main();

module.exports = { SEEDED_HABITS, seed, chooseToken };
