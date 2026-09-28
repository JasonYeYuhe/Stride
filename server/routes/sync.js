// @ts-check
const express = require("express");
const router = express.Router();

/** @typedef {{ id: string, name: string, emoji: string, color_hex: string, is_archived: number, sort_order: number, reminder_enabled: number, reminder_hour: number, reminder_minute: number, note: string|null, kind: string, target_value: number, unit: string|null, schedule_kind: string, times_per_week: number, active_days_mask: number, group_id: string|null, created_at: string, updated_at: string }} HabitRow */
/** @typedef {{ id: string, habit_id: string, date: string, note: string|null, value: number, created_at: string, updated_at: string }} EntryRow */
/** @typedef {{ id: string, name: string, color_hex: string, sort_order: number, created_at: string, updated_at: string }} GroupRow */
/** @typedef {{ entity_type: string, entity_id: string }} TombstoneRow */
const db = require("../db");
const { attachSessionUser, requireUser } = require("../auth");
const { clientAtLeast, clientInfo, errorBody } = require("../lib/clientVersion");
const { syncPauseGuard } = require("../lib/syncPause");
const { createSyncLimiter, createSyncAuthFailureLimiter } = require("../lib/rateLimits");
const metrics = require("../metrics");

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
 *
 * Each read that finds only the snake_case key is counted (metrics.js,
 * `snake_fallback.<camelKey>`): the shim goes when that counter has read zero for long
 * enough, not on a date.
 */
