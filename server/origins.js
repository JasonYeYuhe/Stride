// @ts-check

/**
 * The one origin this deployment answers on.
 *
 * It does two unrelated jobs, which is why it gets its own module: it is the CORS allowlist
 * entry (index.js) AND the host of the link in every magic-link email (routes/auth.js).
 *
 * The old default, "https://stride.colorarchive.me", does not resolve — DNS has a single A
 * record, for stride-api. The /login page that shows the token for copy-paste is served by
 * this Express process, and /login does not consume the token, so a user who follows a dead
 * link has no other way in: the app asks for a token they can never see. Production sets
 * FRONTEND_ORIGIN correctly today; this makes losing that variable a warning at startup
 * instead of silently breaking every login email.
 */
const DEFAULT_ORIGIN = "https://stride-api.colorarchive.me";

const frontendOrigin = process.env.FRONTEND_ORIGIN || DEFAULT_ORIGIN;

/** The link emailed for `token`. Its host must be one that serves GET /login. */
function loginUrl(token) {
  return `${frontendOrigin}/login?token=${encodeURIComponent(token)}`;
}

function warnIfUnset() {
  if (process.env.NODE_ENV === "production" && !process.env.FRONTEND_ORIGIN) {
    console.warn(
      `[config] FRONTEND_ORIGIN is not set; login emails will link to ${DEFAULT_ORIGIN} ` +
        "and CORS will allow only that origin.",
    );
  }
}

module.exports = { DEFAULT_ORIGIN, frontendOrigin, loginUrl, warnIfUnset };
