// @ts-check
require("dotenv").config();

// APM tracing — must be initialized before any other instrumented library is
// required, so this stays at the very top. No-op without a Datadog agent.
if (process.env.NODE_ENV !== "test") {
  require("dd-trace").init({ logInjection: true });
}

const express = require("express");
const path = require("path");
const cors = require("cors");
const helmet = /** @type {any} */ (require("helmet"));
const { createGlobalLimiter } = require("./lib/rateLimits");
const Sentry = require("@sentry/node");
const { sentryInitOptions, routeTag } = require("./lib/sentryScrub");
const { checkDatabase } = require("./lib/health");
const { requestLogger, redactUrl } = require("./logger");
const metrics = require("./metrics");
const origins = require("./origins");
const db = require("./db");

// Error tracking — only active when a DSN is configured (so tests/dev stay quiet).
// Errors only: tracing defaults to 0 (it used to default to 0.1, a transaction with URLs for
// one request in ten, sync included), and every event, transaction and breadcrumb is scrubbed
// of bodies, headers, query strings, emails and tokens first — see lib/sentryScrub.js for what
// 8.x would otherwise send. dd-trace (above) instruments the same http calls but reports only
// to a local Datadog agent; it adds nothing to Sentry events.
if (process.env.SENTRY_DSN) {
  Sentry.init(sentryInitOptions(process.env));
}

origins.warnIfUnset();

const app = express();
const PORT = Number(process.env.PORT) || 3002;

// Behind nginx (single hop): trust the first proxy so express-rate-limit and
// req.ip key on the real client IP from X-Forwarded-For, not the loopback
// upstream (otherwise every user shares one rate-limit bucket).
app.set("trust proxy", 1);

// Security headers — allow inline styles for HTML pages (docs + /login use <style> blocks)
// style-src 'unsafe-inline' is safe: inline styles cannot execute scripts
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      ...helmet.contentSecurityPolicy.getDefaultDirectives(),
      "style-src": ["'self'", "'unsafe-inline'"],
    },
  },
}));

// Apple App Site Association: the server half of one-tap sign-in (M1). With it, iOS opens
// the magic link `/login?token=…` from the email straight in the app instead of the /login
// page below, which stays for devices without the app update. Apple's CDN fetches this file
// and caches it for hours, so it has to answer correctly before the app that relies on it
// ships, and exactly as Apple wants it: 200, `application/json`, no redirect, no auth. It
// sits above the static handler, the logger and every limiter so none of them can turn a
// CDN fetch into a 404, a 429 or a redirect. Content-Type is set on the raw response —
// res.json() would append `; charset=utf-8` — and HEAD gets the same headers (`curl -sI` is
// the acceptance check; Express routes HEAD to this GET handler, Node drops the body).
const APPLE_APP_SITE_ASSOCIATION = JSON.stringify({
  applinks: {
    details: [{
      appIDs: ["KHMK6Q3L3K.yyh.stride.habittracker"],
      components: [{ "/": "/login", "?": { token: "*" } }],
    }],
  },
});
app.get("/.well-known/apple-app-site-association", (req, res) => {
  res.statusCode = 200;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Content-Length", Buffer.byteLength(APPLE_APP_SITE_ASSOCIATION));
  res.end(APPLE_APP_SITE_ASSOCIATION);
});

// Serve static pages (terms, privacy, support) — after helmet so they get security headers
app.use(express.static(path.join(__dirname, "docs"), { extensions: ["html"] }));

// Request logging
app.use(requestLogger);

// Global rate limit: 100 requests per 15 minutes per IP, sync exempt — it has its own
// per-account limiter (lib/rateLimits.js). Bypassed under NODE_ENV=test unless the test
// sets SYNC_RATE_LIMIT_PER_MIN.
app.use(createGlobalLimiter());

const allowedOrigins = new Set([
  origins.frontendOrigin,
  ...(process.env.NODE_ENV !== "production"
    ? ["http://localhost:3000", "http://127.0.0.1:3000"]
    : []),
]);

