// @ts-check
const express = require("express");

/**
 * Test-only routes, for `scripts/sync_rehearsal.sh` — never for production.
 *
 * Two hooks:
 * - `POST /__test/sweep-tombstones {olderThanDays}` runs the real
 *   `sweepStaleData({tombstoneRetentionDays})` from db.js. M2's acceptance needs "a tombstone
 *   swept on the test server" (DEV-PLAN-1.3.md, M2 → sync_rehearsal.sh, *(review 2)*): Full
 *   resync and `snapshot_required` on a device still holding a row another device deleted must
 *   leave it deleted even after the tombstone that answers `tombstoned` is gone — the day
 *   sweeping returns behind a ≥ 1.3.1 426 floor. Production never sweeps tombstones today
 *   (index.js calls sweepStaleData() with no retention), so without this switch that scenario
 *   could only be rehearsed by editing SQLite behind the server's back, which would not run the
 *   sweep code production will run.
 * - `POST /__test/entry-date-guard {enabled}` switches routes/sync.js's entry-date guard
 *   (entryDateOk, X2) off or back on for this process. Off, a push stores entries on any date,
 *   as the server did before the guard was deployed on 2026-10-20: the rehearsal's K1–K3 seed
 *   the non-Gregorian keys a pre-1.4.1 build pushed back then, so the 1.4.1 repair is rehearsed
 *   on rows the server really holds, through the real push. The state is one flag,
 *   `app.locals.testEntryDateGuardOff`; sync.js skips the guard only when it is exactly `true`,
 *   and only this hook sets it, so a process without the hooks mounted always runs the guard.
 *
 * Unreachable in production — three gates, and any one of them is enough:
 * 1. `NODE_ENV` must be exactly `"test"`. Production is started with `NODE_ENV=production`
 *    (DEPLOY.md); an unset or misspelt value also fails closed. `scripts/rehearse_server.sh`
 *    boots its copy of the production database with `env -i … NODE_ENV=production`.
 * 2. `STRIDE_TEST_HOOKS` must be exactly `"1"`. The suite's main test server does not set it
 *    (serverEnv strips an inherited one), and `.env.example` does not mention it.
 *    Both are read once, when index.js mounts the router, and not mounted means no route at
 *    all: Express's own 404, the same answer as any unknown path, not an "access denied" that
 *    says something is there.
 * 3. Even when mounted, a request is served only from a loopback socket with no proxy headers.
 *    The deployed nginx block (DEPLOY.md, the `location /` that proxies to 127.0.0.1) sets
 *    X-Real-IP and X-Forwarded-For, so a test-mode process that somehow ended up behind it
 *    still answers anything from the internet with that same Express 404. nginx adds neither
 *    header by default: this gate holds only while those `proxy_set_header` lines do, which is
 *    why it is the third layer and not the first. Gates 1 and 2 depend on no proxy config.
 */

/** @param {NodeJS.ProcessEnv} env */
function testHooksEnabled(env) {
  return env.NODE_ENV === "test" && env.STRIDE_TEST_HOOKS === "1";
}

const LOOPBACK = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"]);

/** @type {import('express').RequestHandler} */
function loopbackOnly(req, res, next) {
  const h = req.headers;
  const proxied = h["x-forwarded-for"] !== undefined || h["x-real-ip"] !== undefined
    || h["forwarded"] !== undefined;
  // `next("router")` leaves this router, so the request falls through to Express's final
  // 404 exactly as if the hooks were not mounted.
  if (proxied || !LOOPBACK.has(req.socket.remoteAddress ?? "")) return next("router");
  next();
}

/**
 * Mount the test hooks on `app` when, and only when, the environment allows it.
 * @param {import('express').Express} app
 * @param {{ sweepStaleData: (opts?: { tombstoneRetentionDays?: number, belowCursorHorizon?: boolean }) => object }} db
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {boolean} whether anything was mounted
 */
function mountTestHooks(app, db, env = process.env) {
  if (!testHooksEnabled(env)) return false;

  const router = express.Router();
  router.use(loopbackOnly);
  router.post("/sweep-tombstones", (req, res) => {
    const days = req.body && req.body.olderThanDays;
    // 0 is allowed and is the useful value: every tombstone written before now goes, which is
    // what "deleted on B, then swept, then A wakes up" needs without waiting a year.
    if (typeof days !== "number" || !Number.isFinite(days) || days < 0) {
      return res.status(400).json({ error: "olderThanDays must be a number >= 0" });
    }
    // Any age: the rehearsal sweeps tombstones minutes old (db.js MIN_TOMBSTONE_RETENTION_DAYS).
    const swept = db.sweepStaleData({ tombstoneRetentionDays: days, belowCursorHorizon: true });
    res.json({ ok: true, swept });
  });
  router.post("/entry-date-guard", (req, res) => {
    const enabled = req.body && req.body.enabled;
    if (typeof enabled !== "boolean") {
      return res.status(400).json({ error: "enabled must be a boolean" });
    }
    app.locals.testEntryDateGuardOff = !enabled;
    // Loud for the same reason as the mount line: entries on any date are stored while it is off.
    console.warn(enabled
      ? "[test-hooks] entry-date guard ON"
      : "[test-hooks] entry-date guard OFF — pushes store entries on any date, as before 2026-10-20");
    res.json({ ok: true, enabled });
  });
  app.use("/__test", router);
  // Loud on purpose: a server log that shows this line anywhere but a test run is a bug.
  console.warn("[test-hooks] mounted /__test (NODE_ENV=test, STRIDE_TEST_HOOKS=1) — never in production");
  return true;
}

module.exports = { mountTestHooks, testHooksEnabled };
