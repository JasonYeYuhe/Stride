const express = require("express");
const router = express.Router();
const rateLimit = require("express-rate-limit");
const {
  MAGIC_LINK_TTL_MS,
  clearSession,
  clearSessionCookie,
  consumeMagicLinkToken,
  createMagicLinkToken,
  createSession,
  getSessionUser,
  getSessionUserFromHeader,
  setSessionCookie,
} = require("../auth");
const { sendMagicLinkEmail } = require("../email");

const FRONTEND_ORIGIN = process.env.FRONTEND_ORIGIN || "https://stride.colorarchive.me";

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

// Request magic link email
router.post("/request-link", magicLinkLimiter, async (req, res) => {
  const { email } = req.body;

  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return res.status(400).json({ error: "Invalid email" });
  }

  try {
    const { token } = createMagicLinkToken(email);
    const loginUrl = `${FRONTEND_ORIGIN}/login?token=${encodeURIComponent(token)}`;
    await sendMagicLinkEmail(email, {
      loginUrl,
      expiresInMinutes: Math.round(MAGIC_LINK_TTL_MS / 60000),
    });
    return res.json({ ok: true });
  } catch (err) {
    console.error("request-link error:", err);
    return res.status(500).json({ error: "Failed to send login link" });
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

module.exports = router;
