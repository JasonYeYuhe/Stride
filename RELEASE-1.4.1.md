# 1.4.1 (M4) — plan

App ID `6761262334`, bundle `yyh.stride.habittracker`. **Plan dated 2026-10-14; no code yet.**

- Branch `m4/1.4.1`, cut from the `m3/1.4.0` tip `376e69b`. Version 1.4.1 (23), or 24 if Mac 1.4.0
  needs a rebuild (P2).
- Scope: [DEV-PLAN-1.3.md](DEV-PLAN-1.3.md) M4 (`:1176-1249`), which covers strength, editable
  history, best streaks, notes, and stats that scale.
- Also included: RELEASE-1.4.0.md's "Follow-ups for 1.4.1" (`:957-997`), the client half of the
  magic-link fix, and two small server changes that only keep sync data (Data safety 2).
- This file was committed as `RELEASE-1.4.1.md` when `m4/1.4.1` was cut (2026-10-14). W0 opens the
  draft PR.

## Where things stand on 2026-10-14

- **1.4.0 (22):** iOS is live. macOS was submitted on 2026-10-14 (`e785e2d9…`) and is
  WAITING_FOR_REVIEW with MANUAL release (RELEASE-1.4.0.md:939-955). PR #7 is a draft, CLEAN, with
  CI green on 376e69b. `main` is still the merge-base f706596 (1.3.1). Since the uploaded tree
  4617d1b, only docs and `release.py` have changed.
- **Production sign-in outage:** magic-link mail has probably never reached a real user.
  - Stride's `RESEND_API_KEY` is ColorArchive's key, and that Resend account has only
    colorarchive.org verified, so `request-link` answers 500 (server/routes/auth.js:51-72).
  - None of the 4 non-demo accounts has ever synced.
  - The fix needs no app release (P1).
- **Another session's uncommitted work:** session 4c69e79f has 14 modified files (+189/−12) on
  `claude/infallible-agnesi-84254a`, at f706596, in `.claude/worktrees/infallible-agnesi-84254a`.
  - Server: auth.js `code: login_email_unavailable`, api.test.js, DEPLOY.md "The Resend side",
    check_email_auth.sh.
  - Client: APIClient, AuthService `MagicLinkRequestOutcome`, LoginView Contact Support, 2 hosted
    tests, and 1 line in each of the 5 catalogs.
  - **This plan never edits, stashes, checks out or commits in that worktree.**
- **Mac and tooling:**
  - The Mac-only UI (the 13-item checklist, RELEASE-1.4.0.md:974-997) has never been run;
    computer use was declined 3 times.
  - APP_DESKTOP still shows 1.3.1.
  - An old real-bundle-id Debug app sits at `build/Debug/Stride.app`, registered with
    LaunchServices (P3 step 0).
  - Kit and variant builds were purged along with `$TMPDIR`.
  - Suites: StrideTests 540 (en, ja/JP, 2 known skips), hosted 248, rehearsal 81/0/1.

## Decisions of 2026-10-15 (owner, after a Codex + Gemini consult)

The owner took every recommendation ("全部按推荐的做"). The consult and its fact-check are under
"Plan review", below. Where this list and older text disagree, this list wins.

1. **A now,** in refined steps:
   - **0. Dry run (done 2026-10-15):** `FROM_EMAIL` set on the command line only, one send
     through `email.js` to `delivered@resend.dev`. Answer: `sent`.
   - **1–3.** Back up `.env`, set `FROM_EMAIL=Stride <stride@colorarchive.org>`,
     `pm2 restart --update-env`.
   - **4.** Send through `email.js` to the sink again, and make one `request-link` to the
     owner's plus-address (item 4).
   - **5.** The owner checks `dkim=pass`.

   Steps 1–4 each still need a go.
2. **B before 1.4.1's submission.**
   - The owner opened a separate Resend account on 2026-10-15.
   - They add `stride.colorarchive.me` in region us-east-1, which matches the existing
     `send.stride` MX. Then only the DKIM TXT changes at Namecheap.
   - When the domain is Verified, the owner runs `scripts/ops/set_resend_key.sh` themselves.
     It takes hidden key input, swaps the key and FROM back to `hello@stride.colorarchive.me`,
     test-sends, and rolls back on a failed send. An agent never handles the key.
3. **4c69e79f commits its own work.** That session committed twice and opened
   JasonYeYuhe/Stride#8. It also fixed the DEPLOY.md diagnostics to exit 1 on failure. This
   session runs A and the server deploy, with a go per step.
4. **Production test identity.**
   - Every production sign-in test uses one plus-address, `<owner>+stride-smoke@gmail.com`. It
     lands in the same inbox but is a separate account; `auth.js` only trims and lowercases.
   - Never use the owner's primary address or the demo account.
   - Before any `delete-account`, `GET /v1/auth/session` with the same token, and delete only
     if `user.email` is exactly that address.
   - Why: `delete-account` hard-deletes the account's habits, entries, groups, sessions and
     tombstones.
5. **O5 = (1′), payload-shape refusal,** in JasonYeYuhe/Stride#9.
   - A push with any entry lacking `updatedAt` (≤1.2.2) or any habit lacking `kind` (1.1) is
     answered 426 `client_update_required`, with the sentence in `error`, before anything is
     written.
   - Verified from tagged sources:
     - 1.1 and 1.2.0–1.2.2 push before pull in one do/catch, and a non-2xx, non-401 answer
       throws before the pull, so a refused device never runs the destructive first-full-pull
       reconciliation;
     - v1.2.3+ always send both fields.
   - It also closes what (2) left open: 1.1 resetting count/schedule habits on every sync, and
     legacy deletions, including the 1.2.2 widget's count wipe.
6. **The server half of Data safety 2 ships early,** in #9, not W8:
   - the note-keeping CASE;
   - a push-order merge: a newer different-id NULL-note row arrives first, then the older
     noted row; the note merges onto the stored row, its stamp moves +1 ms, and it re-feeds.

   Order: deployed after A, with #8, once both are in `main` (a trial merge is clean; the
   merged server suite passes 516/516), by DEPLOY.md's 5 steps, with a go.
7. **Same-day duplicates merge on write (D4).** *Amended 2026-10-15 by W2's review (data safety):*
   a merge deletes the duplicates **on this device only and queues no tombstone**, and marks the
   kept record `needsResend` at its own stamp (undone on a failed save). The server keeps one row per
   (habit, day), applies deletions first and blocks a tombstoned id for good, so a tombstone for a
   duplicate could only ever delete the day's one row (rehearsal M6–M8 lost the day on the old
   rule). An un-check of a day still tombstones each of its ids once. The test line below now reads
   "[2,8] → setValue(3) leaves one record of 3 and no tombstone".
   - On a day with more than one live record, each setter keeps the record D2 reads: the
     largest value, then the newest stamp.
   - It moves any other non-empty note onto that record, or returns `.needsConfirmation` when
     two differ.
   - It deletes the others and returns all their ids for tombstones.
   - `tap` acts on the same kept record.
   - Tests: [2,8] → `setValue(3)` leaves one record of 3 and no tombstone (amended), in both
     orders; a yes/no day with two records → `setChecked(false)` leaves none and two tombstones
     (one when they share an id).
8. **Editing a habit's target or schedule re-scores its whole history** (no schema change in
   1.4.1).
   - Edit mode's Goal and Frequency footers say so: "Changes apply to your whole history,
     including streaks and strength." That is 1 key × 5 catalogs, in W4.
   - One StatsMathTests/HabitScoreTests case pins it.
9. **Sentry is not a prerequisite for A.** The owner sets up `stride-server`, the DSN and
   uptime when convenient.
10. **O1–O12 at their defaults.**
11. **The owner adds the persistent build roots to the global "Never trash" list** (snippet
    given 2026-10-15).

Plan-text consequences, applied below:
- **Rate limit.** `request-link` allows 3 per 15 min per IP, and the Mac, the simulator and curl
  share one. So P1, gate 11 and the checklist send to the sink through `email.js`, and make at
  most one `request-link` per sitting. A 429 means wait for the reset, not that the outage is
  back.
- **History's draft lives only in view `@State`.** `HabitEntryCommit` runs the setter and
  `save()` back to back on the main actor, with no `await` between them. D4 step 1 prefers the
  commit's own undo to `context.rollback()`. Optional, in W4: undo `AddHabitView.updateHabit`'s
  field changes on a failed save, and the `try?` saves in `createGroup` and
  HabitTemplatesView.swift:166.
- **Accepted residuals** (row-level last-writer-wins, no wire change in 1.4.1):
  - a same-id stale count edit drops a note the device never pulled;
  - legacy deletions apply without a stamp (delete wins), as every client's do;
  - 1.4.0 installs keep deleting noted check-ins after 1.4.1 ships.

## Phase 0 — before and alongside M4 code

**[owner]** = needs the owner's go for that action. Writes that need one:
- **production:** A's `.env` edit and restart, the magic-link server-half deploy, any O5 server
  change, W8's deploy, P1 step 6 and gates 11–12 (each `request-link` creates an account row,
  server/auth.js:62-69), Sentry and uptime setup, any probe cron;
- **ASC:** screenshot uploads (`--yes`), withdrawing Mac 1.4.0 (O12), P2.5's metadata fix and
  `finish`, `build-appstore.sh --upload`, `release.py prepare 1.4.1`, `push_metadata.py 1.4.1`,
  review-notes edits, IAP and subscription localization edits, `finish 1.4.1`, `release 1.4.1`.
- **Pre-approved:** only `release.py release 1.4.0 --platform MAC_OS` (NEXT_SESSION_PROMPT.md:9).
  Any further pre-approval is one line from the owner, recorded here.

**P1. Magic-link fix. Step 0: now, on the owner's go, whatever the Mac review state.**
The first action of the next session is to ask the owner for a go on A and for O5's answer. No app
release is involved: the 500 comes from the mail send (server/routes/auth.js:51-72), and
`FROM_EMAIL` is env-driven (server/email.js:5).
- **Owner of the production change:** session 4c69e79f runs A's `.env` edit and the server-half
  deploy (it has DEPLOY steps 1–2 done). This session only verifies afterwards, and runs them
  itself only if the owner says that session is gone.

| | A: `FROM_EMAIL=Stride <stride@colorarchive.org>` | B: stride.colorarchive.me verified in Stride's own Resend team/key |
|---|---|---|
| Work | Env only: back up `.env`, change one line, `pm2 restart --update-env` | Owner creates the team and key, adds a new DKIM TXT at Namecheap, waits for propagation, swaps the key and FROM |
| Time | Minutes; the domain is verified today | Hours to a day of owner time |
| Risk | Shares ColorArchive's quota and key: a rotation on either side breaks sign-in. The sender differs from the link host (stride-api.colorarchive.me), which can hurt spam scores. check_email_auth.sh turns an apex sender into `org` (:19) | Durable and isolated. A free team gets 1 domain |

**Recommendation: A today; B before 1.4.1 ships, or explicitly deferred by the owner.** Every day
without a fix is a day no new user can sign in. A is reversible and needs no DNS change.
- **Decide O5 before A.** A lets 1.2.x and 1.3.0 builds sign in and push full snapshots. Builds
  ≤ 1.2.2 send entries without `updatedAt` (SyncService.swift:132-143 at v1.2.2; v1.2.3 adds it at
  :116). The server stamps those `now` (sync.js:779-782), and the upsert overwrites note and value
  on a newer-or-equal stamp (sync.js:509-519). Such a device reverts every note or value edit made
  elsewhere on the days it holds, on every sync. Options:
  1. a floor, or refusing entry rows without `updatedAt`, deployed before A;
  2. the server treats a missing entry `updatedAt` as the oldest stamp, so only the outdated device
     loses. It is rehearsed on a production copy and deployed by DEPLOY.md;
  3. accept and name the risk.

  **Default (2).** It ships in W8's **[owner]** deploy, or sooner if the owner prefers. A does not
  wait for it: the synced population is zero today, and 1.4.0 edits reach only the 7-day strip.
- **[owner]** A's steps (run by 4c69e79f):
  1. `sudo cp /root/stride-server/.env /root/stride-server/.env.bak-20261014`
  2. set `FROM_EMAIL`
  3. `sudo pm2 restart stride-server --update-env`
  4. request links for `delivered@resend.dev` and the owner's Gmail
  5. check Gmail's Authentication-Results for `dkim=pass` on colorarchive.org

  Rollback: restore the backup and restart.
- **[owner] 6. The chain after the mail, once after A and again after B.** Nothing after the mail
  has ever run in production: the AASA `/login?token=*` (server/index.js:84-91), the /login page
  (:163-164), applinks (Stride/Stride.entitlements:7, StrideMac/StrideMac.entitlements:7),
  /verify and the first sync.
  - Request a link to the owner's Gmail and open the /login page.
  - Use the token on an iOS 1.4.0 **Release-configuration** simulator build: token paste, plus the
    universal link if that build carries applinks. Debug builds and the variant call
    localhost:3002 (APIClient.swift:7-11).
  - Do the same on the Mac variant (token paste) once W7 gives it a Release configuration.
  - Sign in, push and pull once, then call `/v1/auth/delete-account` for each test account.
  - `delivered@resend.dev` also gets an account row. Its mail cannot be read, so no session can
    delete it; it is listed for the owner. Repeat requests reuse that row (`INSERT OR IGNORE`).
