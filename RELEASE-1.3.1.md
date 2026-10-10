# Stride v1.3.1 — release record

App ID `6761262334`, bundle `yyh.stride.habittracker`. **In progress**: branch `release/1.3.1`,
version 1.3.1 (20). This is [DEV-PLAN-1.3.md](DEV-PLAN-1.3.md) M2: incremental push, cursor
expiry and account isolation. Phases A, B and C are built and committed (last: `aa0362c`).
Phase D (full review, server deploy, device checks, submission) is open, see
[TODO](#todo--phase-d-before-submission). Nothing from this branch has reached a user or the
production server.

1.3.0 (build 19) is in App Review on iOS and macOS, release type `MANUAL`
([RELEASE-1.3.0.md](RELEASE-1.3.0.md)). 1.3.1 cannot ship until 1.3.0 is live: the server half
of 1.3.1 is deployed after 1.3.0 is live and before 1.3.1 is submitted.

## Why this release exists

Every app up to 1.3.0 pushes its **whole store on every sync**, and "local data merges into
whichever account signs in": sign out of A, sign into B on the same device, and A's habits
were pushed into B's account. A full snapshot also hid a whole class of bugs, because a row
the server dropped came back on the next push. Once apps send only what changed, a silent drop
means a row that never syncs. So M2 is not only a faster push. It adds the rules that make
incremental push safe for a fleet that will contain ≤ 1.3.0 snapshot clients for months:

- **Delivery state, not a boolean.** Each row has `syncedAt` (the stamp the server last
  acknowledged; nothing clears it), a hold (`syncHoldReason` / `syncHoldStamp`; any edit
  lifts it), `needsResend` and `restoredAt`. A row is pending when it is not held and
  `needsResend || syncedAt != stamp`. That is an inequality, not an ordering, so a clock step
  backwards strands nothing. All fields are local-only and optional, so the migration is
  lightweight.
- **Chunked push, acknowledged per chunk.** Chunks are bounded by rows and by 1 MB of encoded
  JSON, deletion ids included. The acknowledged ids are the submitted ids minus `skipped`, at
  the stamp that was *sent*.
- **One rule per server answer**, which replaces the old 400 bisection: hold, retry, re-chunk,
  back off or full pull.
- **Account isolation.** The store has an owner. No push or pull runs for any other account
  until the user chooses on the account screen.
- **Millisecond edit stamps** for clients ≥ 1.3.1. On the server, a header-gated millisecond
  pull and an LWW re-feed (the winner goes back to the device that lost).
- **`cursor_expired`**: a full pull first, then the push. This handler is what lets 1.3.1 be
  the lowest version a 426 floor can allow once tombstones are swept again.
- **A recovery log**: an offline edit displaced by another device's deletion is archived on
  disk before anything is deleted, and it can be exported.
- **Restore as new copies**, for a backup from another account or one the server has
  tombstoned.
- **A reauth row** instead of silent failure.

None of this is safe alone (DEV-PLAN-1.3.md "The safe core ships together"), so all of it ships
in 1.3.1.

## The slice — 2026-09-28

The spec required one working vertical slice before the rest, and a new estimate taken from it:

- `6761b00`: the engine. `Shared/SyncDelivery.swift`, `SyncPushPlanner.swift`,
  `SyncAnswers.swift` and `SyncEngine.swift` sit behind a transport protocol, so the host-less
  tests and the rehearsal run the engine the app runs. A run is bound to the owner, token and
  generation it started with, and it re-checks them after every await.
- `f911248`: the server half, **not deployed**. It serves a millisecond pull only to
  `X-Stride-Client` ≥ 1.3.1. Header-less apps and 1.3.0 parse with a default
  `ISO8601DateFormatter`, which returns nil on a fraction. It also adds the LWW re-feed, gated
  on "values differ", so a 1.3.0 echo of a truncated stamp does not re-feed forever.
  Server 412 → 435.
- `2b9b0dd`: `scripts/sync_rehearsal.sh`. It compiles `Shared/` into a macOS tool and runs two
  real 1.3.1 engines, plus 1.2.3-shaped and 1.3.0-shaped snapshot devices, against a throwaway
  local server. It is a release gate from 1.3.1 on.

StrideTests 188 → 297, hosted 53 → 70, rehearsal 37 PASS / 0 FAIL / 5 SKIPPED.
**Re-estimate: about 9.5 solo developer-weeks for M2 (range 8.5–11), not 5.5.** The engine
and the per-answer rules each needed more stated rules than the draft implied. The owner chose
to continue in four phases, each ending in a review-and-fix round.

## Phase A — harden the slice (`d9c98c7`, `ba39421`, `1e9d293`)

- **The first full pull proves the account** (owner decision, slice review R1). An expired
  1.3.0 session keeps `stride_last_sync_time`, so "the device signed out" cannot be inferred
  from it. Migrated delivery marks are therefore provisional (`stride_delivery_marks_unproven`)
  until the adopting account's first full pull. If that pull holds any habit, group or entry id
  this device delivered, the marks stand. If it holds none, every mark is forgotten before the
  deletion pass. So an unproven store never loses rows to another account's snapshot, and a
  dormant same-account device cannot resurrect swept deletions.
- **Large accounts.** Quiet sync of 10 habits × 2 years went from 1.22 s to 0.008 s. The first
  join of 54,750 entries went from 175.6 s to 7.0 s, of which about 75 % is SwiftData's single
  save. A full pull onto a synced large store went from 92.2 s to 2.5 s. `SyncPerformanceTests`
  fails on a return to quadratic work.
- **Version 1.3.1.** A debug build had been sending `ios/1.3.0(18)`, so the server served it
  whole seconds and every 1.3.1 gate was skipped. `check_demo_account.sh` now compiles all of
  `Shared/`. The pre-push hook now builds the commit being pushed. Before, it built the working
  tree and passed on another agent's half-finished edits.

StrideTests 297 → 325, hosted 70 → 71, rehearsal 44 / 0 / 5.

### A shipped bug found on the way: build 18 pulled, 1.3.0 resubmitted as 19

Phase A found a bug in the submitted 1.3.0, and a simulator run of build 18 confirmed it. The
same code is in the live 1.2.3. Once a habit is unchecked, it cannot be checked again that day
until the app is relaunched. `Habit.records` has no inverse, so a loaded habit keeps the deleted
record, and `HabitCheckIn` "deleted" it again on every tap. The fix is `1e9d293`,
cherry-picked as `fed7665`: `HabitCheckIn` asks the store which of the day's records still
exist. The owner pulled 1.3.0 from review and resubmitted build 19 with only that fix
(RELEASE-1.3.0.md, "Build 18 pulled"). 1.3.1 therefore builds from 20, and the branch merged
the hotfix back (`1b33b4a`).

## Phase B — the rest of the non-UI safe core (`e9e273e`)

- `Shared/SyncRecoveryLog.swift`: displaced edits are appended as JSON lines to the owner's own
  file, which is flushed **before** the deletion is saved. If the append fails, nothing is
  deleted and no cursor is written. The file is capped at 5 MB with a dropped-line count. Only
  counts ever leave the device; names and notes never reach Sentry.
- `Shared/SyncCopies.swift` + `DataBackup`: backups record their account. A restore into the
  same account keeps ids (`restoredAt`, so no pull deletes them). A restore into another
  account becomes new copies with fresh ids and the stamps kept. Held rows can be
  re-identified in place or discarded; discarding queues no server deletion.
- `Shared/SyncBackoff.swift`: backoff is persisted per owner. Automatic syncs wait; Sync Now
  never does.
- Server: a rehearsal-only tombstone-sweep hook. It is mounted only under `NODE_ENV=test` AND
  `STRIDE_TEST_HOOKS=1`, and only from loopback. Five tests show it is unreachable in
  production.
- Review (Claude + Gemini through the MCP bridge, fact-checked): an owner change during a
  restore now clears the old owner's cursor along with its queue. The review also set the rule
  for the phase C restore screen: a restore never drops the previous owner's queued deletions
  or recovery-log lines silently.

StrideTests 325 → 385, hosted 71 → 84, server 435 → 443, rehearsal 66 / 0 / 2.

## Phase C — the UI (`aa0362c`)

- **The account screen**, shown only after a sign-in the user started (a typed code or the
  one-tap link). The header reads "This device holds another account's habits." with the
  caption + address lines "Habits from" / "Signed in as". The user can Export a Backup or the
  Recovered Edits first, then pick Start from This Account's Data (confirmed), or Cancel, which
  signs out and changes nothing. A store with no known owner is also offered Upload These
  Habits. No trigger makes a request until the choice is made.
- **Settings → Sync**:
  - rows that can't sync, grouped by reason, with Restore as New Copies / Discard
  - restored habits that were deleted elsewhere
  - Recovered Edits (N) → Export / Clear
  - Full Resync
  - the restore hand-over (RestoreHandoverView)
- Erase offers the recovered edits first. Delete Account erases this device's copy of that
  account and says so.
- **Today**: inline "Sign in again to keep syncing", "Sync paused", and a quiet status line.
  429 and 503 are no longer red errors anywhere. Signed-out Today is pixel-identical to the
  previous build.
- 64 plain + 12 plural keys in all five languages. Screenshots of every scripted state in en/ja
  at default and XXXL are in `build/review/1.3.1/`, which is local and gitignored.

**Reviews and what they changed.** Four reviews ran: UI/a11y, localization, flow data-safety
(with scratch hosted tests that reproduced two defects), and Gemini (MCP bridge, every claim
fact-checked; 1 of 5 findings held). Together they produced 21 fixes. The ones that change
behaviour:

- **UI-1.** The account screen reopened from Settings had no way out except the destructive
  Start. It now has its own navigation stack and a Cancel.
- **G2 / UI-2.** A 429 or 503 `sync_paused` set `syncError`, which Settings showed in red. Now
  only the inline "Sync paused" rows show (acceptance 9).
- **F1.** Any account could silently adopt a device whose session had died. Now a token stored
  at the first 1.3.1 launch counts as signed in only after the server names its user. A dead
  token leaves the store owner-unknown, so the next sign-in meets the account screen.
- **UI-4.** "Sign in again" now persists across launches (`stride_session_expired`). A cold
  launch after a revocation shows the row.
- **F4 / F5.** Erase and Clear Recovered Edits stop if their own sync archived an edit the
  confirmation never counted. A failed erase keeps the owner, so the account screen still
  guards the store.
- **L1–L7.** Terminology and locale fixes:
  - relative times follow the resolved language
  - ja 回収した編集 → 復旧した編集
  - zh 已同步
  - ko/es headline rewording
  - one plural key merged into the account screen's
- **G5 was rejected.** It is a stale waiting count on macOS after a widget edit made while the
  app stays frontmost: minor, and the date half was already handled.

StrideTests 385 → 403 (also 403/0 under `-testLanguage ja -testRegion JP`), hosted 84 → 124,
server 443/443, rehearsal 72 PASS / 0 FAIL / 1 SKIPPED (`STRIDE_REHEARSAL_LARGE=1`: 77 / 0 / 1).
The one skip is the UI-only reauth/pause scenario. Generic iOS build with product checks and
StrideMac pass.

### Owner-level decisions on the phase C leftovers (2026-09-29)

1. **F1 stays.** A device whose session is already dead at its first 1.3.1 launch is
   owner-unknown, so the next sign-in shows Upload / Start even for the **same** account.
   Upload is the right pick then. This matches sub-decision (e): a device that "had its session
   expire" is owner-unknown.
2. **Erase Local Data also clears the persisted "Sign in again" state**, because after an erase
   nothing is left to sync.
3. **Delete Account gets a real in-flow Export step** before the final confirmation, as Erase
   Local Data has. Alerts cannot host a `ShareLink`, so it is a sheet step or ShareLinks above
   the destructive row. It sits inside a flow the user started, so it is not a new
   interruption.
4. **RestoreHandoverView's headline** gets the account screen's caption + address layout, with
   no email inside a sentence.

Items 2–4 are implemented in `7181628`. Item 3's
final button follows the F4 rule: it waits out a sync in flight and counts the recovered edits
again, and lines archived after Continue update the sheet ("New recovered edits arrived…") and
delete nothing (review M2-1).

## Phase D — done so far

- **Product Interaction re-declared** in `Stride/PrivacyInfo.xcprivacy`
  (`NSPrivacyCollectedDataTypeProductInteraction`, not linked, no tracking, purpose Analytics).
  It covers Sentry's per-launch session record, which is used to count devices per version.
  App Store Connect kept the label (RELEASE-1.3.0.md, "After submission"); the manifest now
  matches it again. The comment in the file gives the reason. The widget's manifest is
  unchanged, since the widget starts no Sentry. Generic iOS build: all 14 product checks pass,
  and the built `Stride.app` manifest carries the entry.
- **What's New for 1.3.1** is in `scripts/release.py` in six locales (en-US 1,047 characters,
  es-ES 1,300; the limit is 4,000). It opens by asking users to save a backup first (Settings →
  Export as JSON), because the sync engine changed. It then covers:
  - sync sends only what changed
  - signing in to another account asks what to do with this device's habits: export a backup,
    then start from that account's data, or cancel and leave the device as it is (ko says
    다른 계정, "a different account", not 새 계정)
  - displaced edits are kept in Recovered Edits
  - restores come back as new copies
  - the "Sign in again" row
  Each language reuses its catalog's UI strings.

