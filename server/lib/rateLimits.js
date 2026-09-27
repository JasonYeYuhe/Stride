// @ts-check
const { rateLimit } = require("express-rate-limit");
const { errorBody } = require("./clientVersion");

/**
 * Rate limits, and when they are on.
 *
 * Tests run with NODE_ENV=test and every limiter bypassed, because the suite fires far
 * more than 100 requests from one IP. Setting SYNC_RATE_LIMIT_PER_MIN turns them back on
 * even under test, which is how the suite spawns a second server with a low limit to
 * prove the limiters actually bite.
 */
const rateLimitsEnabled =
  process.env.NODE_ENV !== "test" || process.env.SYNC_RATE_LIMIT_PER_MIN !== undefined;

/** @param {string|undefined} v @param {number} fallback */
function envInt(v, fallback) {
  const n = Number(v);
  return Number.isSafeInteger(n) && n > 0 ? n : fallback;
}

/** `/v1/sync`, `/v1/sync/…`, and the legacy `/sync` mount — not `/syncfoo`. */
const SYNC_PATH = /^\/(?:v1\/)?sync(?:\/|$)/;

/** @param {string} p */
function isSyncPath(p) {
  return SYNC_PATH.test(p);
}

/** @type {import('express').RequestHandler} */
const passThrough = (req, res, next) => next();

/**
 * Seconds until the caller's window resets, from what express-rate-limit put on the request.
 * @param {import('express').Request} req
 * @param {number} windowMs
 */
function retryAfterSeconds(req, windowMs) {
  const reset = /** @type {any} */ (req).rateLimit?.resetTime;
  const ms = reset instanceof Date ? reset.getTime() - Date.now() : windowMs;
  return Math.max(1, Math.ceil(ms / 1000));
}

/**
 * Global per-IP limit: 100 requests / 15 min (GLOBAL_RATE_LIMIT_PER_15MIN overrides).
 *
 * Sync is exempt. It was the one authenticated, high-frequency path sharing this bucket, so
 * a household or office behind one NAT address — or a single user whose chunked first
 * upload (M2) runs to a dozen requests — could lock every device on that address out of
 * sign-in as well as sync. Sync has its own per-account limiter below, which runs after
 * requireUser; an unauthenticated sync request costs one indexed session lookup and is
 * answered 401 before its body is read (routes/sync.js mounts the body parser last), and
 * those are limited per IP by createSyncAuthFailureLimiter below.
 */
function createGlobalLimiter() {
  if (!rateLimitsEnabled) return passThrough;
  return rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: envInt(process.env.GLOBAL_RATE_LIMIT_PER_15MIN, 100),
    standardHeaders: true,
    legacyHeaders: false,
    skip: (req) => isSyncPath(req.path),
    message: { error: "Too many requests, please try again later" },
  });
}

/**
 * Sync limit: 60 requests / minute per ACCOUNT (SYNC_RATE_LIMIT_PER_MIN overrides).
 *
 * Keyed by req.user.id, so it must run after requireUser. It used to be 30/min per IP,
 * which put every account behind one NAT address into one bucket. 60/min leaves a chunked
 * first upload (a few requests) and a push+pull every few seconds plenty of room, and stops
 * one looping client from monopolising the process.
 *
 * The 429 carries the code `rate_limited` and `retryAfterSeconds` (plus Retry-After) so a
 * 1.3.1 client backs off instead of reporting a sync error; errorBody keeps the old sentence
 * in `error` for the shipped apps, which display it.
 */
function createSyncLimiter() {
  if (!rateLimitsEnabled) return passThrough;
  const windowMs = 60 * 1000;
  return rateLimit({
    windowMs,
    limit: envInt(process.env.SYNC_RATE_LIMIT_PER_MIN, 60),
    standardHeaders: true,
    legacyHeaders: false,
    keyGenerator: (req) => `user:${req.user?.id}`,
    handler: (req, res) => {
      const retry = retryAfterSeconds(req, windowMs);
      res.locals.syncStats = { rateLimited: 1 };
      // The sentence is the old limiter's text, which is what shipped apps have shown until now.
      res.status(429).json(errorBody(req, "rate_limited", "Too many sync requests, please try again later",
        { retryAfterSeconds: retry }));
    },
  });
}

/**
 * Sync requests WITHOUT a valid session: 100 / 15 min per IP (SYNC_AUTH_FAILURE_LIMIT_PER_15MIN
 * overrides) — the global limiter's old allowance for them.
 *
 * Exempting sync from the global limiter (above) also exempted requests that fail
 * authentication, and the per-account limiter never sees those (it runs after requireUser):
 * token guessing and 401 floods on /v1/sync had no limit at all. This one counts only requests
 * with no session, so it runs between auth.js attachSessionUser and requireUser; a signed-in
 * device is skipped and never shares a bucket with its neighbours behind one NAT address. An
 * app whose session expired sends a handful of these an hour, far below the limit.
 */
function createSyncAuthFailureLimiter() {
  if (!rateLimitsEnabled) return passThrough;
  const windowMs = 15 * 60 * 1000;
  return rateLimit({
    windowMs,
    limit: envInt(process.env.SYNC_AUTH_FAILURE_LIMIT_PER_15MIN, 100),
    standardHeaders: true,
    legacyHeaders: false,
    skip: (req) => Boolean(req.user),
    handler: (req, res) => {
      const retry = retryAfterSeconds(req, windowMs);
      res.locals.syncStats = { rateLimited: 1, noSession: 1 };
      res.status(429).json(errorBody(req, "rate_limited", "Too many sync requests, please try again later",
        { retryAfterSeconds: retry }));
    },
  });
}

module.exports = {
  rateLimitsEnabled, isSyncPath, createGlobalLimiter, createSyncLimiter, createSyncAuthFailureLimiter,
};