- **B:** after the key and FROM swap, rerun A's steps 4–5 and step 6.
- **Monitoring:** rely on the Sentry magic-link alert below. Any extra probe runs at most once a
  day, to `delivered@resend.dev`, as an **[owner]** cron, because A shares ColorArchive's Resend
  quota.

**Picking up the other session's work without clobbering it.**
1. **[owner]** Ask session 4c69e79f to commit on its own branch in two commits, then open a PR
   into `main`:
   - server/docs: auth.js, api.test.js, DEPLOY.md, check_email_auth.sh;
   - client: APIClient, AuthService, LoginView, 2 tests, 5 catalogs.
2. Trial merges onto 1.4.0 are clean:
   - `git merge-file` found 0 conflicts on the 7 files both lines changed;
   - `git apply --check` passed, with the AuthService hunk at offset +75.
3. **[owner]** Session 4c69e79f deploys the server half by DEPLOY.md's 5 steps. 1.4.0 changed
   nothing under `server/`, so it is safe for every shipped client.
4. m4 merges `main` once #7 and that PR are both in. The client half ships in 1.4.1.
5. Fallback, only if the owner says that session is gone: read `git -C <worktree> diff`
   (read-only), apply it as a credited commit on a branch off `main`, and leave the worktree to the
   owner.

**[owner]** Set up Sentry `stride-server`: the DSN, the magic-link alert rule, and the 1-minute
uptime monitor ($1/month, recorded in `~/Documents/credits.md`). Without a DSN the 500 path is
silent (routes/auth.js:68-70), as it has been since 2026-09-29.

**P2. macOS 1.4.0: release, docs, merge, tag.** It waits only on Apple. Nothing in Phase 0 or W0
waits on it except merging `main` into m4, and M4 work does not wait on it. Run
`release.py show 1.4.0` whenever convenient.
1. If it reads PENDING_DEVELOPER_RELEASE, run `release.py release 1.4.0 --platform MAC_OS`
   (pre-approved), then `show` again until READY_FOR_SALE.
2. On m3, tick RELEASE-1.4.0.md:953-955 in a commit, push, and wait for CI green. Update the
   memory files `project_appstore_status` and `project_next_phase_plan`.
3. `gh pr ready 7`, then `gh pr merge 7 --merge`. Use a **merge commit, never squash or rebase**:
   m4 is cut from the m3 tip, and #6 set the precedent (f706596).
4. Tag the merged m3 tip the way v1.3.1 was tagged:
   `git tag -a v1.4.0 <m3 tip> -m "Stride 1.4.0 (build 22). Code = 4617d1b; later commits are
   docs."`, then push it.
5. On rejection:
   - metadata only: **[owner]** fix it, then **[owner]** `finish 1.4.0 22 --platform MAC_OS`;
   - code: fix on m3 as Mac build 23, merge m3 into m4, and 1.4.1 becomes **24**. So the build
     number is picked at upload, not in W0.
6. Releasing Mac 1.4.0 is also what lets ASC create a Mac 1.4.1 record (RELEASE-1.4.0.md:913-917).

**P3. Mac store screenshots, with the owner.**

*Where they go.* They cannot be replaced on Mac 1.4.0 while it is in review, pending or live:
store_screenshots.py edits only `EDITABLE_STATES` (:61-62, :273-276). The target is the **Mac
1.4.1 record**, uploaded with the 1.4.1 submission. DEVELOPER_REJECTED is editable, so withdrawing
Mac 1.4.0 would allow replacing APP_DESKTOP now, at the cost of a review cycle (O12; default: wait).

*Step 0 **[owner]**, before any Mac sitting.* `/Users/jason/Documents/Stride/build/Debug/Stride.app`
is an old real-bundle-id Debug build: 1.0.0 (1), no entitlements, so unsandboxed. It is
git-ignored (.gitignore:7) and registered with LaunchServices. A launch or computer-use grant by the
name "Stride" could open it on the owner's real store (mac_variant/README.md:8-11, :48).
- The owner moves it to the Trash (it is under `~/Documents`).
- Assert that `mdfind "kMDItemCFBundleIdentifier == 'yyh.stride.habittracker'"` returns nothing.
- Launch the variant only by its path from Bash (never `open -b`: the Debug and Release variants
  share the bundle id, and the Release one is a production client), never with `open_application`
  or by app name.
- Before every computer-use action, check that the frontmost app's bundle id is `…mactest`.

**P3a. Next session, no W0 dependency:** a capture rehearsal plus P4, on a variant built from
v1.4.0 (or the m3 tip).
1. `store_screenshots.py list --platform MAC_OS --version 1.4.0`.
2. `mac_variant/build.sh` into `~/Library/Caches/Stride-build/mac-variant`, not `$TMPDIR` (it gets
   purged) and not `~/Documents` (iCloud).
3. Preflight and first-launch store checks before any `-demo` (mac_variant/README.md:66-94).
4. Size the window with a pre-set NSWindow frame default or osascript/System Events. `.defaultSize`
   is 900×650 (StrideApp.swift:142).
5. Capture the way W0's `capture.sh` will:
   - find the window by PID or bundle id, **never by the name "Stride"**;
   - run `screencapture -o -l <id>`;
   - assert 2880×1800 (the 4K display at @2x).
6. Validate locally only: pixel sizes and file rules through `check_files`
   (store_screenshots.py:261-268). The ASC dry run needs a Mac 1.4.1 record (`resolve_version`
   exits otherwise, :172-181), so it moves to W9, after `prepare`.

*The owner:*
- sits at an unlocked Mac and grants Screen Recording to the host app;
- allows computer use on `yyh.stride.habittracker.mactest` **only**, or clicks through;
- allows the notification prompt;
- picks the slides.

**P3b. After W3 and W5, before W9:** the final capture of every Mac slide on 1.4.1's UI, with W0's
DEBUG `-windowSize 1440x900` and `capture.sh`, into `build/store-screenshots/1.4.1/mac/`.
- Every slide whose screen W3 or W5 changes (Statistics, Settings) is captured here. O8 applies the
  same rule to iOS.
- The owner is present for these captures and revokes Screen Recording for the host app
  afterwards. The sitting can be shared with gate 10's hands-on pass.
- The captures show the free tier: there is no DEBUG Pro override (project.yml:204-206; O8).
- Each `--yes` upload is a separate **[owner]** go at submission.

**P4. Mac UI checklist** (RELEASE-1.4.0.md:974-997), in P3a's sitting.
- Results go to the progress log.
- **Triage:** a data-loss or crash failure triggers **[owner]** a Mac-only 1.4.0.x hotfix off
  v1.4.0. If Mac 1.4.0 is still PENDING_DEVELOPER_RELEASE when the failure is found, ask the owner
  whether to hold the MANUAL release. Everything else becomes a W4/W7 item for 1.4.1.
- Two items are already known gaps: item 4 belongs to W7 (same-day export) and item 12 to W5 (badge
  after grant).

## Spec corrections

| Spec (DEV-PLAN-1.3.md) | Reality at 376e69b | Decision |
|---|---|---|
| M4 = build 21, M5 = 22 (:53-54) | 1.3.1 used 20–21; 1.4.0 is 22 (RELEASE-1.4.0.md:9) | 1.4.1 (23), 1.4.2 (24); +1 each if Mac 1.4.0 takes 23 |
| "the widget's `fetchEntry`" (:1203) | Gone since 1.3.0. The widget reads in `HabitTimelineProvider.read(now:)` (StrideWidget.swift:191-206), then `RowInput.init` (WidgetTimelinePlan.swift:148-160), in another process | Pure `HabitStats` once per habit, no cache (D3) |
| Consumer list (:1202-1203) | Misses OverallStatsCard (StatsView.swift:190-229), ShareStreakView, Siri (StrideShortcuts.swift:107, :137), the badge (NotificationService.swift:685-712), Settings (SettingsView.swift:355), `completedCount` (TodayView.swift:64-66), demo_check (main.swift:47) | `Habit`'s aggregates delegate to `HabitStats`; per-day lookups stay direct; all agree (D2) |
| "debounced `didSave`"; "a pull is one save" (:1198-1201) | A 2 s throttle, per window on iOS (StrideApp.swift:197-204) and process-wide on Mac (:398-407). A sync saves several times (SyncReconciler.swift:113-115, :555; SyncEngine.swift:557-563). Siri and banner actions save in their own contexts | Synchronous bump, an unthrottled process observer, sibling-context and `.habitDataChanged` triggers, and a per-entry fingerprint (D3) |
| "keyed by `habit.id` only" (:1197) | Answers depend on the as-of day: Today's day (TodayView.swift:562), the widget's 2 day-keys, `completionRate(days:)` reading `Date()` (Habit.swift:320-325) | Cache the completed-day set; answer any day from it (D3) |
| Stats over raw `records` | Ghost records survive a saved delete (HabitCheckIn.swift:67-98); a deletion saved by another process looks live (:79-81) | `HabitStats` takes live ids from the store (D2) |
| `measure` block on one simulator (:1205-1207) | StrideTests runs host-less on macOS in CI (project.yml:116-131); no baselines are checked in | SyncPerformanceTests pattern (SyncPerformanceTests.swift:5-26) |
| Heatmap cells become Buttons → `tap` (:1208) | Cells are 14 pt on phones (StatsView.swift:781) and can be 14 pt at regular width (HeatmapLayout.swift:71-79). An untick tombstones on every device (HabitCheckIn.swift:38-44). Save, tombstone and effects are private to the row (TodayView.swift:665-710) | A tap opens History at every width (D5); writes go through one path (D4) |
| `DayEntrySheet` stepper | No set-value API. Today's decrement and reset use the ghost-prone `record(on:)` and tombstone *before* saving (TodayView.swift:737-754) | `setChecked`/`setValue`/`setNote`; Today rerouted (D4) |
| `HabitHistoryView` pushed from the detail card (:1210) | At regular width and on the Mac, all tabs share ONE NavigationStack (ContentView.swift:136-144, :160-178); the app has no NavigationLink; the detail card has no History entry (StatsView.swift:309-324) | A shell sheet, opened by an "Edit history" button on the detail card (D6) |
| "a note on any day" (:1214-1216) | Any yes/no record means done on every shipped client (Habit.swift:147-151, :158-162) | Notes only on days with a record (D7) |
| Backdating clamp; Today filtered by `createdAt` (:1211-1213) | The rate already clamps *up* to `createdAt` (Habit.swift:341-342); streaks do not (:183-212). TodayView has no creation filter today (TodayView.swift:51-66, :89-91) | min(created, earliest record), for the clamp and for Today's past days (D8, O11) |
| Weekly Review lists notes (:1217) | M5 rebuilds WeeklyReviewView (:1253-1263) | Moved to M5 |
| A 5th "Strength 74" tile (:1218-1221) | The 4 tiles are about 70 pt each (StatsView.swift:326-383) | Strength replaces Total (D10) |
| ProLockedCard "names exactly the cards" (:1221) | It names weekly review, which is not behind it (StatsView.swift:131-134); Pro copy lives in 5 places | Lockstep (D11) |
| ProStatus via `subscriptionStatusTask`; `Shared/PurchaseOutcome` (:1222-1227) | Lifetime is a NonConsumable outside the group, and the local group id is `stride_pro`. `manageSubscriptionsSheet` is unavailable on macOS; `offerCodeRedemption` needs macOS 15. StoreKit results can't be built in tests (StoreServiceTests.swift:4-9). Shared/ also compiles into the widget, demo_check and the rehearsal | D12 |
| Templates (:1229-1230) | In the app target (HabitTemplatesView.swift:6-18), saved with `try?` (:166) | Kept: kind, target, unit and the `try?` fix are the spec's own scope. Hosted tests; units as catalog keys; `onAdded` (D15) |
| seed-demo.js "add 2 habits, deploy first" (:1231-1232) | It wipes sessions, tokens and tombstones (seed-demo.js:31-41), which would log out an active reviewer. The INSERT has no kind or schedule (:65-68). It seeds 30 days (:90-104), so on seed day Read 0.716 and Journal 0.711 (< 0.75). demo-topup fills only `PATTERNS` names (demo-topup.js:62, :118) | Add-only script plus top-up entries (D13) |
| "3×/week Mon/Wed/Fri scores 1.0 every day" (:1238) | An EMA started at 0 never reaches 1.0 | Assert the daily *input* is 1.0 and the score is monotonic |
| Acceptance (1): StrideTests ≥ 210 (:1242) | Already 540, plus 248 hosted | Gates below |
| Acceptance (3): device, demo account (:1245-1246) | Device checks are waived; the demo account is a reviewer's live data | Sim E2E kit on a local server copy, iPhone and iPad; Mac by gate 10 (D14) |
| Acceptance (4): Transaction Manager (:1247-1248) | An Xcode GUI step; computer use was declined | Hosted `SKTestSession` (D14) |
| Plan backlog | The schedule-aware "remaining" (RELEASE-1.4.0.md:230-232) is missing; "Export first" (:1327-1332) shipped in 1.4.0 D6 | W9 adds the first and marks the second done |

## Design decisions

Placement rules are 1.4.0's (RELEASE-1.4.0.md:56-74). `Shared/` holds pure values only:
- no `appLocalized` or `appCalendar` (pass a `Calendar`);
- no UIKit;
- no user-facing literals;
- none of the rehearsal's top-level names (Scenario, Device, Report, Check, Account, Verdict,
  describe, unwrap).

