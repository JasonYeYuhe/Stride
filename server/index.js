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
const { rateLimit } = require("express-rate-limit");
const Sentry = require("@sentry/node");
const { requestLogger } = require("./logger");
const origins = require("./origins");
const db = require("./db");

// Error tracking — only active when a DSN is configured (so tests/dev stay quiet).
if (process.env.SENTRY_DSN) {
  Sentry.init({
    dsn: process.env.SENTRY_DSN,
    environment: process.env.NODE_ENV || "development",
    tracesSampleRate: Number(process.env.SENTRY_TRACES_SAMPLE_RATE ?? 0.1),
  });
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

// Serve static pages (terms, privacy, support) — after helmet so they get security headers
app.use(express.static(path.join(__dirname, "docs"), { extensions: ["html"] }));

// Request logging
app.use(requestLogger);

// Global rate limit: 100 requests per 15 minutes per IP (bypassed in test environment)
if (process.env.NODE_ENV !== "test") {
  const globalLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 100,
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: "Too many requests, please try again later" },
  });
  app.use(globalLimiter);
}

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

// The sync endpoints get their own, larger body parser, mounted BEFORE the
// global one. body-parser sets `req._body` and the first parser to run wins, so
// ordering here is load-bearing — moving this below the 10kb line silently
// restores the bug.
//
// Why it is needed: SyncService.pushLocal sends a FULL SNAPSHOT of every habit
// and every check-in on every sync (no incremental filter, no chunking), so the
// payload grows without bound while the cap stayed at 10kb. Measured against
// this exact config: one habit is 403 B and one entry 175 B, so 3 habits + 50
// entries = 10,099 B still passes and 3 habits + 53 entries = 10,627 B returns
// 413 "entity.too.large". That is under three weeks of daily use. Worse, sync()
// awaits pushLocal BEFORE pullRemote, so a 413 kills BOTH directions and never
// self-heals — the client just resends a larger payload next time.
//
// 5mb is ~15 years of daily check-ins at the measured wire size. Making the push
// incremental is the real fix, but it is a client change that needs App Review;
// this is deployable immediately and buys all the time that work needs.
app.use("/v1/sync", express.json({ limit: "5mb" }));
app.use("/sync", express.json({ limit: "5mb" }));   // legacy alias, mounted below

app.use(express.json({ limit: "10kb" }));

// API v1 routes
const authRouter = require("./routes/auth");
const habitsRouter = require("./routes/habits");
const syncRouter = require("./routes/sync");

app.use("/v1/auth", authRouter);
app.use("/v1/habits", habitsRouter);
app.use("/v1/sync", syncRouter);

// Legacy routes (backwards compatible, same handlers)
app.use("/auth", authRouter);
app.use("/habits", habitsRouter);
app.use("/sync", syncRouter);

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

// Health check — also verifies DB connectivity so a locked/corrupt SQLite
// reports unhealthy instead of falsely OK.
app.get("/health", (req, res) => {
  try {
    db.prepare("SELECT 1").get();
  } catch (err) {
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
    console.error(`[ERROR] ${req.method} ${req.originalUrl}:`, err && err.stack ? err.stack : err);
    if (process.env.SENTRY_DSN) Sentry.captureException(err);
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
    // Initial sweep + periodic GC of tombstones / expired sessions & magic links.
    const sweep = () => { try { /** @type {any} */ (db).sweepStaleData(); } catch (e) { console.error("[sweep] failed:", e); } };
    sweep();
    const sweepTimer = setInterval(sweep, 6 * 60 * 60 * 1000); // every 6h
    sweepTimer.unref();
  }
});

// Graceful shutdown: stop accepting connections, checkpoint the WAL, close DB.
function shutdown(signal) {
  console.log(`Received ${signal}, shutting down gracefully...`);
  // Release idle keep-alive sockets so close() resolves promptly (in-flight
  // requests still get to finish).
  if (typeof server.closeIdleConnections === "function") server.closeIdleConnections();
  server.close(() => {
    try {
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