### The whole-M2 review (2026-09-29)

Codex could not run: its usage limit held it until 19:00, and at 19:05 it moved to a weekly
limit that lasts until **2026-10-04 11:40**. So the final review of `1b33b4a..HEAD` was done
internally, adversarially:
- **Reviewers:** four, one per dimension: data safety, delivery, accounts and session
  lifecycle, and the recovery log / backup / tests.
- **Checks:** each dimension's findings went to a skeptic told to refute them, and a
  completeness critic looked for what nobody had covered.
- **Result:** 12 findings confirmed, 3 of them major. The critic added 3 more, 1 major.

It found three bugs the phase reviews had missed, plus the critic's:
- **Refused rows deleted at the upgrade** (data-safety-1). The migrated delivery marks also
  covered rows the 1.3.0 server had refused. 1.3.0 never read `skipped`, so this includes a
  restore that kept another account's ids, and a restore of habits the server had deleted.
  After the proof, the first full pull deleted those rows and the check-ins made on them since,
  with no recovery-log line. The fix went through two rounds (round two below).
- **Check-in lost on a restored habit** (delivery-1). A push answered `tombstoned_habit` deleted
  a check-in made after a same-account restore. The pull path keeps such a check-in with its
  held habit. Fixed in `7a853d4`: the entry stays pending, and Restore as New Copies moves it with
  the habit.