**D1 — Version and branches.**
- 1.4.1 (23), or 24 if P2 needs a rebuild.
- `m4/1.4.1` is cut from 376e69b now, with its draft PR **into `main`**: CI runs only for PRs into
  main or `release/**` (ci.yml:4-7). Until #7 merges, the PR also shows M3.
- After #7 and the magic-link PR land, merge `origin/main` into m4. Merge, never rebase.
- On a pbxproj conflict, take either side and regenerate with xcodegen 2.45.3.

**D2 — `Shared/HabitStats.swift`, one pure computation.**
- **Input:** the habit's records plus an explicit set of live record ids, its kind, target and
  schedule, a `Calendar`, and `today`. Only the store decides what is live: a deletion saved by
  another context or process leaves a ghost that looks live (HabitCheckIn.swift:79-81), and the
  widget deletes in its own process (StrideWidget.swift:113-132). StatsCache fetches the ids once
  per rebuild (as HabitCheckIn.swift:87-97). The widget passes the ids it fetched in its own
  context.
- **Built in the initializer:** only the live day-key set and values by day.
- **Computed on first access:**
  - current streak (keeping the grace of Habit.swift:192-196) and best streak;
  - `bestStreakRanges`: top 5, dated, in Monday-anchored weeks for times-per-week, sorted by
    length, ties broken by the most recent;
  - 30-day rate and per-weekday counts.
  - The strength series and Δ30/Δ90 are computed only when a strength accessor calls `HabitScore`.
- Per-day questions read the set and never rescan; any as-of day is answered from it.
- **Only the aggregates delegate:** `currentStreak(from:)`, `bestStreak()`, `weeklyCompletions`,
  both `completionRate` overloads and `completionsPerWeekday()` go through a `HabitStats`.
- **Per-day lookups stay direct:** `record(on:)`, `loggedValue(on:)`, `progress(on:)` and
  `isCompletedOn` (Habit.swift:127-154) check live records with the in-memory ghost filter
  (`modelContext != nil && !isDeleted`, as SyncCopies.swift:284-286) and never build a `HabitStats`.
- The widget, Siri, the badge, ShareStreakView, Settings and demo_check then agree with no
  per-site rewrite.
- **Deliberate fixes,** each named in a parity test:
  - ghosts are excluded, by store ids;
  - `completionsPerWeekday` counts completed days, not every record (Habit.swift:394-401),
    matching its "check-ins" label (StatsView.swift:689);
  - the rate's start (D8);
  - records dated after `today` are ignored (`bestStreak` walks to `completed.max()`,
    Habit.swift:276-293);
  - a day with several live records counts as its max value, for completion and `loggedValue`
    alike. Today `isCompletedOn` and `loggedValue` read the first record (Habit.swift:127-153),
    while `completedDayKeys` accepts any (:158-165). The per-day lookups adopt the same rule.

  Everything else is frozen by golden values captured first.

**D3 — `StatsCache` (app only, Stride/Sources/Services).**
- `@Observable @MainActor`. The `[habitID: entry]` dictionary is `@ObservationIgnored`. Views
  depend only on `generation`, which every accessor reads, and on the entry's fingerprint.
- Each entry holds a `HabitStats` and a fingerprint, which the accessor checks: live
  `records.count`, max record stamp, `habit.stamp`, kind, target and schedule. Reading it keeps the
  Observation dependency on `habit.records`, so a merge both redraws and invalidates.
- A rebuild makes one store fetch of live record ids (D2).
- **Invalidation:** when a `didSave`'s inserted, updated and deleted ids map cheaply to habits, it
  invalidates only those habits; otherwise it clears all. Stats refill lazily. Triggers:
  1. synchronously in the write path (D4), which is what "same render" needs;
  2. an unthrottled, process-level `ModelContext.didSave` observer installed in `StrideApp.init` on
     both platforms, not on the window, so scene-less saves count;
  3. one main-queue turn after any `didSave` whose object is not mainContext, after the merge;
  4. `.habitDataChanged`, posted by NotificationActionHandler.swift:231 and StrideShortcuts.swift:66
     (today only StrideApp.swift:198, :399 observe it);
  5. `NSCalendarDayChanged` and `NSSystemTimeZoneDidChange` (no time-zone observer exists today);
  6. scene activation, which covers widget writes.
- **Readers:** the detail card; `HeatmapGrid.dayCell` (StatsView.swift:841), through the cached
  `HabitStats` passed into HeatmapView and HeatmapGrid (:139, :725, :774-778); OverallStatsCard
  (:194-210); `TodayView.completedCount` (TodayView.swift:64-66); and the row streaks (:562, :602).
  Today's row check and count state is not a reader (D4).
- Kept-alive hidden tabs (ContentView.swift:160-177) re-render on a bump, at one dictionary read
  per card.
- The widget, a separate process with no app `didSave`, gets no cache. It builds one `HabitStats`
  per habit per timeline from its own context and answers both day-keys from it: 1 set build
  instead of 6 record scans.

**D4 — One write path.**
- New in Shared/HabitCheckIn, built on `liveRecord` (HabitCheckIn.swift:82-98): `setChecked(_:on:)`,
  `setValue(_:on:)` and `setNote(_:on:)`, with nil meaning "unchanged".
  - Each re-reads `liveRecord` at call time and writes only the fields that differ from the store.
    It calls `touch()` only when something changed; otherwise it returns `.noChange`, and the
    commit skips its save and effects.
  - It creates, edits, or deletes (a yes/no unchecked, a count set to 0, Reset) and returns the
    deleted id. It never writes a value-0 record or a note-only yes/no record.
  - Deleting a record with a non-empty note returns `.needsConfirmation` instead. The caller asks
    "Remove the check-in and its note?" and only then deletes (D7).
  - On a day with duplicate records it first merges the day (2026-10-15 decision 7): it keeps
    the record D2 reads (largest value, then newest stamp), moves another record's non-empty
    note onto it (or returns `.needsConfirmation` when two notes differ), deletes the rest and
    returns all their ids for tombstones. `tap` acts on the same kept record.
- Every UI write passes the target state the user saw (`setChecked(!shown)`, `setValue(n)`). No UI
  path calls `tap`; the widget and Siri keep their own semantics. Today's row check and count state
  is derived from the habit, not from StatsCache. Only streak and rate text may come from the cache.
- `HabitEntryCommit.commit` is new in Stride/Sources. It runs, in order:
  1. `save()`. If it throws: undo this commit's own changes, log it (Logger and Sentry), skip steps
     2–4, and return `.saveFailed` so the caller resets its UI (`justCompleted`, History's editor).
     - Undo means re-inserting a deleted record with its id, value, note and stamp. Use
       `context.rollback()` instead only when the commit knows mainContext holds nothing else
       unsaved.
     - Undo is needed because mainContext autosaves and sync saves on it (StrideApp.swift:318;
       SyncEngine.swift:557-563). Without it, a pending delete would land later with no tombstone.
  2. on success only, `trackDeletedEntry` (SyncService.swift:175);
  3. `CheckInEffects.afterCheckIn` with `endsReminders(checkingIn: day)` for a check-in
     (CheckInEffects.swift:70-82), or a widget reload plus badge update for an un-check;
  4. `StatsCache.bump()`.
- **Callers:** History and every Today row write:
  - toggle (TodayView.swift:665-694);
  - increment, decrement and reset (:723-754), which fixes the tombstone-before-save and the ghost
    lookups;
  - the note alert (:506-512), today a `try?` save with no effects.
- Settings' habit delete (SettingsView.swift:636-645) also tombstones before saving; W5 reorders it.

**D5 — Heatmap: a tap opens History.**
- **One behaviour at every width:** a tap on any cell opens History on that day
  (`shell.request = .history(habitID:day:)`). There is no direct toggle and no "Edit day…" context
  menu.
  - `HeatmapLayout.cellSize` never goes below `scaled` (Shared/HeatmapLayout.swift:71-79). So
    regular-width cells can be 14 pt like a phone's, and they reach 44 pt only in a Mac window wider
    than 680 pt (:26-28).
  - An untick tombstones on every device.
- If the owner asks for direct toggle on iPad or Mac (O10), it is gated on the computed cell size,
  not the size class. A cell ≥ 44 pt (or a stated threshold such as 28 pt plus a hover or pressed
  state) toggles through D4; smaller cells open History. Consider an undo toast for an untick.
- **Accessibility (a decision):** today every cell has its own label (StatsView.swift:849,
  :726-728).
  - The grid becomes one element. Its accessibilityValue summarises it ("N of 84 days completed",
    plus the current streak), and it has an "Edit history" action.
  - History's month grid (D6) is the per-day accessible equivalent.
  - On the Mac, cells use a tap gesture or `.focusable(false)` instead of Buttons, so there are no
    84 Tab stops.
  - Hidden-tab gating (RELEASE-1.4.0.md:110-112) is unchanged.
- A 4 pt note dot is added. The cell model leaves room for M6's hatched state.

**D6 — `HabitHistoryView`, a shell sheet.**
- **Entry:** a visible "Edit history" button in HabitDetailStatsCard's header HStack
  (StatsView.swift:309-324), beside Share. It sets
  `shell.request = .history(habitID: habit.id, day: today)`.
  - StatsView's `shell` (:13) is passed into HabitDetailStatsCard (:289-290), HeatmapView and
    HeatmapGrid.
  - The button needs one new catalog key and an a11y identifier for the sim kit.
  - The heatmap tap (D5) and the grid's VoiceOver action are second paths.
- A new `ShellRequest.history(habitID:day:)` (ShellState.swift:132-165) is presented by the shell
  sheet (ContentView.swift:68, :244-258).
  - It survives a size-class crossing, which tab sheets do not (ShellState.swift:12-13).
  - It never pushes into the shared stack.
- **Layout:** a month grid with ‹ › and 44 pt cells, each an accessibility element with day, date
  and state. Under it is the selected day's editor: a check toggle or value stepper, plus a note.
- **Note cap:** the 500-character cap applies only to new input. A draft may exceed it only while
  it equals the stored note, and an existing longer note is never truncated. 1.4.0's note alert has
  no cap (TodayView.swift:506-512).
- History's state holds habitID, day and the draft. At commit it re-resolves the habit and record
  through D4's setters, and it dismisses if the habit is gone.
- No separate DayEntrySheet and no nested sheet. On the Mac, the menu sheet probe covers it
  (MenuCommands.swift:112-121).

**D7 — Notes.**
- `Habit.note` becomes a "Description" field in AddHabitView, shown as one secondary line under
  the row name.
- **Record notes only on days that have a record:**
  - yes/no: the note field enables once the day is checked;
  - count: needs a value ≥ 1.
- **Why:** any yes/no record reads as done on ≤1.4.0 (Habit.swift:150). A note-only or value-0
  record would be a wire change of the kind M6 gates.
- **A noted check-in is never deleted silently.** The rule lives in HabitCheckIn (D4,
  `.needsConfirmation`) and covers every path:
  - Today: toggle, decrement at 1, Reset (TodayView.swift:665-667, :737-754);
  - History: un-check, stepper to 0;
  - widget: `RowInput` carries `hasNote`. A checked, noted row renders as a link that opens the app
    on that habit (History for that day, via `shell.request`) instead of a toggle button, so the
    extension never deletes a noted record. Today it can (StrideWidget.swift:125-132).
  - The app has no such route yet; its only URL path is the sign-in link (StrideApp.swift:225,
    Shared/LoginLink.swift). W2 adds the route, kept apart from the sign-in path.
- **No server change for notes.** The server checks no note length (sync.js:758-778). The cap is
  client-side, because a new server skip reason would be held forever by apps ≥1.3.1
  (SyncDelivery.swift:84-89).

**D8 — Backdating and Today's past days.**
- History allows days from `min(createdAt, earliest record) − 365 d` up to today, never a future
  day.
- `createdAt` is never written; the server sets it only on insert (sync.js:474-492).
- The rate starts at `min(creationDayKey, earliestLiveRecordKey)`. It can drop (that is honest) but
  never passes 100 %.
- **Today on a past day (O11, default: filter):** when `selectedDate < today`, TodayView shows only
  habits whose `min(dayKey(createdAt), earliest live record key) <= selectedDate`.
  - The filter applies to `groupedSections` (TodayView.swift:51-62), `completedCount` (:64-66) and
    ProgressSummaryCard's total (:90).
  - Today itself is never filtered, so Today, the widget and the badge still agree. The badge counts
    only today (NotificationService.swift:677-679, :697-700).
  - Trade-off: backfilling a habit created today moves from the week strip to History (D6).

**D9 — `Shared/HabitScore.swift`.**
- Uses the spec's `m = 0.5^(√freq/13)` (DEV-PLAN-1.3.md:1180-1188).
- Daily input:
  - yes/no: 1 or 0;
  - count: `min(1, value/target)`;
  - times-per-week: `min(1, trailing-7 completions / timesPerWeek)`, every day.
- Neutral days leave the score unchanged: `specificDays` rest days now, M6 skips later.
- The walk starts at min(created, earliest live record).
- **Today (O1):** today's input is applied only once `isCompletedOn(today)` is true; until then the
  walk ends at yesterday.
  - The rule is the same for every kind. A count habit's partial today is not applied.
  - A times-per-week habit holds only today, never the streak's in-progress-week grace
    (Habit.swift:245-249).
  - Past days are always evaluated, so decay resumes the next day.
- Shown as 0–100 with one sentence: "Strength grows with every check-in and recovers after a miss;
  it counts a rolling 7 days, the streak counts calendar weeks."
- Recomputed:
  - 30 perfect days 0.798; 100 days 0.995; one miss after 60 days −4.98 points;
  - current 30-day seed: Read 0.716, Journal 0.711;
  - 90 days: 0.890 and 0.883.

**D10 — Statistics layout.**
- **Free:** the detail card's "Total" tile (StatsView.swift:375, `records.count`, which counts
  partial days and ghosts) becomes "Strength". It stays 4 tiles, so the a11y layout does not move;
  the Statistics slide is re-shot (O8, P3b). The check-in count moves to History's header.
