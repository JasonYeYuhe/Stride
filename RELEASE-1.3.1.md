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

Items 2–4 are implemented in the round after `aa0362c`; record their commit here. Item 3's
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

- [ ] **Codex review** of the whole M2 diff (`1b33b4a..HEAD`), queued since the slice after its
  usage reset. Fact-check every claim against the code before adopting it, as for 1.3.0.
- [ ] Final full review of the phase C follow-up round (decisions 2–4 above), and a native read
  of the short labels "Habits from" / "Signed in as" in ja (習慣のアカウント) and ko
  (습관 소유 계정), of "Changes from" (restore hand-over caption: ja 変更元のアカウント, which
  wraps to two lines at AX-XXXL, ko 변경 사항 소유 계정), and of ja 復旧した編集.

### Server — deploy only after 1.3.0 is live

- [ ] 1.3.0 (19) approved **and released** (`release.py release 1.3.0`, on the owner's go).
- [ ] Deploy the header-gated millisecond pull and the LWW re-feed (`f911248`, plus the phase B
  server commits) with the prod-copy rehearsal (`scripts/rehearse_server.sh`), before any
  1.3.1 build reaches a user. Confirm the tombstone-sweep hook is not mounted in production.
- [ ] Acceptance (7): against production, a pull with `X-Stride-Client: ios/1.3.1(20)` shows
  millisecond `updatedAt`, and one without the header shows whole seconds (curl, DEPLOY.md's
  post-deploy check).

### Migration and gates

- [ ] **Real-container migration test** (acceptance 2). Download a populated container from a
  device running 1.2.3 or 1.3.0 (Xcode → Devices → download container) and run
  `TEST_RUNNER_STRIDE_REAL_STORE_PATH=… xcodebuild test -scheme StrideTests -destination
  platform=macOS -only-testing:StrideTests/SyncDeliveryTests/testARealDeviceStoreOpensUnderTheNewSchema`.
  It is skipped until then. Fresh simulators prove nothing about live stores.
- [ ] `sync_rehearsal.sh` and `check_demo_account.sh` green on the build that ships (acceptance
  1, 3).
- [ ] Acceptance (8): the **archived** 1.3.1 app's `PrivacyInfo.xcprivacy` declares Product
  Interaction. `product_checks.sh` fails a built app whose manifest drops it, and
  `verify_archive.sh` runs it on the archive and the export, so a green `verify_archive.sh` is
  the check.

### Device checks (acceptance 4, 5, 6, 9)

- [ ] (4) Mixed fleet on real builds: a 1.3.0 (or 1.2.3) device and a 1.3.1 device on one test
  account. Tap one habit on each and sync both; both show both taps.
- [ ] (5) Sign out of A and sign into B on one device. The server log shows no sync request from
  that device until the choice. The screen offers Export first. "Start from this account's
  data" leaves none of A's habits on the device or in B. Signing back into A instead resumes,
  and its next sync with no edits pushes 0/0/0.
- [ ] (6) Export a backup on A and restore it as new copies on a device signed into B. The
  habits are in B after a sync and still there after a full pull. A restored habit that another
  device deleted is held, and "Restore as New Copies" brings it back.
- [ ] (9) Revoke the session server-side: Today shows the reauth row on the next foreground.
  Flip the pause switch: "Sync paused" shows, with no error.
- [ ] The screens no script captures (see Known limitations), on a device and on a Mac.

### Release mechanics

- [x] Product Interaction re-declared (above).
- [x] What's New in six locales (above), opening with the backup advice.
- [ ] ASC App Privacy: unchanged from 1.3.0. Product Interaction stays declared, and Email
  Address, Other User Content, Crash Data and Other Diagnostic Data match the manifest.
- [ ] Archive and export both platforms through every gate (`verify_archive.sh --exported`):
  1.3.1 (20), Distribution-signed, no `get-task-allow`, associated domains present.
- [ ] `release.py prepare 1.3.1`, upload, then **`release.py finish 1.3.1 20` on the owner's go**.
  The version is created `MANUAL`; publish with `release.py release 1.3.1` after the device
  checks.
