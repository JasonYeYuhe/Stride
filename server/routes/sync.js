// @ts-check
const express = require("express");
const router = express.Router();
const crypto = require("crypto");
const { rateLimit } = require("express-rate-limit");

/** @typedef {{ id: string, name: string, emoji: string, color_hex: string, is_archived: number, sort_order: number, reminder_enabled: number, reminder_hour: number, reminder_minute: number, note: string|null, kind: string, target_value: number, unit: string|null, schedule_kind: string, times_per_week: number, active_days_mask: number, group_id: string|null, created_at: string, updated_at: string }} HabitRow */
/** @typedef {{ id: string, habit_id: string, date: string, note: string|null, value: number, created_at: string, updated_at: string }} EntryRow */
/** @typedef {{ id: string, name: string, color_hex: string, sort_order: number, created_at: string, updated_at: string }} GroupRow */
/** @typedef {{ entity_type: string, entity_id: string }} TombstoneRow */
const db = require("../db");
const { requireUser } = require("../auth");

/**
 * Read a push-payload field that may arrive under either casing.
 *
 * Every shipped iOS/macOS client up to and including 1.2.1 encodes with
 * `JSONEncoder.keyEncodingStrategy = .convertToSnakeCase`, so it sends
 * `habit_id` / `deleted_habit_ids` / `color_hex` while this route was written
 * against camelCase. The mismatch silently dropped EVERY check-in (the
 * `!e.habitId` guard), reset habit fields to defaults, and stopped deletions
 * from propagating — and the client's full-pull reconciliation then deleted the
 * user's local records because the server had none. The client is fixed, but
 * installed clients keep sending snake_case until users update, so the server
 * must accept both. Do not remove while any <= 1.2.1 build is still in the wild.
 */
const toSnake = (k) => k.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase());
function field(obj, camelKey) {
  if (obj === null || obj === undefined) return undefined;
  const v = obj[camelKey];
  return v !== undefined ? v : obj[toSnake(camelKey)];
}

/*
 * Two clocks per row.
 *
 * `client_updated_at` is when someone last EDITED the row, on their device. It decides
 * conflicts: an older edit never overwrites a newer one.
 * `updated_at` is when the row last CHANGED ON THIS SERVER. It is what `?since` filters on.
 *
 * They used to be one column, and each table got it wrong in a different direction:
 * - habits and groups stored the device's edit time. A rename made offline on Monday and
 *   pushed on Wednesday was stamped Monday, i.e. before the cursor of every device that
 *   synced on Tuesday, so those devices never received it — not on the next sync, not ever.
 * - entries stored only server time, so nothing could tell a newer check-in from an older
 *   one and the last device to push won: an iPad coming back online with "Water 2/8" from the
 *   morning overwrote the 8/8 logged on the phone that afternoon, and pulled 2 back to it.
 *
 * A row's `updated_at` moves only when the push actually changes it. Every client pushes a
 * full snapshot on every sync, so bumping unchanged rows would put the whole dataset back
 * into every other device's incremental pull.
 */

/** Normalise a client timestamp to this server's own format, or null if it isn't one.
 * @param {unknown} v
 * @returns {string|null} */