- **Pro,** inside `store.isPro` (StatsView.swift:125-136), in new StatsProCards.swift:
  - `StrengthCard`: score, Δ30, Δ90, and weekly bars in TrendCard's hand-rolled style;
  - `BestStreaksCard`: top 5.
- New `-statsScrollTo strength|beststreaks` anchors (:51-76).
- TrendCard's per-render `DateFormatter()` (:457) becomes static.
- The dead formatters in DateHelpers.swift:92-108 are deleted.

**D11 — Pro claims in lockstep.**
- **Pro is:** Habit Groups; Advanced Analytics (Insights, 8-week Trend, Strength chart, and Best
  Streaks, worded "your top 5 streaks"); Weekly Review. The free detail card keeps its Best Streak
  tile (StatsView.swift:348-349), so no copy sells "your best streaks" as Pro.
- One commit changes all of:
  - ProLockedCard (StatsView.swift:131-134), which drops "weekly review";
  - the paywall rows (StoreService.swift:271-272);
  - the Settings upsell (SettingsView.swift:144);
  - the 6 STRIDE PRO blocks (metadata/en-US/description.txt:37-41 and its 5 peers);
  - the ASC review notes.
- W9's grep gate checks them. It also reads back the subscription and IAP localizations through the
  ASC API, including the "save 44%" that setup_iap.py:47-52 hard-codes in 6 locales. That figure
  is checked against current prices; the app computes the saving per storefront
  (StoreService.swift:114-128). A change there is **[owner]**.

**D12 — Subscription status.**
- `StoreService.proStatus` = `.lifetime | .active(productID, renewsOn?, willAutoRenew?) |
  .billingIssue(productID, graceUntil?) | .lapsed(expiredOn) | .never`. It is display-only.
  - `isPro` stays derived from `Transaction.currentEntitlements` (StoreService.swift:48-50,
    :181-195), unchanged.
  - Lifetime comes from `currentEntitlements`.
  - Subscriptions come from `Product.SubscriptionInfo.status(for:)`. The group id is read from
    `product.subscription?.subscriptionGroupID`, because the local `stride_pro` is not ASC's.
  - If a subscription is entitled and `status(for:)` throws or returns nothing, the status is
    `.active(productID, renewsOn: nil, willAutoRenew: nil)` and no date is shown.
  - The billing-retry and grace-period states map to `.billingIssue`.
  - `.lapsed` applies only when `currentEntitlements` holds no Pro product and status reports
    expired. Revoked or refunded maps to lapsed, with its own date.
  - `proStatus` is recomputed inside `refreshPurchasedProducts()`, which StrideApp.swift:178, :252
    and :433 already call, and on `Transaction.updates` (StoreService.swift:201).
  - It lives in the service because Settings is also the Mac Settings window.
- `Shared/PurchaseOutcome.swift` maps local mirror types and has no StoreKit import. The adapter
  stays at StoreService.swift:143-170 and :210-221. An unverified purchase is an error, never a
  quiet cancel.
- **Settings shows:**
  - plan and renewal date;
  - Manage Subscription: `manageSubscriptionsSheet` on iOS; the
    `apps.apple.com/account/subscriptions` URL on macOS, where the sheet is unavailable;
  - for `.billingIssue`: "Payment problem — update your payment method", plus Manage;
  - when Lifetime is owned and a subscription still auto-renews: "A subscription still renews →
    Manage";
  - when lapsed, one row: "Pro ended on <date> — Resubscribe";
  - Redeem Code only if an ASC offer code ships, on iOS and macOS 15+. Otherwise it is hidden in
    1.4.1 (O9).

**D13 — Demo account.**
1. Read-only first: `check_demo_account.sh` shows each habit's `created` date and record count. The
   daily top-up (crontab.stride:21) may already have built more than 90 days of history.
2. New add-only `server/ops/demo-add-habits.js`:
   - adds "Water" (count, 8 glasses) and "Stretch" (3×/week), with 90 days of history and a few
     notes;
   - writes `created_at` explicitly, at least 91 days back, and stamps
     `updated_at = client_updated_at = now`;
   - is idempotent per (user, name): it skips, and exits 0, when the habit exists;
   - never touches sessions, tokens or ids.
3. `seed-demo.js` gets the same habits and `created_at`, 90 days, and the missing columns. Its
   `Token:` line (:112) is filtered from agent output.
4. `demo-topup.js` gets `PATTERNS` entries, count fill at target, and a fixed Mon/Wed/Fri rule.
   A per-day hash (:150-151) can break a weekly streak.
5. All three scripts cap new entry dates at min(UTC today, America/Los_Angeles today). The top-up
   dates by UTC (demo-topup.js:88, :115) and runs at 03:50 Etc/UTC (crontab.stride:1, :21), which is
   the previous evening for US reviewers.
6. **[owner]** Deploy only when no review is open (DEPLOY.md:723-724), after a rehearsal on a
   production copy. The same deploy carries Data safety 2's server changes.

**D14 — Verification, agent-run (2026-10-07 waiver).**
- Acceptance (3) runs on the sim E2E kit against a local server seeded by
  `scripts/sim_e2e/seed-demo.sh`.
  - A = iPhone 17 Pro and B = 17 Pro Max are reused and taken with `/tmp/lock-*`. Gate 3's iPad leg
    uses an existing iPad simulator.
  - E2E H1 opens History through the "Edit history" button on iPhone, iPad and the Mac variant.
  - A widget un-check (or, in a hosted test, a second-context delete) is followed by app
    foreground. Stats and the History cell must show the day cleared, and History's re-check must
    create a record.
  - The Mac leg runs on the variant only; gate 10 is its gate.
- StoreKit: hosted `SKTestSession` tests on `Stride/Configuration.storekit`. W0 makes the file
  loadable by the hosted tests: either as a StrideAppTests resource (its sources are only
  StrideAppTests/, project.yml:141-151), or through `SKTestSession(contentsOf:)` with its path.
  `storeKitConfiguration` is set only on the run actions (:204-206, :233).
- Upgrade gates run because record semantics change, even though `@Model` does not.

**D15 — Templates, collapsed groups.**
- `HabitTemplate` (HabitTemplatesView.swift:6-18) gains kind, target and unit; units are catalog
  keys.
- `addHabit(from:)` shows its error instead of `try?` (:166).
- `HabitTemplatesView` gains `var onAdded: () -> Void = {}`, called after a successful save and
  before `dismiss()` (:173). AddHabitView's sheet (:266-268) passes `onAdded: { dismiss() }` (W4).
  TodayView.swift:814's call site is unchanged.
- `TodayView.collapsedGroups` (:24) is kept per device in `@AppStorage`.

## Data safety (invariants; each has a test)

1. **One write path.** Every new write and every Today row write goes through `HabitCheckIn`, then
   `HabitEntryCommit`.
   - Hosted: an un-check queues exactly one tombstone, after the save. Inject a save failure, then
     perform an unrelated successful save: the record is still in the store and the deletion queue
     is empty.
   - Host-less:
     - `setChecked` on a ghost creates a fresh record;
     - an edit changes the stamp, so the row is pending (SyncDelivery.swift:99-101);
     - a no-op commit leaves `updatedAt` unchanged;
     - deleting a noted record returns `.needsConfirmation` on every path (D7).
   - A pull changes the note while History's editor is open, and the user then changes the value:
     the pulled note survives. A 600-character stored note survives a value edit.
2. **No new wire semantics:** no value-0 or note-only yes/no records, no `createdAt` writes, and no
   `@Model` change.
   - **The server changes only** in the demo scripts and in two named exceptions. Both ship in W8's
     **[owner]** deploy, after server tests and a production-copy rehearsal:
     - The entry upsert keeps the stored note when the incoming id differs from the stored row's
       and the incoming note is NULL (sync.js:509-519):
       `note = CASE WHEN habit_entries.id <> excluded.id AND excluded.note IS NULL THEN
       habit_entries.note ELSE excluded.note END`. It only keeps more data, so it is safe for every
       shipped client. Fallback if it cannot ship: History writes to a day with no local record wait
       for a completed pull, or run one first.
     - O5's option, (2) by default: a missing entry `updatedAt` counts as the oldest stamp
       (sync.js:779-782).
   - `sync_rehearsal` gains 5 scenarios (scripts/sync_rehearsal/Scenarios.swift):
     - a past-day edit on A, pulled by B;
     - an un-tap and re-tap of a past day (delete-and-replace, sync.js:854-908);
     - a last-writer-wins note edit;
     - a record dated before `createdAt`;
     - **stale cursor:** B checks day X with a note and syncs. A, holding a stale cursor, ticks X in
       History and syncs; push runs before pull (SyncEngine.swift:523-538). B pulls. X's note is
       intact on A, B and the server.
   - A server test (or rehearsal case) sends a raw legacy push (entries without `updatedAt`) after a
     1.4.1-style note edit, and asserts the outcome O5 chose.
3. **Parity:** `HabitStatsParityTests` hold golden values from today's methods on these fixtures:
   - daily, specificDays, 3×/week, count partials, backdated, ghost, DST, UTC−9;
   - same-day duplicates: a count habit with values below and above the target, and a yes/no habit
     with two records;
   - a record dated after today;
   - a record before `createdAt` across a DST change;
   - a deletion saved by a second `ModelContext` on the same container.

   Rules for the parity tests:
   - They land in W1's first commit, before the switch, and run in the default zone and under
     `TZ=America/Los_Angeles`.
   - Only D2's named fixes may differ.
   - `Habit.isCompletedOn` equals `HabitStats`' per-day answer on every fixture day. The exception
     is the second-context fixture, where only the store-id answer is right.
   - `bestStreakRanges.first?.length == bestStreak()` on every fixture.
   - `check_demo_account.sh` prints the same streak, best and rate before and after.
4. **Performance:** host-less `StatsPerformanceTests`, in the SyncPerformanceTests pattern:
   - 10 habits × 730 days: the full `HabitStats` build, 100 cached reads, a widget read over 2
     day-keys, and the uncached wrapper path (84 `isCompletedOn` plus `currentStreak` per habit),
     which must run no strength walk;
   - 50 × 1,095 (54,750 entries, as SyncPerformanceTests.swift:112): a full build.

   A hosted case covers the cache, which is app-only: a multi-chunk pull at 50 × 1,095 with
   StatsCache alive, counting rebuilds per pull. Each measurement is bounded at 5× its first value
   and prints `PERF`.
5. **Widget memory:** no static cache; one `HabitStats` per habit, released before the plan
   returns.

## Workstreams (in order; parallel workstreams never share a file)

Sizes are relative (S < M < L). For scale, M3 was specced at 3.5 w (DEV-PLAN-1.3.md:1132). It took
about 2 agent-days from branch cut to iOS submission (2026-10-10 to 2026-10-11, RELEASE-1.4.0.md:935,
:1002-1004).