- **Owner left unrecorded at the first launch** (accounts-1). A session confirmed at the first
  1.3.1 launch left the store owner-less until a sync ran. A Log Out in that gap let the next
  account adopt the previous account's rows with no account screen. This is the leak M2 exists to
  close. Fixed in `4746fb6`: the owner is recorded when the server first names the stored token's
  user.
- **Sign-in sheet torn down early** (critic-1). Today's "Sign in again" row presented the login
  sheet, and the sign-in removed the row. That tore the sheet down before the account screen
  could appear, so a device owed the Upload / Start choice stayed signed in with every sync
  blocked. Fixed in `4746fb6`: the sheet's presenter outlives the row.

Minors fixed in `7a853d4`, `deb5ebc`, `4746fb6` and `22691e0`:
- **Undecided proving pull** (data-safety-2): it applies nothing and stops before the push, so
  its own upserts can't "prove" the next pull.
- **Day-match rename** (data-safety-3): a record renamed to the server's id for its day takes
  the server's value unless it is pending or held.
- **Uncheck deleting nothing** (data-safety-4, older than M2): unchecking a day whose server row
  kept another device's id deleted nothing. The push answer now names the stored id (`aliases`,
  ≥ 1.3.1 only), and the app realigns the id as it acknowledges.
- **Double pull after Full Resync** (delivery-2): every later sync pulled twice. Fixed.
- **Hours of backoff after being offline** (critic-2): a failure with no HTTP answer now waits
  about a minute and never doubles. "Offline" shows only while that window is open. It used to
  back off for up to 6 h after an offline day.
- **macOS never synced on activation** (critic-3). It now does.
- **Cancel losing the reauth state** (accounts-2): a Cancel on the account screen keeps the
  owner's "Sign in again".
- **401 on Delete Account** (accounts-3): it now leaves the reauth state, not a silent
  signed-in-but-dead device.
- **Recovered-edit guards blind at the cap** (recovery-backup-1): the Clear / Erase / Delete
  Account guards compare lines + dropped, so at the 5 MB cap they still catch an edit archived
  after the count was shown.
- **Checks that could not fail** (recovery-backup-2 and -3): a trim test and a rehearsal check.

Two skeptics re-reviewed the fix commits. Every finding was closed except three, all closed in
round two (`51da3f8`):
- the data-safety-1 design;
- a persistence gap in the accounts-2 fix;
- the missing test for critic-1's presenter.

Gates on `22691e0`:
- StrideTests 422 (en and ja, 2 expected skips)
- hosted 136
- server 451
- rehearsal 74 PASS / 0 FAIL / 1 SKIPPED (LARGE 79/0/1)
- the generic iOS and macOS product checks

### The simulator end-to-end run (2026-09-29)

This was the first run of the device checks on real builds, before the owner's device pass. The
setup:
- **Builds:** Debug 1.3.1 (20) from this branch and 1.3.0 (19) from `release/1.3.0`, in the
  iPhone 17 Pro and 17 Pro Max simulators.
- **Server:** a throwaway local copy of `server/` with a fresh database, no `.env`, port 3002
  (where Debug builds point), and request logging added to the copy only.
- **Sign-in:** through the app's paste-token field, with magic-link rows minted in that
  database.

Nothing touched production. The kit lived in that session's scratchpad and is gone; this section and the re-run below describe it well enough to rebuild in about an hour.

Results:
- **(5) account switch: PASS.**
  - No sync request from the device until the choice.
  - Export is offered first.
  - Start leaves none of A's rows on the device or in B, and A's rows are byte-identical.
  - Cancel changes nothing.
  - Back into A resumes with 0/0/0.
- **(6) restore as new copies: PASS**, including the held "deleted on another device" row and
  Restore as New Copies.
