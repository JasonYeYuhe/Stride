// @ts-check
/**
 * Usage counters: which shipped behaviours are still in use, measured instead of guessed.
 *
 * Four things on this server exist only for apps that may no longer be installed, and each
 * costs something to keep:
 *   - the snake_case field() shim in routes/sync.js (<= 1.2.1 apps encode snake_case);
 *   - the legacy /sync, /auth and /habits mounts, and the REST /v1/habits routes the apps
 *     never call;
 *   - no 426 minimum-version floor, which is what keeps tombstones from being swept (db.js
 *     sweepStaleData) and the <= 1.2.3 full-snapshot push alive;
 *   - habits pushed with no `kind` (the 1.1 field-wipe population, never measured).
 * **These numbers decide when each of them can go — not a date.** A shim is removed when its
 * counter has read zero for long enough (the M6 gate is eight weeks), and the floor is raised
 * when `ops/usage-report.js` shows the legacy / < 1.3.1 cohort is gone. Guessing wrong in
 * either direction was measured once already: the snake_case bug silently dropped every
 * check-in from <= 1.2.1 apps (see field() in routes/sync.js).
 *
 * Counting is in memory (a Map increment per event, nothing on the request's critical path)
 * and bucketed by UTC hour. flush() runs hourly and on shutdown, and writes each bucket twice:
 *   - one `[metrics] {json}` log line, for reading next to the request log;
 *   - SQLite, `usage_counters` (additive upsert) and `user_clients` (the per-account cohort),
 *     because pm2-logrotate keeps ~30 days of logs and the decisions above need eight weeks
 *     or more.
 * Counter names:
 *   snake_fallback.<camelKey>  a field() read that found only the snake_case key (per row)
 *   habit_without_kind         a pushed habit with no `kind` key
 *   mount.<path>               a request on /sync, /auth, /habits or /v1/habits
 *   client.<label>             an API request from `ios/1.3.1(19)`-style label, `legacy`
 *                              (no or malformed X-Stride-Client), or `other` (label cap hit)
 *
 * No timers under NODE_ENV=test (index.js starts them); tests call flush() directly or stop
 * a server with SIGTERM.
 */

const db = require("./db");
const { clientInfo } = require("./lib/clientVersion");

const FLUSH_INTERVAL_MS = 60 * 60 * 1000;

/**
 * Distinct client labels counted per hour before the rest fold into `client.other`. The
 * header is parsed strictly (lib/clientVersion.js) but the build number is free, so without a
 * cap one script could write a row per request into usage_counters.
 */
const MAX_CLIENT_LABELS_PER_HOUR = 50;

/** Same idea for the cohort map: past this, new (account, client) pairs are counted as
 * `user_clients_dropped` instead of recorded. */
const MAX_PENDING_USER_CLIENTS = 10000;

/**
 * Distinct clients recorded per account per flush. The build number in the key is free text,
 * so one signed-in account varying it on every request added a permanent user_clients row
 * each time (kept 400 days) and could fill MAX_PENDING_USER_CLIENTS, pushing every other
 * account's pairs for that hour into `user_clients_dropped` — the cohort the 426 floor is
 * decided from. A real account syncs from one or two devices; 4 leaves room for an update
 * landing mid-hour on both.
 */
const MAX_CLIENTS_PER_ACCOUNT_PER_FLUSH = 4;

/** @type {Map<string, Map<string, number>>} hour -> counter name -> count */
let pending = new Map();

/** @type {Map<string, { userId: number, platform: string, version: string, build: number, first: string, last: string }>} */
let pendingClients = new Map();

/** @type {Map<number, number>} account id -> distinct clients in pendingClients */
let pendingClientsPerAccount = new Map();

/** UTC hour bucket, 'YYYY-MM-DDTHH' — a prefix of toISOString(), so it sorts and compares as one. */
function hourKey(ms = Date.now()) {
  return new Date(ms).toISOString().slice(0, 13);
}

/**
 * @param {string} name
 * @param {number} [by]
 */
function count(name, by = 1) {
  const hour = hourKey();
  let bucket = pending.get(hour);
  if (!bucket) pending.set(hour, (bucket = new Map()));
  bucket.set(name, (bucket.get(name) ?? 0) + by);
}

/**
 * `ios/1.3.1(19)`, or `legacy` for an app that sends no parseable X-Stride-Client — every
 * shipped build up to 1.2.3.
 * @param {import('express').Request} req
 */
function clientLabel(req) {
  const c = clientInfo(req);
  return c ? `${c.platform}/${c.version}(${c.build})` : "legacy";
}