| W | Scope | Files (exclusive while it runs) | Tests | Size |
|---|---|---|---|---|
| **W0** scaffold | 1.4.1 (23); every new file as a compiling stub; `ShellRequest.history`; all new keys in the 5 Localizable.strings (es, ja, ko, zh-Hans, zh-Hant) and, for plural keys, the 6 Localizable.stringsdict (those plus en.lproj; LocalizationCatalogTests.swift:14-16, :53-57); Configuration.storekit loadable by hosted tests (D14); DEBUG `-windowSize`; `mac_variant/capture.sh`; xcodegen 2.45.3; draft PR into main | project.yml, pbxproj, ShellState.swift (enum only), Shared/*.lproj, StrideApp.swift (flag only), scripts/mac_variant/ | Builds on iOS and macOS | S |
| **W1** stats core | `HabitStats` (D2), `HabitScore` (D9), `Habit`'s aggregates delegating, `RowInput` built once per habit and carrying `hasNote`; demo_check prints strength, Δ30 and the top 3 and exits 4 below 0.75 | Shared/HabitStats.swift, Shared/HabitScore.swift, Shared/Habit.swift, Shared/WidgetTimelinePlan.swift, scripts/demo_check/main.swift | HabitScoreTests (count 4/8 today equals yesterday's score, 8/8 raises it; a 3×/week habit unchecked today equals yesterday's score and decays the next day); HabitStatsParityTests (golden first, two zones); StatsMathTests (backdating) plus BestStreakRanges cases (order, ties to the most recent, at most 5, exact dates, specificDays runs across rest days counted in scheduled days, Monday weeks, the open run under the grace); host-less StatsPerformanceTests | L |
| **W2** write path and cache | D4's setters, `.needsConfirmation` and Today's confirm alert; `HabitEntryCommit` with undo; `StatsCache` (D3) and its observers; Today's row writes; the widget's noted-row link and its app route (D7); rehearsal scenarios | Shared/HabitCheckIn.swift, Services/HabitEntryCommit.swift, Services/StatsCache.swift, StrideApp.swift, TodayView.swift (write funcs), StrideWidget/Sources/StrideWidget.swift, scripts/sync_rehearsal/ | HabitCheckInTests (setters, ghosts, no-op, a confirmation per path); hosted HabitEntryCommitTests (failed save, then an unrelated save); StatsCacheTests (hosted, with Stats alive, a CompleteHabitIntent write and a NotificationActionHandler.perform write: cache == fresh recompute after the merge); the hosted cache perf case; 5 rehearsal scenarios (the 5th goes green with W8's upsert) | L, after W1's API |
| **W3** Statistics UI | Cards, heatmap and OverallStatsCard read the cache; the heatmap tap opens History, grid a11y summary, Mac cells not focusable, note dot (D5); the "Edit history" button (D6); Strength tile; Pro cards; ProLockedCard copy; static formatters | StatsView.swift, Views/StatsProCards.swift, Shared/HeatmapLayout.swift, Shared/DateHelpers.swift | a11y sweep on iPhone and iPad with the new anchors; hosted "same render" test (a commit changes the cached value before the next read) | M, after W2 |
| **W4** History, notes, shell, Today | HabitHistoryView (D6) and its presenter. Today rows: check and count state from the habit, streak and rate text and `completedCount` from the cache, the description line, the past-day filter (D8). AddHabitView: Description field, and the template sheet passes `onAdded: { dismiss() }`. collapsedGroups. **Follow-up:** menu Export checks its own window and clears a dropped request (ContentView.swift:291-330, MenuCommands.swift:112-121) | Views/HabitHistoryView.swift, ContentView.swift, MenuCommands.swift, Shared/MenuCommandRules.swift, AddHabitView.swift, TodayView.swift (rows) | Hosted History tests (pulled note survives an open editor; 600-character note; habit deleted while open); hosted Today filter (a habit created today is absent on yesterday, and present after a History backfill of yesterday); after a second-context delete, a tap on that row creates and deletes nothing; MenuCommandRules tests; E2E H1–H3 | L, after W2, alongside W3 |
| **W5** subscription and Settings | D12. **Follow-up:** badge after the permission grant (SettingsView.swift:1033 → `updateBadge`; NotificationService.swift:217, :685). Delete-habit tombstone order | StoreService.swift, Shared/PurchaseOutcome.swift, SettingsView.swift, NotificationService.swift | PurchaseOutcomeTests (incl. "entitled, status unavailable → active, never lapsed"); hosted SKTestSession: buy, expire → lapsed, lifetime, unverified, billing retry, grace period, `refundTransaction`, Lifetime bought during an active subscription | M, alongside, from W0 |
| **W6** templates | D15 templates: kind, target, unit; the error replaces `try?`; `onAdded`. Never edits AddHabitView.swift | HabitTemplatesView.swift | Hosted template tests | S, alongside |
| **W7** export, privacy, scripts | **Follow-ups:** same-day export names (DataExportService.swift:46, :493 → `yyyy-MM-dd-HHmmss`). C617.1 and 35F9.1 in Stride/PrivacyInfo.xcprivacy:98-103, and 35F9.1 in StrideWidget/PrivacyInfo.xcprivacy:25-29: the widget compiles SharedModelContainer.swift:402 (project.yml:169-180); verify_archive.sh asserts both. `release.py cancel --platform` (:583-614). ship.sh refuses to run (stale: :16-17, :100). A Release configuration for the Mac variant (gate 12, P1 step 6) | DataExportService.swift, both PrivacyInfo.xcprivacy, scripts/verify_archive.sh, scripts/release.py, scripts/ship.sh, scripts/mac_variant/build.sh | Export-name test; verify_archive on a Debug archive | S, alongside |
| **W8** server and demo | D13 scripts. (Data safety 2's upsert and O5's refusal shipped early in #9, decisions 5–6; W8 only re-runs their tests.) Optional: the server refuses `delete-account` for the demo account, matching SettingsView.swift:697. Edits to files the magic-link PR touches (api.test.js, DEPLOY.md, check_email_auth.sh) wait until it lands: the stale tombstone comments (demo-topup.js:38-40, DEPLOY.md:713-714), check_email_auth.sh's apex parse | server/seed-demo.js, server/ops/demo-topup.js, server/ops/demo-add-habits.js, server/routes/sync.js, server/test/api.test.js, server/test/demo-scripts.test.js | Node tests: the top-up weekday rule; add-only keeps sessions; a second run adds nothing; no entry dated after the LA day. A production-copy rehearsal | S + **[owner]** deploy |
| **W9** release | What's New ×6 (release.py, after W7; no sign-in sentence), metadata ×6, review notes, DEV-PLAN backlog edits, the Pro-claim grep and ASC IAP read-back, the ASC screenshot dry run after `prepare`, full gates, screenshot uploads | metadata/, scripts/release.py, DEV-PLAN-1.3.md, this file | Gates below | M |

**Critical path:** W0 → W1 → W2 → W3/W4 → P3b and gate 10 → W9. W5–W8 run alongside.
- Calendar time is bounded by owner gos, App Review and the no-open-review deploy window, not by
  code.
- The magic-link PR (P1) is in `main`, and `main` is merged into m4, before W9. Catalog conflicts
  therefore show up early.
- Reviews: this plan was reviewed before W0 (see "Plan review" below). Before W9, a whole-branch
  review: Gemini via agy on a throwaway copy, plus Claude adversarial lenses.

## Release gates and acceptance (1.4.1)

1. **Tests:**
   - StrideTests: 540 + new, green in en and ja/JP with 2 known skips;
   - hosted: at least 248 + new, including SKTestSession;
   - `sync_rehearsal.sh`: 81/0/1 plus the 5 M4 scenarios;
   - server tests, including the upsert and legacy-push cases;
   - kit selftest and drift clean; CI green; perf bounds hold.
2. **Demo account:** `check_demo_account.sh` prints strength, Δ30 and the top 3 runs. It exits
   non-zero if any habit with at least 25 completed days in the last 30 scores below 0.75. Run it
   after the W8 deploy and again on submission day, in the default zone and under
   `TZ=America/Los_Angeles`.
3. **History edit (sim kit):**
   - On A, open a habit's detail card, tap "Edit history" on "Read 30 Minutes", and tick a day 20
     days back. The cell, rate, best streak and strength change in the same render (hosted test
     plus screenshot).
   - After Sync Now, B shows the day. Untick and re-tick it: B ends with exactly one record.
   - iPad leg: tap a past heatmap cell, and History opens on that day. Tick it, and B sees it.
     Untick and re-tick it, and B has exactly one record.
   - Widget leg: as in D14.
4. **StoreKit:**
   - Monthly shows the plan and renewal date.
   - On expiry: one lapsed row and locked cards, nothing else.
   - Lifetime never shows as lapsed, and an entitled subscriber never sees the lapsed row.
   - Billing retry and grace show the payment row. A refund shows lapsed with its date.
   - Lifetime with a renewing subscription shows the Manage row.
5. **Pro claims:** the 6 Pro blocks, paywall, upsell, ProLockedCard and review notes list exactly
   D11's set. The ASC subscription and IAP localizations are read back, with "save 44%" checked
   against current prices.
6. **No new interruptive UI.**
7. **Upgrades:**
   - iOS: `upgrade.sh`, with a widget placed and `--reminders`, from 1.4.0 (22), 1.3.1 (21), 1.3.0
     and 1.2.3.
   - Mac: build the variant at v1.4.0 (or the m3 tip) and seed it. Install m4's variant over it in
     place. Run upgrade.sh's store, row-count and checksum checks against
     `~/Library/Containers/yyh.stride.habittracker.mactest/Data/Documents/Stride.store`.
   - v1.3.1 has no `STRIDE_MAC_VARIANT` branches, and build.sh refuses to build without one
     (mac_variant/README.md:29-30). So Mac 1.3.1→1.4.1 is covered only by `@Model` being unchanged
     plus the iOS 1.3.1 leg.
8. **Accessibility:** the a11y sweep on iPhone and iPad Pro 13", at default and AX sizes. It covers
   History at AX5, History's grid under VoiceOver, and the heatmap strip.
9. **Magic-link client:** hosted tests for the `login_email_unavailable`, 502 and plain-500 copy;
   LoginView shows Contact Support.
10. **macOS, on the final tree:**
    1. a StrideMac Release archive, then `scripts/verify_archive.sh <archive> macos`. It checks the
       entitlements, including `files.user-selected.read-write`, plus W7's privacy reasons;
    2. `mac_variant/build.sh`, preflight and a background launch. The store is created only under
       `~/Library/Containers/yyh.stride.habittracker.mactest`, the real group store is unchanged,
       and the app is stopped by pid (as RELEASE-1.4.0.md:1083-1089);
    3. tests that pin D12's macOS branches (the Manage URL; Redeem hidden without an offer code and
       below macOS 15) and the MenuCommandRules/shell request for History;
    4. a hands-on pass on the variant in a second owner sitting, at full and at narrow window
       width:
       - a heatmap click opens History; tick, untick and re-tick (B ends with exactly one record);
       - a History edit syncs to iPhone B;
       - the Settings plan, Manage and Redeem rows;
       - VoiceOver and Full Keyboard Access on the heatmap and History;
       - the 13-item list.

       Results go to the progress log.
11. **Magic link live** (sink sends through `email.js`, at most one `request-link` per sitting, to the plus-address of decision 4): on submission day, production `request-link` returns 200 and the mail
    arrives.
12. **Release-build smoke,** before `finish`:
    - iOS: a Release-configuration simulator build, which talks to production (APIClient.swift:10).
      Launch it, sign in with a token for a production test account (**[owner]**), Sync Now, and
      place the widget. Expect no crash and no unexpected sign-out (as RELEASE-1.3.1.md:594-596).
      Delete the account afterwards, as in P1 step 6.
    - Mac: a Release-configuration variant build (W7) launches and passes the store preflight.
      Never launch the exported real-id Mac app.

## Submission checklist (1.4.1)

- [ ] P2 done; m4 has merged `main`, including the magic-link PR.
- [ ] Magic link live: `POST /v1/auth/request-link` for delivered@resend.dev returns 200, and
  `scripts/ops/check_email_auth.sh` (from the magic-link PR) passes. Check on submission day and
  after any key or FROM change. The owner confirms dkim=pass in Gmail once after B.
- [ ] B done, or explicitly deferred by the owner.
- [ ] **[owner]** W8 deployed while no review is open (demo scripts and both server changes);
  `check_demo_account.sh` passes gate 2.
- [ ] Gates 1–12 green on the final tree. Signing preflight: `security show-keychain-info` plus a
  1 s codesign probe.
- [ ] If a 1.4.0 archive is still needed, copy `build/appstore` out first: build-appstore.sh:93
  deletes it. The dSYMs are safe in build/dsyms/1.4.0-22.
- [ ] **[owner]** `build-appstore.sh all --upload` with `verify_archive --exported` on both
  platforms, including W7's privacy reasons. **Never `ship.sh`.**
- [ ] `WHATS_NEW_BY_VERSION["1.4.1"]` ×6 **before** **[owner]** `release.py prepare 1.4.1`:
  prepare creates the record first and checks the copy only after (release.py:435-438, :577-580).
- [ ] **[owner]** `push_metadata.py 1.4.1`. It has no `--platform`, so it writes both records
  (push_metadata.py:247-264).
- [ ] Screenshots:
  - after `prepare`, the dry run `upload --platform MAC_OS --version 1.4.1 --set APP_DESKTOP`;
  - Mac APP_DESKTOP from P3b, and the iOS slides per O8;
  - an **[owner]** go for each `--yes`; read back with `list`.
- [ ] **[owner]** Review notes: D11's Pro list, and where to find Strength and History (Statistics
  → a habit → Edit history).
- [ ] **[owner]** `release.py finish 1.4.1 <build> --platform IOS` first. Mac follows only after gate
  10 passes, with its owner sitting done: `finish 1.4.1 <build> --platform MAC_OS`. Each platform
  needs its own go.
- [ ] **[owner]** After approval, `release.py release 1.4.1`; merge the m4 PR with a merge commit;
  tag v1.4.1.

**Draft copy (en-US; W9 makes all 6 locales):**
- **What's New:** "Strength: a 0–100 score that rewards consistency and recovers after a missed
  day. Fix past days in your history, and add notes to the days you check in. Stride Pro adds a
  strength chart and your top 5 streaks."
- **STRIDE PRO block:** "Stride Pro adds three things: Habit Groups — organize habits into
  collapsible groups; Advanced Analytics — Insights, the 8-week Trend chart, the Strength chart and
  your top 5 streaks; Weekly Review — a look back at how your week went." The paywall uses the
  same "your top 5 streaks".
- **STATISTICS paragraph** gains "a strength score that recovers from a missed day" and "fix past
  days in your history". It says "fix", not "tap": a tap opens the editor.

## Risks

1. **The outage outlives the plan.** New users cannot reach M4's sync features until P1's env fix,
   which waits for neither 1.4.1 nor Apple. Until A lands, a Mac reviewer who taps Send Login Link
   gets the 500 message (APIClient.swift:382-383), while the description sells sync
   (metadata/en-US/description.txt:29-31).
2. **Re-seeding during a review** logs the reviewer out (seed-demo.js:31-41). Use the add-only
   script, and only when no review is open.
3. **Data loss through the new edit surfaces.** The guards:
   - D4's setters, which write only what changed and use the state the user saw, and undo on a
     failed save;
   - no direct heatmap toggle (D5);
   - `.needsConfirmation` before deleting a noted check-in, on every path including the widget
     (D7);
   - the note-keeping upsert;
   - the 5 rehearsal scenarios.

   Until W8's deploy, a past-day tick on a device with a stale cursor can still erase another
   device's note (scenario 5). The race already exists in 1.4.0's 7-day strip.
4. **A stale cache, or views losing their Observation dependency.** The guards: D3's fingerprint,
   the synchronous bump, the sibling-context and `.habitDataChanged` triggers, the `generation` read,
   and the day and time-zone observers. Residual risk: a deletion saved by the widget can leave
   Today's row showing the day checked until the habit is re-fetched (pre-existing since 1.2.2). A
   tap then writes nothing, because `setChecked` re-reads the store.
5. **Shell regressions:** a push into the shared stack, ungated toolbars, or a sheet lost on a
   size-class change. D6 uses the shell request, and W4 re-runs the shell tests and E2E.
6. **The Mac stays unverified.** 1.4.1 adds Mac clicks (heatmap, History, Manage/Redeem). Gate 10
   is the Mac gate: the Mac submission waits for it, and iOS goes first, as in 1.4.0.
7. **Merge churn with the magic-link work** (catalogs, AuthService). Land it in `main` early, then
   merge `main` into m4. Never cherry-pick the uncommitted files.
8. **Pro copy drift** across 5 sites × 6 locales, plus the ASC IAP copy. The W9 grep gate and
   read-back catch it.
9. **Disk is 94 % full** (59 GiB free). Use one derived-data directory per session. The gate
   builds for 1.4.0, 1.3.1, 1.3.0 and 1.2.3 and the variants live outside `$TMPDIR`. The
   per-tag gate builds and the 1.4.0 variant root are trashed when 1.4.1 ships; the persistent
   roots (shared SourcePackages, `sim-e2e`, `mac-variant`, `a11y-dd`; README "Building
   locally") stay.
10. **Week anchors disagree.** Weekly logic is Monday-based (Habit.swift:216-223), while heatmap
    rows follow the region (HeatmapLayout.swift:37-41). This predates M4 and is left alone; the
    copy names no weekday.
11. **Legacy ≤1.2.2 snapshot clients revert edits.** (Closed by #9's refusal once it is deployed, decision 5; until then A's window is open, with zero synced users today.) Once A lets them sync, each of their syncs
    reverts note and value edits made elsewhere on the days they hold (sync.js:779-782,
    :509-519). Mitigation: O5, by default (2).

## Owner decisions

**2026-10-15: all taken at their defaults except O4 and O5, decided as above.**

Defaults are proposals. O4, O5, O6 and O12 involve production or ASC writes, and each still needs a
go per action.

| # | Question | Default |
|---|---|---|
| O1 | Strength for an unfinished today: 0, or hold yesterday's score until today is complete? | Hold, with the same rule for every kind (D9) |
| O2 | Notes on unchecked yes/no days? | No; only on days with a record (D7) |
| O3 | Rate start with backdated records: earliest record, or keep `createdAt`? | Earliest record (D8) |
| O4 | **Decided 2026-10-15** (decisions 1–3). Magic link: A now and B later? Who runs A, and who commits 4c69e79f's work? | A as the next session's first go, run by session 4c69e79f, with this session verifying; B before 1.4.1 ships or explicitly deferred; that session commits twice and opens a PR into main |
| O5 | **Decided 2026-10-15: (1′), payload-shape refusal, #9** (decision 5). Legacy ≤1.2.2 clients once A lets them sync: (1) a floor or refusal, deployed before A; (2) a missing entry `updatedAt` counts as oldest; (3) accept. Decided before A | (2), in W8's deploy or sooner. The 426 floor (≥ 1.3.1) stays in M6 |
| O6 | Demo account: add-only, or a full 90-day re-seed? | Add-only, while no review is open |
| O7 | Free Strength tile: replace Total, or add a 5th tile? | Replace Total |
| O8 | Screenshots: free tier, or a DEBUG `-demoPro`? Which iOS slides? | Free tier; every slide whose screen W3 or W5 changes (Statistics, Settings), on both platforms (P3b) |
| O9 | ASC offer codes and win-back offers in 1.4.1? | None, so Redeem Code is hidden. If offer codes ship, Redeem shows on iOS and macOS 15+ |
| O10 | Heatmap tap behaviour? | Opens History on every width; direct toggle on iPad/Mac only if the owner asks, then gated on cell size (D5) |
| O11 | Today on a past day: hide habits that had not started by then? | Filter (D8); backfilling a habit created today moves to History |
| O12 | Withdraw Mac 1.4.0 (DEVELOPER_REJECTED) to replace APP_DESKTOP now, at the cost of a review cycle, or wait for 1.4.1? | Wait |

## Out of scope

- **M5 (1.4.2):** the Weekly Review rebuild (the week's notes, at-risk math, schedule-aware
  "remaining"), and a single presenter via `shell.request = .weeklyReview`. Today there are two
  presenters: StatsView.swift:167-169 and ContentView.swift:251-252.
- **M6 (1.5.0, gated):** skip days, the 426 floor, the tombstone sweep, merge-import. M4 only leaves
  room for them: a neutral-day input, a Skip slot in the day editor, and a third cell visual.
- **Not planned:**
  - "change start date", which needs a server change because `created_at` is insert-only;
  - negative habits, monthly frequency, "day starts at";
  - macOS widgets, Swift Charts;
  - any schema change.

## Progress log

- 2026-10-14: Plan drafted from four read-only mappers (spec, client, server, ops) at 376e69b. The
  strength numbers were recomputed independently.
- 2026-10-15, #8 + #9 merged into main and deployed (DEPLOY 5 steps, rehearsal 32/32); main merged
  into m4 (31f23e8). Mac 1.4.0 went IN_REVIEW.
- 2026-10-17, gate 8 (a11y) first pass.
  - Commits: 0083fb4 deflakes BackgroundSyncTests and adds the DEBUG `-openHistory <habit>
    [-historyDay n]` / `-scrollTo historyEditor` hooks; 4d65525 fixes the sweep.
  - The flake was a test race, not product code. Under utility-QoS starvation the 5 s bound passed
    before the submitter answered (reproduced 4/4, fixed 0/4).
  - Four sweeps: iPhone 17 Pro Max and iPad Pro 13 (M5), each at default and AX5 (148 PNGs). The
    PNG review found 28 findings; the real ones are fixed and re-swept:
    - habit-colour text reaches ≥ 4.5:1 via `ColorContrast.readable`, the Today streak text too;
    - Edit history and Share have 44 pt tap areas;
    - tile and OverallStatsCard baselines line up;
    - History's disabled note field is dimmed;
    - iPad History and account sheets use the page size on iOS 18+;
    - AX5 layouts: Upgrade to Pro, the iPad sidebar, the Sync rows, the holdings box.
  - A DEBUG `-demoScenario details` set covers the Description line, note dots, the count stepper
    and a light habit colour.
  - Rejected: the 14 pt phone heatmap cell (D5's trade-off; Edit history and the VoiceOver action
    are the 44 pt paths).
  - Left as follow-ups: Settings habit rows' #FF9500 "4d" on white (2.1:1); Today's check circle
    filled with a yellow habit's colour (by design); the Spanish iPad sidebar at AX5 is unchecked.
- 2026-10-17, **P2 done**:
  - Mac 1.4.0 was approved (PENDING_DEVELOPER_RELEASE at 16:25 JST) and released at once; READY_FOR_SALE.
  - RELEASE-1.4.0.md ticked (6f5af54). #7 merged (c6507f7) after a CI re-run: one flaky hosted test,
    `BackgroundSyncTests.testAFinishedRunWaitsForTheResubmitsAnswerUpToItsBound`, failed on the
    runner on a docs-only commit. It is a 1.4.1 fix item.
  - Tag v1.4.0 on 6f5af54. main merged into m4 (de03fd4).
  - Prepared but not merged, pending owner Q1/Q2:
    - the X2 server date guard, draft PR #11 (server 602, local rehearsal 36/36);
    - W10, the client fix and migration, on branch worktree-wf_0f3bb37c-d94-2: StrideTests 697,
      hosted 322, rehearsal 109/0/1; review found 4 defects, fixed, including a 45 s first pass
      now ~3 s for 10,000 strays.
- 2026-10-17, **gate 8 (a11y sweeps)**: iPhone 17 Pro Max and iPad Pro 13" at the default size and
  AX5. The PNG review's 28 findings were checked against the PNGs and the code; the real ones are
  fixed and re-swept (all four sweeps), the rest rejected below.
  - Fixed: habit colours as text are a contrast-checked shade where they do not read on the card
    (Edit history/Share: Green 1.99 → 4.5:1, Yellow 1.35 → 4.5:1; Today's streak text 1.97 →
    4.5:1); text and dots on a habit-colour fill turn black where white is under 3:1 (History's
    digits and dot, the heatmap's dot; Yellow, Green, Orange, Teal); the detail card's 44 pt tap
    areas (layout unchanged); its tiles' values and OverallStatsCard's on one line; History's
    disabled Note field dimmed; the iPad History and account sheets at the page size (iOS 18+);
    holdings icons in one column; at accessibility sizes the Sync rows' captions under the Label,
    the Upgrade row's crown above its words, the sidebar's icons above their titles, Unlock with
    Pro centred in a rounded rectangle, Today's Description wrapped in full; syncAll's seeded
    habits in a fixed order.
  - Coverage: `-demoScenario details` (Yellow Morning Run with a Description and noted check-ins,
    Drink Water counted) and the sweep's `15_details_*` captures, `02_stats_detail` at AX sizes,
    `-scrollTo todayHabits`.
  - Rejected: the phone heatmap's 14 pt cells (D5's recorded trade-off; the phone cell is kept
    at every text size, 44 pt is out of reach anyway, and Edit history is the 44 pt path); the
    iPad Sync section's held-row indentation (List's own leading for icon-less rows, pre-1.4.1,
    no reading cost). Not coverable by the sweep: D12's plan rows (needs a purchase; hosted
    SKTestSession, gate 4) and Today on a past day (no launch argument picks a date).
- 2026-10-20, owner "全部按你说的做" (Q1a–Q5a as recommended):
  - **W10 merged** into m4 (c9dc2ea). Integrated gates on it: StrideTests 707 (705 + 2 known
    skips) in Asia/Tokyo and America/Los_Angeles; hosted 324 + 12 known skips (StoreKit on 26.5).
  - **Q1a, #11 merged** into main (36691cf) and **deployed**: X2's read-only query on production
    and on the pre-deploy backup found 0 rows outside [2025-01-01, today+2] or non-canonical (281
    entries, 7 users); server 602, typecheck clean; host diff = exactly #11's 5 files; prod-copy
    rehearsal 36/36; backup /root/backups/stride-predeploy-20261020-141247.db; health 200,
    loopback 000, AASA application/json, check_demo_account exit 0. main merged into m4 (95e4610;
    package.json's `npm test` lists both new test files).
  - **W8 deployed** from m4's server/ (Mac 1.4.0 review closed, so no review open): server 645,
    typecheck clean; host diff = exactly W8's 6 files; prod-copy rehearsal 36/36; the demo scripts
    on a separate prod copy first (add 2 habits, second run adds nothing, top-up dry run names all
    8, integrity ok; copy removed); backup stride-predeploy-20261020-141701.db; same post-deploy
    checks. Then on production: `demo-add-habits.js` added Water (+84 check-ins) and Stretch (+38),
    a second run added nothing, and the top-up dry run names all eight habits.
  - **Gate 2** after the W8 deploy: check_demo_account.sh exit 0 in the default zone and under
    TZ=America/Los_Angeles; every habit at 25 or more of the last 30 days scores 0.85 or more (the
    bar is 0.75).
  - **Q3a**: the gate-2 residual is accepted (no re-seed). A second top-up at 08:20 UTC, after LA
    midnight, is in root's crontab (7ca1428; before/after saved in /root/backups).
  - **Q4a, gate 4** on a new iOS 18.5 simulator `Stride-StoreKit-iOS18` (StoreKit testing works
    there; on 26.5 it skips): run 1 10/1, run 2 11/1, a different test each time
    (`testAnExpiredSubscriptionIsOneLapsedRowAndLocked`, then `testBillingRetryShowsThePaymentRow`).
    Both were the test reading `isPro` (currentEntitlements) before StoreKit caught up with the
    status it had waited for. `refresh(until:)` now also waits for the expected `isPro`; then
    12/12 (StoreKitStatusTests 11 + StoreKitConfigurationLoadTests 1, no skips) twice in a row.
  - **Rehearsal on the merged tree: 103/9/1.** #11's guard refuses the fixtures of M4 (dates in
    2028) and K1–K3 (old-build keys pushed to seed the server). Production is unaffected (0 such
    rows). The fix is a test-only hook that switches the guard off only while K1–K3 seed rows
    "stored before the guard", plus a new K4 for the guarded path (held rows re-keyed in place).
  - **Q5a**: the pre-existing Today crash risk (another context deleting a whole habit while Today
    shows it; no production path does this) is accepted for 1.4.1.
  - **P4 / gate 10.4, first sitting** (owner granted computer use on the variant only; background
    control, then the console locked, so the keyboard items wait for a second sitting):
    - 7 (menus): File = New Habit, Sync Now, Export Backup…, Export as CSV… (no New Window); View =
      Today, Statistics, Weekly Review; Window → Stride. Pass. Shortcut glyphs and the disabled
      state with Settings key are not readable from the background: open.
    - 9: Weekly Review before Statistics was ever opened shows the paywall (free); Close; it reopens.
      Pass. Esc: open (a keystroke).
    - 6: the picked day (Sun 18) and the Statistics chip survive ⌘1/⌘2 (via View); one toolbar per
      tab (Today: New Habit; Statistics: Weekly Review). Pass after the fix below.
    - 13: ⌘, opens a window titled Settings, 900×552; the paywall sheet from it fits (scrolls) and
      closes. Pass. Free tier: Upgrade + Restore; Redeem hidden (no offer code). Pass.
    - 1: the export panel opens as a sheet on the Settings window; Cancel leaves no file in
      `…mactest/Data/tmp` (only the system's empty TemporaryItems). Pass. "Lands where chosen": open
      (the out-of-process panel takes no background clicks; only ~/Documents, iCloud, was reachable).
    - gate 10.4 (local): a heatmap click opens History; tick, untick, re-tick Oct 16: one record
      (sqlite on the variant store), and Statistics updates in the same render. Pass.
    - **Found and fixed (eccdd49):** Statistics' habit chips did nothing under AXPress, the action
      VoiceOver and Full Keyboard Access use on the Mac: `.onTapGesture` + `.isButton` with no
      `.accessibilityAction`. Fixed and verified on a rebuilt variant;
      AccessibilityActionScanTests now fails any `.onTapGesture` without an action.
    - The paywall's products never load in the Debug variant (its bundle id has no products): a
      spinner, then "Unable to load subscription options" + Try Again. Expected for the variant.
    - Left for the second sitting (keyboard or screen needed): 1 (destination), 2, 3, 4, 5, 7
      (glyphs, Settings-key state), 8, 9 (Esc), 10, 11, 12; gate 10.4's VoiceOver/FKA pass, the
      narrow width, and "a History edit syncs to iPhone B".
  - **P3b** Mac candidates captured at 2880×1800, 12 in dark and light
    (build/store-screenshots/1.4.1/mac/candidates, contact_sheet.png). Default pick 01–04: light
    Today (details), light Statistics heatmap, light History, dark Today (the live listing also
    has 4). The paywall is left out: the Debug variant's products never load (spinner). The Mac
    sidebar has no Settings tab (`-tab 2` shows Today).
- 2026-10-21, gates while the owner was away (workflow wf_81ac01c3-f52: one run per gate, each
  checked by an adversarial verifier; evidence in the session scratchpad, gates-1.4.1/):
  - **Gate 10.1 PASS:** `build-appstore.sh all` without --upload on 0b91a64 (code = eccdd49):
    both 1.4.1 (23) archives and exports pass verify_archive (C617.1 + 35F9.1 in the app and the
    widget, Mac sandbox + files.user-selected.read-write, Apple Distribution, no get-task-allow).
    The 1.4.0 archives were copied to build/appstore-1.4.0-22 first. The script also uploaded the
    1.4.1 (23) dSYMs to Sentry (stride-apple).
  - **Gate 7 Mac PASS:** a v1.4.0 variant seeded with -demo, then m4's variant in place: row counts
    and the model checksum equal before and after, no default.store, the store-open line logged,
    W10's flag set with nothing to repair, and the real group container unchanged. (The verifier
    asked only for a saved artefact of the pid stop.)
  - **X2 on a real upgrade (gate 7, non-Gregorian, PARTIAL):** promax set to ja_JP@calendar=japanese
    (restored afterwards to en_US). The 1.4.0 (22) build wrote all 63 records at year 0008 (its
    By Weekday was wrong). After `upgrade.sh` in place (exit 0), the first 1.4.1 launch logged
    "Day-key repair: 63 found, 63 re-keyed, 0 replaced, …"; every record keeps its id and moves to
    its real 2026 day; later launches do nothing; Today, Statistics (By Weekday now right) and
    History ("October 8 Reiwa") are right. The kit server's guard answers a 1.4.0 push of 0008 with
    invalid_value and a 1.3.0 push with 426. Not run: the signed-in branch (held rows lifted, the
    server ending with the real days), which needs UI input.
  - **Blocked: gate 3 (partly) and gate 7 iOS.** The iOS Simulator MCP crashed repeatedly while the
    host ran at load average 400–1000 with swap nearly full (other sessions' builds plus this
    archive), then refused every call until the simulator panel is reopened. Done before that, on
    1.4.1 (23): gate 3 bullet 1 on A (Read 30 Minutes, Edit history, 2026-09-30 ticked: Best 11→20,
    rate 86→90 %, strength 88→89 and the heatmap cell in the first frame after Done; the server got
    one row on sync). Still to run: B, untick/re-tick, the iPad leg, the widget leg; gate 7 iOS's 4
    legs with a widget and --reminders.
  - Fixed in the kit (f086529): `upgrade.sh --reminders` refused a correct 1.4.0 starting point (it
    demanded 1.3.x's bare id for the Mon/Wed/Fri habit). Selftest 114/0.
  - DayKeyRepair now logs "nothing to repair" (a0f9cd0), so a Gregorian upgrade's log shows the
    pass ran.
  - **W9 merged (63d090e):** WHATS_NEW_BY_VERSION["1.4.1"] ×6 (Strength; fix past days from Edit
    history or a heatmap day, and notes on checked days in History — notes themselves are not new;
    Pro adds the strength chart and top 5 streaks; the W10 calendar fix, with iOS Settings' own
    calendar names), verbs that fit the Mac too; store descriptions use the app's names (ja, ko,
    zh-Hans, es-ES "De por vida"); the es-ES subtitle fits 30; docs/review-notes-1.4.1.md. Two
    reviewers (claims, language) raised 12 findings; 11 applied, 1 left for the owner.
    test_release.py 17/17; LocalizationSourceScanTests + LocalizationCatalogTests pass.
  - **Gate 5, ASC read-back (read-only, 25 GETs):** the subscriptions' 6 localizations each are
    APPROVED and match setup_iap.py. Open for the owner:
    - Yearly's ASC description says "save 44%" in every language. True in USD (19.99 vs 12×2.99);
      EUR 35 %, TWD 36 %, CNY/HKD 43 %, JPY 50 %, KRW 45 %. The app's paywall computes the figure
      from the live prices, so only the ASC text is off.
    - The Lifetime IAP has only an en-US localization, and its description omits Weekly Review
      (D11).
    - The live app name is "Stride - Habit Tracker" in every locale with no subtitle:
      metadata/<locale>/name.txt and subtitle.txt have never been pushed (`--app-info`).
    - The promotional text advertises widgets on the Mac record too (push_metadata.py writes the
      same files to both platforms).
    - Should What's New also name the Description field, Settings' plan rows (D12), templates with
      target and unit?
- 2026-10-16, wave B merged (W7 c39d4d8, W6 a094ca2, D11 172fdab); 8 review findings confirmed and
  fixed, 2 refuted.
  - W6: templates carry kind, target and unit. A failed add says so. A pick closes New Habit too:
    W6 wired AddHabitView's `onAdded` itself (W4 was already merged).
    - Count templates are only those reachable by tapping (Morning Run 5 km, Drink Water 8
      glasses, Sleep 8 hrs). Walk 10k Steps, Write 500 Words and Read 30min stay yes/no until a
      count can be logged by amount.
    - New key "%lld %@ a day".
  - W7:
    - Export names are yyyy-MM-dd-HHmmss.
    - Privacy reasons C617.1 + 35F9.1 (app) and 35F9.1 (widget); verify_archive.sh checks them.
    - `release.py cancel --platform`.
    - ship.sh is retired: it refuses to run.
    - `mac_variant/build.sh --release` builds into the persistent root
      ~/Library/Caches/Stride-build/mac-variant-release. It is a production client, so sign-in
      only with the owner's plus-address (decision 4), and launch by path only.
    - Before any Mac screenshot, rebuild the default Debug variant: it is still 1.4.0 without
      `-windowSize`, and capture.sh refuses it.
  - D11: paywall rows, the Settings upsell, ProLockedCard and the 6 STRIDE PRO blocks name exactly
    D11's set. The STATISTICS paragraph gains strength and "fix past days".
    - Tests `testProClaimsNameExactlyD11sSet` and `testStoreDescriptionsSellD11sProSet` are W9's
      grep gate.
    - en-US and es-ES descriptions are within 8–12 characters of 4000.
    - Open for W9/owner: store copy uses different feature names than the app's catalog (es
      Estadísticas avanzadas vs Análisis avanzado, ja 週次レビュー vs 週間レビュー, ko 고급 통계 vs
      고급 분석, zh-Hans 高级统计 vs 高级分析, zh-Hant 深入分析卡片 vs 洞察); the review notes; the ASC IAP
      read-back.
- 2026-10-15, wave A merged (W8 d2f6cd7, X1 1f9ec40, W5 4702f9f, W3 163efe4, W4 7703331), each implemented
  in its own worktree, reviewed by 2 lenses, findings verified and fixed (17 confirmed, 1 refuted).
  - Integrated gates on 7703331:
    - xcodegen drift clean; iOS and Mac builds green;
    - StrideTests 670 (+2 known skips) in two zones;
    - hosted 311, plus 12 skipped: StoreKitStatusTests' 11 cases (Xcode 27.0 + iOS 26.5 SKTestSession
      bug FB22774836) and one more;
    - server 559; rehearsal 102/0/1.
  - W3: Statistics reads StatsCache. A heatmap tap, the grid's VoiceOver action and the "Edit
    history" button (`stats.editHistory`) open History. The Strength tile replaces Total;
    StrengthCard and BestStreaksCard are added; ProLockedCard copy follows D11.
    - Open: run the a11y sweep with the new anchors (gate 8). The Mac heatmap has no pointer or
      hover state (gate 10).
  - W4: HabitHistoryView (D6–D8), the Description field, Today rows read StatsCache with the
    past-day filter, collapsedGroups is per device, decision 8's footers are in, and menu Export
    checks its own window. New key: "No habits had started by this day."
    - Open (owner, Q5): a pre-existing crash if another context deletes a whole habit while Today
      shows it. No production path does this today.
  - W5: ProStatus (D12) with the pure mirror; Settings plan/renewal/Manage/billing/lapsed rows; the
    habit delete is saved, rolled back on failure, then tombstoned; badge after a grant. The
    Configuration.storekit version format is fixed. `run_hosted_tests.sh` now lists skips and
    never reads them as passes.
    - Open: SKTestSession on an iOS 18.5 device (Q4). D11's paywall row and Settings upsell are
      left for the D11 lockstep commit.
  - W8: demo-add-habits.js (add-only Water/Stretch, 90 days), the seed and top-up get the same
    shapes, LA-day cap, node tests.
    - Open: the owner's deploy once no review is open, and gate 2's residual (Q3). The LA cap means
      a Tokyo-morning demo check reads low; check in the Tokyo afternoon or under the LA zone.
  - X1: a pull never puts one id on two local records (it prefers the record carrying the id and
    never renames onto a taken id). Same-id pairs left by 1.3.1–1.4.0 heal on W2's merge at the next
    write to that day.
  - X2 (investigation): docs/X2-non-gregorian-day-keys.md.
    - Every build since 1.2.0 writes wrong keys on non-Gregorian devices (th_TH, fa_IR, ar_SA by
      default).
    - Production has 0 out-of-window rows (only the demo account has data).
    - Owner decisions: Q1, a server date guard now; Q2, the client fix and migration as W10 in
      1.4.1, with History's floor capped at 2025-01-01.
- 2026-10-15, W2 done (f141fe4 write path, 20b4dde cache/widget/rehearsal, 692e411 review fixes):
  - Setters with the day merge and persistentModelID matching; HabitEntryCommit with an undo
    journal. Today's writes and both confirm alerts.
  - StatsCache: process-level didSave, sibling-context merge, .habitDataChanged, day and zone
    triggers, scene activation. The widget's noted yes/no rows are a Link to History.
  - The route is `stride://history?habit=<UUID>&day=<yyyy-MM-dd>`, kept apart from sign-in. It is
    presented only when the window has nothing else up.
  - Gates: StrideTests 632 (2 known skips) in two zones; hosted 280; rehearsal 97/0/1, including M1–M5
    and M6–M8 for the merge.
  - Review: 7 findings, 6 confirmed and fixed. The critical one is decision 7's tombstones (amended
    above).
  - Deviations:
    - D3's fingerprint drops the newest record stamp and record identities (82 ms → 0.3 ms per warm
      read of 50 × 1,095). Record changes are still caught through the save mapping.
    - The setters re-read the day's stored fields before writing (`adoptStoredFields`), because
      mainContext does not see other contexts' saves.
    - SettingsView's habit delete is reverted to its pre-W2 order; W5 does the reorder with a rollback
      on a failed save and a hosted test.
  - New items:
    - **X1 (sync, 1.4.1).** `SyncDayIndex.record(of:onDayOf:)` (Shared/SyncReconciler.swift) renames
      the day's first record to the server's id even when another local record already holds that
      id, which creates same-id duplicates. It should prefer the record carrying the entry's id and
      never rename onto a taken id (as SyncPushResolver's `takenIDs`).
    - **X2 (pre-existing, data correctness).** Day keys take Y/M/D from `Calendar.current` (and
      `appCalendar` keeps its identifier). On a device whose system calendar is Japanese or Buddhist
      (Thailand's region default), records are stored and synced as year 0008 or 2569.
      SyncDelivery's 1970–2069 year parse, `DataBackup.dayKey` and `NotificationRouter.day(from:)`
      bound years too. Fixing it needs a Gregorian day-key calendar plus a key migration (local and
      server). Investigation first, then an owner decision.
- 2026-10-15, W1 done (dbd1df9 goldens, 338f36e implementation, 52088f1 review fixes):
  - HabitStats, HabitScore and the delegating aggregates are in; the widget makes one RowInput
    per habit and carries hasNote; demo_check reports strength.
  - Parity: 1,129 golden values; only the 57 NAMED FIX entries flipped.
  - StrideTests 600 (2 known skips) in Tokyo and under TZ=America/Los_Angeles. Builds are green.
  - Review: 5 findings, 4 confirmed and fixed (the widget's "now" streak counted tomorrow's
    times-per-week record; wrapper cost).
  - Carried forward:
    - **Per-call wrapper cost.** One aggregate wrapper call costs ~2.5 ms against 1.4.0's
      1.0–1.7 ms (-O, 730 records). The extra is D2's store check. So any render that asks many
      questions builds one `habit.makeStats(today:)` per habit, or reads StatsCache:
      - W3: TrendCard, insights, ShareStreakView;
      - W4: TodayView's "x/y this week" (:560, :598) and WeeklyReviewView (today ~270 ms for 10
        habits × 730 records against 113 ms);
      - W5: SettingsView.swift:355.
    - **Crash safety (W2).** A record deleted and saved by another context faults on any
      attribute read (id, date) unless this context read it since. So `HabitCheckIn.liveRecord`
      and every new setter match `habit.records` to the store by `persistentModelID` before they
      read `date`, as `HabitStats.LiveRecords.persistentIDs` does. This is pre-existing in 1.4.0's
      `liveRecord`.
    - **Records order is not stable across a save.** "First match" was never deterministic;
      decision 7's merge uses `HabitRecord.outranks` (largest value, newest stamp, larger id).
    - **Parity rule clarified.** `isCompletedOn` equals HabitStats' per-day answer on every day
      up to today. Days after today, and the second-context fixture, are the exceptions (D2's
      named fixes).
    - **Perf bounds can trip on a heavily loaded machine.** Check the load before treating a
      PERF failure as a regression.
- 2026-10-15:
  - Codex (gpt-6-astra, read-only) and Gemini 3.8 Flash High (agy) were consulted on the open
    decisions, and every claim was fact-checked against the code by 8 read-only agents. The
    owner took all the recommendations; see "Decisions of 2026-10-15".
  - A's dry run passed.
  - #8 (magic-link fix, by 4c69e79f) and #9 (legacy refusal + notes) are open; the trial merge
    is clean and the merged suite passes 516/516.
  - `scripts/ops/set_resend_key.sh` was added for B.
  - Shared SourcePackages and persistent build roots landed (63e5689, README "Building
    locally").
  - Mac 1.4.0 is still WAITING_FOR_REVIEW.
- 2026-10-14: Plan reviewed (below) and revised. Next: P1 (the owner's go on A, and O5), then P3a
  with P4, then W0.

## Plan review (2026-10-14)

**Reviewers:**
- Gemini 3.8 Flash (`gemini-3.8-flash-high`) via agy, on a throwaway copy of the workspace, with two
  lenses:
  - correctness and completeness: 6 major and 5 minor findings, nothing critical;
  - sequencing and risk.
- Claude adversarial lenses: data safety, and release/ops.
- Gemini 3.1 Pro was requested, but agy on this machine does not offer it.
- Each finding was checked against the code at 376e69b before it was accepted or rejected.

**Accepted (41):**

| Reviewer | Finding | What changed |
|---|---|---|
| Gemini correctness | Habit wrappers would rebuild full stats per call (84 per heatmap render) | D2: only aggregates delegate, lazily; per-day lookups stay direct. D3 names the cache readers. Perf test of the uncached path |
| Gemini correctness | No visible History entry point | D6: "Edit history" button on the detail card, with the shell passed down; gate 3 and E2E H1 use it |
| Gemini correctness | Today's start filter was dropped on a wrong rationale | D8: past days filtered by min(created, earliest record); O11; hosted test |
| Gemini correctness | Strength grace undefined per kind | D9: today is applied only once complete, for every kind; HabitScoreTests cases |
| Gemini correctness | proStatus could revoke an entitled user's Pro offline | D12: `isPro` unchanged; status unavailable → active; test; gate 4 |
| Gemini correctness | There are 6 stringsdicts (en included), not 5 | W0 wording |
| Gemini correctness | No rollback on a failed save | D4 step 1: undo plus `.saveFailed`; Data safety 1 case |
| Gemini correctness | `bestStreakRanges` untested | W1 cases; D2 tie rule |
| Gemini sequencing | Outage fix sat behind the Mac review ("in order") | Phase 0 reordered: magic link is P1, the Mac release is P2 |
| Gemini sequencing | W6 needed AddHabitView, a W4 file | `onAdded` callback; W4 wires it |
| Gemini sequencing | Dual heatmap modes are over-scoped | D5: a tap opens History at every width; O10 |
| Gemini sequencing | Week estimates don't match agent cadence | Relative sizes; calendar time bounded by gos, review and deploy window |
| Gemini sequencing | What's New advertised sign-in failures | Sentence removed |
| Gemini sequencing | No macOS release gate | Gate 10 (a)–(c) |
| Gemini sequencing | No live magic-link gate | B verification; checklist item; gate 11 |
| Claude data | Cache goes stale after sibling-context writes, and toggles act on the wrong state | D3 fingerprint and triggers; D4 target-state writes, no `tap` in UI; W2 tests |
| Claude data | Ghost filter misses widget-process deletions | D2 store ids; second-context fixture; widget E2E |
| Claude data | ≤1.2.2 clients undo edits, and A lets them sync | O5 decided before A, default (2); legacy push test; Risk 11 |
| Claude data | A stale-cursor past-day tick erases another device's note | Rehearsal scenario 5; note-keeping upsert as a named exception; fallback |
| Claude data | `set(value:note:)` writes stale drafts, touches on no-ops, truncates | Three setters; cap on new input only; History re-resolves; tests |
| Claude data | Noted check-ins deletable silently on other paths | `.needsConfirmation` in HabitCheckIn; widget noted row becomes a link; Risk 3 wording |
| Claude data | A failed commit leaves a pending delete | D4 undo of its own changes; Data safety 1 case |
| Claude data | Demo scripts: `created_at`, idempotency, UTC "tomorrow" | D13 items 2, 3, 5; D2 ignores future records; gate 2 in the LA zone |
| Claude data | Parity fixtures skip the disagreement cases | New fixtures, duplicate rule, two zones |
| Claude data | Observed dictionary written during render; full rebuild per save | `@ObservationIgnored`; per-habit invalidation; 50 × 1,095 perf |
| Claude release | Magic-link fix behind review, with two owners | P1 first; 4c69e79f owns the production change; P2 blocks nothing; Risk 1 |
| Claude release | Sign-in chain verified only up to DKIM | P1 step 6; gate 11; B checklist item; probe at most daily |
| Claude release | No hands-on gate for 1.4.1's Mac UI | Gate 10(d), a second sitting, Mac submission conditional |
| Claude release | Upgrade gates narrowed; no Mac upgrade path | Gate 7: four iOS legs plus a Mac variant leg |
| Claude release | Screenshots depend on W0 and go stale | P3a/P3b split; O12 |
| Claude release | A stale real-id Mac app is registered with LaunchServices | P3 step 0 |
| Claude release | D5 silently removed per-cell VoiceOver; 84 Mac Tab stops | D5 accessibility decision; History grid per day; gates 8 and 10 |
| Claude release | Size-class gating, but regular-width cells can be 14 pt | Cell-size gating if O10 opts in; gate 3 iPad leg; gate 10 widths |
| Claude release | StoreKit states missing | `.billingIssue`, refund, Lifetime-plus-renewing row; tests; storekit file in W0 |
| Claude release | ASC and production writes unmarked | Phase 0 legend; **[owner]** marks; O-table header |
| Claude release | P3 dry run impossible before `prepare`; Screen Recording grant | Local validation in P3a; dry run in W9; owner present for P3b and revokes |
| Claude release | P1 ticked docs after the merge; build number hard-coded | P2 order: release, tick with CI, merge, tag; `<build>` |
| Claude release | No hotfix lane | P4 triage rule |
| Claude release | Pro copy blurs Best Streak; IAP copy unchecked | "your top 5 streaks"; ASC IAP read-back |
| Claude release | Copy overclaims; Redeem would be dead UI | "fix past days"; D10 wording; Redeem only with an offer code |
| Claude release | No Release-build smoke | Gate 12 |

**Rejected (10):**
- Gemini correctness, "cached stats can't answer as-of-date streaks": already decided. Any day is
  answered from the cached set (Spec corrections, D2).
- Gemini correctness, "HeatmapGrid lacks the shell": an implementation detail inside W3's
  StatsView.swift, already covered by the Edit history change.
- Gemini correctness, "A's verification is blocked by the apex parse": A verifies with a real send
  and Gmail's Authentication-Results. The parse affects only the DMARC fallback and the root-SPF
  WARN, and the file is the other session's uncommitted work.
- Gemini sequencing, "the branch cut guarantees catalog conflicts": the other session's key sits
  about 120 lines from W0's end-of-file block, and the trial merge found 0 conflicts. The proposed
  fix would block M4 on Apple, or cherry-pick uncommitted files.
- Gemini sequencing, "W3 and W4 share StatsView.swift": they don't. The tap only sets
  `shell.request`, and W4 owns the presenter.
- Gemini sequencing, "W2 and W5 share StrideApp.swift": the refresh call sites already exist, and
  `proStatus` is recomputed inside StoreService (W5).
- Gemini sequencing, "Phase 0 blocks on a joint session": the owner asked to do the screenshots
  together. Gate 10 and P4 hold the fallback.
- Gemini sequencing, "Pro claims diverge": D11 already names the sites, with one commit and a grep
  gate. A string-equality test can't span deliberately different wordings, and the paywall list
  scrolls.
- Gemini sequencing, "the free-tier screenshot shows the lock card": O8 already asks. The Strength
  tile is free, and there is no isPro bypass by design.
- Gemini sequencing, "gate 1 doesn't name the localization tests": both suites are in StrideTests,
  which gate 1 runs in full. The known skips are not localization tests.

**Consult of 2026-10-15 (Codex + Gemini on the open decisions), fact-checked:**

| Source | Claim | Verdict | Outcome |
|---|---|---|---|
| Gemini | `request-link` rate limit (3/15 min/IP) stalls verification | partly | Plan text: sink sends through `email.js`, one `request-link` per sitting |
| Gemini | `note = excluded.note` wipes notes for multi-device users | partly: only when the writing device lacks the note | #9: the CASE plus the push-order merge; residuals accepted |
| Gemini | A sync rollback discards typed drafts | false: drafts are view `@State` | Rejected; the D4/D6 sentence above |
| Codex | D2 reads the max duplicate, D4 writes the first | true | Decision 7 |
| Codex | O5 (2) leaves legacy holes (deletions, 1.1 habits, widget) | partly: 1.1 is real; delete-wins is system-wide | Decision 5, (1′) |
| Codex | The DEPLOY diagnostics exit 0 on failure | true | Fixed in #8 |
| Codex | P1 step 6 / gate 12 would delete the owner's real account | true | Decision 4 |
| Codex | Editing target/schedule re-scores all history | partly: no data loss | Decision 8 |
| Codex | B before 1.4.1 (Gemini: defer) | — | Decision 2: B before 1.4.1 |
| Gemini | Sentry DSN before A | — | Decision 9: not a prerequisite |

**How overlapping findings were merged:**
- D5: Gemini's single behaviour is the default. Claude's cell-size gating applies only if the owner
  opts into direct toggle (O10).
- Both reviews proposed an O11: the Today filter is O11, and the Mac 1.4.0 withdrawal is O12.
- Rollback: Gemini's `rollback()` and Claude's undo of the commit's own changes are combined in D4
  step 1.
- Phase 0 combines Gemini's reordering with Claude's ownership and non-blocking P2.
- Gate 10 joins Gemini's archive and variant checks with Claude's hands-on pass.
- Parity equality (Gemini) excludes the second-context fixture (Claude), where only store ids are
  right.
- P1 step 6 uses Release-configuration builds, because Debug builds and the variant call
  localhost:3002.
- P3b runs after W3 as well as W5, since W3 changes Statistics.
- The cache-alive 50 × 1,095 pull is hosted, because StatsCache is app-only.
- The O-table header also names O5 and O12, which involve production and ASC writes.