- **Delete Account hand-off: PASS.**
  - The alert → Continue opens the Export step.
  - The recheck catches an edit archived after Continue, updates the sheet in place and deletes
    nothing.
  - The final delete removes the account server-side, erases the device, clears the recovery log
    and the Keychain token.
- **(4) mixed fleet: PASS as specified.** A 1.3.0 and a 1.3.1 device converge after interleaved
  taps, a rename, and an uncheck/re-check with a sync in between.
- **(9) reauth and pause: PASS on Today.** The reauth row and "Sync paused" show with a 503 in
  the log. But Settings showed a red "Please log in again" under a green "Signed in" (round two).

It found:
- **Old apps lose a same-day re-check** (major, in 1.3.0 build 19 and live 1.2.3). A peer
  unchecks and re-checks a day with no sync in between, which deletes entry X and creates Y for
  the same day. An app below 1.3.1 that pulls both in one response then loses Y. Its reconciler
  deletes X, which stays in `habit.records` (no inverse, the build-18 ghost), day-matches Y onto
  that ghost, and the save drops it. The day shows unchecked until a full pull, while the server
  is right. Old apps can't be fixed, so the server now handles it (next section). 1.3.0 is not
  pulled again: 1.2.3, live today, has the same flaw, and the server fix reaches every old app
  without an update.
- **The session token was cached on disk** (pre-existing). `URLSession.shared`'s cache stored
  the `/v1/auth/verify` answer, with the live `sessionToken`, in `Caches/Cache.db`, along with
  pull bodies. The server fix is in the next section; the app fix is in round two.
- UI and behaviour items, fixed in round two:
  - the Settings reauth state
  - Sync Now doing nothing while the account choice is pending
  - a stray `text.txt` next to every exported JSON
  - export temp files, a deleted account's among them, never removed, with three copies per tap
  - Delete Account sheet text truncating after the in-place update, and its warning drawn fainter
    than the footer
  - the recheck offering Export as JSON for an empty store
  - "them" under a singular held-row title
  - Start looking like a safe button
  - Settings' "in 0s" label that never refreshed

### Old apps never get a deletion with its same-day replacement (server, `41c8fea`)

Part of the 1.3.1 server half: not deployed yet, and deployed with the rest after 1.3.0 is live.
- **Schema:** `deletion_tombstones` gains nullable `habit_id` and `entry_date`. The ALTER is
  additive, idempotent and PRAGMA-guarded; existing rows keep NULL. Both are filled from the
  row that a sync push or the REST uncheck deletes.
- **Pull:** a pull from an app below 1.3.1 holds back an entry deletion whose day the same
  response carries under another id. The old app then day-matches its still-live X, re-IDs it to
  Y and converges without deleting. This is always sufficient: the replacement is written after
  the deletion, so any window that includes the deletion also carries it.
- **Unchanged:** 1.3.1+ get every deletion, as before. Tombstones written before the deploy name
  no day, so they are sent as before.
- **Logging:** the pull's log line counts `withheld=`.
- **No-store:** every answer on `/v1` and the legacy mounts, errors included, is `Cache-Control:
  no-store`, and conditional headers are ignored. ETags are off app-wide. `/login` is no-store
  too, since the page shows a live token. Static pages and the AASA file are unchanged.
- **Checks:** `server/ops/rehearsal-checks.js` checks the columns, the no-store answers, and a
  real uncheck + re-check pulled as 1.3.0, header-less and 1.3.1. DEPLOY.md has the migration and
  the post-deploy checks.
- **Tests:** server 478 on the combined tree, and the rehearsal 74/0/1.
- **Still open:** one case is inferred and not reproduced. If the deletion and the re-check
  reach an old app in two separate pulls within one app session, the ghost might still eat the
  re-check. S4 saw a later pull in the same session heal the day, which suggests the reconciler's
  fresh context does not keep the ghost. The simulator re-run checks it explicitly.

### Round two (2026-09-29): the upgrade pass decided by the account's deletions (`51da3f8`, `cc272aa`)

**Why `deb5ebc` was not the end of data-safety-1.** Its first pass after the upgrade resent
every delivered row the account lacked, instead of deleting it. That protected the rows the 1.3.0
server had refused. The re-review found two costs:
- **Resurrection after a sweep (major).** Once tombstones are swept, the resend becomes an
  insert. A long-dormant device would then bring back rows deleted elsewhere, which is exactly
  the case the migrated marks exist for (owner decision R1).
- **Noise (minor).** Every ordinary deletion or untap made on another device since this
  device's last 1.3.0 sync came back `tombstoned` and landed in Recovered Edits. One untap on
  the iPad gave "Recovered Edits (1)"; a deleted two-year habit gave about 731 lines.

**v2.** The two cases can be told apart by the account's deletions since the store's last 1.3.0
pull. 1.3.0 kept that pull's server-time cursor (`stride_sync_cursor`).
- **Pinning:** the delivery migration pins the cursor as `stride_delivery_marks_deletions_since`.
- **Asking:** the full pull that verifies the marks sends it as `deletionsSince`. The server
  (≥ 1.3.1, full pulls only) answers `deletionsSince: {complete, habitIds, entryIds, groupIds}`,
  read in the same transaction as the snapshot. Past the 355-day cursor horizon it answers
  `{complete: false}`.
- **The pass:**
  - A row that is listed was deleted elsewhere. It goes by the normal rule, quietly unless it
    was edited here.
  - A row missing from a complete list was refused. It is resent with `restoredAt`, so a
    `tombstoned` or `not_owned` answer holds it, and its check-ins, for Restore as New Copies. A
    row no server holds is inserted.
  - With no list, the row is deleted and every row is archived first: nothing lost, nothing
    resurrected.
- **Harness result:**
  - H1 (swept, cursor past the horizon): 0 rows pushed, 4 lines archived, nothing re-inserted.
  - H2 and H3 (deleted or untapped elsewhere): 0 pushed, 0 lines.
  - With `deb5ebc`, H1 re-inserted; H2 gave 4 pushed / 4 lines, H3 1 / 1.
- **The one rule v2 relies on:** tombstones are kept at least 365 days, so a list the server
  calls complete really is. `sweepStaleData` now enforces that: it refuses a younger retention
  unless the caller is the rehearsal hook or a test.