app.use(
  cors({
    origin(origin, callback) {
      // Allow requests with no origin (mobile apps, curl)
      if (!origin || allowedOrigins.has(origin)) {
        return callback(null, true);
      }
      return callback(new Error("Not allowed by CORS"));
    },
    methods: ["GET", "POST", "PUT", "DELETE"],
    credentials: true,
  }),
);

// Sync is mounted BEFORE the global 10kb body parser, and parses its own bodies (5 MB)
// only after the pause switch, the session and the per-account rate limit have passed —
// see routes/sync.js. body-parser sets `req._body` and the first parser to run wins, so
// this ordering is load-bearing: mounting sync below the 10kb line 413s every full-snapshot
// push (3 habits + 53 entries already exceed 10kb), and since the apps push before they
// pull, that stops sync in both directions for good.
const syncRouter = require("./routes/sync");
// metrics.countRequests counts each API request's client label, and hits on the mounts no
// current app should be using — those counters decide when the mounts can go (metrics.js).
app.use("/v1/sync", metrics.countRequests(), syncRouter);
app.use("/sync", metrics.countRequests("mount./sync"), syncRouter);   // legacy alias

app.use(express.json({ limit: "10kb" }));

// API v1 routes
const authRouter = require("./routes/auth");
const habitsRouter = require("./routes/habits");

app.use("/v1/auth", metrics.countRequests(), authRouter);
// The apps never call the REST habit routes (they sync), so /v1/habits is counted like a
// legacy mount.
app.use("/v1/habits", metrics.countRequests("mount./v1/habits"), habitsRouter);

// Legacy routes (backwards compatible, same handlers)
app.use("/auth", metrics.countRequests("mount./auth"), authRouter);
app.use("/habits", metrics.countRequests("mount./habits"), habitsRouter);

// Magic link login page — handles email link taps from mobile
app.get("/login", (req, res) => {
  const token = /** @type {string} */ (req.query.token) || "";
  /** @param {string} s @returns {string} */
  const escapeHtml = (s) =>
    s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
     .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  const safeToken = escapeHtml(token);
  res.send(`<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Stride - Complete Login</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
display:flex;justify-content:center;align-items:center;min-height:100vh;background:#f5f5f7;color:#1d1d1f}
.card{background:#fff;border-radius:16px;padding:48px 32px;text-align:center;max-width:420px;width:90%;
box-shadow:0 2px 12px rgba(0,0,0,0.08)}
.icon{font-size:56px;margin-bottom:16px}
h1{font-size:22px;font-weight:600;margin-bottom:8px}
p{font-size:15px;color:#86868b;margin-bottom:16px;line-height:1.5}
.token-box{background:#f5f5f7;border-radius:8px;padding:12px;margin:16px 0;word-break:break-all;
font-family:monospace;font-size:11px;color:#424245;user-select:all;-webkit-user-select:all}
.steps{text-align:left;margin:16px 0;font-size:14px;color:#424245}
.steps li{margin-bottom:8px}
</style></head><body>
<div class="card">
<div class="icon">✉️</div>
<h1>Complete Login in Stride</h1>
<p>Your login link has been verified. To complete sign-in, go back to the <strong>Stride</strong> app and paste the code below.</p>
<ol class="steps">
<li>Copy the code below</li>
<li>Switch back to <strong>Stride</strong></li>
<li>Paste it in the login screen</li>
</ol>
${safeToken ? `<div class="token-box">${safeToken}</div>` : '<p style="color:#ff3b30">No login token found. Please request a new login link from Stride.</p>'}
</div></body></html>`);
});

// Health check — also reads the tables every sign-in and sync touches (lib/health.js), so a
// locked, corrupt or wrong SQLite file reports unhealthy instead of falsely OK. Hit every
// minute by the uptime monitor (DEPLOY.md), so it stays O(1) and reports to the log only.
app.get("/health", (req, res) => {
  try {
    checkDatabase(db);
  } catch (err) {
    console.error(`[health] database check failed: ${err && err.message}`);
    return res.status(503).json({ ok: false, error: "database unavailable" });
  }
  res.json({ ok: true, version: "1.0.0", apiVersions: ["v1"], uptime: process.uptime() });
});

