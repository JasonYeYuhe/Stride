const crypto = require("crypto");
const db = require("./db");

const SESSION_COOKIE = "stride_session";
const MAGIC_LINK_TTL_MS = 1000 * 60 * 30; // 30 min
const SESSION_TTL_MS = 1000 * 60 * 60 * 24 * 30; // 30 days

function now() {
  return Date.now();
}

function hashToken(token) {
  return crypto.createHash("sha256").update(token).digest("hex");
}

function safeCompareHashes(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const bufA = Buffer.from(a, "utf8");
  const bufB = Buffer.from(b, "utf8");
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function createOpaqueToken() {
  return crypto.randomBytes(32).toString("hex");
}

function parseCookies(req) {
  const header = req.headers.cookie;
  if (!header) return {};
  return Object.fromEntries(
    header.split(";").map((part) => {
      const [name, ...rest] = part.trim().split("=");
      return [name, decodeURIComponent(rest.join("="))];
    }),
  );
}

function buildCookie(value, maxAgeMs = SESSION_TTL_MS) {
  const parts = [
    `${SESSION_COOKIE}=${encodeURIComponent(value)}`,
    "Path=/",
    "HttpOnly",
    "Secure",
    "SameSite=Lax",
    `Max-Age=${Math.floor(maxAgeMs / 1000)}`,
  ];
  return parts.join("; ");
}

function buildClearCookie() {
  return `${SESSION_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`;
}

function getOrCreateUser(email) {
  const normalized = email.trim().toLowerCase();
  db.prepare("INSERT OR IGNORE INTO users (email) VALUES (?)").run(normalized);
  return db.prepare("SELECT id, email, tier, created_at FROM users WHERE email = ?").get(normalized);
}

function createMagicLinkToken(email) {
  const user = getOrCreateUser(email);
  const token = createOpaqueToken();
  const tokenHash = hashToken(token);
  const expiresAt = now() + MAGIC_LINK_TTL_MS;

  db.prepare(
    "INSERT INTO magic_link_tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)",
  ).run(user.id, tokenHash, expiresAt);

  return { user, token, expiresAt };
}

function consumeMagicLinkToken(token) {
  // Clean up expired tokens periodically
  db.prepare("DELETE FROM magic_link_tokens WHERE expires_at < ? OR used_at IS NOT NULL").run(now() - 86400000);

  const tokenHash = hashToken(token);
  const record = db.prepare(`
    SELECT magic_link_tokens.id, magic_link_tokens.user_id, magic_link_tokens.expires_at,
           magic_link_tokens.used_at, magic_link_tokens.is_reusable,
           users.email, users.created_at
    FROM magic_link_tokens
    INNER JOIN users ON users.id = magic_link_tokens.user_id
    WHERE magic_link_tokens.token_hash = ?
  `).get(tokenHash);

  if (!record || (!record.is_reusable && record.used_at) || record.expires_at < now()) {
    if (record && !record.is_reusable) {
      db.prepare("DELETE FROM magic_link_tokens WHERE id = ?").run(record.id);
    }
    return null;
  }

  if (!record.is_reusable) {
    db.prepare("UPDATE magic_link_tokens SET used_at = datetime('now') WHERE id = ?").run(record.id);
  }

  return { id: record.user_id, email: record.email, created_at: record.created_at };
}

function createSession(userId) {
  const token = createOpaqueToken();
  const tokenHash = hashToken(token);
  const expiresAt = now() + SESSION_TTL_MS;

  db.prepare(
    "INSERT INTO sessions (user_id, token_hash, expires_at) VALUES (?, ?, ?)",
  ).run(userId, tokenHash, expiresAt);

  return { token, expiresAt };
}

function getSessionUser(req) {
  const cookies = parseCookies(req);
  const sessionToken = cookies[SESSION_COOKIE] ?? null;
  if (!sessionToken) return null;

  const tokenHash = hashToken(sessionToken);
  const session = db.prepare(`
    SELECT sessions.id as session_id, sessions.user_id, sessions.expires_at,
           users.email, users.created_at, users.tier
    FROM sessions
    INNER JOIN users ON users.id = sessions.user_id
    WHERE sessions.token_hash = ?
  `).get(tokenHash);

  if (!session || session.expires_at < now()) {
    if (session) {
      db.prepare("DELETE FROM sessions WHERE id = ?").run(session.session_id);
    }
    return null;
  }

  return { id: session.user_id, email: session.email, tier: session.tier, created_at: session.created_at };
}

// For mobile app: auth via Bearer token instead of cookie
function getSessionUserFromHeader(req) {
  const authHeader = req.headers.authorization;
  if (authHeader && authHeader.startsWith("Bearer ")) {
    const token = authHeader.slice(7);
    const tokenHash = hashToken(token);
    const session = db.prepare(`
      SELECT sessions.id as session_id, sessions.user_id, sessions.expires_at,
             users.email, users.created_at, users.tier
      FROM sessions
      INNER JOIN users ON users.id = sessions.user_id
      WHERE sessions.token_hash = ?
    `).get(tokenHash);

    if (!session || session.expires_at < now()) {
      if (session) {
        db.prepare("DELETE FROM sessions WHERE id = ?").run(session.session_id);
      }
      return null;
    }

    return { id: session.user_id, email: session.email, tier: session.tier, created_at: session.created_at };
  }
  return null;
}

function clearSession(req) {
  const cookies = parseCookies(req);
  const sessionToken = cookies[SESSION_COOKIE];
  if (!sessionToken) return;
  db.prepare("DELETE FROM sessions WHERE token_hash = ?").run(hashToken(sessionToken));
}

function setSessionCookie(res, token) {
  res.setHeader("Set-Cookie", buildCookie(token));
}

function clearSessionCookie(res) {
  res.setHeader("Set-Cookie", buildClearCookie());
}

function requireUser(req, res, next) {
  const user = getSessionUserFromHeader(req) || getSessionUser(req);
  if (!user) return res.status(401).json({ error: "Unauthorized" });
  req.user = user;
  return next();
}

function deleteUserAccount(userId) {
  // Foreign keys with ON DELETE CASCADE handle magic_link_tokens and sessions.
  // Habits don't cascade, so delete entries first, then habits, then user.
  const habitIds = db.prepare("SELECT id FROM habits WHERE user_id = ?").all(userId).map(r => r.id);
  if (habitIds.length > 0) {
    const placeholders = habitIds.map(() => "?").join(",");
    db.prepare(`DELETE FROM habit_entries WHERE habit_id IN (${placeholders})`).run(...habitIds);
  }
  db.prepare("DELETE FROM habits WHERE user_id = ?").run(userId);
  db.prepare("DELETE FROM users WHERE id = ?").run(userId);
}

module.exports = {
  createMagicLinkToken,
  consumeMagicLinkToken,
  createSession,
  getSessionUser,
  getSessionUserFromHeader,
  setSessionCookie,
  clearSessionCookie,
  clearSession,
  deleteUserAccount,
  requireUser,
  getOrCreateUser,
  MAGIC_LINK_TTL_MS,
};