**Also in `51da3f8`:**
- **accounts-2:** what Cancel restores is persisted (`stride_session_expired_before_sign_in`,
  from `sessionExpired || needsReauth`). It survives a relaunch and covers a 401 met this launch.
- **The reauth row after sign-in:** a successful sign-in clears `needsReauth`, so the row no
  longer waits for the first sync to succeed.
- **critic-1 test:** a hosted test puts the real TodayView in a window from a `{user: null}`
  cold launch, taps the row and signs in. It checks that the same sheet stays up and shows the
  account step. It fails on the old structure.
- **Test seams:** the test needs two, both outside the shipped app. `testOverride` on
  `AuthService.shared` / `SyncService.shared` is Debug-only. The accessibility automation switch
  is reached through `dlopen` inside the StrideAppTests bundle only.

**`cc272aa`: the simulator run's app findings.**
- **Session token on disk:** the app talks through its own ephemeral session, with no URL
  cache and no cookie store. Every launch purges what earlier builds left in the shared cache
  and the API hosts' cookies.
- **Settings' Account section in the reauth state:** it shows Today's "Sign in again to keep
  syncing" row, with the email and the same sheet. The red error is gone.
- **Sync Now while the account choice is pending:** it opens that account screen.
- **Exports:**
  - one file per share, and no stray `text.txt`;
  - every `StrideExport-*` folder is removed at launch, after an erase, after Delete Account,
    and after Start from This Account's Data.
- **The Delete Account sheet:**
  - the footer wraps after the in-place update;
  - the warning is drawn at the footer's own contrast;
  - the recheck re-reads whether there is anything to export;
  - the backup advice shows only when there is something to back up.
- **Held-row wording:** held-row bodies follow the count, with plural keys in six languages.
- **Start from This Account's Data:** tinted as destructive.
- **Settings' last-sync label:** reads like Today's and refreshes every minute; no more "in 0s".
- **Sign-in sheet:** opened from a "Sign in again" row, it starts with the account's email.

Gates on the merged tree (`cc272aa` + `5dca011`), and again on the final tree `0b7bdd2` after
the re-run's polish, with the same counts:
- StrideTests 432, en and ja, 2 expected skips (the real-container test and an iOS-only one)
- hosted 151
- server 488, typecheck clean
- rehearsal 80 PASS / 0 FAIL / 1 SKIPPED (LARGE 85/0/1)
- the generic iOS and macOS product checks

### The simulator re-run on the round-two build (2026-09-29/30)

Same setup and kit as the first run. Real builds: 1.3.1 (20) rebuilt from `9d1d05e`, and 1.3.0
(19).

**Upgrade in place, a real 1.3.0 store (E2E-U): all seven checks PASS.** The store was set up
on 1.3.0:
- another account's backup restored while signed in, so its habit was refused `not_owned` on
  every 1.3.0 sync;
- the account's own habits, synced, then synced again more than 5 minutes later (the
  migration's margin).

Then, on another device, one habit was deleted and one check-in unchecked. The 1.3.1 app was
installed over 1.3.0, keeping the data container, and its first sync ran:
- It pulled `?deletionsSince=` 1.3.0's cursor, and the answer listed the deleted habit, its
  check-in and the unchecked check-in.
- Those were removed quietly: no Recovered Edits row, and no recovery log at all.
- The other account's habit and its check-in were resent, answered `not_owned` /
  `not_owned_habit`, and held ("1 habit belongs to another account").
- Restore as New Copies uploaded them into the account under new ids. Nothing of the other
  account's leaked, and its rows are unchanged.
- The unverified / unproven / pinned-cursor keys were cleared, and the next sync was quiet.
- 1.3.0's cached `/v1/auth/verify` answer, with the session token, was purged at the first 1.3.1
  launch. This was checked against a 1.3.0-era server copy, since the new server's no-store
  answers leave nothing to cache.
- No crash.

**Mixed fleet against the new server (E2E-M): all four PASS.**
- **One pull carries both.** A 1.3.1 uncheck + re-check with no sync in between was pulled by
  1.3.0 with `withheld=1`. 1.3.0 re-IDed its record, and the day stayed checked, including after
  a cold launch.
- **Two separate pulls in one 1.3.0 session.** This was the unreproduced residual: the deletion
  came in one pull and the re-check in the next, with no relaunch. The re-check was not lost, in
  that session or after a relaunch, so no further server measure is needed. That rests on one
  reproduction.
- **The id alias.** Two devices checked a day offline. The 1.3.1 push answer named the stored id
  (`aliases`), the app took it, and a later uncheck deleted the server row; both devices end
  unchecked.
- **No cache on either app version.** Every `/v1` answer is `no-store` with no ETag, and
  `If-None-Match: *` still gets a 200.

**Sign-in, reauth and the account screen (E2E-R, on `cef373d`): all six PASS.**
- **The reauth state.** Settings' Account section shows Today's "Sign in again to keep syncing"
  row, with the email under it. There is no green "Signed in" and no red text, and Data Storage
  says "Not Syncing".
- **The account screen after a reauth sign-in (critic-1).** Tapping the row opens the sign-in
  sheet with the account's email filled in. Signing in to a different account shows the account
  screen inside that same sheet.
- **Cancel (accounts-2).** It signs out and changes nothing. "Sign in again" comes back and
  survives a cold launch.
- **A sign-in ends the row.** It goes at once, even when the next sync is paused, or after a
  session check that failed offline.
- **Sync Now while the choice is pending.** It opens the account screen and sends no request.
  Start from This Account's Data is red.
- **Settings' last-sync label** refreshes by itself ("Synced just now", then "1m ago"). The
  swipe Delete is red.

**Exports, Delete Account and held rows (E2E-X, on `cef373d`): all five PASS.**
- **Exports.** One item per Save to Files and no `text.txt`. One `StrideExport-*` folder per
  share, although the share sheet asks for the file twice. The folders are gone after a cold
  launch and after an erase.
- **Delete Account with recovered edits.**
  - The sheet offers both exports.
  - An edit archived while the sheet is up updates it in place: nothing is deleted, and the
    footer wraps in full. The warning is drawn in the footer's own colour (sampled 133,133,139
    for both).
  - Once the store is empty, the updated sheet drops Export as JSON.
  - The final delete removes the account server-side and signs the device out. It empties the
    store, the recovery log and `tmp`, and leaves no token.
