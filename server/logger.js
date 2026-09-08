// @ts-check


/** Query params whose values must never reach the log. */
const SECRET_PARAMS = new Set(["token", "session", "session_token", "sessionToken", "key", "password"]);

/**
 * Strip secrets out of a URL before logging it.
 *
 * The magic-link email points at `/login?token=<token>` (routes/auth.js), so
 * logging `originalUrl` verbatim wrote every live login token into the
 * application log — and hitting /login does NOT consume the token, it only
 * renders it for the user to paste, so each logged token stayed valid until it
 * was used or expired. Anyone who could read the PM2 logs could sign in as that
 * user. Tokens are also accepted in POST bodies, which are not logged.
 *
 * @param {string} url
 * @returns {string}
 */
function redactUrl(url) {
  const q = url.indexOf("?");
  if (q === -1) return url;
  const path = url.slice(0, q);
  const params = new URLSearchParams(url.slice(q + 1));
  for (const name of params.keys()) {
    if (SECRET_PARAMS.has(name)) params.set(name, "[REDACTED]");
  }
  const rendered = params.toString();
  return rendered ? `${path}?${decodeURIComponent(rendered)}` : path;
}

/**
 * Simple request logger middleware.
 * @param {import('express').Request} req
 * @param {import('express').Response} res
 * @param {import('express').NextFunction} next
 */
function requestLogger(req, res, next) {
  const start = Date.now();
  const { method, originalUrl } = req;

  res.on("finish", () => {
    const duration = Date.now() - start;
    const status = res.statusCode;
    const level = status >= 500 ? "ERROR" : status >= 400 ? "WARN" : "INFO";
    const timestamp = new Date().toISOString();
    console.log(
      `[${timestamp}] ${level} ${method} ${redactUrl(originalUrl)} ${status} ${duration}ms`,
    );
  });

  next();
}

module.exports = { requestLogger, redactUrl };
