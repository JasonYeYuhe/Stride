// @ts-check
const fs = require("fs");
const path = require("path");
const { errorBody } = require("./clientVersion");

/**
 * The sync pause switch: every /v1/sync/* (and legacy /sync/*) request answers
 * `503 {error:"sync_paused", retryAfterSeconds}` while it is on, for every client (an app
 * that sends no X-Stride-Client gets the sentence in `error` instead — see errorBody).
 *
 * It exists for the day the server cannot take the sync load or a bad deploy needs the
 * fleet held still while it is rolled back. 1.3.1+ clients back off with jitter and show
 * "sync paused"; older clients show the error in Settings and try again on their next sync,
 * which is exactly what they do for any failed sync today. It is deliberately NOT a
 * "re-upload everything" switch — told to snapshot all at once, every client would push its
 * whole history in the same minute (see snapshot requests in routes/sync.js, which are
 * per-account only).
 *
 * Two ways to turn it on, both read on every request so neither needs a restart:
 * - `SYNC_PAUSED=1` (or `true`) in the environment — takes a `pm2 restart --update-env`;
 * - a flag file at `SYNC_PAUSE_FILE` (default `server/SYNC_PAUSED`): `touch` it to pause,
 *   `rm` it to resume. If it holds an integer, that is the Retry-After in seconds.
 *
 * The flag file is gitignored and MUST stay out of the deploy rsync: carried to the host it
 * would pause every user. The test harness points SYNC_PAUSE_FILE outside the repo for the
 * same reason.
 *
 * Mounted before requireUser and before the 5 MB body parser, so a paused server answers
 * without a session lookup or parsing a snapshot.
 */

const DEFAULT_PAUSE_FILE = path.join(__dirname, "..", "SYNC_PAUSED");
const DEFAULT_RETRY_AFTER_SECONDS = 900;

/** @param {unknown} v @returns {number|null} */
function positiveInt(v) {
  if (typeof v !== "string" || !/^\s*\d+\s*$/.test(v)) return null;
  const n = Number(v.trim());
  return n > 0 && Number.isSafeInteger(n) ? n : null;
}

/** @returns {{ paused: boolean, retryAfterSeconds: number }} */
function syncPauseState() {
  const envPaused = ["1", "true"].includes(String(process.env.SYNC_PAUSED ?? "").trim().toLowerCase());
  /** @type {string|null} */
  let flag = null;
  try {
    flag = fs.readFileSync(process.env.SYNC_PAUSE_FILE || DEFAULT_PAUSE_FILE, "utf8");
  } catch {
    // ENOENT is the normal, unpaused case. Anything else (a directory, no permission) is
    // also read as "no flag": a broken flag must not take sync down.
  }
  const paused = envPaused || flag !== null;
  const retryAfterSeconds = positiveInt(flag)
    ?? positiveInt(process.env.SYNC_PAUSE_RETRY_AFTER_SECONDS)
    ?? DEFAULT_RETRY_AFTER_SECONDS;
  return { paused, retryAfterSeconds };
}

/** @type {import('express').RequestHandler} */
function syncPauseGuard(req, res, next) {
  const { paused, retryAfterSeconds } = syncPauseState();
  if (!paused) return next();
  res.set("Retry-After", String(retryAfterSeconds));
  res.locals.syncStats = { paused: 1 };
  return res.status(503).json(errorBody(req, "sync_paused",
    "Sync is paused for maintenance. Your data is safe on this device; it will sync when the pause ends.",
    { retryAfterSeconds }));
}

module.exports = { syncPauseGuard, syncPauseState, DEFAULT_PAUSE_FILE };