- **One held habit.** The Sync section reads, in the singular:
  - "1 restored habit was deleted on another device"
  - "Restore it as a new copy…"
  - a "Restore as a New Copy" button
  - "Discard This Item?" with "It's removed from this device…"

  Restore as a New Copy uploads the habit under a new id, and Today's "1 change can't sync —
  see Settings" goes with it.

**Found on the way (fixed in `cef373d` and `0b7bdd2`):**
- With one held habit, the body read "Restore it as a new copy" above a "Restore as New Copies"
  button. The button, the Discard dialog title and both Discard messages now follow the count.
- Settings' three swipe Deletes were drawn green (the app tint). They are red.
- Full Resync was offered while the session needed signing in again, where it can only get a
  401. It is hidden then (`0b7bdd2`).

**A 1.3.0 flaw the re-run confirmed (not a 1.3.1 bug):**
- **What happens:** on 1.3.0, a restore of another account's backup made while SIGNED OUT is
  lost when you then sign in. The logout had cleared 1.3.0's cursor, so the sign-in sync is a
  full pull, which deletes every local row the account lacks, with no message.
- **Why 1.3.0 is not pulled:** the backup file keeps the rows. 1.3.1 restores another account's
  backup only as new copies. The server cannot change what 1.3.0 deletes locally. It is recorded
  under RELEASE-1.3.0.md's known limitations.

### Round three (2026-10-07): agent-run tests replace the device pass, and they found a blocker

The owner waived TestFlight and the real-device pass for good. The agent tests directly, with the
simulator kit now committed as `scripts/sim_e2e/` (README.md is its manual): ad-hoc-signed Debug
builds of any tag, a throwaway server copy on :3002, paste-token sign-in, and `upgrade.sh` for
in-place upgrades.

**The blocker: the first 1.3.1 launch after an upgrade could hide every habit.** 1.3.1 is the
first model change since 1.2.x, so its first launch migrates the store.
- **What happened:** chronod starts the widget extension at the same moment as the app, and
  `StrideWidget.init()` opened the same App Group store. Both processes migrated it at once. The
  app's `ModelContainer` failed with CoreData 134110 / 134100 ("store version hashes didn't
  migrate"), and `SharedModelContainer` silently fell back to a NEW EMPTY `default.store`.
- **What the user saw:** "Start Your Journey". The delivery migration was spent on the empty
  store, so the next launch pushed the whole real store and filled Recovered Edits with rows
  deleted elsewhere.
- **The evidence:** 4 of 4 real upgrades failed with the widget present (from 1.2.3 and from
  1.3.0), and 0 of 2 without it. The acceptance-2 test passed on the same stores: it runs in one
  process, so it cannot see the race. The 2026-09-29 1.3.0 upgrade run passed by luck: the widget
  happened to finish migrating first.
- **Build 20** (uploaded 2026-10-07) has the bug. It was never submitted and is superseded by
  build 21.

**The fix (`ac1fbec`, review round `7ee5f8f`).**
- **Only the app opens or migrates the store** (`SharedModelContainer.openForApp`). After its
  open succeeds, it writes `stride_store_schema_version` to the App Group defaults and reloads the
  widgets.
- **The widget waits.** Its timeline and its check-in intent open the store only when that marker
  equals the widget's own schema (`openForExtension`, `StoreSchemaGate`). Until then it shows
  "Open Stride to see your habits" and writes nothing.
  - A test pins the models' version hashes to the marker value, so a model change without a bump
    fails.
- **A failed open never falls back to an empty store.** It retries for up to 3 s while the store
  file exists, then shows "Stride couldn't open your data" with Try Again. It sends one Sentry
  report with the error codes only, and touches nothing.
  - The empty fallback remains only when there is no App Group container at all.
- **One-time migrations refuse anything but the real store.**
- **Review round (`7ee5f8f`):**
  - reading the container never waits on an open in progress;
  - the widget's open path is tested end to end;
  - the error screen names what can work: free up storage, and reinstall + sign in only for
    synced accounts.
- **Translations:** six new strings in all five languages. Each message names the Try Again
  button as its catalog does.
- **Privacy page:** `docs/privacy.html` lists the new error report.

**Re-verified on the fixed build.** Six real in-place upgrades all passed: three from 1.2.3 and
three from 1.3.0, three of them with the widget placed. A fresh install with the widget passed
too. In every run:
- no 134110 and no fallback store;
- the data on screen at the first launch;
- the first full pull asked `deletionsSince=` the old app's cursor, and the 21 deletions made on
  the other device went quietly (no push, no Recovered Edits);
- the marker written, and every delivery flag cleared;
- the next sync quiet.

This is the first run of round two's intended upgrade path on a real old store. The widget
showed the placeholder until the app's first launch, then the real numbers.

**The upgrade run is now a release gate** (`scripts/sim_e2e/upgrade.sh`, from each live older
version, with the widget). So is the Release-build smoke run, which passed: no crash, and no
stride-api traffic signed out.

Gates on `7ee5f8f`:
- StrideTests 458, en and ja, 2 expected skips
- hosted 159
- server 488, typecheck clean
- rehearsal 80/0/1
- iOS and macOS product checks; no xcodegen drift

## Known limitations

- **Count habits merge by last-write-wins per entry**, not additively. 3 glasses logged offline
  on the phone and 5 on the iPad resolve to whichever was edited later, not 8. Additive merge
  is a later design.
- **An older app's edit is only as precise as its string.** A 1.2.3 edit at :18.900 is stored
  as :18.000 and loses to a 1.3.1 edit at :18.400.
- **F1 on the same account.** A device whose 1.3.0 session died before the update gets the
  Upload / Start screen even when the same account signs back in. Upload is correct there, but
  the user has to choose it.
- **The proof residual.** A migrated store whose every delivered row was deleted on another
  device holds nothing a snapshot can show. Its marks are forgotten and the rows re-uploaded.
  While tombstones are kept, the answer is `tombstoned` and the rows land in the recovery log.
  After a sweep they would come back into the account: a restore the user can undo, not a loss.
