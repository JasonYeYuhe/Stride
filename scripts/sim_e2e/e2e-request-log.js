// @ts-check
// The sim_e2e request log. start-server.sh copies this file into a server COPY under
// $STRIDE_E2E_ROOT/servers/<name>/server and adds ONE line to that copy's index.js, right after
// `const app = express();`:
//
//     require("./e2e-request-log")(app);
//
// server/index.js itself is never touched, and nothing here is ever deployed. It runs ahead of
// every other middleware, so it sees every request the app makes, including those a limiter, the
// pause switch or the session check answers.
//
// One line per request, written when the response finishes:
//
//   E2E <iso> <METHOD> <path> <status> client=<X-Stride-Client|-> [user=<id>|null] [error=<code>]
//       [push: applied=… skipped=… skippedReasons=… aliases=… sentHabits=… sentEntries=…
//              sentGroups=… sentDeletedHabitIds=… sentDeletedEntryIds=… sentDeletedGroupIds=…]
//       [pull: full|since out=habits:…,entries:…,groups:…,deletions:… withheld=… deletionsSince=…]
//
// - Not logged: GET /health (start-server.sh polls it; the apps never call it).
// - <path>: every query value is [REDACTED] except `since` and `deletionsSince` (a pull's cursors).
// - user=: who the request's Bearer token belonged to WHEN IT ARRIVED (a plain SELECT, so it
//   never slides or deletes the session): <id> for a live session, `null` for a token the server
//   does not know or that expired, and no field at all when no Bearer was sent. On
//   /v1/auth/verify (no Bearer) it is the user the token signed in. The app's launch session
//   check (GET /v1/auth/session) therefore reads: no user= → no token in the Keychain;
//   user=null → a dead token (1.3.0+ deletes it on that answer); user=<id> → signed in.
// - push lists: `sentEntries=3[1A2B3C4D@2026-10-07=1,…]` — count, then up to 8 rows as
//   id-prefix@day=value (the whole list is cut with `…+N`). Deletion lists the same, ids only.
"use strict";
const crypto = require("crypto");

const SHOWN_QUERY = new Set(["since", "deletionsSince"]);
const MAX_LISTED = 8;

/** @param {string} url */
function renderPath(url) {
  const q = url.indexOf("?");
  const clean = (/** @type {string} */ s) => s.replace(/[\x00-\x20\x7f]/g, (c) => encodeURIComponent(c));
  if (q === -1) return clean(url);
  const params = new URLSearchParams(url.slice(q + 1));
  const parts = [];
  for (const [k, v] of params) parts.push(`${k}=${SHOWN_QUERY.has(k) ? v : "[REDACTED]"}`);
  return clean(url.slice(0, q)) + (parts.length ? `?${clean(parts.join("&"))}` : "");
}

/** @param {unknown} v */
function word(v) {
  return String(v).replace(/\s+/g, "_").slice(0, 80);
}

/** @param {Record<string, unknown>|undefined|null} o */
function kv(o) {
  if (!o || typeof o !== "object") return "-";
  return Object.entries(o).map(([k, v]) => `${k}:${Array.isArray(v) ? v.length : v}`).join(",") || "-";
}

