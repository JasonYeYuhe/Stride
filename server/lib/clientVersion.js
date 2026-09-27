// @ts-check

/**
 * Which app build is talking to us, from the `X-Stride-Client` header.
 *
 * From 1.3.0 the apps send `ios/<version>(<build>)` or `macos/<version>(<build>)`, e.g.
 * `ios/1.3.1(19)`. No shipped build before that sends anything, so a missing header means
 * "one of the <= 1.2.3 snapshot clients" — and so does a header this regex does not accept.
 * That default is deliberate: every contract gated on the version (cursor_expired, row caps,
 * snapshot_required) is something a legacy client has no handler for, so when in doubt the
 * server must behave as it always has. A lenient parse that read "1.3.1-beta" or a spoofed
 * "ios/9.9" as new would hand those clients an error they turn into a dead sync.
 *
 * Add a platform to the alternation only when an app for it sends the header.
 */
const CLIENT_HEADER = /^(ios|macos)\/(\d{1,4})\.(\d{1,4})(?:\.(\d{1,4}))?\((\d{1,9})\)$/;

/** @typedef {{ platform: string, version: string, build: number, parts: [number, number, number] }} ClientInfo */

/**
 * @param {unknown} header
 * @returns {ClientInfo|null} null = legacy client
 */
function parseClientHeader(header) {
  if (typeof header !== "string" || header.length > 64) return null;
  const m = CLIENT_HEADER.exec(header.trim());
  if (!m) return null;
  /** @type {[number, number, number]} */
  const parts = [Number(m[2]), Number(m[3]), Number(m[4] ?? 0)];
  return { platform: m[1], version: parts.join("."), build: Number(m[5]), parts };
}

/**
 * Parsed once per request and cached on it.
 * @param {import('express').Request} req
 * @returns {ClientInfo|null}
 */
function clientInfo(req) {
  if (req.strideClient === undefined) req.strideClient = parseClientHeader(req.get("X-Stride-Client"));
  return req.strideClient;
}

/**
 * @param {[number, number, number]} a
 * @param {[number, number, number]} b
 */
function compareParts(a, b) {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return 0;
}

/**
 * True when the request comes from an app at `minVersion` or later. Legacy clients (no or
 * unparseable header) are never "at least" anything.
 * @param {import('express').Request} req
 * @param {string} minVersion e.g. "1.3.1"
 */
function clientAtLeast(req, minVersion) {
  const client = clientInfo(req);
  if (!client) return false;
  const min = parseClientHeader(`ios/${minVersion}(0)`);
  if (!min) throw new Error(`clientAtLeast: bad version literal ${minVersion}`);
  return compareParts(client.parts, min.parts) >= 0;
}

/**
 * The JSON body of an error, shaped for the app that will display it.
 *
 * Every shipped app up to 1.2.3 puts the server's `error` string verbatim in the Settings
 * footer, so a code there reads to the user as "sync_paused". Those apps send no (valid)
 * X-Stride-Client header, and they get the sentence in `error`. An app that sends the header
 * (1.3.0 on) gets the code in `error` and the sentence in `message` — which means 1.3.0's
 * APIClient must show `message` when there is one (DEV-PLAN-1.3.md M1); an app that shows
 * `error` blindly would put "rate_limited" on screen.
 *
 * `code` is in both shapes, so a client matches on `code` alone and still recognises the
 * error when its own header failed to parse (a malformed CFBundleVersion gets the legacy
 * shape — see parseClientHeader). Use this for every error added from 1.3 on; existing
 * errors keep their old bodies, which the shipped apps already display.
 *
 * @param {import('express').Request} req
 * @param {string} code machine-readable, e.g. "sync_paused"
 * @param {string} message a sentence a user can read
 * @param {Record<string, unknown>} [extra] e.g. { retryAfterSeconds }
 */
function errorBody(req, code, message, extra = {}) {
  return clientInfo(req)
    ? { error: code, code, message, ...extra }
    : { error: message, code, ...extra };
}

module.exports = { parseClientHeader, clientInfo, clientAtLeast, errorBody };
