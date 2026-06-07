#!/usr/bin/env node
/**
 * seed-demo.js — Create a demo account with pre-populated data for App Store review.
 *
 * Usage:  node seed-demo.js
 * Output: prints the demo token for App Store Connect review notes.
 */

require("dotenv").config();
const crypto = require("crypto");
const db = require("./db");

const DEMO_EMAIL = "demo@stride-review.com";
// Token is supplied via the DEMO_TOKEN env var (set in the droplet's .env so it
// stays stable across re-runs) and is NEVER hardcoded here. If unset, a fresh
// random token is generated and printed below — paste that into the ASC review
// notes. Re-running seed-demo revokes any previous demo token (see step 2).
const DEMO_TOKEN = process.env.DEMO_TOKEN || crypto.randomBytes(24).toString("hex");
const TOKEN_HASH = crypto.createHash("sha256").update(DEMO_TOKEN).digest("hex");
// Expires in 1 year
const EXPIRES_AT = Date.now() + 365 * 24 * 60 * 60 * 1000;

const seed = db.transaction(() => {
  // ── 1. Create or find demo user ──
  db.prepare("INSERT OR IGNORE INTO users (email) VALUES (?)").run(DEMO_EMAIL);
  const user = db.prepare("SELECT id FROM users WHERE email = ?").get(DEMO_EMAIL);
  const userId = user.id;
  console.log(`Demo user: ${DEMO_EMAIL} (id=${userId})`);

  // ── 2. Clear existing demo data ──
  const existingHabits = db.prepare("SELECT id FROM habits WHERE user_id = ?").all(userId).map(r => r.id);
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
  ).run(userId, TOKEN_HASH, EXPIRES_AT);
  console.log(`Reusable magic link token created (expires: ${new Date(EXPIRES_AT).toISOString()})`);

  // ── 4. Create habits ──
  const now = new Date();
  const habits = [
    { name: "Morning Run",       emoji: "🏃", color: "#34C759", sort: 0 },
    { name: "Read 30 Minutes",   emoji: "📚", color: "#007AFF", sort: 1 },
    { name: "Meditate",          emoji: "🧘", color: "#AF52DE", sort: 2 },
    { name: "Drink 8 Glasses",   emoji: "💧", color: "#5AC8FA", sort: 3 },
    { name: "Practice Guitar",   emoji: "🎸", color: "#FF9500", sort: 4 },
    { name: "Journal",           emoji: "📝", color: "#FF2D55", sort: 5 },
  ];

  const habitIds = [];
  for (const h of habits) {
    const id = crypto.randomUUID();
    const createdAt = new Date(now.getTime() - 45 * 24 * 60 * 60 * 1000).toISOString(); // created 45 days ago
    db.prepare(`
      INSERT INTO habits (id, user_id, name, emoji, color_hex, sort_order, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `).run(id, userId, h.name, h.emoji, h.color, h.sort, createdAt, createdAt);
    habitIds.push(id);
    console.log(`  Created habit: ${h.emoji} ${h.name}`);
  }

  // ── 5. Create realistic entries for the past 30 days ──
  // Each habit has a different completion pattern to look realistic
  const completionPatterns = [
    // Morning Run: ~70% (skip some days)
    [1,1,0,1,1,1,0,1,1,1,1,0,1,0,1,1,1,0,1,1,1,0,1,1,0,1,1,1,1,1],
    // Read 30 Minutes: ~90% (very consistent)
    [1,1,1,1,1,0,1,1,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1],
    // Meditate: ~60%
    [1,0,1,1,0,0,1,1,0,1,1,0,1,0,1,1,0,1,1,0,1,1,0,0,1,1,1,0,1,1],
    // Drink 8 Glasses: ~80%
    [1,1,1,0,1,1,1,1,0,1,1,1,1,1,0,1,1,1,0,1,1,1,1,1,0,1,1,1,1,0],
    // Practice Guitar: ~50%
    [1,0,0,1,1,0,1,0,0,1,1,0,0,1,0,1,0,1,1,0,0,1,1,0,1,0,0,1,1,0],
    // Journal: ~85% (building streak recently)
    [0,1,0,1,1,1,0,1,1,1,1,0,1,1,1,1,1,1,0,1,1,1,1,1,1,1,1,1,1,1],
  ];

  let entryCount = 0;
  for (let hi = 0; hi < habitIds.length; hi++) {
    const pattern = completionPatterns[hi];
    for (let day = 0; day < 30; day++) {
      if (!pattern[day]) continue;
      const date = new Date(now);
      date.setDate(date.getDate() - (29 - day)); // day 0 = 29 days ago, day 29 = today
      const dateStr = date.toISOString().split("T")[0];
      const entryId = crypto.randomUUID();
      db.prepare(
        "INSERT OR IGNORE INTO habit_entries (id, habit_id, date, created_at) VALUES (?, ?, ?, ?)"
      ).run(entryId, habitIds[hi], dateStr, date.toISOString());
      entryCount++;
    }
  }
  console.log(`  Created ${entryCount} habit entries across 30 days`);

  // ── Done ──
  console.log("\n═══════════════════════════════════════════════");
  console.log("  Demo Account Ready for App Store Review");
  console.log("═══════════════════════════════════════════════");
  console.log(`  Email: ${DEMO_EMAIL}`);
  console.log(`  Token: ${DEMO_TOKEN}`);
  console.log("");
  console.log("  Instructions for reviewer:");
  console.log('  1. Open Stride → tap "Log In"');
  console.log('  2. Tap "I have a login token"');
  console.log("  3. Paste the token above");
  console.log('  4. Tap "Log In"');
  console.log("═══════════════════════════════════════════════\n");
});

seed();