/** @param {any} body @param {string} camel */
function field(body, camel) {
  if (!body || typeof body !== "object") return undefined;
  if (body[camel] !== undefined) return body[camel];
  return body[camel.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`)];
}

/** @param {unknown} id */
const short = (id) => (typeof id === "string" ? id.slice(0, 8) : word(JSON.stringify(id)));

/** @param {unknown} list @param {(row: any) => string} render */
function listed(list, render) {
  if (!Array.isArray(list)) return "0";
  if (list.length === 0) return "0";
  const shown = list.slice(0, MAX_LISTED).map(render);
  const more = list.length > MAX_LISTED ? `,…+${list.length - MAX_LISTED}` : "";
  return `${list.length}[${shown.join(",")}${more}]`;
}

/** @param {any} e */
function entryRow(e) {
  if (!e || typeof e !== "object") return "?";
  const day = typeof e.date === "string" ? e.date.slice(0, 10) : "?";
  const value = e.value === undefined ? "" : `=${e.value}`;
  return `${short(e.id)}@${day}${value}`;
}

/** The non-empty kinds of `{habits: {id: reason}, entries: {…}, groups: {…}}`, as JSON; null when none.
 * @param {Record<string, any>|undefined} o */
function compactJson(o) {
  if (!o || typeof o !== "object") return null;
  const kept = Object.entries(o).filter(([, v]) => v && typeof v === "object" && Object.keys(v).length > 0);
  return kept.length > 0 ? JSON.stringify(Object.fromEntries(kept)).replace(/\s+/g, "_") : null;
}

/** @param {import('express').Express} app */
module.exports = function e2eRequestLog(app) {
  const db = require("./db");
  const sessionOwner = db.prepare("SELECT user_id, expires_at FROM sessions WHERE token_hash = ?");

  app.use((req, res, next) => {
    // The kit's own readiness polling (start-server.sh); no app calls /health.
    if (req.path === "/health") return next();
    /** @type {number|null|undefined} */
    let user;
    const auth = req.headers.authorization;
    if (typeof auth === "string" && auth.startsWith("Bearer ")) {
      try {
        const row = /** @type {{ user_id: number, expires_at: number }|undefined} */ (
          sessionOwner.get(crypto.createHash("sha256").update(auth.slice(7)).digest("hex")));
        user = row && row.expires_at >= Date.now() ? row.user_id : null;
      } catch {
        user = null;
      }
    }

    /** @type {any} */
    let answered;
    const json = res.json.bind(res);
    res.json = (body) => { answered = body; return json(body); };

    res.on("finish", () => {
      try {
        const path = req.originalUrl.split("?")[0];
        const parts = [
          "E2E", new Date().toISOString(), req.method, renderPath(req.originalUrl), String(res.statusCode),
          `client=${word(req.get("X-Stride-Client") || "-")}`,
        ];
        if (user === undefined && /\/auth\/verify$/.test(path) && answered && answered.user) user = answered.user.id;
        if (user !== undefined) parts.push(`user=${user}`);
        // `code` first: an app without X-Stride-Client (<= 1.2.3) gets the sentence in `error`.
        if (res.statusCode >= 400 && answered && (answered.code ?? answered.error) !== undefined) {
          parts.push(`error=${word(answered.code ?? answered.error)}`);
        }

        if (/\/sync\/push$/.test(path) && req.method === "POST" && req.body === undefined) {
          parts.push("push:", "body-not-read");   // refused before the parser (pause, 401, 429)
        } else if (/\/sync\/push$/.test(path) && req.method === "POST") {
          const body = req.body;
          const a = answered || {};
          parts.push("push:",
            `applied=${kv(a.applied)}`,
            `skipped=${kv(a.skipped)}`,
            `skippedReasons=${compactJson(a.skippedReasons) || "-"}`,
            `aliases=${(a.aliases && a.aliases.entries) ? JSON.stringify(a.aliases.entries) : "-"}`,
            `sentHabits=${listed(field(body, "habits"), (h) => short(h && h.id))}`,
            `sentEntries=${listed(field(body, "entries"), entryRow)}`,
            `sentGroups=${listed(field(body, "groups"), (g) => short(g && g.id))}`,
            `sentDeletedHabitIds=${listed(field(body, "deletedHabitIds"), short)}`,
            `sentDeletedEntryIds=${listed(field(body, "deletedEntryIds"), short)}`,
            `sentDeletedGroupIds=${listed(field(body, "deletedGroupIds"), short)}`);
        } else if (/\/sync\/pull$/.test(path) && req.method === "GET") {
          const s = res.locals.syncStats || {};
          if (s.pull) {
            parts.push("pull:", String(s.pull), `out=${kv(s.out)}`,
              `withheld=${s.withheld ?? 0}`,
              `deletionsSince=${s.deletionsSince ?? "-"}`);
          }
        }
        console.log(parts.join(" "));
      } catch (err) {
        console.log(`E2E ${new Date().toISOString()} log-error ${word(err && /** @type {any} */ (err).message)}`);
      }
    });
    next();
  });
  console.log("[sim_e2e] request log mounted");
};
