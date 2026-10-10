// @ts-check

/**
 * What the server may send to Sentry, and what it must not.
 *
 * @sentry/node 8.x attaches a lot to every event by default, and this server's requests are
 * the worst possible input for that:
 *   - the request BODY (8.x reads incoming bodies itself, SentryHttpInstrumentation
 *     patchRequestToCaptureBody): a sync push holds every habit name and note the account
 *     has; /auth/request-link holds an email address; /auth/verify holds a live magic-link
 *     or demo token;
 *   - the request HEADERS: `Authorization: Bearer <session token>` on every sync call, the
 *     session cookie, and X-Forwarded-For (the user's IP — nginx sets it);
 *   - the QUERY STRING: `/login?token=<magic-link token>` (the URL in the email; hitting it
 *     does not consume the token — see logger.js redactUrl, which fixed the same leak in the
 *     log) and `/v1/sync/pull?since=…`;
 *   - `event.user` from req.user, whose `email` the RequestData integration copies by default;
 *   - console breadcrumbs: every console.log/error line becomes a breadcrumb, and not only
 *     the failing request's. index.js calls Sentry.init after express (and so http) is
 *     loaded, so the SDK never forks a per-request scope: every line of the WHOLE process
 *     lands on one global scope, and an event carried the last 100 of them — other accounts'
 *     `sync user=<id>` lines, their `[ERROR]` stacks, whatever a mail provider's message quoted
 *     (reproduced by the 2026-09-28 review with the real index.js and a fake ingest). Console
 *     breadcrumbs are therefore dropped outright (dropConsoleBreadcrumb), not scrubbed. The
 *     same missing scope is why events arrive with no `request` block at all; index.js tags
 *     5xx events with the route pattern instead.
 * A session token in Sentry is a working login for that account until it expires (sliding,
 * so possibly for good); an email + habit list is exactly the data the privacy policy says
 * stays on our server. So nothing is trusted to "probably not be there": index.js turns the
 * collection off at the source (requestDataIntegration below, sendDefaultPii false) AND runs
 * every event, transaction and breadcrumb through the scrubbers here, which keep only an
 * allowlist of the request and redact anything token- or email-shaped left in free text.
 *
 * Pure functions, no Sentry import at module load: test/api.test.js feeds them realistic
 * 8.x event objects and asserts nothing sensitive survives.
 */

const FILTERED = "[Filtered]";

/** Request headers worth keeping on an error: what kind of client, and what it sent. Everything
 * else (Authorization, Cookie, X-Forwarded-For, X-Real-IP, Forwarded, Host…) is dropped. */
const KEEP_HEADERS = new Set(["content-type", "content-length", "user-agent", "x-stride-client"]);

/**
 * Keys whose VALUE is dropped wherever they appear (extra, contexts, tags, breadcrumb data,
 * span data, local variables). `token` matches sessionToken, token_hash, DEMO_TOKEN…;
 * `http.query` / `url.query` are the OpenTelemetry attributes that carry the query string.
 */
const SENSITIVE_KEY = /token|secret|password|passwd|authorization|cookie|^email$|^e-mail$|ip_address|^ip$|x-forwarded-for|x-real-ip|^forwarded$|^(http|url)\.query$|^query_string$|^http\.fragment$|dsn|api[-_]?key/i;

/** Session tokens and magic-link tokens are 32 random bytes in hex (auth.js createOpaqueToken),
 * and so are their stored sha256 hashes. 64 and up, so Sentry's own 32-hex trace ids survive. */
const HEX_TOKEN = /[0-9a-f]{64,}/gi;
/**
 * Anything /auth/request-link would accept as an address (routes/auth.js:
 * /^[^\s@]+@[^\s@]+\.[^\s@]+$/), so the same shape here. An ASCII-only pattern let josé@…,
 * user@bücher.de and o'brien@… through whole or in part (2026-09-28 review); an address that
 * the server accepted, mailed and then quoted in an error is exactly the one to catch. It
 * over-matches — `name@8.55.0` goes too — which costs a little readability in a message and
 * nothing else. Leading and trailing punctuation is given back (emailReplacement) so `(to: x@y.z,`
 * still reads `(to: [Filtered],`: the brackets and commas identify nobody.
 */