- **A store with no list of its deletions.** Three cases get archive-then-delete for the rows
  its account lacks at the first pass after the upgrade:
  - a store that slept more than 355 days;
  - a store that came from an app with no server-time cursor (≤ 1.2.2);
  - a store that meets a server without `deletionsSince`, i.e. the server half not deployed.

  Nothing is lost or resurrected, but deletions made elsewhere land in Recovered Edits. Rows the
  1.3.0 server refused are archived rather than held for Restore as New Copies. So deploy the
  server half before 1.3.1 reaches users.
- **A share sheet left open over a minute writes a second export file.** An export is reused
  for 60 s, so a Save to Files chosen later writes a fresh copy (E2E-X). The user still gets one
  item, and the spare copy is removed at the next launch, erase or account deletion. A longer
  window would hand out stale data after an edit; one file per share sheet needs a presentation
  id.
- **Recovered edits are export-only.** Settings shows a count with Export / Clear, not a
  browsable list. The spec allows that list to move to a later 1.3.x.
- **macOS: a widget edit made while the app stays frontmost** does not refresh the "changes
  waiting" count until the next sync or activation (G5, minor).
- **Tombstones are still never swept**, and there is no 426 floor yet. Both wait on the usage
  report showing the ≤ 1.3.0 cohort gone. The floor must be ≥ 1.3.1.
- **Not captured by any screenshot script:**
  - the Settings owner-choice row → account sheet
  - the confirmation dialogs, and the "Delete Account?" alert → Continue → sheet hand-off (the
    demo scenario presents the sheet directly)
  - the macOS sheets

  Since the decisions 2–4 round, `scripts/a11y_sweep.sh` captures the Delete Account step
  (`13_settings_deleteAccount`, `-demoScenario deleteAccount`) and the restore hand-over
  (`14_restore_handover`, `-demoScenario restoreHandover`) at every size, plus `*_at_<anchor>`
  frames below the fold at accessibility sizes (`-scrollTo <anchor>`, `<anchor>@bottom` for the
  Delete Account address line). The hand-swiped `*_scrollN` frames are deleted.

## TODO — phase D, before submission

### Review

- [x] **Codex review: skipped, on the owner's word** ("codex没反应跳过也行", 2026-10-07). Its quota
  ran out five times between 2026-10-04 and 10-07, the last time midway through a whole-branch
  read. The narrow advisory run (race fix and upgrade pass only, 2026-10-07 19:55–21:45) read
  nothing: its file tool timed out negotiating with the host on every call, and it said so rather
  than report "none". No Codex finding exists for 1.3.1.
- [x] **Gemini 3.1 Pro review of the race fix** (2026-10-07, MCP bridge on a throwaway copy of the
  files): "none" in every category. It raised two minor points, both known trade-offs:
  - the first open can block launch for up to 3 s, only while an existing store keeps failing;
  - the widget-gate unit tests inject the file and model checks. The six real upgrade runs
    exercise the real gate in the widget process.
