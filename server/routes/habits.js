// @ts-check
const express = require("express");
const router = express.Router();
const crypto = require("crypto");
const { rateLimit } = require("express-rate-limit");
const db = require("../db");
const { requireUser } = require("../auth");

/** @typedef {{ id: string, name: string, emoji: string, color_hex: string, is_archived: number, sort_order: number, reminder_enabled: number, reminder_hour: number, reminder_minute: number, note: string|null, created_at: string, updated_at: string }} HabitRow */
/** @typedef {{ id: string, habit_id: string, date: string, note: string|null, created_at: string, updated_at: string }} EntryRow */
/** @typedef {{ count: number }} CountRow */

// Habits-specific rate limit: 60 requests per minute per IP
const habitsLimiter = process.env.NODE_ENV === "test"
  ? /** @type {import('express').RequestHandler} */ ((req, res, next) => next())
  : rateLimit({
      windowMs: 60 * 1000,
      max: 60,
      standardHeaders: true,
      legacyHeaders: false,
      message: { error: "Too many requests, please try again later" },
    });

// All routes require authentication
router.use(requireUser);
router.use(habitsLimiter);

// GET /habits — list all habits for the user
// Query params: limit (default 50, max 200), offset (default 0)
router.get("/", (req, res) => {
  const limit = Math.min(Math.max(parseInt(String(req.query.limit), 10) || 50, 1), 200);
  const offset = Math.max(parseInt(String(req.query.offset), 10) || 0, 0);

  const habits = db.prepare(`
    SELECT id, name, emoji, color_hex, is_archived, sort_order,
           reminder_enabled, reminder_hour, reminder_minute, note,
           created_at, updated_at
    FROM habits
    WHERE user_id = ?
    ORDER BY sort_order ASC, created_at ASC
    LIMIT ? OFFSET ?
  `).all(req.user.id, limit, offset);

  const total = /** @type {CountRow} */ (db.prepare("SELECT COUNT(*) as count FROM habits WHERE user_id = ?").get(req.user.id)).count;

  return res.json({
    habits,
    pagination: { total, limit, offset, hasMore: offset + habits.length < total },
  });
});