/** @param {import('express').Request} req */
function countClient(req) {
  const hour = hourKey();
  const name = `client.${clientLabel(req)}`;
  const bucket = pending.get(hour);
  if (bucket && !bucket.has(name)) {
    let labels = 0;
    for (const k of bucket.keys()) if (k.startsWith("client.")) labels++;
    if (labels >= MAX_CLIENT_LABELS_PER_HOUR) { count("client.other"); return; }
  }
  count(name);
}

/**
 * Middleware for an API mount: counts the request's client label, and the mount itself when
 * given a counter name (the legacy mounts and /v1/habits).
 * @param {string} [mountCounter] e.g. "mount./sync"
 * @returns {import('express').RequestHandler}
 */
function countRequests(mountCounter) {
  return (req, res, next) => {
    countClient(req);
    if (mountCounter) count(mountCounter);
    next();
  };
}

/**
 * Remember which client an authenticated account synced from. Mounted in routes/sync.js
 * after requireUser: sync is what every signed-in app does on every launch, so it is the
 * cohort that matters for the 426 floor and for tombstone sweeping.
 * @param {import('express').Request} req
 * @param {import('express').Response} res
 * @param {import('express').NextFunction} next
 */
function noteSyncClient(req, res, next) {
  if (req.user) {
    const c = clientInfo(req);
    const platform = c ? c.platform : "legacy";
    const version = c ? c.version : "";
    const build = c ? c.build : 0;
    const key = `${req.user.id}|${platform}|${version}|${build}`;
    const now = new Date().toISOString();
    const seen = pendingClients.get(key);
    const forAccount = pendingClientsPerAccount.get(req.user.id) ?? 0;
    if (seen) seen.last = now;
    else if (pendingClients.size < MAX_PENDING_USER_CLIENTS && forAccount < MAX_CLIENTS_PER_ACCOUNT_PER_FLUSH) {
      pendingClients.set(key, { userId: req.user.id, platform, version, build, first: now, last: now });
      pendingClientsPerAccount.set(req.user.id, forAccount + 1);
    } else count("user_clients_dropped");
  }
  next();
}

const addCounter = db.prepare(`
  INSERT INTO usage_counters (hour, name, value) VALUES (?, ?, ?)
  ON CONFLICT(hour, name) DO UPDATE SET value = value + excluded.value
`);

// The account may have been deleted since the request (delete-account cascades user_clients
// away); inserting its row now would violate the foreign key and fail the whole flush.
const touchUserClient = db.prepare(`
  INSERT INTO user_clients (user_id, platform, version, build, first_seen, last_seen)
  SELECT ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM users WHERE id = ?)
  ON CONFLICT(user_id, platform, version, build) DO UPDATE SET
    first_seen = MIN(first_seen, excluded.first_seen),
    last_seen  = MAX(last_seen, excluded.last_seen)
`);

/**
 * Write everything counted so far to the log and to SQLite, then start from zero. On a
 * database error the counts are kept for the next flush rather than lost.
 * @returns {{ counters: Record<string, Record<string, number>>, userClients: number } | null}
 *   what was flushed, or null when there was nothing to flush (or the write failed)
 */
function flush() {
  if (pending.size === 0 && pendingClients.size === 0) return null;
  /** @type {Record<string, Record<string, number>>} */
  const counters = {};
  for (const [hour, bucket] of pending) counters[hour] = Object.fromEntries(bucket);
  const clients = [...pendingClients.values()];

  try {
    db.transaction(() => {
      for (const [hour, bucket] of pending) {
        for (const [name, value] of bucket) addCounter.run(hour, name, value);
      }
      for (const c of clients) {
        touchUserClient.run(c.userId, c.platform, c.version, c.build, c.first, c.last, c.userId);
      }
    })();
  } catch (err) {
    console.error("[metrics] flush failed, keeping counts for the next one:", err);
    return null;
  }

  pending = new Map();
  pendingClients = new Map();
  pendingClientsPerAccount = new Map();
  const flushed = { counters, userClients: clients.length };
  console.log(`[metrics] ${JSON.stringify(flushed)}`);
  return flushed;
}

/** @type {NodeJS.Timeout | null} */
let timer = null;

/** Hourly flush. Called by index.js outside NODE_ENV=test; the timer never holds the process open. */
function start() {
  if (timer) return;
  timer = setInterval(flush, FLUSH_INTERVAL_MS);
  timer.unref();
}

module.exports = {
  count,
  countRequests,
  noteSyncClient,
  clientLabel,
  flush,
  start,
  hourKey,
  MAX_CLIENT_LABELS_PER_HOUR,
  MAX_CLIENTS_PER_ACCOUNT_PER_FLUSH,
};
