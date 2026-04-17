require("dotenv").config();
const express = require("express");
const path = require("path");
const cors = require("cors");
const helmet = /** @type {any} */ (require("helmet"));
const { rateLimit } = require("express-rate-limit");
const { requestLogger } = require("./logger");

const app = express();
const PORT = process.env.PORT || 3002;

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

// Global rate limit: 100 requests per 15 minutes per IP
const globalLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: "Too many requests, please try again later" },
});
app.use(globalLimiter);

const allowedOrigins = new Set([
  process.env.FRONTEND_ORIGIN || "https://stride.colorarchive.me",
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
  const token = req.query.token || "";
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

// Health check
app.get("/health", (req, res) => {
  res.json({ ok: true, version: "1.0.0", apiVersions: ["v1"], uptime: process.uptime() });
});

app.listen(PORT, () => {
  console.log(`Stride API running on port ${PORT}`);
});