// Global error handler — must be last. Preserves client-error statuses
// (e.g. 413 payload too large, 400 malformed JSON) but never leaks stack
// traces or internal messages for 5xx.
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  const status = err.status || err.statusCode || 500;
  if (status >= 500) {
    // redactUrl: the same /login?token= leak the request log was fixed for (logger.js).
    console.error(`[ERROR] ${req.method} ${redactUrl(req.originalUrl)}:`, err && err.stack ? err.stack : err);
    // Sentry.init runs after express is loaded, so the SDK attaches no `request` to events (no
    // per-request scope; lib/sentryScrub.js). The route PATTERN says which endpoint failed:
    // `/v1/habits/:id`, never the id, never the query string.
    if (process.env.SENTRY_DSN) {
      const route = routeTag(req.method, req.originalUrl, req.route && req.route.path);
      Sentry.captureException(err, { tags: { route } });
    }
  }
  if (res.headersSent) return next(err);
  const message = status >= 500
    ? "Internal server error"
    : (err.expose && err.message ? err.message : "Bad request");
  res.status(status).json({ error: message });
});

// Bind to loopback. This listened on 0.0.0.0 with ufw inactive, so
// http://<public-ip>:3002/ answered 200 straight off the internet and nginx —
// which terminates TLS and is the only thing setting X-Forwarded-For — was
// bypassable. That mattered more than the missing TLS: `app.set("trust proxy", 1)`
// above means Express trusts one hop of XFF, and a caller reaching Node directly
// IS that hop, so it could forge req.ip and mint a fresh rate-limit bucket per
// request. Demonstrated 2026-07-27: the same forged XFF decremented one bucket, a
// different value got a fresh allowance. That made magicLinkLimiter on the
// unauthenticated POST /auth/request-link a no-op — an unmetered mail sender on a
// Resend key SHARED with ColorArchive, so abuse here would have broken that
// project's magic-link login and transactional email too.
//
// nginx already proxies to http://localhost:3002 (stride-api.colorarchive.me) and
// already sets X-Forwarded-For correctly, so restricting the bind surface costs
// nothing and makes every per-IP limiter in this process real.
const BIND_HOST = process.env.BIND_HOST || "127.0.0.1";

const server = app.listen(PORT, BIND_HOST, () => {
  console.log(`Stride API running on ${BIND_HOST}:${PORT}`);
  if (process.env.NODE_ENV !== "test") {
    // Initial sweep + periodic GC of expired sessions & magic links. Tombstones are kept —
    // see sweepStaleData in db.js for why, and what would turn their sweeping back on.
    const sweep = () => { try { /** @type {any} */ (db).sweepStaleData(); } catch (e) { console.error("[sweep] failed:", e); } };
    sweep();
    const sweepTimer = setInterval(sweep, 6 * 60 * 60 * 1000); // every 6h
    sweepTimer.unref();
    // Hourly usage-counter flush (log line + SQLite); shutdown() flushes the remainder.
    metrics.start();
  }
});

// Graceful shutdown: stop accepting connections, checkpoint the WAL, close DB.
function shutdown(signal) {
  console.log(`Received ${signal}, shutting down gracefully...`);
  // Counters live in memory until flushed; without this every deploy (pm2 restart) would
  // lose up to an hour of them. Flushed again below for requests that finish meanwhile.
  metrics.flush();
  // Release idle keep-alive sockets so close() resolves promptly (in-flight
  // requests still get to finish).
  if (typeof server.closeIdleConnections === "function") server.closeIdleConnections();
  server.close(() => {
    try {
      metrics.flush();
      db.pragma("wal_checkpoint(TRUNCATE)");
      db.close();
    } catch (e) {
      console.error("Error during DB shutdown:", e);
    }
    process.exit(0);
  });
  // Force-exit if connections linger.
  setTimeout(() => process.exit(1), 10000).unref();
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
