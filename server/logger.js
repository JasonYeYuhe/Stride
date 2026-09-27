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
  // Decoded for readability, but a control character stays escaped: `?since=%0A…` decoded
  // raw would start a forged line in the log.
  return rendered
    ? `${path}?${decodeURIComponent(rendered).replace(/[\x00-\x1f\x7f]/g, (c) => encodeURIComponent(c))}`
    : path;
}

/**
 * Render a handler's per-request counters (`res.locals.syncStats`) as ` key=value` pairs,
 * nested objects as `key=a:1,b:2`, e.g.
 *   sync user=12 in=habits:0,entries:3,groups:0,deletions:0 applied=habits:0,entries:3,groups:0 …
 *
 * This is how row volume is measured: once 1.3.1 pushes only changed rows, the counts per
 * request are what show whether it does (a push of 0/0/0 after an idle sync, one entry after
 * one tap) and which accounts are big enough to matter. Deliberately no "snapshot/incremental"
 * label: a chunking client cannot know which it is sending, and the counts say it anyway.
 *
 * @param {Record<string, unknown>|undefined} stats
 * @returns {string}
 */
function formatStats(stats) {
  if (!stats || typeof stats !== "object") return "";
  const parts = Object.entries(stats).map(([k, v]) =>
    v && typeof v === "object"
      ? `${k}=${Object.entries(v).map(([a, b]) => `${a}:${b}`).join(",")}`
      : `${k}=${v}`,
  );
  return parts.length > 0 ? ` sync ${parts.join(" ")}` : "";
}

/**
 * The X-Stride-Client header as it may appear in a log line: `ios/1.3.1(19)`, or `-` when
 * absent. It is client-controlled text, so anything outside [A-Za-z0-9./()_-] becomes `_`
 * (a newline could otherwise forge a whole log line) and it is cut at 40 characters.
 * Replaced rather than dropped, so a malformed header still looks malformed: the server
 * treats it as a legacy client (lib/clientVersion.js), and the log should show why.
 *
 * @param {unknown} header
 * @returns {string}
 */
function sanitizeClientHeader(header) {
  if (typeof header !== "string" || header === "") return "-";
  return header.slice(0, 40).replace(/[^A-Za-z0-9./()_-]/g, "_");
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
      `[${timestamp}] ${level} ${method} ${redactUrl(originalUrl)} ${status} ${duration}ms` +
        ` client=${sanitizeClientHeader(req.get("X-Stride-Client"))}` +
        formatStats(res.locals.syncStats),
    );
  });

  next();
}

module.exports = { requestLogger, redactUrl, formatStats, sanitizeClientHeader };