// POST /habits — create a new habit
router.post("/", (req, res) => {
  const { id, name, emoji, colorHex, reminderEnabled, reminderHour, reminderMinute, note } = req.body;

  if (!name || typeof name !== "string" || name.trim().length === 0) {
    return res.status(400).json({ error: "Name is required" });
  }
  if (name.trim().length > 100) {
    return res.status(400).json({ error: "Name must be 100 characters or less" });
  }

  if (reminderEnabled) {
    const hour = reminderHour ?? 20;
    const minute = reminderMinute ?? 0;
    if (!Number.isInteger(hour) || hour < 0 || hour > 23) {
      return res.status(400).json({ error: "reminderHour must be an integer 0–23" });
    }
    if (!Number.isInteger(minute) || minute < 0 || minute > 59) {
      return res.status(400).json({ error: "reminderMinute must be an integer 0–59" });
    }
  }

  const habitId = id || crypto.randomUUID();
  const maxOrder = /** @type {{ next: number }} */ (db.prepare(
    "SELECT COALESCE(MAX(sort_order), -1) + 1 as next FROM habits WHERE user_id = ?",
  ).get(req.user.id));

  const now = new Date().toISOString();
  try {
    db.prepare(`
      INSERT INTO habits (id, user_id, name, emoji, color_hex, sort_order,
                          reminder_enabled, reminder_hour, reminder_minute, note,
                          created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      habitId, req.user.id, name.trim(), emoji || "⭐", colorHex || "#34C759", maxOrder.next,
      reminderEnabled ? 1 : 0, reminderHour ?? 20, reminderMinute ?? 0, note ?? null,
      now, now,
    );
  } catch (err) {
    if (err.message && err.message.includes("UNIQUE constraint")) {
      return res.status(409).json({ error: "A habit with this ID already exists" });
    }
    throw err;
  }

  const habit = db.prepare(`
    SELECT id, name, emoji, color_hex, is_archived, sort_order,
           reminder_enabled, reminder_hour, reminder_minute, note,
           created_at, updated_at
    FROM habits WHERE id = ?
  `).get(habitId);
  return res.status(201).json({ habit });
});

// PUT /habits/:id — update a habit
router.put("/:id", (req, res) => {
  const { name, emoji, colorHex, isArchived, sortOrder, reminderEnabled, reminderHour, reminderMinute, note } = req.body;

  const existing = db.prepare("SELECT id FROM habits WHERE id = ? AND user_id = ?").get(req.params.id, req.user.id);
  if (!existing) return res.status(404).json({ error: "Habit not found" });

  if ("name" in req.body) {
    if (!name || typeof name !== "string" || name.trim().length === 0) {
      return res.status(400).json({ error: "Name is required" });
    }
    if (name.trim().length > 100) {
      return res.status(400).json({ error: "Name must be 100 characters or less" });
    }
  }

  if ("reminderHour" in req.body && reminderHour != null) {
    if (!Number.isInteger(reminderHour) || reminderHour < 0 || reminderHour > 23) {
      return res.status(400).json({ error: "reminderHour must be an integer 0–23" });
    }
  }
  if ("reminderMinute" in req.body && reminderMinute != null) {
    if (!Number.isInteger(reminderMinute) || reminderMinute < 0 || reminderMinute > 59) {
      return res.status(400).json({ error: "reminderMinute must be an integer 0–59" });
    }
  }

  db.prepare(`
    UPDATE habits SET
      name = COALESCE(?, name),
      emoji = COALESCE(?, emoji),
      color_hex = COALESCE(?, color_hex),
      is_archived = COALESCE(?, is_archived),
      sort_order = COALESCE(?, sort_order),
      reminder_enabled = COALESCE(?, reminder_enabled),
      reminder_hour = COALESCE(?, reminder_hour),
      reminder_minute = COALESCE(?, reminder_minute),
      note = CASE WHEN ? THEN ? ELSE note END,
      updated_at = ?
    WHERE id = ? AND user_id = ?
  `).run(
    name != null ? name.trim() : null,
    emoji ?? null,
    colorHex ?? null,
    isArchived != null ? (isArchived ? 1 : 0) : null,
    sortOrder ?? null,
    reminderEnabled != null ? (reminderEnabled ? 1 : 0) : null,
    reminderHour ?? null,
    reminderMinute ?? null,
    "note" in req.body ? 1 : 0, note ?? null,
    new Date().toISOString(),
    req.params.id,
    req.user.id,
  );

  const habit = db.prepare(`
    SELECT id, name, emoji, color_hex, is_archived, sort_order,
           reminder_enabled, reminder_hour, reminder_minute, note,
           created_at, updated_at
    FROM habits WHERE id = ?
  `).get(req.params.id);
  return res.json({ habit });
});

// DELETE /habits/:id — permanently delete a habit and its entries
router.delete("/:id", (req, res) => {
  const existing = db.prepare("SELECT id FROM habits WHERE id = ? AND user_id = ?").get(req.params.id, req.user.id);
  if (!existing) return res.status(404).json({ error: "Habit not found" });

  const deletedAt = new Date().toISOString();
  db.transaction(() => {
    db.prepare("DELETE FROM habits WHERE id = ? AND user_id = ?").run(req.params.id, req.user.id);
    db.prepare(
      "INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, ?, ?, ?)",
    ).run(req.user.id, "habit", req.params.id, deletedAt);
  })();
  return res.json({ ok: true });
});

// POST /habits/:id/entries — check in (complete a habit for a date)
router.post("/:id/entries", (req, res) => {
  const { date, id, note } = req.body;

  const habit = db.prepare("SELECT id FROM habits WHERE id = ? AND user_id = ?").get(req.params.id, req.user.id);
  if (!habit) return res.status(404).json({ error: "Habit not found" });

  if (!date || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    return res.status(400).json({ error: "Date must be YYYY-MM-DD" });
  }
  const parsed = new Date(date + "T00:00:00Z");
  if (isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== date) {
    return res.status(400).json({ error: "Invalid date" });
  }

  const entryId = id || crypto.randomUUID();

  try {
    const entryNow = new Date().toISOString();
    db.prepare("INSERT INTO habit_entries (id, habit_id, date, note, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)").run(entryId, req.params.id, date, note ?? null, entryNow, entryNow);
    return res.status(201).json({ entry: { id: entryId, habit_id: req.params.id, date, note: note ?? null, created_at: entryNow } });
  } catch (err) {
    if (err.message.includes("UNIQUE constraint")) {
      return res.status(409).json({ error: "Already checked in for this date" });
    }
    console.error("Entry creation failed:", err.message);
    return res.status(500).json({ error: "Failed to create entry" });
  }
});

// DELETE /habits/:id/entries/:date — uncheck (remove completion for a date)
router.delete("/:id/entries/:date", (req, res) => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(req.params.date)) {
    return res.status(400).json({ error: "Date must be YYYY-MM-DD" });
  }

  const habit = db.prepare("SELECT id FROM habits WHERE id = ? AND user_id = ?").get(req.params.id, req.user.id);
  if (!habit) return res.status(404).json({ error: "Habit not found" });

  const entry = /** @type {{ id: string }|undefined} */ (
    db.prepare("SELECT id FROM habit_entries WHERE habit_id = ? AND date = ?").get(req.params.id, req.params.date)
  );
  if (entry) {
    const deletedAt = new Date().toISOString();
    db.transaction(() => {
      db.prepare("DELETE FROM habit_entries WHERE habit_id = ? AND date = ?").run(req.params.id, req.params.date);
      db.prepare(
        "INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, ?, ?, ?)",
      ).run(req.user.id, "entry", entry.id, deletedAt);
    })();
  }
  return res.json({ ok: true });
});

// GET /habits/:id/entries — get entries for a habit (with optional date range & pagination)
// Query params: from, to (date range), limit (default 100, max 500), offset (default 0)
router.get("/:id/entries", (req, res) => {
  const habit = db.prepare("SELECT id FROM habits WHERE id = ? AND user_id = ?").get(req.params.id, req.user.id);
  if (!habit) return res.status(404).json({ error: "Habit not found" });

  const { from, to } = req.query;
  const limit = Math.min(Math.max(parseInt(String(req.query.limit), 10) || 100, 1), 500);
  const offset = Math.max(parseInt(String(req.query.offset), 10) || 0, 0);

  let entries;
  let total;

  if (from && to) {
    entries = db.prepare(
      "SELECT id, habit_id, date, note, created_at FROM habit_entries WHERE habit_id = ? AND date >= ? AND date <= ? ORDER BY date LIMIT ? OFFSET ?",
    ).all(req.params.id, from, to, limit, offset);
    total = /** @type {CountRow} */ (db.prepare(
      "SELECT COUNT(*) as count FROM habit_entries WHERE habit_id = ? AND date >= ? AND date <= ?",
    ).get(req.params.id, from, to)).count;
  } else {
    entries = db.prepare(
      "SELECT id, habit_id, date, note, created_at FROM habit_entries WHERE habit_id = ? ORDER BY date LIMIT ? OFFSET ?",
    ).all(req.params.id, limit, offset);
    total = /** @type {CountRow} */ (db.prepare(
      "SELECT COUNT(*) as count FROM habit_entries WHERE habit_id = ?",
    ).get(req.params.id)).count;
  }

  return res.json({
    entries,
    pagination: { total, limit, offset, hasMore: offset + entries.length < total },
  });
});

// GET /habits/:id/stats — get streak and completion stats
router.get("/:id/stats", (req, res) => {
  const habit = /** @type {{ id: string, created_at: string } | undefined} */ (db.prepare("SELECT id, created_at FROM habits WHERE id = ? AND user_id = ?").get(req.params.id, req.user.id));
  if (!habit) return res.status(404).json({ error: "Habit not found" });

  const entries = db.prepare(
    "SELECT date FROM habit_entries WHERE habit_id = ? ORDER BY date",
  ).all(req.params.id).map((e) => /** @type {{ date: string }} */ (e).date);

  const today = new Date().toISOString().slice(0, 10);
  const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);

  // Current streak
  let currentStreak = 0;
  const dateSet = new Set(entries);
  let checkDate = dateSet.has(today) ? today : (dateSet.has(yesterday) ? yesterday : null);

  if (checkDate) {
    while (dateSet.has(checkDate)) {
      currentStreak++;
      const d = new Date(checkDate);
      d.setDate(d.getDate() - 1);
      checkDate = d.toISOString().slice(0, 10);
    }
  }

  // Best streak
  let bestStreak = 0;
  let streak = 0;
  for (let i = 0; i < entries.length; i++) {
    if (i === 0) {
      streak = 1;
    } else {
      const prev = new Date(entries[i - 1]);
      const curr = new Date(entries[i]);
      const diffDays = (curr.getTime() - prev.getTime()) / 86400000;
      streak = diffDays === 1 ? streak + 1 : (diffDays === 0 ? streak : 1);
    }
    bestStreak = Math.max(bestStreak, streak);
  }

  // 30-day completion rate
  const thirtyDaysAgo = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
  const createdDate = habit.created_at.slice(0, 10);
  const effectiveStart = thirtyDaysAgo > createdDate ? thirtyDaysAgo : createdDate;
  const totalDays = Math.max(1, Math.ceil((new Date(today).getTime() - new Date(effectiveStart).getTime()) / 86400000) + 1);
  const completedInRange = entries.filter((d) => d >= effectiveStart && d <= today).length;
  const completionRate = completedInRange / totalDays;

  return res.json({
    currentStreak,
    bestStreak,
    completionRate: Math.round(completionRate * 1000) / 1000,
    totalEntries: entries.length,
  });
});

module.exports = router;