const EMAIL = /[^\s@]+@[^\s@]+\.[^\s@]+/g;
const EMAIL_EDGE = /^([("'`<[{]*)[\s\S]*?([)"'`>\]},;:.!?]*)$/;
const BEARER = /\b(Bearer|Basic)\s+[^\s"',;]+/gi;
/** `?…` after something path-shaped: `/login?token=…`, `https://host/x?since=…`. Stops at
 * whitespace, quotes and `)`, so a URL quoted in parentheses keeps its closing bracket. */
const QUERY_IN_TEXT = /(\/[^\s?#"'<>()]*)\?[^\s#"'<>)]*/g;
/** `re_…` is Resend's key format; it is in the process env, never supposed to be in a message. */
const RESEND_KEY = /\bre_[A-Za-z0-9_]{8,}\b/g;

/** @param {string} match */
function emailReplacement(match) {
  const m = EMAIL_EDGE.exec(match);
  const lead = m ? m[1] : "";
  const trail = m ? m[2] : "";
  // Keep the edges only if an @ is still inside what is cut: `@x.y` with a leading `(` stays whole.
  const core = match.slice(lead.length, match.length - trail.length);
  return core.includes("@") ? `${lead}${FILTERED}${trail}` : FILTERED;
}

/**
 * Redact everything token-, email- or query-shaped from free text.
 * @param {string} s
 * @returns {string}
 */
function scrubString(s) {
  if (typeof s !== "string") return s;
  return s
    .replace(BEARER, `$1 ${FILTERED}`)
    .replace(HEX_TOKEN, FILTERED)
    .replace(RESEND_KEY, FILTERED)
    .replace(EMAIL, emailReplacement)
    .replace(QUERY_IN_TEXT, `$1?${FILTERED}`);
}

/**
 * A URL with its query string and fragment removed — the path is all an error needs.
 * @param {unknown} url
 * @returns {string | undefined}
 */
function scrubUrl(url) {
  if (typeof url !== "string") return undefined;
  const cut = url.search(/[?#]/);
  return scrubString(cut === -1 ? url : url.slice(0, cut));
}

/**
 * Deep copy of `value` with sensitive keys dropped and every string scrubbed.
 * @param {unknown} value
 * @param {number} [depth]
 * @param {WeakSet<object>} [seen]
 * @returns {any}
 */
function scrubDeep(value, depth = 0, seen = new WeakSet()) {
  if (typeof value === "string") return scrubString(value);
  if (value === null || typeof value !== "object") return value;
  if (depth > 8 || seen.has(value)) return FILTERED;
  seen.add(value);
  if (Array.isArray(value)) return value.map((v) => scrubDeep(v, depth + 1, seen));
  /** @type {Record<string, unknown>} */
  const out = {};
  for (const [k, v] of Object.entries(value)) {
    out[k] = SENSITIVE_KEY.test(k) ? FILTERED : scrubDeep(v, depth + 1, seen);
  }
  return out;
}

/**
 * Keep method, path and an allowlist of headers. Body (`data`), cookies, query string, env
 * and every other header are dropped, not redacted: none of them helps debug a 500 here.
 * @param {any} request
 */
function scrubRequest(request) {
  if (!request || typeof request !== "object") return undefined;
  /** @type {Record<string, any>} */
  const out = {};
  if (typeof request.method === "string") out.method = request.method;
  const url = scrubUrl(request.url);
  if (url) out.url = url;
  if (request.headers && typeof request.headers === "object") {
    /** @type {Record<string, string>} */
    const headers = {};
    for (const [k, v] of Object.entries(request.headers)) {
      if (KEEP_HEADERS.has(k.toLowerCase()) && typeof v === "string") headers[k] = scrubString(v);
    }
    if (Object.keys(headers).length > 0) out.headers = headers;
  }
  return out;
}

/**
 * The account id only — never email, username or IP. The id is what `ops/` scripts and the
 * request log already key on, so an error can still be tied to an account.
 * @param {any} user
 */
function scrubUser(user) {
  if (!user || typeof user !== "object") return undefined;
  const id = user.id;
  return typeof id === "number" || (typeof id === "string" && /^\d+$/.test(id)) ? { id } : undefined;
}

/**
 * @param {any} breadcrumb
 * @returns {any}
 */
function scrubBreadcrumb(breadcrumb) {
  if (!breadcrumb || typeof breadcrumb !== "object") return breadcrumb;
  const out = { ...breadcrumb };
  if (typeof out.message === "string") out.message = scrubString(out.message);
  if (out.data && typeof out.data === "object") {
    const data = scrubDeep(out.data);
    if (typeof data.url === "string") data.url = scrubUrl(breadcrumb.data.url);
    out.data = data;
  }
  return out;
}

/**
 * beforeBreadcrumb: console lines are dropped (see the module comment — without a per-request
 * scope they are the whole process's log, other accounts included); every other breadcrumb
 * (outgoing http, e.g. the Resend call) is scrubbed and kept.
 * @param {any} breadcrumb
 * @returns {any}
 */
function dropConsoleBreadcrumb(breadcrumb) {
  if (breadcrumb && typeof breadcrumb === "object" && breadcrumb.category === "console") return null;
  return scrubBreadcrumb(breadcrumb);
}

/**
 * Scrub an error event or a transaction in place of the copy Sentry would send. Returns the
 * event (never null: dropping it would hide the error; the fields are what is dangerous).
 * @template {Record<string, any>} E
 * @param {E} event
 * @returns {E}
 */
function scrubEvent(event) {
  if (!event || typeof event !== "object") return event;
  /** @type {Record<string, any>} */
  const e = event;

  if ("request" in e) {
    const request = scrubRequest(e.request);
    if (request) e.request = request; else delete e.request;
  }
  if ("user" in e) {
    const user = scrubUser(e.user);
    if (user) e.user = user; else delete e.user;
  }
  if (typeof e.message === "string") e.message = scrubString(e.message);
  if (e.logentry && typeof e.logentry === "object") e.logentry = scrubDeep(e.logentry);
  if (typeof e.transaction === "string") e.transaction = scrubUrl(e.transaction);

  if (e.exception && Array.isArray(e.exception.values)) {
    for (const ex of e.exception.values) {
      if (!ex || typeof ex !== "object") continue;
      if (typeof ex.value === "string") ex.value = scrubString(ex.value);
      if (ex.mechanism && ex.mechanism.data) ex.mechanism.data = scrubDeep(ex.mechanism.data);
      const frames = ex.stacktrace && Array.isArray(ex.stacktrace.frames) ? ex.stacktrace.frames : [];
      // Local variables are off by default (includeLocalVariables), but if anyone turns them
      // on they hold the parsed push body — habit names and notes, which no pattern can
      // recognise — and the session row. Dropped, not scrubbed.
      for (const f of frames) if (f && typeof f === "object") delete f.vars;
    }
  }

  for (const key of ["extra", "contexts", "tags"]) {
    if (e[key] && typeof e[key] === "object") e[key] = scrubDeep(e[key]);
  }
  if (Array.isArray(e.breadcrumbs)) {
    // The same rule as beforeBreadcrumb, again here for breadcrumbs that reach the event
    // another way (a future integration writing to the scope directly).
    e.breadcrumbs = e.breadcrumbs.map(dropConsoleBreadcrumb).filter((/** @type {any} */ b) => b !== null);
  }
  if (Array.isArray(e.spans)) {
    e.spans = e.spans.map((/** @type {any} */ span) => {
      if (!span || typeof span !== "object") return span;
      const s = { ...span };
      if (typeof s.description === "string") s.description = scrubUrl(s.description);
      if (s.data && typeof s.data === "object") s.data = scrubDeep(s.data);
      return s;
    });
  }
  return event;
}

/**
 * `<METHOD> <route pattern>` for a 5xx event's `route` tag: `PUT /v1/habits/:id`, not the id,
 * not the query. The error handler in index.js cannot read the mount from req.baseUrl (express
 * resets it to "" once the error leaves the router, while req.route keeps the router's own
 * `/:id`), so the pattern's segments replace the same number of trailing segments of the path.
 * @param {string} method
 * @param {string | undefined} originalUrl
 * @param {string | undefined} routePath req.route.path, when a route matched
 * @returns {string}
 */
function routeTag(method, originalUrl, routePath) {
  const path = String(originalUrl || "").split(/[?#]/)[0] || "/";
  if (typeof routePath !== "string") return scrubString(`${method} ${path}`);
  const segments = path.split("/").filter(Boolean);
  const pattern = routePath.split("/").filter(Boolean);
  const mount = segments.slice(0, Math.max(0, segments.length - pattern.length));
  return scrubString(`${method} /${[...mount, ...pattern].join("/")}`);
}

/**
 * SENTRY_TRACES_SAMPLE_RATE, or 0. Tracing sends a transaction per sampled request — its
 * spans carry URLs and timings for every sync, which is volume and exposure this server has
 * no use for; errors are what we want. An unset, empty or malformed value is 0, never NaN
 * (Sentry would treat NaN as invalid and log about it on every request).
 * @param {string | undefined} raw
 * @returns {number}
 */
function tracesSampleRate(raw) {
  if (raw === undefined || raw.trim() === "") return 0;
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 && n <= 1 ? n : 0;
}

/**
 * The options index.js passes to Sentry.init.
 * @param {NodeJS.ProcessEnv} env
 */
function sentryInitOptions(env) {
  const Sentry = require("@sentry/node");
  return {
    dsn: env.SENTRY_DSN,
    environment: env.NODE_ENV || "development",
    tracesSampleRate: tracesSampleRate(env.SENTRY_TRACES_SAMPLE_RATE),
    sendDefaultPii: false,
    // Replaces the default RequestData integration (same name): collect method and URL, not
    // the body, headers, cookies, query string, IP or the account's email in the first place.
    // The scrubbers below are the second line, for whatever a future SDK adds by default.
    integrations: [
      Sentry.requestDataIntegration({
        include: {
          cookies: false, data: false, headers: false, ip: false, query_string: false, url: true,
          user: { id: true, username: false, email: false },
        },
      }),
    ],
    beforeSend: (/** @type {any} */ event) => scrubEvent(event),
    beforeSendTransaction: (/** @type {any} */ event) => scrubEvent(event),
    beforeBreadcrumb: (/** @type {any} */ breadcrumb) => dropConsoleBreadcrumb(breadcrumb),
  };
}

module.exports = {
  scrubEvent,
  scrubBreadcrumb,
  dropConsoleBreadcrumb,
  scrubString,
  scrubUrl,
  routeTag,
  tracesSampleRate,
  sentryInitOptions,
  FILTERED,
};