const toSnake = (k) => k.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase());
function field(obj, camelKey) {
  if (obj === null || obj === undefined) return undefined;
  const v = obj[camelKey];
  if (v !== undefined) return v;
  const snakeKey = toSnake(camelKey);
  if (snakeKey === camelKey) return undefined;
  const snake = obj[snakeKey];
  if (snake !== undefined) metrics.count(`snake_fallback.${camelKey}`);
  return snake;
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
 * A row's `updated_at` moves only when the push actually changes it. Every client up to 1.3.0
 * pushes a full snapshot on every sync, so bumping unchanged rows would put the whole dataset
 * back into every other device's incremental pull — and from 1.3.1, where a device pushes only
 * its changed rows, a 1.2.3 or 1.3.0 device's snapshot of the same rows must still change
 * nothing. The one deliberate exception is the LWW re-feed (the comment above habitValues): a push that
 * lost to a strictly newer edit with different values moves the winner back into the feed.
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
 * Timestamps go out at whole-second precision to apps before 1.3.1.
 *
 * Apps up to 1.2.2 parse them with a default ISO8601DateFormatter, which rejects fractional
 * seconds and returns nil. Anything this process stamps has milliseconds — including the whole
 * App Review demo account, seeded with toISOString() — and on nil the app fell back to Date(),
 * so a freshly signed-in device thought every demo habit was created today: its 30-day rate,
 * Weekly Review and trend chart all started from today. No header may mean one of those apps.
 * 1.2.3 and 1.3.0 read both forms in the reconciler (SyncTimestamp.parse), but were built and
 * tested against whole seconds and gain nothing from a fraction (their entry guard floors to
 * whole seconds), so the gate is the first version whose reconciler compares milliseconds.
 * @param {string|null|undefined} v
 */
function wireTime(v) {
  if (!v) return v;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? v : d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/**
 * Timestamps at full precision, for apps >= 1.3.1 (DEV-PLAN-1.3.md M2, "Millisecond edit
 * stamps"): toISOString()'s fixed-width `…:18.700Z`, the form every stored stamp is compared in.
 *
 * Why the pull must carry them, not only the push: served truncated, a remote edit at :18.700
 * arrives as :18.000, and a local edit at :18.300 looks newer to the 1.3.1 local-newer guard. It
 * is kept and pushed, the server keeps :18.700 and reports the push applied, the device
 * acknowledges it — and shows the losing value until the row changes again.
 * @param {string|null|undefined} v
 */
function wireTimeMs(v) {
  if (!v) return v;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? v : d.toISOString();
}

/*
 * The LWW re-feed (DEV-PLAN-1.3.md M2, "The LWW winner goes back to the device that lost").
 *
 * A push the guard keeps as older counts as `applied`, and a 1.3.1 device acknowledges it. The
 * winner reaches that device only if its `updated_at` is after the device's cursor, and in the
 * case that matters it is not: the device pulled the winner, then made an edit its slow clock
 * stamped earlier. From then on the device shows its own value and the server keeps another,
 * until the row changes again. So when an upsert changes nothing because the stored edit is
 * STRICTLY newer AND the values differ, the stored row's `updated_at` moves to now, and the
 * losing device's next pull brings the winner (the refeedMismatchedEntry precedent below).
 *
 * Both conditions are needed. Every 1.3.0 snapshot echoes a 1.3.1 millisecond stamp truncated
 * to whole seconds (:18.000 < :18.700) with the same values; re-feeding on the stamp alone
 * would put that row back into every device's feed on every sync, forever.
 *
 * "Values differ" means differ as an app holds them, not as the columns hold them. The pull
 * serves `note: ''` as null and `kind: ''` as "binary", the push stores an absent emoji as ⭐,
 * and a habit's groupId pointing at a deleted group is pushed as null while the stored row
 * keeps it (a group delete does not touch its habits here). A device that pulled the winner
 * and echoes it back through those rules is not holding a different value, and a re-feed it
 * cannot act on would repeat on every one of its syncs. So both sides go through the same
 * normalisation before they are compared. For the same reason a habit pushed with no `kind`
 * key is compared only on the fields that app has: `kind`, the schedule fields and `groupId`
 * all arrived together in 1.2.0 (v2), so a 1.1 app (the `habit_without_kind` population) can
 * never hold them, and re-feeding it the winner's would never end. Counted per kind (`lww_refeed.<kind>` in
 * metrics.js, `refed=` on the request line): a count that keeps climbing for one account is a
 * device that cannot hold the winner, which this reasoning says should not exist.
 */

/** @param {unknown} v */
const text = (v) => (v === null || v === undefined || v === "" ? null : String(v));

/**
 * A habit's values as an app ends up holding them, from a stored row or from a pushed row
 * after the push's own defaults (both keyed by column name). `v2Fields` false leaves out what
 * a 1.1 app cannot hold.
 * @param {Record<string, any>} v @param {Set<string>} deletedGroups @param {boolean} v2Fields
 */
function habitValues(v, deletedGroups, v2Fields) {
  const always = [
    text(v.name), text(v.emoji) ?? "⭐", text(v.color_hex) ?? "#34C759", v.is_archived ? 1 : 0,
    Number(v.sort_order || 0), v.reminder_enabled ? 1 : 0, Number(v.reminder_hour ?? 20),
    Number(v.reminder_minute ?? 0), text(v.note),
  ];
  if (!v2Fields) return always;
  const group = text(v.group_id);
  return [
    ...always, text(v.kind) ?? "binary", Number(v.target_value ?? 1), text(v.unit),
    text(v.schedule_kind) ?? "daily", Number(v.times_per_week ?? 7), Number(v.active_days_mask ?? 127),
    group !== null && !deletedGroups.has(group) ? group : null,
  ];
}
/** @param {Record<string, any>} v */
const entryValues = (v) => [text(v.note), Number(v.value ?? 1)];
/** @param {Record<string, any>} v */
const groupValues = (v) => [text(v.name), text(v.color_hex) ?? "#34C759", Number(v.sort_order || 0)];

/** @param {unknown[]} a @param {unknown[]} b */
const sameValues = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);


/*
 * The incremental-push contract (server half; the 1.3.1 client is DEV-PLAN-1.3.md M2).
 *
 * From 1.3.1 a device pushes only its changed rows, chunked, and marks a row synced only once
 * the server has accepted it. So the push response says, per row, what happened:
 *   applied — rows accepted. Includes rows the LWW guard kept as they were (the server already
 *             holds an edit at least as new) and identical re-sends: the device may treat them
 *             as delivered, and its next pull brings the newer version down — even when the
 *             device's cursor is past it, because a kept edit that is strictly newer and
 *             differs is moved back into the feed (the LWW re-feed, above habitValues).
 *   skipped — ids that were not written, with the reason for each in `skippedReasons`
 *             (`{habits:{id:reason}, entries:{…}, groups:{…}}`). The reason is what tells the
 *             device whether to drop the row or send it again, so it must not be guessed from
 *             the id alone:
 *               tombstoned        the row itself was deleted (earlier, or in this very push) — drop
 *               tombstoned_habit  an entry whose habit was deleted — drop
 *               missing_field     no name / habitId / date — never applies as sent
 *               row_error         SQLite refused the row (constraint, unbindable value)
 *               not_owned         a habit or group id that belongs to another account
 *               not_owned_habit   an entry whose habit id belongs to another account
 *               skipped_habit     an entry whose habit was in this push and was skipped — retry
 *                                 once the habit lands
 *               unknown_habit     an entry whose habit this server does not have at all (e.g.
 *                                 the habit's own chunk has not landed yet) — retry
 *               invalid_value     a number no app can produce: not finite, out of range, or a
 *                                 fraction where an app sends a whole number (PUSH_BOUNDS below)
 *                                 — never applies as sent; quarantine it, do not retry
 *             The two not_owned reasons are ids that exist under another account. With 1.3.1's
 *             account isolation (the store has one owner; there is no "keep this device's
 *             habits and add them to this account") only two paths reach them: a restore that
 *             kept another account's ids, and a device whose owner was unknown when the user
 *             chose to upload its habits. The device holds such a row — never acknowledges it
 *             (its full-pull rule would then delete it), never drops it — and offers "Restore
 *             as new copies", which gives it new ids.
 * Before 1.3.1 nothing read this — the apps decode only `ok` — and a dropped row was harmless
 * because the next snapshot re-sent it anyway. Once clients stop re-sending, a silent drop
 * becomes a row that is never synced, so it has to be visible.
 *
 * One malformed row must never fail the request: it is a 200 with a `skippedReasons` entry,
 * and SQLite errors are caught per row as `row_error`. A push's only 400s are envelope errors
 * (`invalid_payload`, `too_many_rows`), and the 1.3.1 client has one rule per answer, not
 * bisection (DEV-PLAN-1.3.md M2, "One rule per push answer"): `too_many_rows` re-chunks against
 * `limits`; `invalid_payload` stops the sync and backs off with every row still pending,
 * holding nothing, because the rows are not what is wrong; 5xx backs off. So a bad row that
 * failed its whole request — 400 or 500 — would stop that account syncing, permanently.
 */

/**
 * Row caps per request, for clients that chunk (>= 1.3.1).
 *
 * Rows only, not the deleted*Ids lists. The apps queue one deletedEntryId per check-in when a
 * habit is deleted (SettingsView: trackDeletedEntry for every record), so deleting a couple
 * of multi-year habits queues thousands of ids. M2's planner bounds each chunk by encoded
 * bytes as well as rows (<= 1 MB, deletion ids included), so a big queue is spread over
 * several chunks, but a count cap here would be one more limit every client must mirror
 * exactly — and a 400 on a deletion-only chunk that re-chunking could not fix would stop the
 * account syncing. Each id is one indexed DELETE and one tombstone INSERT; the 5 MB body limit
 * bounds them, as it always has. The planner's row bounds (200 / 500 / 2,000) sit inside these.
 */
const ROW_LIMITS = Object.freeze({ habits: 500, entries: 5000, groups: 200 });

/*
 * What a pushed number must be, or the row is skipped as `invalid_value`.
 *
 * Until 1.3.0 the server stored whatever arrived, and handed it to every other device on the
 * account. Every shipped app (<= 1.2.3) formats a count with `String(Int(value))` and reads a
 * target with `Int(targetValue)`, and `Int(Double)` traps on infinity or past 9.2e18: one
 * check-in of `1e19` — or `1e999`, which JSON.parse turns into Infinity — made Today trap on
 * every launch, on every device signed into the account. And they decode `sortOrder`,
 * `reminderHour`, `reminderMinute`, `timesPerWeek` and `activeDaysMask` as Swift `Int`, so a
 * `2.5` or a `1e19` there fails the decode of the whole pull: that account never syncs again.
 * 1.3.0 stops trapping (Shared/SafeNumber.swift), but 1.2.3 is what most people run, so the
 * server must stop carrying these rows.
 *
 * The bounds are what the apps themselves write, with room, so no well-behaved push changes:
 *   value, targetValue  finite within ±1e9. A tap adds 1 and the target stepper stops at 1,000;
 *                       ±1e9 is exactly DataBackup.checkAmount, what a 1.3.0 restore accepts, so
 *                       nothing a restore brings back is refused here. Negative is allowed: no
 *                       app writes one (a count at 1 is deleted, not decremented), but none traps
 *                       on one either — `String(Int(-3))` is fine, a negative ring trim draws
 *                       nothing, a target <= 0 is guarded in Habit.progress. Refusing it (the
 *                       first cut did, min 0) cost a restored habit: the push skipped it, its
 *                       entries read skipped_habit, and the next full pull, lacking them, made
 *                       SyncReconciler delete the habit and its check-ins on that device.
 *   sortOrder (habit)   a whole number within ±1e15 — pushed as `Int(sortOrder)`; the default is
 *                       the creation time in epoch seconds (~1.8e9), a reorder writes index×1000.
 *                       ±1e15 is DataBackup.maxSortOrder.
 *   sortOrder (group)   finite within ±1e15 — a Double in the apps (max + 1).
 *   reminderHour 0…23, reminderMinute 0…59 — a DatePicker's; timesPerWeek 1…7 — the stepper's;
 *   activeDaysMask 0…127 — seven weekday bits. All whole numbers.
 * An absent or null field is not checked: it takes the column default, as it always has (apps
 * before `kind` existed send no target at all). A string or boolean where a number belongs is
 * invalid — no app sends one, and SQLite would have stored it as text.
 */
const MAX_AMOUNT = 1e9;
const MAX_SORT_ORDER = 1e15;
/** @typedef {{ min: number, max: number, whole?: boolean }} Bound */
const PUSH_BOUNDS = Object.freeze({
  habits: /** @type {Record<string, Bound>} */ ({
    sortOrder: { min: -MAX_SORT_ORDER, max: MAX_SORT_ORDER, whole: true },
    targetValue: { min: -MAX_AMOUNT, max: MAX_AMOUNT },
    reminderHour: { min: 0, max: 23, whole: true },
    reminderMinute: { min: 0, max: 59, whole: true },
    timesPerWeek: { min: 1, max: 7, whole: true },
    activeDaysMask: { min: 0, max: 127, whole: true },
  }),
  entries: /** @type {Record<string, Bound>} */ ({ value: { min: -MAX_AMOUNT, max: MAX_AMOUNT } }),
  groups: /** @type {Record<string, Bound>} */ ({ sortOrder: { min: -MAX_SORT_ORDER, max: MAX_SORT_ORDER } }),
});

/**
 * A row's bounded numbers, each read once in either casing (field() counts a snake_case read,
 * so reading twice would double the count), or null if any is out of bounds.
 * @param {any} row @param {Record<string, Bound>} bounds
 * @returns {Record<string, unknown> | null}
 */
function boundedNumbers(row, bounds) {
  /** @type {Record<string, unknown>} */
  const out = {};
  for (const [key, b] of Object.entries(bounds)) {
    const v = field(row, key);
    out[key] = v;
    if (v === undefined || v === null) continue;
    if (typeof v !== "number" || !Number.isFinite(v) || v < b.min || v > b.max) return null;
    if (b.whole && !Number.isInteger(v)) return null;
  }
  return out;
}

/** Every array a push may carry, in either casing (see field()). */
const PUSH_ARRAYS = /** @type {const} */ ([
  "habits", "entries", "groups", "deletedHabitIds", "deletedEntryIds", "deletedGroupIds",
]);

/*
 * Change-feed cursors. Tombstones are kept forever for now (db.js sweepStaleData), so no
 * cursor is ever actually too old to be served correctly. The window is a contract with the
 * 1.3.1 client, enforced before sweeping comes back: once a 426 minimum-version floor has
 * retired every app <= 1.3.0 — 1.3.0 still pushes full snapshots and has no cursor_expired
 * handler, exactly like 1.2.3, so the floor must be at least 1.3.1 — tombstones older than
 * CURSOR_RETENTION_DAYS can be swept, and a client whose cursor predates what the server
 * still holds must do a full pull instead of trusting an incremental one that silently lacks
 * those deletions. The grace refuses cursors
 * 10 days before the sweep line, so a cursor accepted today can never need a tombstone that a
 * sweep running between two syncs has just removed.
 */
const CURSOR_RETENTION_DAYS = 365;

/** Row errors logged one line each per request; the rest are counted. */
const MAX_ROW_ERROR_LOG_LINES = 5;
const CURSOR_GRACE_DAYS = 10;

/** @param {unknown} v */
const isRow = (v) => typeof v === "object" && v !== null && !Array.isArray(v);

/** A row's id if it has a usable one. @param {unknown} row @returns {string|null} */
function rowId(row) {
  if (!isRow(row)) return null;
  const id = /** @type {any} */ (row).id;
  return typeof id === "string" && id !== "" ? id : null;
}

/**
 * A failure that belongs to one row, not to the request: a constraint SQLite refused (the
 * statement is rolled back, the transaction survives), or a value better-sqlite3 cannot bind
 * (an object or boolean where a string belongs — thrown before the statement runs).
 * Anything else — disk, lock, a bug — still fails the request.
 * @param {any} err
 */
function isRowError(err) {
  if (err instanceof TypeError || err instanceof RangeError) return true;
  const code = err?.code;
  return typeof code === "string" && (code.startsWith("SQLITE_CONSTRAINT") || code === "SQLITE_MISMATCH");
}

/**
 * Support tool, one account at a time: `ops/request-snapshot.js <email>` sets a flag, and the
 * next push or pull from that account's first 1.3.1+ device answers 409 snapshot_required —
 * that device marks every row dirty and re-uploads everything, repairing an account whose
 * server copy has gone wrong. One-shot: answering marks the request answered (when, and to
 * which build) instead of deleting it. The 409 can be lost on the way — a timeout, the app
 * suspended mid-sync — and the device then carries on incrementally with the repair never
 * run; a deleted row would leave support believing it had. `request-snapshot.js --list` shows
 * answered requests, and running it again for the email re-arms one. Clients before 1.3.1
 * have no handler for the 409, and push a full snapshot on every sync anyway, so they neither
 * see it nor use the request up.
 */
const takeSnapshotRequest = db.prepare(
  "UPDATE sync_snapshot_requests SET answered_at = ?, answered_client = ? WHERE user_id = ? AND answered_at IS NULL"
);

/** @param {import('express').Request} req @param {import('express').Response} res */
function answerSnapshotRequest(req, res) {
  if (!clientAtLeast(req, "1.3.1")) return false;
  const client = /** @type {import('../lib/clientVersion').ClientInfo} */ (clientInfo(req));
  const label = `${client.platform}/${client.version}(${client.build})`;
  if (takeSnapshotRequest.run(new Date().toISOString(), label, req.user.id).changes === 0) return false;
  res.locals.syncStats = { user: req.user.id, snapshotRequested: 1 };
  res.status(409).json(errorBody(req, "snapshot_required", "This account needs a full re-upload from this device."));
  return true;
}

// Order matters, cheapest refusal first: a paused server answers before any session lookup,
// and nobody's snapshot is parsed until the session and the per-account limit have passed.
// The 5 MB parser lives here rather than in index.js for that reason — index.js mounts this
// router ahead of the global 10kb parser, which would otherwise 413 every snapshot (see the
// comment on the parser below).
// Sync is exempt from the global per-IP limiter (lib/rateLimits.js), so requests WITHOUT a
// valid session get their own per-IP limit, between the session lookup and the 401: signed-in
// devices behind one NAT address never share a bucket, and token guessing still does.
router.use(syncPauseGuard);
router.use(attachSessionUser);
router.use(createSyncAuthFailureLimiter());
router.use(requireUser);
router.use(metrics.noteSyncClient);   // which app build this account syncs from (metrics.js)
router.use(createSyncLimiter());

// Why sync needs a larger body limit than the global 10kb: every client up to 1.3.0
// (SyncService.pushLocal) sends a FULL SNAPSHOT of every habit and every check-in on every
// sync, so the payload grows without bound. Measured against the old 10kb cap: one habit is
// 403 B and one entry 175 B, so 3 habits + 53 entries = 10,627 B returned 413 — under three
// weeks of daily use. Worse, sync() awaits pushLocal BEFORE pullRemote, so a 413 killed BOTH
// directions and never self-healed. 5mb is ~15 years of daily check-ins at the measured wire
// size, and stays the ONLY ceiling for those clients: they cannot chunk, so the row caps below
// apply to 1.3.1+ only. body-parser sets `req._body` and the first parser to run wins, so this
// one must run before the global parser — which is why index.js mounts this router first.
router.use(express.json({ limit: "5mb" }));

// POST /sync/push — mobile app pushes local changes to server
// Accepts { habits, entries, groups, deletedHabitIds, deletedEntryIds, deletedGroupIds }
// Returns { ok, applied: {habits, entries, groups}, skipped: {habits: [ids], entries: [ids], groups: [ids]},
//           skippedReasons: {habits: {id: reason}, entries: {…}, groups: {…}} }
router.post("/push", (req, res) => {
  const userId = req.user.id;
  const body = req.body ?? {};

  // A present-but-wrong field used to throw a TypeError inside the loop and answer 500. null
  // still means "none" — a test pins that for the shipped clients.
  /** @type {Record<string, unknown[]>} */
  const lists = {};
  for (const name of PUSH_ARRAYS) {
    const v = field(body, name);
    if (v === undefined || v === null) { lists[name] = []; continue; }
    if (!Array.isArray(v)) {
      return res.status(400).json(errorBody(req, "invalid_payload", `Sync data was malformed ("${name}" must be an array).`));
    }
    lists[name] = v;
  }
  const { habits, entries, groups } = lists;

  // Caps only for clients that chunk. A client before 1.3.1 — and 1.3.0, which still pushes a
  // full snapshot — cannot split its push, so a 400 would be exactly as fatal to it as a 413:
  // every sync fails, forever. The 5 MB body limit stays their only ceiling. For a chunking
  // client the caps turn "too big" into a diagnosable error naming the limits, instead of a
  // bare 413 or a request that holds the write lock for seconds.
  if (clientAtLeast(req, "1.3.1")) {
    const over = /** @type {(keyof typeof ROW_LIMITS)[]} */ (Object.keys(ROW_LIMITS))
      .filter((name) => lists[name].length > ROW_LIMITS[name]);
    if (over.length > 0) {
      return res.status(400).json(errorBody(req, "too_many_rows",
        `Too many rows in one request (${over.join(", ")}); split the push into smaller chunks.`,
        { limits: ROW_LIMITS }));
    }
  }

  if (answerSnapshotRequest(req, res)) return;

  // Deletion ids that are not non-empty strings cannot be anyone's row; bound as-is, an object
  // would throw and fail the whole push.
  let noId = 0;
  /** @param {unknown[]} ids @returns {string[]} */
  const idsOnly = (ids) => /** @type {string[]} */ (ids.filter((id) => {
    const ok = typeof id === "string" && id !== "";
    if (!ok) noId++;
    return ok;
  }));
  const deletedHabitIds = idsOnly(lists.deletedHabitIds);
  const deletedEntryIds = idsOnly(lists.deletedEntryIds);
  const deletedGroupIds = idsOnly(lists.deletedGroupIds);

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
      AND excluded.client_updated_at >= COALESCE(habits.client_updated_at, habits.updated_at, '')
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
    WHERE excluded.client_updated_at >= COALESCE(habit_entries.client_updated_at, habit_entries.updated_at, '')
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
      AND excluded.client_updated_at >= COALESCE(habit_groups.client_updated_at, habit_groups.updated_at, '')
      AND (habit_groups.client_updated_at IS NOT excluded.client_updated_at
        OR habit_groups.name IS NOT excluded.name OR habit_groups.color_hex IS NOT excluded.color_hex
        OR habit_groups.sort_order IS NOT excluded.sort_order)
  `);

  // The LWW re-feed (the comment above habitValues): the stored row, read only when an
  // upsert of an own row changed nothing, and the bump that puts it back into the feed.
  const storedHabit = db.prepare(`
    SELECT name, emoji, color_hex, is_archived, sort_order, reminder_enabled, reminder_hour,
           reminder_minute, note, kind, target_value, unit, schedule_kind, times_per_week,
           active_days_mask, group_id, COALESCE(client_updated_at, updated_at, '') AS edited
    FROM habits WHERE id = ? AND user_id = ?`);
  const storedEntry = db.prepare(
    "SELECT note, value, COALESCE(client_updated_at, updated_at, '') AS edited FROM habit_entries WHERE habit_id = ? AND date = ?"
  );
  const storedGroup = db.prepare(
    "SELECT name, color_hex, sort_order, COALESCE(client_updated_at, updated_at, '') AS edited FROM habit_groups WHERE id = ? AND user_id = ?"
  );
  const refeedHabit = db.prepare("UPDATE habits SET updated_at = ? WHERE id = ? AND user_id = ?");
  const refeedEntry = db.prepare("UPDATE habit_entries SET updated_at = ? WHERE habit_id = ? AND date = ?");
  const refeedGroup = db.prepare("UPDATE habit_groups SET updated_at = ? WHERE id = ? AND user_id = ?");

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
  const fetchHabitIds = db.prepare("SELECT id FROM habits WHERE user_id = ?");
  const habitExists = db.prepare("SELECT 1 FROM habits WHERE id = ?");
  const fetchGroupIds = db.prepare("SELECT id FROM habit_groups WHERE user_id = ?");

  /** @param {import('better-sqlite3').Statement} stmt @returns {Set<string>} */
  const idSet = (stmt, col = "id") =>
    new Set(/** @type {Record<string, string>[]} */ (stmt.all(userId)).map((r) => r[col]));

  const applied = { habits: 0, entries: 0, groups: 0 };
  /** Rows the LWW re-feed moved back into the feed (counted in `applied` too). */
  const refed = { habits: 0, entries: 0, groups: 0 };
  /** Skipped id -> reason, per kind; a Map keeps the order ids were skipped in. The first
   * reason wins when an id is sent twice. @type {{ habits: Map<string, string>, entries: Map<string, string>, groups: Map<string, string> }} */
  const skipped = { habits: new Map(), entries: new Map(), groups: new Map() };
  /** @type {Record<string, number>} */
  const reasons = {};
  /** @param {"habits"|"entries"|"groups"} kind @param {string} id @param {string} reason */
  const skip = (kind, id, reason) => {
    if (!skipped[kind].has(id)) skipped[kind].set(id, reason);
    reasons[reason] = (reasons[reason] ?? 0) + 1;
  };
  // A row error is logged, but the id is client text: raw, an id holding a newline wrote a
  // whole forged request line into the log, and one push of 5 MB of bad rows (no row caps
  // before 1.3.1) wrote a line per row. So the id is quoted and cut, and only the first few
  // rows per request get a line; the rest are counted (`reasons` on the request line).
  let rowErrors = 0;
  /** @param {"habits"|"entries"|"groups"} kind @param {string} id @param {any} err */
  const skipRowError = (kind, id, err) => {
    if (++rowErrors <= MAX_ROW_ERROR_LOG_LINES) {
      const why = String(`${err?.code ?? err?.name} ${err?.message}`).replace(/\s+/g, " ").slice(0, 200);
      console.warn(`[sync] push user=${userId} skipped ${kind} ${JSON.stringify(id.slice(0, 64))}: ${why}`);
    }
    skip(kind, id, "row_error");
  };

  const transaction = db.transaction(() => {
    // Load pre-existing tombstones to prevent cross-device resurrection
    const blockedHabits = idSet(fetchHabitTombstones, "entity_id");
    const blockedEntries = idSet(fetchEntryTombstones, "entity_id");
    const blockedGroups = idSet(fetchGroupTombstones, "entity_id");
    // This account's rows before the push. An upsert of an id outside these sets that changed
    // nothing hit the `user_id = ?` guard: the id is another account's row.
    // (Added to as rows are accepted, so an id sent twice in one push is not misread.)
    const ownGroups = idSet(fetchGroupIds);
    const ownHabitsSoFar = idSet(fetchHabitIds);

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
    for (const g of /** @type {any[]} */ (groups)) {
      const id = rowId(g);
      if (!id) { noId++; continue; }
      if (blockedGroups.has(id)) { skip("groups", id, "tombstoned"); continue; }
      if (!g.name) { skip("groups", id, "missing_field"); continue; }
      const num = boundedNumbers(g, PUSH_BOUNDS.groups);
      if (!num) { skip("groups", id, "invalid_value"); continue; }
      const v = { name: g.name, color_hex: field(g, "colorHex") || "#34C759", sort_order: num.sortOrder || 0 };
      const edited = isoOrNull(field(g, "updatedAt")) || now;
      try {
        const r = upsertGroup.run(
          id, userId, v.name, v.color_hex, v.sort_order,
          field(g, "createdAt") || now, now, edited,
          userId,
        );
        if (r.changes === 0) {
          if (!ownGroups.has(id)) { skip("groups", id, "not_owned"); continue; }
          const stored = /** @type {any} */ (storedGroup.get(id, userId));
          if (stored && stored.edited > edited && !sameValues(groupValues(stored), groupValues(v))) {
            refeedGroup.run(now, id, userId);
            refed.groups++;
          }
        }
        ownGroups.add(id);
        applied.groups++;
      } catch (err) {
        if (!isRowError(err)) throw err;
        skipRowError("groups", id, err);
      }
    }

    // Upsert habits — skip any that are tombstoned (deleted in this push or previously)
    for (const h of /** @type {any[]} */ (habits)) {
      const id = rowId(h);
      if (!id) { noId++; continue; }
      // Apps before `kind` existed (1.1) push habits without it, and the upsert below resets
      // the stored kind/target/unit to defaults: the field-wipe population, never measured.
      if (h.kind === undefined) metrics.count("habit_without_kind");
      if (blockedHabits.has(id)) { skip("habits", id, "tombstoned"); continue; }
      if (!h.name) { skip("habits", id, "missing_field"); continue; }
      const num = boundedNumbers(h, PUSH_BOUNDS.habits);
      if (!num) { skip("habits", id, "invalid_value"); continue; }
      // Drop a stale group reference (group deleted on another device)
      const rawGroupId = field(h, "groupId");
      const groupId = rawGroupId && !blockedGroups.has(rawGroupId) ? rawGroupId : null;
      // The values as written, keyed by column, so the re-feed compares exactly these.
      const v = {
        name: h.name, emoji: h.emoji || "⭐", color_hex: field(h, "colorHex") || "#34C759",
        is_archived: field(h, "isArchived") ? 1 : 0, sort_order: num.sortOrder || 0,
        reminder_enabled: field(h, "reminderEnabled") ? 1 : 0,
        reminder_hour: num.reminderHour ?? 20, reminder_minute: num.reminderMinute ?? 0,
        note: h.note ?? null,
        kind: h.kind || "binary", target_value: num.targetValue ?? 1, unit: h.unit ?? null,
        schedule_kind: field(h, "scheduleKind") || "daily", times_per_week: num.timesPerWeek ?? 7,
        active_days_mask: num.activeDaysMask ?? 127,
        group_id: groupId,
      };
      const edited = isoOrNull(field(h, "updatedAt")) || now;
      try {
        const r = upsertHabit.run(
          id, userId, v.name, v.emoji, v.color_hex, v.is_archived, v.sort_order,
          v.reminder_enabled, v.reminder_hour, v.reminder_minute, v.note,
          v.kind, v.target_value, v.unit, v.schedule_kind, v.times_per_week, v.active_days_mask,
          v.group_id,
          field(h, "createdAt") || now, now, edited,
          userId,
        );
        if (r.changes === 0) {
          if (!ownHabitsSoFar.has(id)) { skip("habits", id, "not_owned"); continue; }
          const stored = /** @type {any} */ (storedHabit.get(id, userId));
          const v2 = h.kind !== undefined;
          if (stored && stored.edited > edited
            && !sameValues(habitValues(stored, blockedGroups, v2), habitValues(v, blockedGroups, v2))) {
            refeedHabit.run(now, id, userId);
            refed.habits++;
          }
        }
        ownHabitsSoFar.add(id);
        applied.habits++;
      } catch (err) {
        if (!isRowError(err)) throw err;
        skipRowError("habits", id, err);
      }
    }

    // Read once, after this push's habit deletes and upserts: a habit created in this push
    // counts, one deleted in it does not. This was one SELECT per entry.
    const ownHabits = idSet(fetchHabitIds);

    // Upsert entries — skip any that are tombstoned (deleted in this push or previously)
    for (const e of /** @type {any[]} */ (entries)) {
      const id = rowId(e);
      if (!id) { noId++; continue; }
      if (blockedEntries.has(id)) { skip("entries", id, "tombstoned"); continue; }
      const entryHabitId = field(e, "habitId");
      if (!entryHabitId || !e.date) { skip("entries", id, "missing_field"); continue; }
      // Not one of this account's habits. Which case it is decides whether the device drops
      // the entry or keeps it for a retry (see the contract above), so say which. The lookup
      // runs only on this path.
      if (!ownHabits.has(entryHabitId)) {
        const reason = blockedHabits.has(entryHabitId) ? "tombstoned_habit"
          : habitExists.get(entryHabitId) ? "not_owned_habit"
          : skipped.habits.has(entryHabitId) ? "skipped_habit"
          : "unknown_habit";
        skip("entries", id, reason);
        continue;
      }
      // After the habit checks: an entry of a deleted habit is dropped, whatever its value.
      const num = boundedNumbers(e, PUSH_BOUNDS.entries);
      if (!num) { skip("entries", id, "invalid_value"); continue; }
      const v = { note: e.note ?? null, value: num.value ?? 1 };
      // Clients before 1.2.3 send no entry updatedAt; stamping those `now` keeps their
      // last-push-wins behaviour rather than letting them lose every conflict (and, being
      // `now`, never re-feeds).
      const edited = isoOrNull(field(e, "updatedAt")) || now;
      try {
        const r = upsertEntry.run(id, entryHabitId, e.date, v.note, v.value,
          field(e, "createdAt") || now, now, edited);
        // A row this upsert changed already carries updated_at = now. The entry's habit is
        // this account's (checked above), so the row at (habit, day) is too.
        if (r.changes === 0) {
          const stored = /** @type {any} */ (storedEntry.get(entryHabitId, e.date));
          if (stored && stored.edited > edited && !sameValues(entryValues(stored), entryValues(v))) {
            refeedEntry.run(now, entryHabitId, e.date);
            refed.entries++;
          } else {
            refeedMismatchedEntry.run(now, entryHabitId, e.date, id);
          }
        }
        applied.entries++;
      } catch (err) {
        if (!isRowError(err)) throw err;
        skipRowError("entries", id, err);
      }
    }
  });

  transaction();

  // After the commit: a push whose transaction threw re-fed nothing.
  for (const kind of /** @type {const} */ (["habits", "entries", "groups"])) {
    if (refed[kind] > 0) metrics.count(`lww_refeed.${kind}`, refed[kind]);
  }

  if (noId > 0) console.warn(`[sync] push user=${userId} dropped ${noId} row(s) with no usable id`);
  if (rowErrors > MAX_ROW_ERROR_LOG_LINES) {
    console.warn(`[sync] push user=${userId} skipped ${rowErrors - MAX_ROW_ERROR_LOG_LINES} more row(s) on row errors`);
  }
  res.locals.syncStats = {
    user: userId,
    in: {
      habits: habits.length, entries: entries.length, groups: groups.length,
      deletions: deletedHabitIds.length + deletedEntryIds.length + deletedGroupIds.length,
    },
    applied,
    skipped: { habits: skipped.habits.size, entries: skipped.entries.size, groups: skipped.groups.size },
    ...(refed.habits + refed.entries + refed.groups > 0 ? { refed } : {}),
    ...(Object.keys(reasons).length > 0 ? { reasons } : {}),
    ...(noId > 0 ? { noId } : {}),
  };
  return res.json({
    ok: true,
    applied,
    skipped: {
      habits: [...skipped.habits.keys()],
      entries: [...skipped.entries.keys()],
      groups: [...skipped.groups.keys()],
    },
    skippedReasons: {
      habits: Object.fromEntries(skipped.habits),
      entries: Object.fromEntries(skipped.entries),
      groups: Object.fromEntries(skipped.groups),
    },
  });
});

// GET /sync/pull — mobile app pulls all data from server
// Optional: ?since=ISO8601 to get only changes after a timestamp
// Returns { habits, entries, groups, deleted*Ids, serverTime, totals: {habits, entries, groups} }
router.get("/pull", (req, res) => {
  const userId = req.user.id;
  const rawSince = req.query.since;
  // `?since=a&since=b` arrives as an array, which used to reach SQLite and answer 500.
  if (rawSince !== undefined && typeof rawSince !== "string") {
    return res.status(400).json(errorBody(req, "invalid_payload", 'Sync request was malformed ("since" must be a single timestamp).'));
  }
  // Compared as a string against stored toISOString() values, so bring it to that format
  // first: "…:18Z" sorts AFTER "…:18.500Z" ('Z' > '.'), which silently dropped every row
  // written later in the same second as the cursor.
  const sinceIso = isoOrNull(rawSince);
  const since = sinceIso ?? rawSince;

  if (answerSnapshotRequest(req, res)) return;

  // Only for clients that know what to do with it (a full pull, then push). An app <= 1.3.0 has
  // no handler (1.3.0 sends the header but is below the gate): it would show the error and
  // retry the same cursor on every sync, forever — it keeps getting 200, which is correct for as
  // long as tombstones are never swept. A full pull (no since) is never refused.
  if (sinceIso && clientAtLeast(req, "1.3.1")) {
    const oldest = Date.now() - (CURSOR_RETENTION_DAYS - CURSOR_GRACE_DAYS) * 86400000;
    if (new Date(sinceIso).getTime() < oldest) {
      res.locals.syncStats = { user: userId, cursorExpired: 1 };
      return res.status(409).json(errorBody(req, "cursor_expired",
        "This device has not synced for too long; a full sync is needed.",
        { retentionDays: CURSOR_RETENTION_DAYS }));
    }
  }

  const HABIT_COLS = `id, name, emoji, color_hex, is_archived, sort_order,
              reminder_enabled, reminder_hour, reminder_minute, note,
              kind, target_value, unit, schedule_kind, times_per_week,
              active_days_mask, group_id,
              created_at, COALESCE(client_updated_at, updated_at) AS updated_at`;
  const GROUP_COLS = "id, name, color_hex, sort_order, created_at, COALESCE(client_updated_at, updated_at) AS updated_at";
  const ENTRY_COLS = "id, habit_id, date, note, value, created_at, COALESCE(client_updated_at, updated_at, created_at) AS updated_at";
  const OWN_HABITS = "SELECT id FROM habits WHERE user_id = ?";

  // One read transaction, so `totals` and the arrays describe the same snapshot. The server is
  // not the only writer (seed-demo.js and other scripts write from another process in WAL
  // mode), and a client that deletes whatever a full pull lacks must be able to tell a
  // complete response from one that raced a write: M2's rule is to delete only when the
  // totals equal the arrays.
  const read = db.transaction(() => {
    const totals = {
      habits: /** @type {{ n: number }} */ (db.prepare("SELECT COUNT(*) AS n FROM habits WHERE user_id = ?").get(userId)).n,
      entries: /** @type {{ n: number }} */ (db.prepare(
        `SELECT COUNT(*) AS n FROM habit_entries WHERE habit_id IN (${OWN_HABITS})`,
      ).get(userId)).n,
      groups: /** @type {{ n: number }} */ (db.prepare("SELECT COUNT(*) AS n FROM habit_groups WHERE user_id = ?").get(userId)).n,
    };

    if (since) {
      // Return tombstones created since last sync (DISTINCT prevents duplicate IDs on retry pushes)
      const tombstones = /** @type {TombstoneRow[]} */ (db.prepare(
        "SELECT DISTINCT entity_type, entity_id FROM deletion_tombstones WHERE user_id = ? AND deleted_at > ?"
      ).all(userId, since));
      /** @param {string} type */
      const deletedOf = (type) => tombstones.filter((t) => t.entity_type === type).map((t) => t.entity_id);
      return {
        totals,
        habits: db.prepare(`SELECT ${HABIT_COLS} FROM habits WHERE user_id = ? AND updated_at > ?`).all(userId, since),
        groups: db.prepare(`SELECT ${GROUP_COLS} FROM habit_groups WHERE user_id = ? AND updated_at > ?`).all(userId, since),
        entries: db.prepare(
          `SELECT ${ENTRY_COLS} FROM habit_entries WHERE habit_id IN (${OWN_HABITS}) AND updated_at > ?`,
        ).all(userId, since),
        deletedHabitIds: deletedOf("habit"),
        deletedEntryIds: deletedOf("entry"),
        deletedGroupIds: deletedOf("group"),
      };
    }
    return {
      totals,
      habits: db.prepare(`SELECT ${HABIT_COLS} FROM habits WHERE user_id = ?`).all(userId),
      groups: db.prepare(`SELECT ${GROUP_COLS} FROM habit_groups WHERE user_id = ?`).all(userId),
      entries: db.prepare(`SELECT ${ENTRY_COLS} FROM habit_entries WHERE habit_id IN (${OWN_HABITS})`).all(userId),
      // Full pull: no tombstones needed (client reconciles against full set)
      deletedHabitIds: [],
      deletedEntryIds: [],
      deletedGroupIds: [],
    };
  });
  const { totals, habits, entries, groups, deletedHabitIds, deletedEntryIds, deletedGroupIds } = read();

  // One branch, on the header: >= 1.3.1 compares milliseconds and needs them (wireTimeMs);
  // everything older keeps the whole seconds it can parse (wireTime).
  const stamp = clientAtLeast(req, "1.3.1") ? wireTimeMs : wireTime;

  res.locals.syncStats = {
    user: userId,
    pull: since ? "since" : "full",
    out: {
      habits: habits.length, entries: entries.length, groups: groups.length,
      deletions: deletedHabitIds.length + deletedEntryIds.length + deletedGroupIds.length,
    },
  };
  return res.json({
    habits: habits.map((h) => { const row = /** @type {HabitRow} */ (h); return {
      id: row.id, name: row.name, emoji: row.emoji, colorHex: row.color_hex,
      isArchived: Boolean(row.is_archived), sortOrder: row.sort_order,
      reminderEnabled: Boolean(row.reminder_enabled), reminderHour: row.reminder_hour,
      reminderMinute: row.reminder_minute, note: row.note || null,
      kind: row.kind || "binary", targetValue: row.target_value, unit: row.unit || null,
      scheduleKind: row.schedule_kind || "daily", timesPerWeek: row.times_per_week,
      activeDaysMask: row.active_days_mask, groupId: row.group_id || null,
      createdAt: stamp(row.created_at), updatedAt: stamp(row.updated_at),
    }; }),
    entries: entries.map((e) => { const row = /** @type {EntryRow} */ (e); return {
      id: row.id, habitId: row.habit_id, date: row.date, note: row.note || null,
      value: row.value, createdAt: stamp(row.created_at), updatedAt: stamp(row.updated_at),
    }; }),
    groups: groups.map((g) => { const row = /** @type {GroupRow} */ (g); return {
      id: row.id, name: row.name, colorHex: row.color_hex, sortOrder: row.sort_order,
      createdAt: stamp(row.created_at), updatedAt: stamp(row.updated_at),
    }; }),
    deletedHabitIds,
    deletedEntryIds,
    deletedGroupIds,
    serverTime: new Date().toISOString(),
    // Rows the server holds for this account, full-pull scope, on every pull. A client may
    // delete local rows missing from a full pull only when these equal the arrays' lengths.
    totals,
  });
});

module.exports = router;