function isoOrNull(v) {
  if (typeof v !== "string" || v === "") return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

/**
 * Timestamps go out at whole-second precision.
 *
 * Every shipped app parses them with a default ISO8601DateFormatter, which rejects
 * fractional seconds and returns nil. Anything this process stamps has milliseconds —
 * including the whole App Review demo account, seeded with toISOString() — and on nil the
 * app fell back to Date(), so a freshly signed-in device thought every demo habit was
 * created today: its 30-day rate, Weekly Review and trend chart all started from today.
 * @param {string|null|undefined} v
 */
function wireTime(v) {
  if (!v) return v;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? v : d.toISOString().replace(/\.\d{3}Z$/, "Z");
}


// Sync-specific rate limit: 30 requests per minute per IP
const syncLimiter = process.env.NODE_ENV === "test"
  ? /** @type {import('express').RequestHandler} */ ((req, res, next) => next())
  : rateLimit({
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
  const habits = req.body.habits ?? [];
  const entries = req.body.entries ?? [];
  const groups = req.body.groups ?? [];
  const deletedHabitIds = field(req.body, "deletedHabitIds") ?? [];
  const deletedEntryIds = field(req.body, "deletedEntryIds") ?? [];
  const deletedGroupIds = field(req.body, "deletedGroupIds") ?? [];
  const userId = req.user.id;

  const upsertHabit = db.prepare(`
    INSERT INTO habits (id, user_id, name, emoji, color_hex, is_archived, sort_order,
                        reminder_enabled, reminder_hour, reminder_minute, note,
                        kind, target_value, unit, schedule_kind, times_per_week,
                        active_days_mask, group_id,
                        created_at, updated_at, client_updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      name = excluded.name,
      emoji = excluded.emoji,
      color_hex = excluded.color_hex,
      is_archived = excluded.is_archived,
      sort_order = excluded.sort_order,
      reminder_enabled = excluded.reminder_enabled,
      reminder_hour = excluded.reminder_hour,
      reminder_minute = excluded.reminder_minute,
      note = excluded.note,
      kind = excluded.kind,
      target_value = excluded.target_value,
      unit = excluded.unit,
      schedule_kind = excluded.schedule_kind,
      times_per_week = excluded.times_per_week,
      active_days_mask = excluded.active_days_mask,
      group_id = excluded.group_id,
      client_updated_at = excluded.client_updated_at,
      updated_at = excluded.updated_at
    WHERE habits.user_id = ?
      AND excluded.client_updated_at >= COALESCE(habits.client_updated_at, habits.updated_at)
      AND (habits.client_updated_at IS NOT excluded.client_updated_at
        OR habits.name IS NOT excluded.name OR habits.emoji IS NOT excluded.emoji
        OR habits.color_hex IS NOT excluded.color_hex OR habits.is_archived IS NOT excluded.is_archived
        OR habits.sort_order IS NOT excluded.sort_order OR habits.note IS NOT excluded.note
        OR habits.reminder_enabled IS NOT excluded.reminder_enabled
        OR habits.reminder_hour IS NOT excluded.reminder_hour
        OR habits.reminder_minute IS NOT excluded.reminder_minute
        OR habits.kind IS NOT excluded.kind OR habits.target_value IS NOT excluded.target_value
        OR habits.unit IS NOT excluded.unit OR habits.schedule_kind IS NOT excluded.schedule_kind
        OR habits.times_per_week IS NOT excluded.times_per_week
        OR habits.active_days_mask IS NOT excluded.active_days_mask
        OR habits.group_id IS NOT excluded.group_id)
  `);

  const upsertEntry = db.prepare(`
    INSERT INTO habit_entries (id, habit_id, date, note, value, created_at, updated_at, client_updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(habit_id, date) DO UPDATE SET
      note = excluded.note,
      value = excluded.value,
      client_updated_at = excluded.client_updated_at,
      updated_at = excluded.updated_at
    WHERE excluded.client_updated_at >= COALESCE(habit_entries.client_updated_at, habit_entries.updated_at)
      AND (habit_entries.client_updated_at IS NOT excluded.client_updated_at
        OR habit_entries.note IS NOT excluded.note OR habit_entries.value IS NOT excluded.value)
  `);

  // Two devices that each checked in on the same day hold different ids for one row; the
  // server keeps the first. The other device only adopts the server's id when the row comes
  // back in its pull, so when its push didn't change the row (older, or identical), move the
  // row into the feed anyway. Once the ids agree this matches nothing.
  const refeedMismatchedEntry = db.prepare(
    "UPDATE habit_entries SET updated_at = ? WHERE habit_id = ? AND date = ? AND id <> ?"
  );

  const upsertGroup = db.prepare(`
    INSERT INTO habit_groups (id, user_id, name, color_hex, sort_order, created_at, updated_at, client_updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      name = excluded.name,
      color_hex = excluded.color_hex,
      sort_order = excluded.sort_order,
      client_updated_at = excluded.client_updated_at,
      updated_at = excluded.updated_at
    WHERE habit_groups.user_id = ?
      AND excluded.client_updated_at >= COALESCE(habit_groups.client_updated_at, habit_groups.updated_at)
      AND (habit_groups.client_updated_at IS NOT excluded.client_updated_at
        OR habit_groups.name IS NOT excluded.name OR habit_groups.color_hex IS NOT excluded.color_hex
        OR habit_groups.sort_order IS NOT excluded.sort_order)
  `);

  const deleteHabit = db.prepare("DELETE FROM habits WHERE id = ? AND user_id = ?");
  const deleteEntry = db.prepare(
    "DELETE FROM habit_entries WHERE id = ? AND habit_id IN (SELECT id FROM habits WHERE user_id = ?)"
  );
  const deleteGroup = db.prepare("DELETE FROM habit_groups WHERE id = ? AND user_id = ?");

  const insertTombstone = db.prepare(
    "INSERT INTO deletion_tombstones (user_id, entity_type, entity_id, deleted_at) VALUES (?, ?, ?, ?)"
  );

  const fetchHabitTombstones = db.prepare(
    "SELECT entity_id FROM deletion_tombstones WHERE user_id = ? AND entity_type = 'habit'"
  );
  const fetchEntryTombstones = db.prepare(
    "SELECT entity_id FROM deletion_tombstones WHERE user_id = ? AND entity_type = 'entry'"
  );
  const fetchGroupTombstones = db.prepare(
    "SELECT entity_id FROM deletion_tombstones WHERE user_id = ? AND entity_type = 'group'"
  );

  const transaction = db.transaction(() => {
    // Load pre-existing tombstones to prevent cross-device resurrection
    const blockedHabits = new Set(
      /** @type {{ entity_id: string }[]} */ (fetchHabitTombstones.all(userId)).map((r) => r.entity_id)
    );
    const blockedEntries = new Set(
      /** @type {{ entity_id: string }[]} */ (fetchEntryTombstones.all(userId)).map((r) => r.entity_id)
    );
    const blockedGroups = new Set(
      /** @type {{ entity_id: string }[]} */ (fetchGroupTombstones.all(userId)).map((r) => r.entity_id)
    );

    // Delete first and record tombstones
    const now = new Date().toISOString();
    for (const id of deletedHabitIds) {
      deleteHabit.run(id, userId);
      insertTombstone.run(userId, "habit", id, now);
      blockedHabits.add(id);
    }
    for (const id of deletedEntryIds) {
      deleteEntry.run(id, userId);
      insertTombstone.run(userId, "entry", id, now);
      blockedEntries.add(id);
    }
    for (const id of deletedGroupIds) {
      deleteGroup.run(id, userId);
      insertTombstone.run(userId, "group", id, now);
      blockedGroups.add(id);
    }

    // Upsert groups first so habits can reference them
    for (const g of groups) {
      if (blockedGroups.has(g.id)) continue;
      if (!g.id || !g.name) continue;
      upsertGroup.run(
        g.id, userId, g.name, field(g, "colorHex") || "#34C759", field(g, "sortOrder") || 0,
        field(g, "createdAt") || now, now, isoOrNull(field(g, "updatedAt")) || now,
        userId,
      );
    }

    // Upsert habits — skip any that are tombstoned (deleted in this push or previously)
    for (const h of habits) {
      if (blockedHabits.has(h.id)) continue;
      if (!h.id || !h.name) continue;
      // Drop a stale group reference (group deleted on another device)
      const rawGroupId = field(h, "groupId");
      const groupId = rawGroupId && !blockedGroups.has(rawGroupId) ? rawGroupId : null;
      upsertHabit.run(
        h.id, userId, h.name, h.emoji || "⭐", field(h, "colorHex") || "#34C759",
        field(h, "isArchived") ? 1 : 0, field(h, "sortOrder") || 0,
        field(h, "reminderEnabled") ? 1 : 0, field(h, "reminderHour") ?? 20, field(h, "reminderMinute") ?? 0,
        h.note ?? null,
        h.kind || "binary", field(h, "targetValue") ?? 1, h.unit ?? null,
        field(h, "scheduleKind") || "daily", field(h, "timesPerWeek") ?? 7, field(h, "activeDaysMask") ?? 127,
        groupId,
        field(h, "createdAt") || now, now, isoOrNull(field(h, "updatedAt")) || now,
        userId,
      );
    }

    // Upsert entries — skip any that are tombstoned (deleted in this push or previously)
    for (const e of entries) {
      if (blockedEntries.has(e.id)) continue;
      const entryHabitId = field(e, "habitId");
      if (!e.id || !entryHabitId || !e.date) continue;
      // Verify the habit belongs to this user
      const habit = db.prepare("SELECT id FROM habits WHERE id = ? AND user_id = ?").get(entryHabitId, userId);
      if (habit) {
        // Clients before 1.2.3 send no entry updatedAt; stamping those `now` keeps their
        // last-push-wins behaviour rather than letting them lose every conflict.
        upsertEntry.run(e.id, entryHabitId, e.date, e.note ?? null, e.value ?? 1, field(e, "createdAt") || now, now,
          isoOrNull(field(e, "updatedAt")) || now);
        refeedMismatchedEntry.run(now, entryHabitId, e.date, e.id);
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
  // Compared as a string against stored toISOString() values, so bring it to that format
  // first: "…:18Z" sorts AFTER "…:18.500Z" ('Z' > '.'), which silently dropped every row
  // written later in the same second as the cursor.
  const since = isoOrNull(req.query.since) ?? req.query.since;

  const HABIT_COLS = `id, name, emoji, color_hex, is_archived, sort_order,
              reminder_enabled, reminder_hour, reminder_minute, note,
              kind, target_value, unit, schedule_kind, times_per_week,
              active_days_mask, group_id,
              created_at, COALESCE(client_updated_at, updated_at) AS updated_at`;

  let habits, entries, groups, deletedHabitIds, deletedEntryIds, deletedGroupIds;

  if (since) {
    habits = db.prepare(
      `SELECT ${HABIT_COLS} FROM habits WHERE user_id = ? AND updated_at > ?`,
    ).all(userId, since);

    groups = db.prepare(
      `SELECT id, name, color_hex, sort_order, created_at, COALESCE(client_updated_at, updated_at) AS updated_at
       FROM habit_groups WHERE user_id = ? AND updated_at > ?`,
    ).all(userId, since);

    const habitIds = db.prepare(
      "SELECT id FROM habits WHERE user_id = ?",
    ).all(userId).map((h) => /** @type {{ id: string }} */ (h).id);

    if (habitIds.length > 0) {
      const placeholders = habitIds.map(() => "?").join(",");
      entries = db.prepare(
        `SELECT id, habit_id, date, note, value, created_at, COALESCE(client_updated_at, updated_at) AS updated_at
         FROM habit_entries WHERE habit_id IN (${placeholders}) AND updated_at > ?`,
      ).all(...habitIds, since);
    } else {
      entries = [];
    }

    // Return tombstones created since last sync (DISTINCT prevents duplicate IDs on retry pushes)
    const tombstones = db.prepare(
      "SELECT DISTINCT entity_type, entity_id FROM deletion_tombstones WHERE user_id = ? AND deleted_at > ?"
    ).all(userId, since);

    deletedHabitIds = tombstones.map((t) => /** @type {TombstoneRow} */ (t)).filter((t) => t.entity_type === "habit").map((t) => t.entity_id);
    deletedEntryIds = tombstones.map((t) => /** @type {TombstoneRow} */ (t)).filter((t) => t.entity_type === "entry").map((t) => t.entity_id);
    deletedGroupIds = tombstones.map((t) => /** @type {TombstoneRow} */ (t)).filter((t) => t.entity_type === "group").map((t) => t.entity_id);
  } else {
    habits = db.prepare(`SELECT ${HABIT_COLS} FROM habits WHERE user_id = ?`).all(userId);
    groups = db.prepare(
      `SELECT id, name, color_hex, sort_order, created_at, COALESCE(client_updated_at, updated_at) AS updated_at
       FROM habit_groups WHERE user_id = ?`,
    ).all(userId);
    const habitIds = habits.map((h) => /** @type {HabitRow} */ (h).id);

    if (habitIds.length > 0) {
      const placeholders = habitIds.map(() => "?").join(",");
      entries = db.prepare(
        `SELECT id, habit_id, date, note, value, created_at, COALESCE(client_updated_at, updated_at) AS updated_at
         FROM habit_entries WHERE habit_id IN (${placeholders})`,
      ).all(...habitIds);
    } else {
      entries = [];
    }

    // Full pull: no tombstones needed (client reconciles against full set)
    deletedHabitIds = [];
    deletedEntryIds = [];
    deletedGroupIds = [];
  }

  return res.json({
    habits: habits.map((h) => { const row = /** @type {HabitRow} */ (h); return {
      id: row.id, name: row.name, emoji: row.emoji, colorHex: row.color_hex,
      isArchived: Boolean(row.is_archived), sortOrder: row.sort_order,
      reminderEnabled: Boolean(row.reminder_enabled), reminderHour: row.reminder_hour,
      reminderMinute: row.reminder_minute, note: row.note || null,
      kind: row.kind || "binary", targetValue: row.target_value, unit: row.unit || null,
      scheduleKind: row.schedule_kind || "daily", timesPerWeek: row.times_per_week,
      activeDaysMask: row.active_days_mask, groupId: row.group_id || null,
      createdAt: wireTime(row.created_at), updatedAt: wireTime(row.updated_at),
    }; }),
    entries: entries.map((e) => { const row = /** @type {EntryRow} */ (e); return {
      id: row.id, habitId: row.habit_id, date: row.date, note: row.note || null,
      value: row.value, createdAt: wireTime(row.created_at), updatedAt: wireTime(row.updated_at),
    }; }),
    groups: groups.map((g) => { const row = /** @type {GroupRow} */ (g); return {
      id: row.id, name: row.name, colorHex: row.color_hex, sortOrder: row.sort_order,
      createdAt: wireTime(row.created_at), updatedAt: wireTime(row.updated_at),
    }; }),
    deletedHabitIds,
    deletedEntryIds,
    deletedGroupIds,
    serverTime: new Date().toISOString(),
  });
});

module.exports = router;
