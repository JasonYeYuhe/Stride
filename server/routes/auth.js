// @ts-check
/// <reference path="../types.d.ts" />

const express = require("express");
const Sentry = require("@sentry/node");
const router = express.Router();
const { rateLimit } = require("express-rate-limit");
const {
  MAGIC_LINK_TTL_MS,
  clearSession,
  clearSessionCookie,
  consumeMagicLinkToken,
  createMagicLinkToken,
  createSession,
  deleteUserAccount,
  getSessionUser,
  getSessionUserFromHeader,
  requireUser,
  setSessionCookie,
} = require("../auth");
const { sendMagicLinkEmail } = require("../email");
const origins = require("../origins");


// Strict rate limit for magic link requests: 3 per 15 minutes per IP
const magicLinkLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 3,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: "Too many login attempts, please try again later" },
});

// Rate limit for token verification: 10 per 15 minutes per IP
const verifyLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: "Too many verification attempts, please try again later" },
});

// The answer when the login email could not be sent. The sentence is in `error` AND `message`,
// never the code: apps up to 1.3.0 print `error` verbatim and 1.3.1 prints `message ?? error`, so
// lib/clientVersion.js `errorBody`, which puts the code in `error` for any app that sends
// X-Stride-Client, would show 1.3.0 users "login_email_unavailable". An app that knows the code
// shows its own translated sentence and Contact Support (APIError.isLoginEmailUnavailable).
// "Failed to send login link" told nobody whose problem it was, or that retrying was pointless.
const LOGIN_EMAIL_UNAVAILABLE =
  "Stride couldn't send the login email right now. This is a problem on our side, not with your email address. Please try again later.";

// Request magic link email
router.post("/request-link", magicLinkLimiter, async (req, res) => {
  const { email } = req.body;

  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return res.status(400).json({ error: "Invalid email" });
  }

  try {
    const { token } = createMagicLinkToken(email);
    const loginUrl = origins.loginUrl(token);
    await sendMagicLinkEmail(email, {
      loginUrl,
      expiresInMinutes: Math.round(MAGIC_LINK_TTL_MS / 60000),
    });
    return res.json({ ok: true });
  } catch (err) {
    console.error("request-link error:", err);
    // Reported, not just logged: the magic link is the ONLY way to sign in, so a broken mail
    // provider (revoked key, unverified domain, quota) locks every signed-out user out, and a
    // log line alerts nobody. The event carries neither the address nor the link: the
    // scrubber (lib/sentryScrub.js) drops the request body and redacts emails and tokens from
    // the error message, which a provider error may quote. Nothing is added here to scrub.
    // Note: resend 3.x RETURNS API and network failures as `{ error }` instead of throwing, so
    // this only sees them once sendMagicLinkEmail (email.js) throws on that result.
    if (process.env.SENTRY_DSN) {
      Sentry.captureException(err, { tags: { area: "magic-link" }, level: "error" });
    }
    return res.status(500).json({
      error: LOGIN_EMAIL_UNAVAILABLE,
      code: "login_email_unavailable",
      message: LOGIN_EMAIL_UNAVAILABLE,
    });
  }
});

// Verify magic link token → create session
router.post("/verify", verifyLimiter, (req, res) => {
  const { token } = req.body;

  if (!token || typeof token !== "string") {
    return res.status(400).json({ error: "Missing token" });
  }

  const user = consumeMagicLinkToken(token);
  if (!user) {
    return res.status(400).json({ error: "Invalid or expired login link" });
  }

  const session = createSession(user.id);
  setSessionCookie(res, session.token);

  // Return session token for mobile app storage
  return res.json({
    ok: true,
    user,
    sessionToken: session.token,
  });
});

// Check current session
router.get("/session", (req, res) => {
  const user = getSessionUserFromHeader(req) || getSessionUser(req);
  return res.json({
    user: user ? { id: user.id, email: user.email, tier: user.tier, created_at: user.created_at } : null,
  });
});

// Logout
router.post("/logout", (req, res) => {
  clearSession(req);
  clearSessionCookie(res);
  return res.json({ ok: true });
});

// Delete account and all associated data
router.post("/delete-account", requireUser, (req, res) => {
  try {
    deleteUserAccount(req.user.id);
    clearSessionCookie(res);
    return res.json({ ok: true });
  } catch (err) {
    console.error("delete-account error:", err);
    return res.status(500).json({ error: "Failed to delete account" });
  }
});

module.exports = router;
