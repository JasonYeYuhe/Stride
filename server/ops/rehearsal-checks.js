// @ts-check
/**
 * Contract checks against a server started on a COPY of the production database.
 *
 * Run on the host by scripts/rehearse_server.sh, never against the live process. It signs in
 * as the App Review demo account (token from the live .env, never printed), so every check
 * runs on the real data shapes production holds — the NULL updated_at that 1.2.3's rehearsal
 * caught was invisible to the test suite because the test database never has that shape.
 *
 * Exit 0 = every check passed. Anything else = do not deploy.
 */
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const Database = require("better-sqlite3");

const BASE = process.env.REHEARSAL_BASE || "http://127.0.0.1:3199";
const DIR = process.env.REHEARSAL_DIR; // the copy's server dir (holds stride.db)
const LIVE_ENV = process.env.LIVE_ENV || "/root/stride-server/.env";
if (!DIR) { console.error("REHEARSAL_DIR is required"); process.exit(2); }

const results = [];
function check(name, ok, detail = "") {
  results.push({ name, ok });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  — " + detail : ""}`);
}

function demoToken() {
  const line = fs.readFileSync(LIVE_ENV, "utf8").split("\n").find((l) => l.startsWith("DEMO_TOKEN="));
  if (!line) throw new Error("DEMO_TOKEN not in live .env");
  return line.slice("DEMO_TOKEN=".length).replace(/["\r]/g, "").trim();
}

/**
 * @param {string} method @param {string} url
 * @param {{ token?: string, body?: unknown, headers?: Record<string, string> }} [opts]
 */
async function call(method, url, { token, body, headers = {} } = {}) {
  /** @type {Record<string, string>} */
  const h = { ...headers };
  if (token) h.Authorization = `Bearer ${token}`;
  if (body !== undefined) h["Content-Type"] = "application/json";
  const res = await fetch(BASE + url, { method, headers: h, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not json */ }
  return { status: res.status, headers: res.headers, json, text };
}

const wholeSecond = (iso) => (iso ? new Date(iso).toISOString().replace(/\.\d{3}Z$/, "Z") : iso);

async function main() {
  const db = new Database(path.join(DIR, "stride.db"));
  db.pragma("journal_mode = WAL");

  // --- schema on the upgraded production database ---
  const integrity = db.pragma("integrity_check", { simple: true });
  check("integrity_check on the migrated copy", integrity === "ok", String(integrity));
  const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map((r) => /** @type {any} */ (r).name);
  for (const t of ["sync_snapshot_requests", "usage_counters", "user_clients"]) {
    check(`table ${t} exists after startup migrations`, tables.includes(t));
  }
  // E2E S4: an entry tombstone's habit and day, added by ALTER TABLE on this copy. Every row
  // production already holds keeps NULL (nothing has pushed yet), which the pull serves as before.
  const tombCols = db.prepare("PRAGMA table_info(deletion_tombstones)").all().map((r) => /** @type {any} */ (r).name);
  const tombRows = /** @type {any} */ (db.prepare("SELECT COUNT(*) AS n, COUNT(habit_id) + COUNT(entry_date) AS named FROM deletion_tombstones").get());
  check("deletion_tombstones.habit_id and .entry_date added, every existing row NULL",
    tombCols.includes("habit_id") && tombCols.includes("entry_date") && tombRows.named === 0,
    `columns=${tombCols.join(",")} rows=${tombRows.n} named=${tombRows.named}`);

  // --- unauthenticated surfaces ---
  const health = await call("GET", "/health");
  check("GET /health 200", health.status === 200);
  const aasaHead = await fetch(BASE + "/.well-known/apple-app-site-association", { method: "HEAD", redirect: "manual" });
  check("HEAD AASA 200 application/json", aasaHead.status === 200 && /application\/json/.test(aasaHead.headers.get("content-type") || ""),
    `${aasaHead.status} ${aasaHead.headers.get("content-type")}`);
  const aasa = await call("GET", "/.well-known/apple-app-site-association");
  const ids = aasa.json?.applinks?.details?.[0]?.appIDs;
  check("AASA names the app", Array.isArray(ids) && ids.includes("KHMK6Q3L3K.yyh.stride.habittracker"));

  // --- demo sign-in ---
  const verify = await call("POST", "/v1/auth/verify", { body: { token: demoToken() } });
  const session = verify.json?.sessionToken;
  check("demo token verifies", verify.status === 200 && typeof session === "string");
  // E2E S9 URL cache: the answer holding the session token must not be stored or revalidated.
  const noStore = (/** @type {Headers} */ h) => h.get("cache-control") === "no-store" && h.get("etag") === null;
  check("…the verify answer is Cache-Control: no-store, with no ETag", noStore(verify.headers),
    `cache-control=${verify.headers.get("cache-control")} etag=${verify.headers.get("etag")}`);
  if (!session) return;

  try {
    // --- full pull + totals ---
    const pull = await call("GET", "/v1/sync/pull", { token: session });
    const p = pull.json || {};
    check("full pull 200", pull.status === 200);
    check("…Cache-Control: no-store, with no ETag", noStore(pull.headers),
      `cache-control=${pull.headers.get("cache-control")} etag=${pull.headers.get("etag")}`);
    const t = p.totals || {};
    check("totals equal the arrays on a full pull",
      t.habits === p.habits?.length && t.entries === p.entries?.length && t.groups === p.groups?.length,
      `totals=${JSON.stringify(t)} arrays=${p.habits?.length}/${p.entries?.length}/${p.groups?.length}`);
    const byHabit = new Set((p.habits || []).map((h) => h.id));
    const orphans = (p.entries || []).filter((e) => !byHabit.has(e.habitId)).length;
    check("every pulled entry matches a pulled habit", orphans === 0, `orphans=${orphans}`);
    check("all ids upper case", [...(p.habits || []), ...(p.entries || [])].every((r) => r.id === r.id.toUpperCase()));

    // --- the millisecond pull (M2): only for >= 1.3.1, the same instants for everyone ---
    // Real rows are where a stored stamp might not be the fixed-width toISOString() form (seed
    // scripts, columns added by ALTER TABLE) — a row served raw here would show as a FAIL.
    const MS = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/;
    const WHOLE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
    /** Every served stamp, keyed "kind:id:field". @param {any} j */
    const stampsOf = (j) => {
      /** @type {[string, string][]} */
      const out = [];
      for (const [k, rows] of /** @type {[string, any[]][]} */ ([["h", j?.habits], ["e", j?.entries], ["g", j?.groups]])) {
        for (const r of rows || []) out.push([`${k}:${r.id}:c`, r.createdAt], [`${k}:${r.id}:u`, r.updatedAt]);
      }
      return out;
    };
    const pull131 = await call("GET", "/v1/sync/pull", { token: session, headers: { "X-Stride-Client": "ios/1.3.1(19)" } });
    const ms = stampsOf(pull131.json);
    const notMs = ms.filter(([, v]) => !MS.test(v));
    check("pull with ios/1.3.1(19) -> every createdAt/updatedAt in fixed-width milliseconds",
      pull131.status === 200 && ms.length > 0 && notMs.length === 0,
      `${pull131.status} stamps=${ms.length} bad=${notMs.length}${notMs.length ? " e.g. " + JSON.stringify(notMs[0]) : ""}`);
    const pull130 = await call("GET", "/v1/sync/pull", { token: session, headers: { "X-Stride-Client": "ios/1.3.0(18)" } });
    for (const [label, other] of /** @type {[string, typeof pull][]} */ ([["ios/1.3.0(18)", pull130], ["no header", pull]])) {
      const whole = new Map(stampsOf(other.json));
      const differ = ms.filter(([k, v]) => whole.get(k) !== wholeSecond(v) || !WHOLE.test(whole.get(k) ?? ""));
      check(`pull with ${label} -> whole seconds, the same instants`,
        other.status === 200 && whole.size === ms.length && differ.length === 0,
        `${other.status} stamps=${whole.size}/${ms.length} differ=${differ.length}${differ.length ? " e.g. " + differ[0][0] : ""}`);
    }

    // --- the mixed-fleet contract on real rows: a 1.2.3 snapshot push bumps nothing ---
    // Also the LWW re-feed's negative case on real rows: the demo rows carry millisecond stamps
    // (seeded with toISOString()), so this whole-second echo is strictly older with the same
    // values, and must not move them back into the feed.
    const before = db.prepare(`SELECT
      (SELECT COUNT(*) FROM habits h JOIN users u ON u.id=h.user_id WHERE u.email='demo@stride-review.com') AS nh,
      (SELECT MAX(updated_at) FROM habits h JOIN users u ON u.id=h.user_id WHERE u.email='demo@stride-review.com') AS hmax,
      (SELECT MAX(e.updated_at) FROM habit_entries e JOIN habits h ON h.id=e.habit_id JOIN users u ON u.id=h.user_id WHERE u.email='demo@stride-review.com') AS emax`).get();
    const snapshot = {
      habits: (p.habits || []).map((h) => {
        const o = { id: h.id, name: h.name, emoji: h.emoji, colorHex: h.colorHex, isArchived: h.isArchived, sortOrder: h.sortOrder,
          reminderEnabled: h.reminderEnabled, reminderHour: h.reminderHour, reminderMinute: h.reminderMinute,
          kind: h.kind, targetValue: h.targetValue, scheduleKind: h.scheduleKind, timesPerWeek: h.timesPerWeek,
          activeDaysMask: h.activeDaysMask, createdAt: wholeSecond(h.createdAt), updatedAt: wholeSecond(h.updatedAt) };
        if (h.note != null) o.note = h.note;         // 1.2.3 omits nil optionals
        if (h.unit != null) o.unit = h.unit;
        if (h.groupId != null) o.groupId = h.groupId;
        return o;
      }),
      entries: (p.entries || []).map((e) => {
        const o = { id: e.id, habitId: e.habitId, date: e.date, value: e.value, createdAt: wholeSecond(e.createdAt), updatedAt: wholeSecond(e.updatedAt) };
        if (e.note != null) o.note = e.note;
        return o;
      }),
      groups: (p.groups || []).map((g) => ({ id: g.id, name: g.name, colorHex: g.colorHex, sortOrder: g.sortOrder, createdAt: wholeSecond(g.createdAt), updatedAt: wholeSecond(g.updatedAt) })),
      deletedHabitIds: [], deletedEntryIds: [], deletedGroupIds: [],
    };
    const echo = await call("POST", "/v1/sync/push", { token: session, body: snapshot });
    check("1.2.3-shaped snapshot of the real account -> 200, nothing skipped",
      echo.status === 200 && echo.json?.ok === true
        && (echo.json?.skipped?.habits?.length ?? -1) === 0 && (echo.json?.skipped?.entries?.length ?? -1) === 0,
      JSON.stringify({ status: echo.status, applied: echo.json?.applied, skipped: echo.json?.skipped }));
    const after = db.prepare(`SELECT
      (SELECT MAX(updated_at) FROM habits h JOIN users u ON u.id=h.user_id WHERE u.email='demo@stride-review.com') AS hmax,
      (SELECT MAX(e.updated_at) FROM habit_entries e JOIN habits h ON h.id=e.habit_id JOIN users u ON u.id=h.user_id WHERE u.email='demo@stride-review.com') AS emax`).get();
    check("…and bumped no updated_at (no echo into other devices' feeds)",
      /** @type {any} */ (after).hmax === /** @type {any} */ (before).hmax && /** @type {any} */ (after).emax === /** @type {any} */ (before).emax,
      `habits ${/** @type {any} */ (before).hmax} -> ${/** @type {any} */ (after).hmax}; entries ${/** @type {any} */ (before).emax} -> ${/** @type {any} */ (after).emax}`);

    // --- unknown habit -> skipped ---
    const ghost = crypto.randomUUID().toUpperCase();
    const ghostEntry = crypto.randomUUID().toUpperCase();
    const skip = await call("POST", "/v1/sync/push", { token: session, body: { habits: [], entries: [{ id: ghostEntry, habitId: ghost, date: "2026-09-01", value: 1 }], groups: [] } });
    check("entry for an unknown habit -> 200 with skipped.entries", skip.status === 200 && (skip.json?.skipped?.entries || []).includes(ghostEntry),
      JSON.stringify(skip.json));

    // --- E2E S4 on a real check-in: uncheck + re-check pushed by 1.3.1, then pulled by each app ---
    // The tombstone must name the row's habit and date exactly as production stores them (seeded
    // rows included), and only apps < 1.3.1 are spared the deletion; the day stays checked.
    const real = (p.entries || [])[0];
    if (!real) {
      check("E2E S4: the demo account has a check-in to uncheck", false, "no entries");
    } else {
      const cursor = (await call("GET", "/v1/sync/pull", { token: session })).json?.serverTime;
      await new Promise((r) => setTimeout(r, 5));
      const recheckId = crypto.randomUUID().toUpperCase();
      const at = new Date().toISOString();
      const recheck = await call("POST", "/v1/sync/push", { token: session, headers: { "X-Stride-Client": "ios/1.3.1(20)" }, body: {
        habits: [], groups: [], deletedHabitIds: [], deletedGroupIds: [], deletedEntryIds: [real.id],
        entries: [{ id: recheckId, habitId: real.habitId, date: real.date, value: real.value, createdAt: at, updatedAt: at }],
      } });
      const tomb = /** @type {any} */ (db.prepare(
        "SELECT habit_id, entry_date FROM deletion_tombstones WHERE entity_type = 'entry' AND entity_id = ?").get(real.id));
      check("uncheck + re-check with ios/1.3.1(20) -> 200, the tombstone names the row's habit and date as stored",
        recheck.status === 200 && (recheck.json?.skipped?.entries || []).length === 0
          && tomb?.habit_id === real.habitId && tomb?.entry_date === real.date,
        JSON.stringify({ status: recheck.status, skipped: recheck.json?.skipped, tomb, habitId: real.habitId, date: real.date }));
      for (const [label, client, heldBack] of /** @type {[string, string, boolean][]} */ ([
        ["ios/1.3.0(19)", "ios/1.3.0(19)", true], ["no header", "", true], ["ios/1.3.1(20)", "ios/1.3.1(20)", false],
      ])) {
        const r = await call("GET", `/v1/sync/pull?since=${encodeURIComponent(cursor)}`,
          { token: session, headers: client ? { "X-Stride-Client": client } : {} });
        const carries = (r.json?.entries || []).some((e) => e.id === recheckId);
        const deletes = (r.json?.deletedEntryIds || []).includes(real.id);
        check(`…pull since, ${label} -> the re-check ${heldBack ? "WITHOUT" : "with"} the deletion`,
          r.status === 200 && carries && deletes === !heldBack, `${r.status} carries=${carries} deletes=${deletes}`);
      }
    }

    // --- cursor gating ---
    const old = new Date(Date.now() - 400 * 86400000).toISOString();
    const gated = await call("GET", `/v1/sync/pull?since=${encodeURIComponent(old)}`, { token: session, headers: { "X-Stride-Client": "ios/1.3.1(19)" } });
    check("since=400d with ios/1.3.1(19) -> 409 cursor_expired", gated.status === 409 && JSON.stringify(gated.json).includes("cursor_expired"), `${gated.status}`);
    const legacy = await call("GET", `/v1/sync/pull?since=${encodeURIComponent(old)}`, { token: session });
    check("since=400d without the header -> 200", legacy.status === 200, `${legacy.status}`);

    // --- sliding session on a 20-day-old session ---
    const hash = crypto.createHash("sha256").update(session).digest("hex");
    const tenDays = Date.now() + 10 * 86400000;
    db.prepare("UPDATE sessions SET expires_at = ? WHERE token_hash = ?").run(tenDays, hash);
    await call("GET", "/v1/auth/session", { token: session });
    const exp = /** @type {any} */ (db.prepare("SELECT expires_at FROM sessions WHERE token_hash = ?").get(hash))?.expires_at;
    check("a 20-day-old session is extended to ~30 days", typeof exp === "number" && exp > Date.now() + 29 * 86400000,
      exp ? `now+${((exp - Date.now()) / 86400000).toFixed(2)}d` : "missing");

    // --- pause switch via the flag file ---
    const flag = path.join(DIR, "SYNC_PAUSED");
    fs.writeFileSync(flag, "120");
    const paused = await call("GET", "/v1/sync/pull", { token: session });
    fs.unlinkSync(flag);
    check("flag file -> 503 sync_paused with Retry-After", paused.status === 503 && !!paused.headers.get("retry-after"),
      `${paused.status} retry-after=${paused.headers.get("retry-after")} body=${paused.text.slice(0, 120)}`);
    const resumed = await call("GET", "/v1/sync/pull", { token: session });
    check("flag removed -> 200", resumed.status === 200);
  } finally {
    await call("POST", "/v1/auth/logout", { token: session, body: {} });
    db.close();
  }
}

main().then(() => {
  const failed = results.filter((r) => !r.ok).length;
  console.log(`\n${results.length - failed}/${results.length} checks passed`);
  process.exit(failed ? 1 : 0);
}).catch((e) => { console.error("rehearsal crashed:", e); process.exit(1); });