- [x] **Privacy page published** (owner's OK, 2026-10-07): stride-site `c0d5d1c` adds 1.3.1's
  "couldn't open your data" error report (error codes only), dated October 7, 2026. Verified live
  at https://jasonyeyuhe.github.io/stride-site/privacy.
- [x] Final full review: the internal cross-phase review and its re-review (above).
- [x] Phase C follow-up round (decisions 2–4) reviewed and fixed (`7181628`).
- [ ] **Native read.** Gemini 3.1 Pro read the 1.3.1 strings and What's New; its ko and zh
  What's New findings were fixed (`97e9697`), and its ja "Synced %@" claim was wrong. A human
  native read is still open for:
  - the short labels "Habits from" / "Signed in as": ja 習慣のアカウント, ko 습관 소유 계정
  - "Changes from": ja 変更元のアカウント, which wraps at AX-XXXL; ko 변경 사항 소유 계정
  - ja 復旧した編集

### Server — deploy only after 1.3.0 is live

- [x] 1.3.0 (19) approved **and released**: READY_FOR_SALE on iOS and macOS, found 2026-09-30
  01:3x JST. The version was MANUAL, so the owner released it.
- [x] **Deployed 2026-09-29 16:25 UTC** (server tree at `5dca011`), by DEPLOY.md's five steps:
  - tests: 488 pass, typecheck clean;
  - host diff: every host file equal to the last deploy `441b809`, nothing host-only;
  - prod-copy rehearsal: every check PASS, "safe to deploy";
  - backup: `/root/backups/stride-predeploy-20260929-162541.db` (integrity ok);
  - rsync and restart.

  Verified after: `/health` 200 via nginx; loopback bind intact (direct :3002 → 000); AASA 200
  `application/json`; `/v1` answers `Cache-Control: no-store` with no ETag (static pages keep
  theirs); `deletion_tombstones` has `habit_id` / `entry_date` (production had 0 tombstones);
  `integrity_check` ok; `check_demo_account.sh` exit 0.
- [x] The deploy's scope: the 1.3.1 server half, with the prod-copy rehearsal
  (`scripts/rehearse_server.sh`), before any 1.3.1 build reaches a user. Confirm the tombstone-sweep hook is not mounted in
  production. The half includes:
  - the header-gated millisecond pull and the LWW re-feed (`f911248`, plus the phase B server
    commits)
  - the id aliases (`22691e0`)
  - the `deletion_tombstones` migration, the old-app hold-back and no-store (`41c8fea`)
  - `deletionsSince` on a ≥ 1.3.1 full pull (`51da3f8`), which the upgrade pass needs; without
    it the pass falls back to archive-then-delete
  - the 365-day floor in `sweepStaleData` (`5dca011`)

  The deploy also helps live 1.2.3 users (the same-day re-check). Run DEPLOY.md's post-deploy
  checks for both `41c8fea` fixes.
- [x] Acceptance (7), checked against production after the deploy as the demo account (session
  logged out after): `ios/1.3.1(20)` gets `2026-08-02T02:37:19.313Z`; `ios/1.3.0(19)` and no
  header get `2026-08-02T02:37:19Z`.

### Migration and gates

- [x] **Real-store migration test** (acceptance 2). It passed on stores written by the real 1.2.3
  (7 habits / 135 records) and 1.3.0 (6 / 119) apps from realistic demo history, on macOS and
  the iOS 26.5 simulator, with every row and link intact (round three). It is single-process; the
  in-place upgrade runs cover the race. The command, with `STRIDE_REAL_STORE_PATH` pointing at
  such a store:
  `TEST_RUNNER_STRIDE_REAL_STORE_PATH=… xcodebuild test -scheme StrideTests -destination
  platform=macOS -only-testing:StrideTests/SyncDeliveryTests/testARealDeviceStoreOpensUnderTheNewSchema`.
  It is skipped until then. Fresh simulators prove nothing about live stores.
- [x] `sync_rehearsal.sh` (80 PASS / 0 FAIL / 1 SKIPPED) and `check_demo_account.sh` (exit 0)
  green on the tree that was archived (`a2cff60`, 2026-10-07; acceptance 1, 3).
- [x] Acceptance (8): both archived 1.3.1 (20) apps' `PrivacyInfo.xcprivacy` declare Product
  Interaction (`verify_archive.sh`, 2026-10-07). `product_checks.sh` fails a built app whose manifest drops it, and
  `verify_archive.sh` runs it on the archive and the export, so a green `verify_archive.sh` is
  the check.

### Device checks (acceptance 4, 5, 6, 9)

These stay unticked because no real device ran them; they are **closed by the waiver below,
not by a device**. All of them passed in the simulators against a local server (the E2E runs above). **The owner
waived TestFlight and the real-device pass (2026-10-07: "不需要testflight 以后都可以省略这个步骤
你直接测试就好")**, for this release and every later one. Agent-run testing replaces it: the
simulator runs, in-place upgrades from the real 1.2.3 and 1.3.0 builds, the real-store migration
test on stores those builds wrote, and a Release-build smoke run (round three, below).

- [ ] (4) Mixed fleet on real builds: a 1.3.0 (or 1.2.3) device and a 1.3.1 device on one test
  account. Tap one habit on each and sync both; both show both taps. Also uncheck and re-check a
  day on the 1.3.1 device with no sync in between, then sync the old device: the day stays
  checked there. This needs the deployed server half; the simulators passed it against a local
  copy.
- [ ] (5) Sign out of A and sign into B on one device. The server log shows no sync request from
  that device until the choice. The screen offers Export first. "Start from this account's
  data" leaves none of A's habits on the device or in B. Signing back into A instead resumes,
  and its next sync with no edits pushes 0/0/0.
- [ ] (6) Export a backup on A and restore it as new copies on a device signed into B. The
  habits are in B after a sync and still there after a full pull. A restored habit that another
  device deleted is held, and "Restore as New Copies" brings it back.
- [ ] (9) Revoke the session server-side: Today shows the reauth row on the next foreground,
  and Settings shows the same state with no red text. Tap the row and sign in to a different
  account: the account screen appears inside that sheet (critic-1). Flip the pause switch:
  "Sync paused" shows, with no error. On the Mac, bringing the app forward is enough (critic-3).
- [ ] Delete Account on a device with a recovered edit: alert → Continue → Export step → an edit
  archived while the sheet is up updates it in place and deletes nothing (the simulators passed
  this).
- [ ] The screens no script captures (see Known limitations), on a device and on a Mac. The
  simulator runs walked every iOS one: the owner-choice row → account sheet, the confirmation
  dialogs, and the alert → Continue → sheet → recheck hand-off. The macOS sheets are still
  unseen.

### Release mechanics

- [x] Product Interaction re-declared (above).
- [x] What's New in six locales (above), opening with the backup advice.
- [ ] ASC App Privacy: unchanged from 1.3.0. Product Interaction stays declared, and Email
  Address, Other User Content, Crash Data and Other Diagnostic Data match the manifest.
- [x] Archived, exported and uploaded both platforms through every gate
  (`build-appstore.sh all --upload`, 2026-10-07 01:19 JST, tree `a2cff60`).
  - Each one: 1.3.1 (20), Distribution-signed, no `get-task-allow`, associated domains present,
    Sentry DSN compiled in.
  - dSYMs are kept in `build/dsyms/1.3.1-20/` and uploaded to Sentry.
  - Apple's "Upload Symbols Failed" warning is about the prebuilt Sentry.framework's missing
    dSYM. It is harmless, as in earlier builds.
- [x] `release.py prepare 1.3.1`: both version records are PREPARE_FOR_SUBMISSION, with What's
  New in six locales, MANUAL.
- [x] **Build 21** (the upgrade-race fix, tree `c4edb6a`): archived, verified and uploaded on both
  platforms, 2026-10-07 05:50 JST. Before the archive: the signing probe passed, the rehearsal was
  80/0/1 and the demo check exit 0. `verify_archive.sh` passed: 1.3.1 (21), Product Interaction,
  Distribution-signed, associated domains. Build 20 is superseded and never submitted.
- [x] **Submitted 2026-10-07 16:09 JST** (`release.py finish 1.3.1 21`, on the owner's go), build
  21 on both platforms:
  - iOS review submission `1216f4ac-29c3-481f-803b-1eca5c9ad9ad`
  - macOS review submission `74e1bb03-77b5-46b7-8d18-964d41b08b16`

  Both WAITING_FOR_REVIEW, MANUAL. The owner allowed skipping Codex when it does not answer ("codex
  没反应跳过也行"). The narrow Codex run still goes at 19:55 as an advisory check: anything serious
  goes into 1.3.2, or 1.3.1 is pulled from review if urgent.
- [x] **Approved on both platforms.** iOS 1.3.1 (21) was released by the owner in ASC and is
  READY_FOR_SALE (found 2026-10-10). Sentry, production environment, 7 days: 1.3.1+21 has 8
  healthy sessions from 5 installs, none crashed or errored. The server log has no error since the
  deploy.
- [ ] **macOS 1.3.1 (21) is PENDING_DEVELOPER_RELEASE**: approved, waiting on the owner's go for
  `release.py release 1.3.1` (or the Release button in ASC).
- [x] `release/1.3.1` merged with `main` (`75697be`: the only conflict was `docs/privacy.html`;
  kept the 2026-10-07 page that stride-site serves, the tree is identical to `315878b`). PR
  JasonYeYuhe/Stride#6 merged into `main`; tag `v1.3.1` on `315878b`, whose code is the build's
  tree `c4edb6a` (every later commit is docs).