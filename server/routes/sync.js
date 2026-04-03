const express = require("express");
const router = express.Router();
const crypto = require("crypto");
const rateLimit = require("express-rate-limit");
const db = require("../db");
const { requireUser } = require("../auth");

// Sync-specific rate limit: 30 requests per minute per IP
const syncLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 30,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: "Too many sync requests, please try again later" },
});

router.use(requireUser);
router.use(syncLimiter);

// POST /sync/push — mobile app pushes local changes to server
// Accepts { habits: [...], entries: [...], deletedHabitIds: [...], deletedEntryIds: [...] }
router.post("/push", (req, res) => {
  const { habits = [], entries = [], deletedHabitIds = [], deletedEntryIds = [] } = req.body;
  const userId = req.user.id;

  const upsertHabit = db.prepare(`
    INSERT INTO habits (id, user_id, name, emoji, color_hex, is_archived, sort_order, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      name = excluded.name,
      emoji = excluded.emoji,
      color_hex = excluded.color_hex,
      is_archived = excluded.is_archived,
      sort_order = excluded.sort_order,
      updated_at = excluded.updated_at
    WHERE habits.user_id = ?
  `);

  const upsertEntry = db.prepare(`
    INSERT INTO habit_entries (id, habit_id, date, created_at)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(habit_id, date) DO NOTHING
  `);

  const deleteHabit = db.prepare("DELETE FROM habits WHERE id = ? AND user_id = ?");
  const deleteEntry = db.prepare(
    "DELETE FROM habit_entries WHERE id = ? AND habit_id IN (SELECT id FROM habits WHERE user_id = ?)"
  );

  const transaction = db.transaction(() => {
    // Delete first
    for (const id of deletedHabitIds) {
      deleteHabit.run(id, userId);
    }
    for (const id of deletedEntryIds) {
      deleteEntry.run(id, userId);
    }

    // Upsert habits
    for (const h of habits) {
      upsertHabit.run(
        h.id, userId, h.name, h.emoji || "⭐", h.colorHex || "#34C759",
        h.isArchived ? 1 : 0, h.sortOrder || 0,
        h.createdAt || new Date().toISOString(), h.updatedAt || new Date().toISOString(),
        userId,
      );
    }

    // Upsert entries
    for (const e of entries) {
      // Verify the habit belongs to this user
      const habit = db.prepare("SELECT id FROM habits WHERE id = ? AND user_id = ?").get(e.habitId, userId);
      if (habit) {
        upsertEntry.run(e.id, e.habitId, e.date, e.createdAt || new Date().toISOString());
      }
    }
  });

  transaction();
  return res.json({ ok: true });
});

// GET /sync/pull — mobile app pulls all data from server
// Optional: ?since=ISO8601 to get only changes after a timestamp
router.get("/pull", (req, res) => {
  const userId = req.user.id;
  const since = req.query.since;

  let habits, entries;

  if (since) {
    habits = db.prepare(
      "SELECT id, name, emoji, color_hex, is_archived, sort_order, created_at, updated_at FROM habits WHERE user_id = ? AND updated_at > ?",
    ).all(userId, since);

    const habitIds = db.prepare(
      "SELECT id FROM habits WHERE user_id = ?",
    ).all(userId).map((h) => h.id);

    if (habitIds.length > 0) {
      const placeholders = habitIds.map(() => "?").join(",");
      entries = db.prepare(
        `SELECT id, habit_id, date, created_at FROM habit_entries WHERE habit_id IN (${placeholders}) AND created_at > ?`,
      ).all(...habitIds, since);
    } else {
      entries = [];
    }
  } else {
    habits = db.prepare("SELECT id, name, emoji, color_hex, is_archived, sort_order, created_at, updated_at FROM habits WHERE user_id = ?").all(userId);
    const habitIds = habits.map((h) => h.id);

    if (habitIds.length > 0) {
      const placeholders = habitIds.map(() => "?").join(",");
      entries = db.prepare(
        `SELECT id, habit_id, date, created_at FROM habit_entries WHERE habit_id IN (${placeholders})`,
      ).all(...habitIds);
    } else {
      entries = [];
    }
  }

  return res.json({
    habits: habits.map((h) => ({
      id: h.id,
      name: h.name,
      emoji: h.emoji,
      colorHex: h.color_hex,
      isArchived: Boolean(h.is_archived),
      sortOrder: h.sort_order,
      createdAt: h.created_at,
      updatedAt: h.updated_at,
    })),
    entries: entries.map((e) => ({
      id: e.id,
      habitId: e.habit_id,
      date: e.date,
      createdAt: e.created_at,
    })),
    serverTime: new Date().toISOString(),
  });
});

module.exports = router;
