# Stride — development plan for the next phase (1.3.x → 1.4.x)

Written 2026-09-24, the week after 1.2.3 (build 17) went live on iOS and macOS.
Baseline: `main` = `00554e9` + `5fa64d8` (the demo-account acceptance script).

## How this plan was made, and what it optimises for

Four researchers worked independently: a survey of open-source habit trackers (Loop Habit
Tracker's scoring, frequency and entry models read from source; Kado, Beaver, Habo, mhabit,
habitsync, Habitica; demand signals from Loop's discussions and issues), an iOS-platform
survey (what iOS 17 / macOS 14 allow without a target bump — checked against the installed
SDK's swiftinterfaces), a gap analysis of Stride's own code and infrastructure, and a
sync-architecture design. Three planners drafted roadmaps from different priorities
(reliability-first, product-first, Pro-value-first); two judges — a demanding paying user and
a staff engineer who has shipped sync — scored them. The merged draft was then reviewed by
Gemini 3.1 Pro and Gemini 3.8 Flash; what they changed is in "Review log" at the end.

What it optimises for, in order:

1. **Nothing a paying user can lose.** Sync is the headline feature and the thing 1.2.2/1.2.3
   spent two releases repairing. The remaining structural risks — every device pushes its
   entire history on every sync; a device offline longer than the tombstone window can
   resurrect deletions; signing into a second account merges the first account's data into
   it — are closed before any feature that adds a column.
2. **Every release is honest.** The store may only sell what the binary gates; every
   milestone ships with the copy that describes it, pushed from the repo in the same
   submission (`release.py` copies the previous description forward — that mechanism
   republished false Pro claims for months).
3. **One developer, realistic weeks.** Effort is in developer-weeks *plus* ~2 days of release
   mechanics per submission (What's New in six locales, demo re-seed, rehearsal scripts,
   build/upload/submit; review latency not counted). Both external reviewers said the first
   draft's estimates were 35–50 % low; the numbers below are the corrected ones. Agents
   parallelise tests, l10n and research; they do not shorten device testing.
4. **No interruptions.** No milestone may add a modal, sheet, alert or system prompt that
   appears without a user action; the one exception is the notification-permission prompt at
   the moment the user enables a reminder. Inline status rows (sync state, sign-in needed,
   subscription lapsed) are allowed; a notification the user opted into is not a nag. This is
   an acceptance criterion on every milestone.

Non-negotiable constraints: deployment targets stay iOS 17 / macOS 14 (nothing below needs a
bump); the existing server stays (paying users sync through it; the demo account lives
there); Habit Groups, Advanced Analytics and Weekly Review remain the only Pro gates, and
nothing free today moves behind Pro.

## Milestone order

| # | Ships as | Weeks | Theme |
|---|---|---|---|
| M0 | server deploy + CI + repo (no App Review) | 3 | Server contract for incremental push, CI that sees the shipped half, ops footing |
| M1 | **1.3.0** (build 18) | 4 | Text/scaling correctness, reminder-permission fix, large widget, lossless backup + restore, one-tap sign-in — a release that cannot corrupt data, and proves the new CI before M2 rides it |
| M2 | **1.3.1** (build 19) | 5.5 (provisional) | Incremental push, cursor expiry, account isolation, sessions that stay signed in |
| M3 | **1.4.0** (build 20) | 3.5 | iPad and Mac as real shells, notification actions, background sync |
| M4 | **1.4.1** (build 21) | 5.5 | Habit strength score, editable history, best streaks, notes, stats that scale, subscription status |
| M5 | **1.4.2** (build 22) | 2 | A Weekly Review worth opening |
| M6 | **1.5.0** | 4 | Skip days / vacation — gated on a 426 floor ≥ 1.3.1 retiring the ≤1.3.0 cohort (M0's counters say when) |

≈ 27.5 developer-weeks + ~3 weeks of release mechanics. **M0 + M1 + M2 (~12.5 weeks) is the
committed phase.** M3–M6 are planned to the same level of detail so the next session can
continue without re-planning; their order can change on what the field shows. Milestones are
independently shippable. If M2 slips, nothing is started on top of it — M4 changes the numbers
on every screen and must land on a stable sync.

---

## M0 — Server contract, CI that sees the shipped half, ops footing (3 w, no App Review)

**Goal.** Land everything the incremental-push client will depend on (deployable today,
backward compatible with every shipped client), make CI able to catch the two classes of
release-blocking bug from 1.2.1/1.2.2 (extension not embedded; Info.plist key silently
dropped), and put backups and monitoring on a footing that does not depend on one laptop
being awake.

**Server** (`server/`, deployed per `server/DEPLOY.md` with the prod-copy rehearsal — that
rehearsal is what caught 1.2.3's NULL `updated_at`):

- `routes/sync.js` push response becomes `{ok, applied:{habits,entries,groups},
  skipped:{habits:[],entries:[],groups:[]}}`, collecting the ids dropped by the tombstone /
  unknown-habit / missing-field branches. `APIClient.OKResponse` decodes only `ok`, so it is
  additive. **This turns the one silent-drop path from "harmless" into "visible" once clients
  stop re-sending everything.**
- Pull response gains `totals: {habits, entries, groups}` — the row counts the server holds
  for the account — so a client can tell a complete full pull from a truncated one before it
  deletes anything (see M2's deletion rule).
- Hoist the per-entry `db.prepare('SELECT id FROM habits …')` (sync.js ≈ :271) into one Set of
  the user's habit ids per push; skip `refeedMismatchedEntry` when the upsert changed the row.
- Log per-request row counts through `logger.js` (no `mode` field: a client that chunks
  "everything dirty" cannot honestly label a chunk, and the counts say the same thing).
- **Pause switch, not a snapshot switch.** An env var read at request time makes every
  `/v1/sync/*` request answer `503 {error:'sync_paused', retryAfterSeconds}`; 1.3.1+ clients
  back off with jitter and show "sync paused" inline. A per-account
  `409 {error:'snapshot_required'}` exists for support use on one account at a time — never as
  a global flag, which would make every client upload its whole history at once.
- Rate limiting: key the sync limiter by `req.user.id` (`requireUser` already precedes it) at
  60/min; exempt `/v1/sync` from the global 100-per-15-min per-IP limiter; explicit array caps
  (5,000 entries / 500 habits / 200 groups per request → 400 with a message, not a bare 413).
- **Tombstones are no longer swept** (`db.js` `tombstoneRetentionDays` → effectively
  unlimited) until a 426 minimum-version floor **≥ 1.3.1** has retired the ≤1.3.0 cohort.
  A shipped client that pulls past the retention window has no handler for `cursor_expired`
  and would resurrect whatever was swept on its next snapshot push; tombstone rows are ~100 B,
  so the cost of keeping them is nothing. Once the floor exists, retention returns to 365 d.
  *(Amended 2026-09-28: this said ≤1.2.3. 1.3.0 also pushes a full snapshot on every sync and
  has no `cursor_expired` handler — the server gates that 409 on ≥ 1.3.1 — so it is in the
  cohort too. Account-level usage data cannot prove the cohort gone: one account with an
  active 1.3.1 phone can own a dormant 1.3.0 iPad. The floor itself, which answers that iPad
  426 when it wakes, is what makes sweeping safe; the counters only say when raising it
  strands few enough people.)* Pull:
  `409 {error:'cursor_expired'}` for `since` older than retention − 10 d, **only for requests
  carrying `X-Stride-Client` ≥ 1.3.1**. Test both branches.
- `auth.js`: sliding sessions — in `getSessionUserFromHeader`, when `expires_at − now < 15 d`,
  extend to `now + 30 d`, at most one UPDATE per session per day (this is the hottest
  authenticated path). Tests at day 29 / 31 / 44. Removes the silent day-30 logout that today
  surfaces only as a red Settings footer.
- `GET /.well-known/apple-app-site-association` served as `application/json`
  (`{applinks:{details:[{appIDs:['KHMK6Q3L3K.yyh.stride.habittracker'],
  components:[{'/':'/login','?':{token:'*'}}]}]}}`), no redirect, no auth, with a test — the
  server half of M1's one-tap sign-in, deployed early because Apple's CDN caches it for hours.
- Observability: log `X-Stride-Client` (clients send it from 1.3.0); hourly in-process counters
  for `field()` snake_case fallbacks (16 call sites), habits arriving without `kind` (the 1.1
  field-wipe population, never measured), and hits on the legacy `/sync`, `/auth`, `/habits`
  mounts. **These counters decide when the shim, the aliases, the 426 floor and tombstone
  sweeping can return** — not a date.
- Tests (`test/api.test.js`): entries-only push leaves other rows' `updated_at` untouched;
  entry for an unknown habit → 200 with `skipped.entries` containing the id; identical chunk
  re-sent → no `updated_at` change; **a full-snapshot push shaped like 1.2.3 (optional fields
  omitted, whole-second timestamps) after an incremental push bumps nothing** — the
  mixed-fleet contract; **a 1.2.3-shaped snapshot and a 1.3.1 incremental push for the same
  entry interleaved in the same transaction window resolve by `client_updated_at`** (the race
  the reviewers asked for); habits-then-entries two-request sequence → full pull returns all;
  `totals` match the arrays; per-user limiter; pause switch; cursor_expired gated on the
  header; sliding sessions; AASA route.
- Ops: commit `server/backup.sh` (on the host, not in the repo; DEPLOY.md excludes it from
  rsync); nightly on-host restore drill (restore the latest backup to a temp file, `PRAGMA
  integrity_check`, row counts, non-zero exit → Sentry message); an external uptime check on
  `/health` with alerting; an Azure VM snapshot so the offsite tier is not only one Mac's
  `~/Library`; a weekly on-host cron that re-seeds the demo account (it decays within days —
  the release record says "re-seed if review slips"); verify SPF/DKIM/DMARC for
  `stride.colorarchive.me` (DKIM present; root DMARC is `p=none`) since sign-in depends on an
  email arriving.
- **Owner action, not code:** wipe `stride.db` on the retired DigitalOcean droplet
  (`143.198.85.72`, DEPLOY.md:4-7). It still holds user emails and habit content.

**CI and project** (`.github/workflows/ci.yml`, `project.yml`):

- `ios-build` job: `xcodebuild build -scheme Stride -destination generic/platform=iOS
  CODE_SIGNING_ALLOWED=NO` (a device destination needs no simulator runtime), then assert
  `PlugIns/StrideWidgetExtension.appex` and `PrivacyInfo.xcprivacy` exist in the .app and the
  .appex. Budget a day: if the runner image cannot do it, the pre-push hook below is the gate.
- **Pin CI to the Xcode major that ships.** Releases go out from Xcode 27; CI on Xcode 16
  proves little. Use the newest macOS runner image that carries it; if none does, run the
  same jobs in a local pre-push hook and let CI keep only what it can do honestly.
- `npm run typecheck` (the script exists and has never run in CI); `xcodegen generate && git
  diff --exit-code Stride.xcodeproj`; extend the branch filter to `release/**`.
- `scripts/verify_archive.sh`, called by `ship.sh` before upload: assert the appex, both
  privacy manifests, `CFBundleDisplayName`, and — from M1 — the associated-domains
  entitlement, in the archive that is actually being shipped. CI cannot see the machine that
  ships. *(As built in M0: `build-appstore.sh` calls it after each archive and again on the
  export with `--exported` — the archive is Development-signed, so entitlements are asserted on
  the Distribution-signed app that is uploaded — and uploads nothing until every requested
  platform has passed.)*
- A **hosted test target** `StrideAppTests` (TEST_HOST = Stride.app) so `StoreService`,
  `SyncService.sync` ordering, `APIClient` (401 → nil token; header; decode of
  `applied/skipped`), `NotificationService` trigger planning and `AuthService` become
  testable. It runs on a simulator **locally, as a `ship.sh` gate** — hosted tests cannot run
  on a generic destination, so CI keeps the host-less `StrideTests` on macOS. Budget for the
  singletons: `StoreService`/`SyncService` are tightly coupled; test through injected
  `APIClient`/`Product` seams rather than mocking everything.
- `project.yml`: add `Stride/PrivacyInfo.xcprivacy` to `StrideWidgetExtension` sources (the
  shipped appex reads app-group UserDefaults and declares nothing); wire
  `Stride/Configuration.storekit` into the Stride and StrideMac schemes' run action (the file
  has all three products since `7fad788`); **remove the StrideWatch target** (never embedded —
  no Embed Watch Content phase, absent from the 1.2.3 archive, no data path, never sold; it
  costs build time and every a11y/l10n pass). Keep `StrideWatch/` in git history; record the
  decision in RELEASE-1.3.0.md.
- Repo hygiene: `.gitignore` or commit the eight untracked root files; add `README.md`
  (targets, the `Shared/` rule, scripts, release procedure pointers). (`NEXT_SESSION_PROMPT.md`,
  which carried the ASC key and issuer ids, was rewritten without them on 2026-09-24.)
- ASC check, no code: whether Monthly/Yearly carry introductory offers in App Store Connect
  (`Configuration.storekit` and `scripts/setup_iap.py` say $0.99 / $9.99; the paywall shows
  only `displayPrice` — a Guideline 3.1.2 exposure). Decide: remove the offers in ASC, or
  ship the disclosure line in M1.

**Acceptance.** (1) `cd server && npm test` ≥ 320 tests green. (2) Against production after
deploy: a push with one entry whose habitId is unknown returns
`{"ok":true,"applied":{…},"skipped":{"entries":["<id>"]}}`; a full pull carries `totals`
equal to the array lengths; `GET /v1/sync/pull?since=<400 days ago>` with `X-Stride-Client:
ios/1.3.1(19)` returns 409 and without the header returns 200; a 20-day-old session's
`expires_at` extends (visible in sqlite); `curl -sI …/.well-known/apple-app-site-association`
returns 200 `application/json`. (3) A PR shows the new jobs green; a scratch branch that
sets the widget dependency to `embed: false` in `project.yml` (deleting `embed: true` is a
no-op in XcodeGen 2.45.3) turns `ios-build` (or the pre-push hook) red.
(4) `scripts/check_demo_account.sh` green; the re-seed cron run once by hand leaves it green.
(5) The restore-drill log shows `integrity_check: ok` with row counts; stopping the pm2
process for two minutes triggers the uptime alert once. (6) `git status` clean at the repo
root; `grep StrideWatch project.yml` empty.

---

## M1 — 1.3.0: correctness, the reminder fix, the large widget, backup, one-tap sign-in (4 w)

**Goal.** A release that cannot corrupt anyone's data, which (a) stops rendering "1 days" /
"1 check-ins" / "Racha de 1 días" and the untranslated "weeks", (b) makes the 8–10 pt chart
text scale with Dynamic Type, (c) fixes the verified "reminders don't fire" and "the widget is
stuck" paths, (d) ships the one cheap feature that closes a dead end (the large widget),
(e) **gives every user a restorable backup before M2 changes the sync engine underneath
them**, (f) makes sign-in one tap, and (g) proves the M0 CI jobs and rehearsal scripts on a
release that does not touch the schema.

- **Plural rules.** `Localizable.stringsdict` in a new `Shared/en.lproj` (there is no en.lproj
  today; English is the key) and in es (CJK/Korean get a single `other` form so
  `testEveryLanguageHasTheSameKeys` still holds) for: `%lld day streak`, `%lld week streak`,
  `%lld check-ins`, `%lld remaining`, `%lld more habits`, `%lld of %lld habits completed`
  (+ `, %lld percent`), `🔥 All %lld habits done!`, `🏃 %lld/%lld habits done`, `%@, %lld
  habits`, `%@ %@: %lld day|week streak` (Siri), `Active Habits (%lld)`, `Archived (%lld)`.
  Verify plural lookup through `LanguageManager.bundle` on a device in es and ja; if
  `String(localized:bundle:)` skips stringsdict, route `appLocalized` through
  `NSLocalizedString(_:tableName:bundle:)`. (Migrating the five `.strings` files to an
  `.xcstrings` String Catalog is the better long-term shape and is compatible with the
  per-lproj bundle lookup; do it here if it fits, otherwise in M3.)
- **The missing `weeks` key.** `StatsView.swift` (:237, :251) shows `Text("weeks")` for
  times-per-week habits; the literal exists in none of the five catalogs, so English leaks
  into every language. Replace with a count-bearing key and add it everywhere.
- **Source-scanning localization test.** `StrideTests/LocalizationSourceScanTests.swift`
  reads `Stride/Sources` and `StrideWidget/Sources` via `#filePath`, extracts literal keys from
  `Text/Label/Button/Section/navigationTitle/accessibilityLabel/accessibilityHint/appLocalized`,
  and asserts each exists in ja. It is a regex over source and will miss multi-line and
  computed keys — that is acceptable: it exists to catch the `weeks` class (a plain literal
  with no entry), which is the class that shipped. Build the key list with the
  Mirror-on-LocalizedStringKey method from RELEASE-1.2.3.md, not `-exportLocalizations`.
- **Dynamic Type.** Replace the fixed 8–10 pt fonts (`StatsView.swift` :376, :382, :510, :522,
  :583, :619, :628; `SettingsView.swift` :304; `StoreService.swift` :427) with `.caption2` /
  `Font.system(size:relativeTo:)`; heatmap cell, legend swatch and weekday-column geometry via
  `@ScaledMetric`, **with a breakpoint: at accessibility sizes the 12-week grid becomes a
  horizontally scrolling strip** rather than overflowing the screen; decorative 50–72 pt
  symbols `relativeTo: .largeTitle` capped at `.accessibility2`. `ShareStreakView` (a rendered
  image) stays fixed by design. `scripts/a11y_sweep.sh`: boot the shared iPhone 17 Pro, set
  `content_size accessibility-extra-extra-extra-large`, launch with `-demo` on each tab plus
  the paywall, capture PNGs to `build/a11y/`, restore. A review artefact per release.
  *(Amended after M1: on iPhone 17 Pro Max, the screenshot device — the Pro is held by hosted
  test runs; and Stats is captured five times through a DEBUG-only `-statsScrollTo`, because
  the charts this item makes scale start two screens down and a top-of-screen capture proved
  nothing about them.)*
- **Reminders on a fresh install.** `AddHabitView.createHabit` / `updateHabit` call
  `NotificationService.shared.requestPermission()` before `scheduleHabitReminder` — the only
  caller today is the Settings "Daily Reminder" toggle, so a per-habit reminder enabled from
  the New Habit sheet on a fresh install is queued under `.notDetermined` and never
  delivered. On denial, show the footer Settings already uses.
- **Large widget.** `.systemLarge` (and `.systemExtraLarge`, iPad/Mac) in
  `supportedFamilies`; up to 8–10 rows with the same `Button(intent: ToggleHabitIntent)`; the
  medium widget's `+N more` stays only on medium. *(Amended after M1: large keeps `+N more`
  too, as the last of its rows — a list that silently stops at eight looks complete, so a ninth
  habit reads as lost; the line replaces the last row rather than adding one, because a line
  past the fixed height is clipped, and at large text sizes that would be the `+N more` itself.
  See `WidgetTimelinePlan.visibleRows`.)* `.invalidatableContent()` on the check icon
  and `Toggle(isOn:intent:)` for binary rows. **Rollover:** `Shared/WidgetTimelinePlan.swift`
  (pure; takes a `now: Date` so tests are deterministic) yields `[entry(now),
  entry(localMidnight)]` where the midnight entry's rows use `isCompletedOn(tomorrow)` /
  `currentStreak(from: tomorrow)`, policy `.after(midnight + 1 h)` as the safety net;
  `WidgetTimelinePlanTests` covers the `America/New_York` 2026-11-01 DST boundary. macOS
  desktop widgets are out of scope (Sonoma's tinted/desktop rendering is its own work).
- **Lossless export v2 + restore** (free; `Stride/Sources/Services/DataExportService.swift`
  and a new `Shared/DataBackup.swift` with pure parsers so StrideTests cover them). JSON
  `{schemaVersion: 2, exportedAt, groups[], habits[{every v2 field, records[{date, value,
  note}]}]}`; CSV gains value/target/unit/schedule columns; both serialisations move out of
  `SettingsView`'s body (:455-456 runs both on every render) into the `ShareLink` item
  closures. **Restore:** Settings → "Restore from backup…" (`.fileImporter`) accepts a v2 JSON
  **into an empty store only** (fresh install / after "Erase local data"), with a preview
  ("6 habits, 133 check-ins") and confirmation; it inserts through `mainContext` with
  `touch()` so the next push carries it. *(Amended after M1: restore keeps the backup's ids,
  `createdAt` and `updatedAt` and never calls `touch()`. New ids would duplicate every habit
  the moment the device signs back into the account that still holds the originals; a fresh
  `updatedAt` would make a months-old backup win every last-write-wins conflict against edits
  other devices made since. Nothing needs the stamp to be uploaded: 1.3.0 pushes the whole
  store on every sync, and M2 treats never-acknowledged rows as dirty. Records also carry `id`
  and `updatedAt`. Restore withdraws queued deletions of the ids it brings back; ids the
  server has already tombstoned come back only until the first full pull — M2, below.)*
  Merge-import into a populated store is M6+ (it must
  obey the sync rules M2 introduces). Round-trip test: export → restore into an empty store
  → identical habits, records, values, notes, groups, and the same record→habit linkage
  counts (not just decodable JSON).
- **One-tap sign-in as a universal link** (the server half is M0's AASA route). Not a custom
  scheme: any installed app can claim `stride://` and receive the token. `Stride.entitlements`
  / `StrideMac.entitlements` add `com.apple.developer.associated-domains =
  applinks:stride-api.colorarchive.me` (an entitlement, not an Info.plist key —
  `GENERATE_INFOPLIST_FILE` silently drops custom plist keys, the SentryDSN casualty);
  `StrideApp` `.onOpenURL` parses `?token=` and calls `AuthService.verifyToken`;
  `verify_archive.sh` asserts the entitlement. **`/login` keeps the copy-paste fallback
  forever:** in-app mail browsers and Gmail's link proxy never fire universal links, and
  Apple's CDN caches the AASA for hours. Test with Apple Mail and Gmail on a device before
  shipping; if it does not fire in either, the page is still what it is today.
- **Small verified items:** `ShareStreakView.swift` :27-28 render once in `.task` instead of
  twice per render; `WeeklyReviewView` empty state when `habits.isEmpty` and hide the Stats
  toolbar button then; remove the dead `AnalyticsService` call sites, the Settings analytics
  toggle and the `ProductInteraction` entry in `Stride/PrivacyInfo.xcprivacy` (the appID is a
  placeholder — the declared collection never happens); the paywall computes the SAVE badge
  from the real yearly-vs-12×monthly prices (the M0 ASC check found **no introductory offers**
  on Monthly or Yearly, so no intro-offer disclosure line is needed; `Configuration.storekit`
  and `setup_iap.py` were aligned in M0); `APIClient` sends
  `X-Stride-Client: ios|macos/<version>(<build>)` and — because the server answers a client
  that sends the header with the machine code in `error` — decodes `{error, code?, message?}`,
  shows `message ?? error`, and matches behaviour on `code` (`sync_paused`, `rate_limited`,
  …) so 1.3.0 never prints a raw code in the Settings footer.
- **Metadata.** `description.txt` widget sentence in all six locales → "small, medium and
  large on the Home Screen", edited in this submission only and pushed with
  `scripts/push_metadata.py`. What's New: text fixes in every language, large widget, larger
  text sizes, reminder fix, backup and restore, one-tap sign-in.

**Acceptance.** (1) Simulator in English with one habit and one check-in: Settings "1
check-in", Today "1 day streak", medium widget "1 remaining"; Spanish "Racha de 1 día"; no
screen renders "1 days" / "1 hábitos". *(Amended after M1: "1 remaining" is on the **small and
large** widgets — `HabitEntry.statusText` is drawn only there; the medium widget has no status
line — and it needs a habit not yet done today, since with the one habit done the line reads
"All done! 🎉". `simctl` cannot place a widget, so this part is a device or widget-preview
check.)* (2) Japanese, a times-per-week habit: the Stats card
shows the translated unit beside both streak tiles. (3) Adding `Text("Zzz test")` to any view
fails `LocalizationSourceScanTests`; removing it passes. (4) `a11y_sweep.sh` PNGs at
accessibility-XXXL show scaled chart labels, a scrolling heatmap strip, and no truncated Today
row. (5) Fresh install: New Habit → Reminder on → Save shows the system prompt before the
sheet dismisses. (6) Widget gallery offers Large (and Extra Large on iPad) listing ≥ 8
habits; `WidgetTimelinePlanTests` proves the midnight entry deterministically; a manual
overnight check on a device confirms the flip. (7) Store screenshots at default text size
show no layout change (diff with a small tolerance — sub-pixel text rendering may move).
(8) Export JSON → erase → Restore reproduces every habit, target, schedule, note and record.
(9) Request a login link on a device and tap it in Apple Mail → the app foregrounds signed
in, no paste; the archived Info.plist carries the entitlement. (10) StrideTests ≥ 160, CI
green, `check_demo_account.sh` green. (11) No new interruptive UI.

---

## M2 — 1.3.1: incremental push, cursor expiry, account isolation (5.5 w, provisional) (revised 2026-09-28 after the Codex / Gemini 3.8 Flash review — see RELEASE-1.3.0.md)

**Goal.** Replace the full-snapshot push with per-row acknowledgement, chunked and
acknowledged per chunk, with the reconciler, cursor and account rules that make it safe for a
fleet that will contain ≤1.3.0 snapshot clients for months — 1.3.0 still pushes its whole store
on every sync and has no `cursor_expired` handler, exactly like 1.2.3. This is the hardest
milestone in the plan; both reviewers called the first estimate a fantasy, and it is scheduled
alone.

**The 2026-09-28 revision.** Two external reviews of this design (Codex; Gemini 3.8 Flash) were
fact-checked against the code before anything was adopted — where a reviewer and the code
disagreed, the code won (RELEASE-1.3.0.md, "After submission — external review and the
owner's decisions"). The owner adopted eight changes; each is marked *(revised)* where it
lands below:

1. Account switch offers only "start from this account's data"; every sync trigger is blocked
   until the choice is made; cursors, acknowledgements and the deletion queue belong to one
   account.
2. Delivery state is three things, not a boolean: acknowledged (`syncedAt`), held
   (quarantine), forced resend.
3. A delete from another device still wins over an offline edit here, but the edit goes to a
   recoverable on-device log instead of only a log line.
4. Millisecond edit stamps for clients ≥ 1.3.1.
5. Chunks bounded by encoded bytes as well as rows, deletion ids included.
6. One rule per push answer instead of 400 bisection.
7. The retirement cohort is ≤ 1.3.0, and the 426 floor must be ≥ 1.3.1 before tombstones are
   swept.
8. A restore into a different account (and a restore the server has tombstoned) becomes new
   copies, on the user's choice.

A second Codex pass over this revision (the same day) raised ten gaps; each was checked
against the code before it was folded in, and each fix is marked *(review 2)* where it lands:
a sync run bound to one account across its awaited chunks; `syncedAt` records the stamp that
was sent even when an edit landed in flight; the local-newer guard compares milliseconds, and a
record's stamp is `updatedAt ?? date`; a forced resend runs only after a pull has settled
deletions; restored rows are protected on every deletion path; restore-as-copies while signed
in takes that account as owner, and held rows are converted by their own operation; affected
descendants, held rows and groups are archived, and the archive is on disk before anything is
deleted; the full-pull deletion pass needs a validated snapshot, not only matching counts; the
LWW winner is re-fed to the device that lost; and acknowledged ids are derived from the
submitted ids, because `applied` holds counts.

**Sub-decisions taken 2026-09-28** (under the owner's adopted revisions; overrule here if wanted):
(a) A held row whose lifting edit is later answered `tombstoned` (deleted on another device
meanwhile) goes to the recovery archive and is deleted locally — delete wins, nothing is lost.
(b) Migrated rows: on the first 1.3.1 launch, once, rows whose `updatedAt` is at least 5 minutes
older than the last successful 1.3.0 sync are marked acknowledged (every successful 1.3.0 sync
pushed them in a full snapshot); newer rows stay never-acknowledged and are pushed. (c) The
server's LWW re-feed (bump `updated_at` when the stored edit is strictly newer and the values
differ, so a device whose older edit lost gets the winner even behind its cursor) is part of
the 1.3.1 server work, deployed before submission with the header-gated millisecond pull.
(d) A full pull that fails snapshot validation (totals or ids) still applies its upserts —
they are LWW-safe — and skips only the deletion pass. (e) A device with no recorded owner
(1.3.0 records none) that has local rows is offered BOTH "upload this device's habits to this
account" and "start from this account's data": local-only users must be able to start syncing
the data they have; only a device with a known, different owner is restricted to start-fresh.

**The safe core ships together in 1.3.1:** the delivery state, the chunked push, the per-answer
rules, account isolation, the millisecond stamp, the `cursor_expired` handler, the reauth row,
and the full-pull deletion rule with its recovery log and restore-as-copies — and on the
server, deployed first, the millisecond pull and the LWW re-feed *(review 2)*. None is safe
alone: incremental push without account isolation uploads the previous account's never-pushed
rows; the deletion rule without the held state deletes quarantined rows; a hold without
restore-as-copies leaves rows nobody can resolve. Only optional UX may move to a later 1.3.x:
the sync-status line on Today, a browsable "Recovered edits" list (its JSON export stays in
1.3.1), and per-row sync diagnostics beyond counts and reasons.

**Estimate — provisional.** 5.5 w is a guess until the first vertical slice exists: the
real-store migration test plus `sync_rehearsal.sh` running two devices on one account through
the delivery state, the planner and per-chunk acknowledgement. Build that first, re-estimate
from what it took, and record the new number in the progress log before building the rest.

**Design** (from the sync-architecture research; the verified state is `SyncService.pushLocal`
serialising every row on every sync, and the server's value-based two-clock guard from 1.2.3
that makes a mixed fleet safe):

- **Delivery state, not a boolean** *(revised)*. Local-only fields on `Habit`, `HabitRecord`
  and `HabitGroup`, all optional or defaulted (lightweight migration, the same shape as the
  existing `updatedAt` addition); none goes on the wire. A row's **stamp** is
  `updatedAt ?? createdAt` for habits and groups, and `updatedAt ?? date` for records
  *(review 2)*: `HabitRecord` has no `createdAt`, and the push already sends `record.date` in
  its place (`SyncService.swift` :174-175).
  - `syncedAt: Date?` — the stamp the server last acknowledged. It is the evidence that the
    row was delivered at least once: written only by an acknowledgement or by applying remote
    state, and cleared by nothing — not sign-out, not re-login, not a forced resend. Only
    erasing the row removes it.
  - `syncHoldReason: String?` + `syncHoldStamp: Date?` — quarantine. A row is **held** iff
    `syncHoldStamp == stamp`, so an edit (a new stamp) lifts the hold by itself and no mutation
    site has to know about holds. Reasons: `missing_field`, `row_error`, `invalid_value`,
    `unknown_habit`, `not_owned`, `too_large`, and `tombstoned` for restored rows (below).
  - `needsResend: Bool = false` — forced resend (`409 snapshot_required`, Settings → "Full
    resync"). The row is sent again, but only after a pull has settled deletions ("Forced
    resend", below); its `syncedAt` stays.
  - `restoredAt: Date?` — set by a restore that keeps the backup's ids; cleared on the row's
    first acknowledgement. While it is set, no pull deletes the row (Reconciler, below).

  A row is **pending** (sent on the next push) iff it is not held and (`needsResend` or
  `syncedAt != stamp`) — **inequality, not ordering**, so a clock step backwards cannot strand
  edits. No mutation site changes: every edit already calls `touch()` (the 1.2.3 LWW fix
  depends on that). Why three states: the first draft quarantined a bad row *by acknowledging
  it*, and its full-pull rule deletes acknowledged rows the server lacks — so the next full
  pull would have deleted every quarantined row. It also reset `syncedAt = nil` on re-login,
  which made "delivered, then deleted on another device" indistinguishable from "never
  uploaded": harmless while tombstones are kept forever (the re-push is answered
  `tombstoned`), a resurrection path the day sweeping returns. **Migration test:** a populated
  store copied from a real device (Xcode → Devices → download container; 1.3.0 changed no
  model, so a 1.2.3 or 1.3.0 container is the same schema) opens under the 1.3.1 schema in a
  test before submission; fresh simulators prove nothing about live stores.
  **Migrated rows** *(found while applying review 2; the same resurrection path as the forced
  resend below)*: every row of a 1.3.0 store opens with `syncedAt == nil`, "never delivered",
  which a full pull keeps and the next push re-sends. Harmless while tombstones are kept (the
  answer is `tombstoned`), but the device the 426 floor forces to update is exactly the dormant
  one whose deletions have been swept. So the first 1.3.1 launch, once, sets `syncedAt = stamp`
  on every row whose stamp is at least 5 min before 1.3.0's `stride_last_sync_time`, when the
  store has one: 1.3.0 wrote that key only after a full snapshot went up and the pull came
  back, and the same device clock stamped both. Later rows stay pending (a re-send is harmless).
  A 1.3.0 device that signed out cleared the key, so its rows stay "never delivered", and the
  owner-unknown screen below decides them.
- **Millisecond edit stamps from 1.3.1** *(revised)*. The app sends whole seconds
  (`SyncTimestamp.string`) and the server's guard is `excluded.client_updated_at >= stored`
  plus a values-differ check (`routes/sync.js` :385, :408, :431), so two different edits of
  one row in the same second resolve by push order, not by which was made later. From 1.3.1:
  - `touch()` stores `updatedAt` floored to the whole millisecond, so the store and the wire
    hold the same number and an acknowledgement or an echo compares equal (a sub-millisecond
    `Date` never equals what comes back);
  - the app sends `createdAt` / `updatedAt` with three fractional digits
    (`SyncTimestamp.parse` already reads both forms);
  - the server keeps accepting whole seconds from older apps — `isoOrNull` stores them through
    `toISOString()` as `.000Z`, fixed width, so the string comparison stays chronological;
  - pull serves milliseconds **only when `clientAtLeast(req, "1.3.1")`**; without the header,
    and to 1.3.0, it keeps `wireTime()`'s whole seconds, because header-less apps parse with a
    default `ISO8601DateFormatter` that returns nil on a fraction (the demo account's "created
    today" incident). One branch in the pull serialiser, deployed before submission.

  The pull must carry milliseconds for 1.3.1 too, not only the push: served truncated, a
  remote edit at :18.700 arrives as :18.000, a local edit at :18.300 looks newer to the
  local-newer guard, is kept and pushed; the server keeps :18.700, reports the push `applied`
  (the LWW guard kept its row), the device acknowledges — and shows the losing value until the
  row changes again. Documented limit: an older app's edit is only as precise as its string —
  1.2.3's :18.900 is stored as :18.000 and loses to 1.3.1's :18.400.
- `Shared/SyncPushPlanner.swift` (pure; in `Shared/` so the host-less tests run the real
  code — the move that fixed the reconciler in `72ccb74`). `HabitRecord` has no `habitId` and
  `Habit.records` has no inverse, so the planner walks each habit's records; fine at these
  sizes. **Chunks are bounded by rows and by bytes** *(revised)*: ≤ 200 groups / ≤ 500 habits /
  ≤ 2,000 entries **and ≤ 1 MB of encoded JSON** per request, measured with the encoder that
  sends it, deletion ids included. The server caps rows only: deletion lists are uncapped
  (deleting a multi-year habit queues one id per check-in) and bounded only by the 5 MB body,
  and neither the server nor the app bounds a note — 2,000 entries with multi-KB notes, or a
  big deletion queue, would 413. Order: queued deletions, then pending groups, habits,
  entries; a chunk closes when the next item would pass any bound, and the next chunk carries
  on from there. Chunks go in sequence, so a habit always lands before its entries (the server
  skips an entry whose habit it does not have yet). An item that alone exceeds 1 MB goes in a
  chunk by itself; one whose encoding exceeds 4.5 MB (the body limit less the envelope) is
  never sent — held `too_large` and reported. If chunk k fails, later chunks do not run: the
  server holds new habits without their history until the next sync — peers see fewer entries
  temporarily, which the reconciler already tolerates. The planner never sends a held row, nor
  the entries of a held habit. **Acknowledge per chunk** *(review 2)*. The acknowledged ids are
  the chunk's submitted ids (canonicalised, de-duplicated) minus every id in the response's
  `skipped`: `applied` holds counts per type, not ids (`routes/sync.js` :464, :628). For each,
  set `syncedAt` to the stamp that was **sent**, even when the row has been edited since. The
  edit's new stamp differs from it, so the row stays pending under the inequality rule, and
  the row keeps its evidence of delivery. The first draft wrote nothing on a mismatch, which left
  a first upload edited in flight at `syncedAt == nil` ("never delivered"). The full-pull rule
  keeps such a row and re-pushes it, so once sweeping returns, a row another device deleted
  would come back. Clear `needsResend` and `restoredAt` on the same rows.
  `SyncDeletionQueue.acknowledge` only the delivered deletion ids.
- **One rule per push answer** *(revised — replaces the 400-bisection poison-pill guard)*. The
  server answers a bad *row* with 200 and a `skippedReasons` entry (SQLite errors are caught
  per row as `row_error`); its only push 400s are envelope errors, `invalid_payload` (a field
  that is not an array) and `too_many_rows` (over the row caps) — `routes/sync.js` :322, :337.
  Bisecting a 400 chunk therefore never isolates a bad row: it splits a malformed envelope
  down to single rows and then quarantines good data. Instead:

  | Answer | The app does |
  |---|---|
  | 200, id sent and not in `skipped` | Acknowledge it (above). |
  | `tombstoned` / `tombstoned_habit` | Drop the row locally (delete wins); a pending row goes to the recovery log first. A row carrying `restoredAt` is held `tombstoned` instead, for the restore-as-copies choice. |
  | `missing_field` / `row_error` / `invalid_value` | Hold with that reason: kept locally, never acknowledged, never re-sent until edited, never deleted by a full pull, counted in sync diagnostics, reported to Sentry once. |
  | `unknown_habit` / `skipped_habit` | Stay pending and retry next sync (the habit's chunk may not have landed). An entry still `unknown_habit` three syncs after its habit was acknowledged is held and reported. |
  | `not_owned` / `not_owned_habit` | Hold `not_owned` — never acknowledge (the full-pull rule would then delete it), never drop. With account isolation only two paths reach this: a restore that kept another account's ids, and a device whose owner was unknown (below). Settings offers "Restore as new copies". |
  | 400 `too_many_rows` | A planner bug: re-chunk against the returned `limits` and resend in the same sync; a second one is handled as `invalid_payload`. |
  | 400 `invalid_payload` | A client bug: report to Sentry, stop this sync, back off (doubling 1 min → 6 h, jittered; "Sync Now" retries at once). Rows stay pending; **nothing is held** — the rows are not what is wrong. |
  | 413 | A multi-row chunk: re-chunk at half the byte bound, once. A single-row chunk: hold that row `too_large`. |
  | 401 | `needsReauth` (below); stop. No state is reset. |
  | 409 `snapshot_required` | Support's server repair (the server lost rows this device still has). Mark every row `needsResend` (`syncedAt` and holds untouched), then pull and push in the order "Forced resend" sets out below: the resend goes up only after a pull on a live cursor *(review 2)*. One-shot per request; support re-arms it with `ops/request-snapshot.js` if a device lost it. |
  | 409 `cursor_expired` (pull) | Clear the cursor; full pull first, then push. |
  | 429 `rate_limited` / 503 `sync_paused` | Back off by `Retry-After` / `retryAfterSeconds`; "sync paused" inline; never `syncError`. |
  | Other 5xx, network | Jittered backoff; rows stay pending. |

  Today `APIClient` / `SyncService` have no retry at all. Sentry reports carry ids, reason
  codes, counts and the build — never names, notes or values.
- **Reconciler.** Wherever remote state is applied (habit update/insert, entry update/insert
  including the id-alignment path, group update/insert): set `syncedAt = updatedAt`, clear
  `needsResend` and any hold — otherwise the device's own push returns through the 60 s
  overlap, looks pending again, and every row echoes forever. Add the local-newer guard the
  entry branch has to the habit and group branches, and make all three compare **milliseconds**
  *(review 2)*: both stamps floored to the whole millisecond, and the local row is newer only
  if its stamp is strictly greater. Today's entry guard floors only the local side, to whole
  seconds (`SyncReconciler.swift` :142-144). That was right while the wire carried seconds and
  is wrong from 1.3.1: an edit at :18.700, made while this device's :18.300 push was in
  flight, floors to :18 and loses to its own echo. Rows older apps wrote arrive as `.000` and
  compare the same way.

  **Deletions** *(review 2)*. Every path by which a pull deletes a row does two things. The
  paths are the `deleted*Ids` passes, full-pull absence, and the cascade from a deleted habit
  to its records (`Habit.records` is `.cascade`).
  - It archives every affected row that is pending **or held** to the recovery log first. That
    includes a deleted habit's pending or held records, one by one: checking only the habit
    missed an offline edit to a check-in of a habit nobody touched.
  - It never deletes a row carrying `restoredAt`. It holds that row `tombstoned` instead, exactly
    as a push answered `tombstoned` does. An incremental pull can meet the tombstone before the
    push does (another device deleted the habit after this device's cursor, or inside the 60 s
    overlap); without this, the restore-as-copies choice would be decided by whichever request
    came back first.

  The reconciler saves once per pull, so a pull is one `didSave`, not thousands.
- **Full-pull deletion rule** *(revised; review 2)*. The deletion pass runs only on a snapshot
  that was **validated and applied whole**. `totals` equal to the arrays is necessary (a
  truncated body or a timed-out query must never purge the local store), but it is not enough.
  The reconciler silently skips several kinds of row:
  - an id that is not a UUID (`SyncReconciler.swift` :61, :130, :184);
  - an entry whose habit it cannot find (:132);
  - a date it cannot parse (:133).

  On top of that, the server accepts any non-empty string as an id (`routes/sync.js` :347-352),
  so two case variants of one UUID are two rows there and one row here. So before anything is
  mutated, the pull is checked: every id parses as a UUID and is unique per type after
  `canonicalID`, every entry's habit is in the response, every date parses, and there is one
  entry per habit and day.
  - If the check fails, or the reconciler skips any row, the upserts still apply but the
    deletion pass does not run. Sentry gets the ids and the reason, and support repairs the row,
    as with the `invalid_value` audit. Refusing the whole pull (Codex's suggestion) would stop
    the account syncing because of one bad server row, which is the failure the per-row push
    answers exist to avoid.
  - A reconcile that throws rolls the context back: nothing is saved and no cursor is written.

  Then a local row absent from a validated pull is:
  - **kept if held** — the server refused it, so of course it lacks it;
  - **kept if `syncedAt == nil`** — never delivered from this device, so a partially failed
    first upload or a restore followed by a full pull cannot delete it;
  - **otherwise deleted, `needsResend` or not** *(review 2)*: it was delivered and the server
    no longer has it, so another device deleted it. (The first revision kept `needsResend` rows
    here and let the resend's answer decide. That holds only while the tombstone exists to
    answer `tombstoned`; after a sweep, the resend is a new insert. See "Forced resend" below.)
    Delete wins even over an offline edit here, because "skip all pending rows" would resurrect
    deletions on a device whose cursor expired. The edit is not lost: every pending or held row
    the deletion takes, descendants included, goes to the recovery log first.
- **Forced resend waits until deletions are settled** *(review 2)*. Re-sending a delivered row
  the server lacks is safe only while its tombstone exists to answer `tombstoned`. Once
  sweeping returns (after the ≥ 1.3.1 floor, M0), the server treats it as a new insert, and a
  row another device deleted a year ago comes back. So a sync that holds any `needsResend` row
  **pulls before it pushes**, and it sends the resend only after that pull ran on a **live
  cursor**: within retention − 10 d, and not answered `cursor_expired`.
  - Why a live cursor makes the resend safe: a deletion older than retention reached this
    device before its cursor, either as a tombstone or, through a `cursor_expired` full pull,
    as absence. So a delivered row it still holds that the server lacks was lost by the server,
    not deleted elsewhere, and restoring it is the point of a resend.
  - With no cursor, or an expired one, the sync full-pulls first. The rule above then removes
    delivered-but-absent rows whatever their `needsResend`, archiving them, and the resend
    follows.

  Both entry points use this order:
  - **Settings → Full resync**: every row `needsResend`; pull on the current cursor, push, then
    clear the cursor, so the next sync full-pulls against the repaired server.
  - **`409 snapshot_required`**: support's repair. It is answered on a push or a pull
    (`routes/sync.js` :254-276); either way the device pulls again, and the flag is one-shot.
    On an expired cursor the repair is partial by design: what the full pull removed is in the
    recovery-log export, which support asks the user for.

  Until sweeping returns, both behave as they do today, because the tombstone still answers.
  Rows restored with their ids are the one deliberate exception: after a sweep, a restored row
  whose tombstone is gone is new to the server and is accepted. That is the user's own restore,
  not a background resend.
- **Recovery log** *(revised — was "the edit is lost and logged")*. `Shared/SyncRecoveryLog.swift`
  (pure encoding, so StrideTests cover it): an append-only JSON-lines file in the app's
  Application Support, one line per displaced row: `{archivedAt, reason: deleted_elsewhere |
  tombstoned, accountId, group | habit | record}` in `DataBackup`'s v2 item shapes.
  - A record carries its `habitId` and the habit's name, so it reads on its own.
  - A habit line holds the habit without its records; they get lines of their own, so one
    line is one row.
  - Groups are included *(review 2)*: an offline rename of a group deleted elsewhere is an edit
    too.

  Every path by which a delete reaches a pending **or held** row writes it: an incremental
  pull's `deleted*Ids`, full-pull absence, a habit's cascade to its records, and a push answered
  `tombstoned`.

  **On disk before the delete** *(review 2)*. The lines are appended and flushed
  (`FileHandle.synchronize()`) before the reconciler's `save()`. If the append fails (disk
  full, or file protection during M3's locked background sync), this pull's deletions are not
  applied: the context rolls back, no cursor is written, and the next sync retries.

  **Cap.** The file is capped at 5 MB; the oldest lines are dropped and a count of dropped lines
  is kept. The cap never drops lines from the pass being written: a pass that needs more than
  5 MB grows the file past the cap rather than lose its own rows. The next pass trims it.

  Settings → sync section → "Recovered edits (N)" → **Export as JSON** (`ShareLink`) and
  **Clear**. Local only: never uploaded, never in a Sentry payload (Sentry gets the count).
  Putting a recovered edit back is by hand in 1.3.1; merge-import (M6) can read the file.
- **Cursor age.** `SyncService.sync()` clears a cursor older than retention − 10 d locally and
  handles the server's `409 cursor_expired` the same way: full pull **first**, then push. This
  handler is what makes 1.3.1 the lowest version a 426 floor can allow once tombstones are
  swept again (M0; the Decisions table).
- **Account isolation — the data-leak fix** *(revised)*. Today "local data merges into
  whichever account signs in": User A signs out, User B signs in on the same device, and A's
  habits are pushed into B's account. The store gets an **owner** — the server user id
  (`APIUser.id`) whose data it holds, with that account's email for display — in
  `UserDefaults.standard`. **Invariant: a push or pull runs only while the signed-in account
  is the owner**, checked first in `SyncService.sync()`, so launch, foreground, Sync Now, the
  post-edit sync, pull-to-refresh and M3's background refresh are all blocked by construction
  until ownership is settled — not call site by call site. **The check holds for the whole
  run, not only its start** *(review 2)*. A chunked run spans many awaits, and a sign-out
  followed by a sign-in to B can land between two chunks.
  - Today only the pull is guarded (`ensureStillCurrent`). The push's `queue.acknowledge`
    (`SyncService.swift` :201-203) runs for whoever is signed in by then, and `APIClient` reads
    the token from the keychain on every request (:130), so a later chunk would carry A's rows
    on B's session.
  - So `sync()` captures the owner id, the session token and `stateGeneration` when it starts,
    and every request in the run uses the captured token.
  - The run re-checks all three before every request and after every `await`, before any
    acknowledgement, deletion-queue change, reconcile or cursor write. A mismatch ends the run
    as `SignedOutDuringSync` and acknowledges nothing.

  The cursor, the backoff state and the recovery log are stored with the owner;
  acknowledgement state lives on the owner's rows; none of it is ever read for another account.
  - **Same account again** (re-login after sign-out or `needsReauth`) → resume: rows keep
    `syncedAt` and holds, the cursor and the deletion queue are kept (sign-out no longer
    clears them; the `stateGeneration` guard for a sync in flight at sign-out stays), and
    nothing is re-uploaded. Re-login never resets rows to "never uploaded".
  - **Different account, something to lose** (rows, queued deletions, holds or recovery-log
    lines) → the sign-in the user just started continues with one screen: "This device holds
    habits from <owner email>." It offers **Export a backup** first (M1's v2 JSON, plus the
    recovery log if it has lines), then **Start from this account's data**: erase local rows
    (`DataBackup.eraseLocalData`), clear the deletion queue, cursor, backoff and recovery log,
    make the new account the owner, full pull. **Cancel** signs out of the new account and
    changes nothing. There is no "keep the habits on this device and add them to this account"
    in 1.3.1.
  - **Different account, nothing to lose** → switch silently.
  - **No owner** (a fresh 1.3.1 install, or a store erased empty while signed out) → the first
    account signed into adopts the local rows: the "use it without an account, sign in later"
    path, unchanged.
  - **Owner unknown** — a device that updates to 1.3.1 signed out with rows. 1.3.0 records no
    account and clears its cursor on sign-out, so those rows may be a previous account's or
    nobody's. At the next sign-in the same screen offers both "Upload these habits to this
    account" and "Start from this account's data" — the device cannot tell, so the user
    decides once; rows the server knows as another account's come back `not_owned` and are
    held, not deleted. A device signed in at its first 1.3.1 launch takes that account as
    owner (1.3.0's snapshots pushed its rows there).
  - `deleteAccount` erases local data and clears the owner.

  Why no keep-and-add: reactive `not_owned` handling cannot find all of the previous account's
  rows. The server answers `not_owned` only when the id already exists under another user
  (`routes/sync.js` :532, :567, :592); a habit account A created offline and never pushed does
  not exist there, so it would be applied into account B with no skip reason. The per-account
  cursor, acknowledgements and deletion queue follow from the same fact: an acknowledgement is
  true only for the account that gave it. A cross-account copy, if ever wanted, is a later,
  explicit, re-id-based feature — never a side effect of signing in. Settings gains **"Full
  resync"** as the user's escape hatch: every row `needsResend`, a pull on the current cursor,
  the push, then the cursor cleared (the order in "Forced resend" above). A snapshot is
  "everything pending", so it is one code path.
- **Restore into another account, and restores the server has tombstoned** *(revised)*. A 1.3.0
  restore keeps the backup's ids, so a backup made under account A, restored and then signed
  into account B, is skipped as `not_owned` and removed from the device by the first full pull
  (the file still has it — a 1.3.0 limitation, recorded in RELEASE-1.3.0.md). From 1.3.1:
  - a backup records the owner's `accountId` and `accountEmail` (optional fields;
    `schemaVersion` stays 2 and older restorers ignore them);
  - restore (still into an empty store only) keeps ids when the backup's account is the
    signed-in account — or, signed out, the account the user says this device will use next —
    and the device's owner becomes that account. Otherwise (another account, or a backup
    without an account, which is every 1.3.0 backup) it offers **Restore as new copies**: fresh
    UUIDs for habits, records and groups, `habit.groupId` remapped, every record on its own
    habit, `createdAt` / `updatedAt` kept, `syncedAt` nil. The store's owner becomes the
    signed-in account, since the user confirmed the copies into it; only a restore made while
    signed out leaves the store without an owner, for the next sign-in to adopt *(review 2)*.
    The first draft said "no owner" in both cases, and while signed in the owner gate would
    then have blocked every sync until a sign-in that never comes. Keeping the ids stays
    available for a 1.3.0 backup of this same account. If the backup was in fact another
    account's, the push answers `not_owned` and the rows are held with the same "Restore as new
    copies" action. They are held, so no full pull deletes them;
  - **converting held rows is its own operation** *(review 2)*, not `DataBackup.restore`, which
    refuses any store that is not empty (`storeNotEmpty`, `DataBackup.swift` :413). A
    `SyncCopies.reidentify` in Shared/ (pure over a context, so StrideTests cover it) re-ids
    rows in place, the way the reconciler's id alignment already does:
    - a held habit gets a fresh id together with all of its records;
    - a held group gets a fresh id, and its habits' `groupId` is remapped;
    - a held record whose habit is live gets a fresh id alone.

    It clears the hold and `restoredAt`, leaves `syncedAt` nil, and queues no deletion for the
    old ids (the tombstone, or the other account's row, stays as it is). It saves once.
    **Discard** deletes the held rows locally and queues nothing either;
  - a row restored with its ids carries `restoredAt`; a `tombstoned` / `tombstoned_habit`
    answer for it holds it instead of dropping it, and the sync section shows "N restored
    habits were deleted on another device" with **Restore as new copies** / **Discard** (the
    backup file keeps them either way). This is the product question RELEASE-1.3.0.md left
    open: a restore undoes another device's deletion only when the user says so, and then as
    new rows — the tombstone stays authoritative for the old id.
- **Sign-in that stays.** `AuthService.needsReauth` on 401 → an inline "Sign in again to keep
  syncing" row on Today (today the only signal is a red footer in Settings); pairs with M0's
  sliding sessions. Part of the safe core. **Sync status where the user works** (optional UX,
  may move to 1.3.2): one line under Today's progress card — "synced 2 min ago" / "offline —
  3 changes waiting" / "sync paused" — from the planner's pending count, plus held rows as
  "2 changes can't sync — see Settings".
- **The LWW winner goes back to the device that lost** *(review 2; the first revision listed
  this as a known limitation)*. A push the guard keeps as older counts as `applied`
  (`routes/sync.js` :97-99) and is acknowledged. The winner reaches the losing device only if
  its `updated_at` is after that device's cursor, and it is not in this case: the device pulled
  the winner, then made an edit that its slow clock stamped earlier. From then on the device
  shows its own value and the server keeps another, until the row changes again. The fact-check
  called the hole real but narrow (it needs two devices' clocks to disagree); narrow is not
  closed, and the fix is small.
  - **Server fix**, following the `refeedMismatchedEntry` precedent (:413-419): when an upsert
    changes nothing because the stored client stamp is **strictly newer and the values
    differ**, set that row's `updated_at = now`. The losing device's next pull then brings the
    winner, and its reconciler adopts it.
  - Both conditions are needed. Without "values differ", every 1.3.0 snapshot that echoes a
    1.3.1 millisecond stamp truncated to whole seconds (:18.000 < :18.700, same values) would
    re-feed that row on every sync, forever.
  - It is deployed with the millisecond pull, and it has a server test and a skewed-clock
    rehearsal case (below).
- **Known limitations, documented in the release record:** count-habit values merge by
  last-write-wins per entry, not additively — 3 glasses logged offline on the phone and 5 on
  the iPad resolve to whichever was edited later, not 8; additive merge is a later design.

**Tests.** `StrideTests/SyncPushPlannerTests.swift` (in-memory container, the
SyncReconcileTests pattern):
- *Plan:* fresh store → chunks with groups+habits+entries+deletions; after ack → empty plan;
  one touched record → exactly that entry and no habit; edit during an in-flight push → still
  pending after ack, with `syncedAt` = the stamp that was sent, including on a first upload
  *(review 2)*; the acknowledged set is the submitted ids minus `skipped`, whatever `applied`
  counts; pulled rows are not pending (the echo test at millisecond precision, at
  whole seconds for rows older apps wrote, and through the id-alignment path); pull kept a
  newer local value → still pending; clock step backwards → still pending; a partial payload
  still encodes all six arrays; a record with no `updatedAt` stamps as its `date`; a migrated
  1.3.0 store with `stride_last_sync_time` → rows stamped ≥ 5 min before it are delivered and
  later ones pending, and without the key all are pending.
- *Chunks:* 600 pending habits → two habit chunks; 2,500 entries → later chunks entries-only;
  2,000 entries with 2 KB notes → every chunk ≤ 1 MB encoded; 30,000 queued deletion ids →
  spread over chunks, only delivered ids acknowledged; a 2 MB row alone in its chunk; a 6 MB
  row held `too_large` and never planned; failure at chunk k → < k acknowledged, ≥ k pending,
  retry resumes at k.
- *Answers* (table-driven over the per-answer rule): every skip reason ends dropped, held or
  pending as the table says; a held row is not planned until edited, and an edit lifts the
  hold; entries of a held habit are not planned; `unknown_habit` is held after three syncs;
  `too_many_rows` re-chunks against `limits`; `invalid_payload` holds nothing, leaves rows
  pending, sets the backoff and files a Sentry report with no row content; 413 on a one-row
  chunk → `too_large`.
- *Delivery state:* `needsResend` (snapshot_required, Full resync) plans every row and leaves
  `syncedAt` as it was; re-login to the same account plans nothing and keeps the cursor;
  sign-out clears no `syncedAt`; a sync holding `needsResend` rows pulls before it pushes, and
  on an expired cursor full-pulls first, so a delivered-but-absent `needsResend` row is deleted
  (archived), not re-sent *(review 2)*.
- *Full-pull deletion:* aborts on a `totals` mismatch; keeps held and never-delivered rows;
  removes delivered-but-absent ones, `needsResend` or not; a pending or held one is in the
  recovery log before it goes, and so are a deleted habit's pending and held records one by one
  and an edited group, the same for an incremental `deleted*Ids`, a cascade and a push answered
  `tombstoned`. *(review 2)* A non-UUID id, two case variants of one id, an entry whose habit is
  missing, an unparsable date and two entries on one habit-day each apply the upserts and
  delete nothing; a reconcile that throws saves nothing; a failed recovery-log append deletes
  nothing and writes no cursor.
- *Timestamps:* `touch()` floors to the millisecond; the wire string parses back to the same
  `Date`; `SyncTimestamp.parse` still reads whole seconds; for habits, entries and groups, a
  local edit at :18.700 survives the :18.300 echo of its own push, and a remote :18.700 beats a
  local :18.300 *(review 2)*.
- *Restore:* a backup from another account → new copies with fresh ids and the same
  record→habit and habit→group linkage counts as the file; a 1.3.0 backup (no `accountId`)
  offers copies; a restored row answered `tombstoned` is held, and "Restore as new copies"
  plans it as new; a restored row answered `not_owned` is held and survives a full pull.
  *(review 2)* A restored row whose tombstone arrives first in an incremental pull, directly or
  through its habit's cascade, is held `tombstoned`, not deleted; restoring copies while signed
  into B makes B the owner and the next sync pushes them with no second sign-in, and restoring
  while signed out leaves no owner; `SyncCopies.reidentify` in a non-empty store gives held
  habits, groups and records fresh ids with linkage kept and queues no deletion.
- *Recovery log:* append, cap (oldest dropped, count kept), a pass bigger than the cap kept
  whole, export decodes, and nothing from it reaches a Sentry payload.

`StrideAppTests` (hosted, local gate): `SyncService.sync` ordering; **the owner gate** — after
signing into a different account, no entry point makes a request (the stubbed URLSession sees
none) until the choice; Export, then erase, then a full pull; Cancel leaves store and owner
untouched; an unknown owner offers both choices; an empty store switches silently; 401 →
`needsReauth`; 429/5xx/`sync_paused` → backoff; `snapshot_required` → every row pending with
`syncedAt` kept, pull before the resend; `cursor_expired` → full pull before push; **the run
binding** *(review 2)* — sign out and sign into B while chunk 1 is in flight → chunk 2 is never
sent, nothing is acknowledged, the deletion queue and cursor are unchanged, and the stubbed
URLSession sees no request carrying B's token after the switch.

Server (`test/api.test.js`): a pull with `X-Stride-Client` ≥ 1.3.1 serves millisecond
timestamps, with `ios/1.3.0(18)` or no header whole seconds; two pushes of one entry stamped
:18.700 and :18.300 keep :18.700 in both push orders; a whole-second push after a millisecond
one compares as `.000Z`. *(review 2)* The LWW re-feed: push W stamped :20 and pull, then push
L stamped :10 with a different value → the next pull since that cursor returns W; the same L
with W's values, and a whole-second echo of a millisecond row, re-feed nothing (the row's
`updated_at` does not move).

**`scripts/sync_rehearsal.sh`** (the `check_demo_account.sh` compile-Shared/-into-a-tool
pattern): two in-memory stores as two devices against `NODE_ENV=test node index.js`,
interleaving edit/push/pull/delete/offline/sign-out/sign-in sequences — including a
1.2.3-shaped (no header) and a 1.3.0-shaped (header, whole seconds) snapshot device, a device
with a skewed clock, and a tombstone swept on the test server *(review 2)* — asserting
that the stores and the server converge and that each push carried only the changed rows (count
rows and bytes). Its two-device happy path is the first vertical slice. Run before every
submission next to the demo check — 1.2.3's record says the bugs that mattered were found by
rehearsal, not by suites.

**Release mechanics — checklist before submission.**
- M0's contract is live (deployed 2026-09-27: `skipped`, `skippedReasons`, `totals`,
  `invalid_value`). Deploy the header-gated millisecond pull and the LWW re-feed *(review 2)*
  with the prod-copy rehearsal, and verify the pull with curl, with and without the header.
- **Re-declare Product Interaction** in `Stride/PrivacyInfo.xcprivacy`:
  `NSPrivacyCollectedDataTypeProductInteraction`, Linked false, Tracking false, purpose
  Analytics — Sentry's per-launch session records, used to count devices per version (App
  Store Connect keeps the label declared; RELEASE-1.3.0.md, "After submission"). M1 removed the
  entry with `AnalyticsService`; replace the file's "No ProductInteraction since 1.3.0" comment
  with the reason. Both app targets ship this file; the widget starts no Sentry and its
  manifest stays as it is.
- What's New tells users to make a backup first (M1 shipped it).
- `sync_rehearsal.sh` and `check_demo_account.sh` green on the build that ships.

**Acceptance.** (1) `sync_rehearsal.sh` passes: a second sync with no edits pushes 0/0/0; one
tap → next push carries exactly 1 entry and 0 habits; a 2,500-entry first upload completes in
2 requests with no 429, and 2,000 entries with 2 KB notes upload with no request over 1 MB; a
failure injected at chunk 2 leaves chunk 1 acknowledged and the retry sends only chunk 2; a
`row_error` row is held, the rest of its chunk lands, and the held row survives the next full
pull and is not sent again until edited; two devices plus a 1.2.3-shaped and a 1.3.0-shaped
snapshot device converge after interleaved edits/deletes; two edits of one entry 300 ms apart
on two devices end as the later edit whichever pushes first; a habit deleted on device B while
edited offline on device A is gone from A after its sync, and A's recovery-log export holds the
edit; a truncated full pull deletes nothing. *(review 2)* A sign-in to another account between
two chunks sends no further chunk and acknowledges nothing; with a tombstone swept on the test
server, Full resync and `snapshot_required` on a device still holding the deleted row leave it
deleted on the server and in A's recovery log; a device whose clock runs 10 min slow and loses
an edit ends with the winner's value. (2) StrideTests ≥ 230 green (188 today) incl.
`SyncPushPlannerTests`; StrideAppTests green; the real-container migration test green. (3)
`check_demo_account.sh` green with the streaks in RELEASE-1.2.3.md. (4) Mixed-fleet check on
real builds: a 1.3.0 (or 1.2.3) device and a 1.3.1 device on one test account, tap one habit
on each, sync both — both show both taps. (5) Sign out of account A, sign into account B on the
same device → the server log shows no sync request from that device until the choice; the
screen offers Export first; "Start from this account's data" leaves none of A's habits on the
device or in B's account; signing back into A instead resumes, and its next sync with no edits
pushes 0/0/0. (6) A backup exported on account A and restored as new copies on a device
signed into B is in B after a sync and still there after a full pull; a restored habit that
another device had deleted is held, and "Restore as new copies" brings it back to the account.
(7) Against production after the server deploy: a pull with `X-Stride-Client: ios/1.3.1(19)`
shows millisecond `updatedAt`, one without the header whole seconds. (8) The archived 1.3.1
app's privacy manifest declares Product Interaction. (9) Revoking the session server-side
shows the Today row on next foreground; flipping the pause switch shows "sync paused" and no
error. (10) No new interruptive UI: the account screen is part of a sign-in the user started;
held rows, restored-and-deleted rows and recovered edits are inline rows in Settings.

---

## M3 — 1.4.0: iPad and Mac as real shells, notification actions, background sync (3.5 w)

Scheduled before the stats rewrite so the new views land in the final shell rather than
being rebuilt when the shell changes.

- **iPad** (`ContentView.swift` :39-72, :105-113): `List(selection:)` sidebar shared with the
  macOS `SidebarView`; keep Today/Stats/Settings alive across selection (hidden-bar `TabView`
  or `ZStack` with opacity) instead of `switch selectedTab` recreating them (scroll position,
  selected date and the Stats habit are lost today); `.frame(maxWidth: 680)` centred content;
  heatmap cells sized from the available width. Add an iPad Pro 13" run to
  `scripts/screenshots.sh`. Budget for the lifecycle bugs this kind of change always brings
  (duplicated toolbar items, sheets that will not dismiss).
- **macOS:** one Settings surface (remove the sidebar row, keep the ⌘, scene — two instances
  hold independent reminder/delete-alert state today); `.commands` with Sync Now, Weekly
  Review, Export beside ⌘N; `NSApp.dockTile.badgeLabel` under `#if os(macOS)`; the same
  keep-views-alive fix.
- **Notification "Done".** `scheduleHabitReminder` sets `categoryIdentifier` and
  `userInfo[habitId]`; a `UNNotificationCategory` with Done (count → "Add 1") and Snooze 1 h;
  `Shared/NotificationRouter.swift` is a pure `route(actionIdentifier:, userInfo:) → Action`
  with tests; `StrideApp` installs a `UNUserNotificationCenterDelegate` whose `didReceive`
  **hops to the main actor explicitly** (never assume the callback's thread) and performs
  `HabitCheckIn.markDone` on `SharedModelContainer.mainContext`, awaits the save, reloads
  widgets and the badge. **The store's file protection is set to
  `NSFileProtectionCompleteUntilFirstUserAuthentication`** so a write from the lock screen
  does not fail. Weekday triggers for specificDays habits derived from `activeDaysMask` (no
  schema change). No suppress-today state machine and no 64-request budget juggling.
- **Background sync.** `BGAppRefreshTask` registered and scheduled after every check-in from
  a widget, notification or the app, so a "Done" from the lock screen reaches the server and
  the other devices without waiting for the next foreground. Best-effort by design (iOS
  decides when it runs); the foreground sync remains the guarantee.
- **Lossless export v2** already shipped in M1; nothing here.

**Acceptance.** (1) iPad Pro 13": sidebar with selection highlight; Today → Stats → Today keeps
scroll position and selected date; Stats capped near 680 pt; the heatmap fills its card.
(2) macOS: ⌘, opens Settings, the sidebar has no Settings row, the menu has Sync Now / Weekly
Review / Export, the Dock badge shows the remaining count. (3) With the app force-quit and
the phone locked, the per-habit reminder fires; "Done" on the banner writes the record
(assert the DB write and that a widget reload was dispatched — SpringBoard's render latency is
not ours to promise) and the entry reaches the server within the next background refresh or
foreground. A Mon/Wed/Fri habit has exactly 3 pending weekday triggers. (4) No new
interruptive UI.

---

## M4 — 1.4.1: strength score, editable history, best streaks, notes, stats that scale (5.5 w)

**Goal.** Replace streak-or-nothing feedback with a forgiving strength number (the single
most-cited reason users choose Loop/Kado over chain-based apps), let the user fix any past day
(Today reaches only the last 7 days; the heatmap is display-only), give Advanced Analytics a
metric worth paying for, and stop recomputing every statistic from raw records on every render
— which incremental push makes urgent by making multi-year stores realistic.

- **`Shared/HabitScore.swift`** — derive-on-read, never persisted, no schema change. Walk
  day-keys from `min(createdAt, earliest record)` to today; on scheduled days value = 1/0
  (binary), `min(1, value/target)` (count), and for times-per-week `min(1, completions in the
  trailing 7 days / timesPerWeek)` evaluated every day; `score = prev·m + value·(1−m)` with
  `m = 0.5^(√freq / 13)`, `freq` = 1 (daily) | popcount(activeDaysMask)/7 | timesPerWeek/7.
  It is ten lines, and the frequency-aware decay is the point: a fixed-alpha average punishes
  a 3×/week habit harder than a daily one for the same miss. **Shown to the user as a plain
  0–100 "strength" with one sentence of explanation**; nobody sees the formula. Re-derived
  from Loop's published formula, not copied (uhabits is GPL). The card says "strength is
  rolling 7 days; the streak is calendar weeks" — the two numbers on one card use different
  windows on purpose, and a fixture test asserts both.
- **`Shared/HabitStats.swift`** + cache — one value per habit per render (completed day-key
  Set, current/best streak, `bestStreakRanges` (top 5 with dates; `bestStreak()` becomes
  `ranges.first?.length`), 30-day rate, per-weekday counts, score series). **Invalidation is
  cheap by construction:** the cache is keyed by `habit.id` only and is cleared wholesale by
  a generation counter bumped on `ModelContext.didSave` (debounced, as the widget reload
  already is) and on foreground — no `max(records.updatedAt)` scan per render, no per-key
  validation. A sync pull is one save (the reconciler saves once), so a pull invalidates
  once. Consumers: `HabitRowView`, the Stats cards, `HeatmapView` (84 × `isCompletedOn` per
  render today), `WeeklyReviewView`, the widget's `fetchEntry`. Static `DateFormatter`s.
  Parity: `StatsMathTests` assert `HabitStats` equals the existing `Habit` methods;
  `check_demo_account.sh` prints identical numbers before and after. **Performance is an
  `XCTest` `measure` block** on a synthesised 10-habit × 730-day store in `StrideTests`,
  pinned on one simulator model — not an Instruments reading.
- **Editable history.** `HeatmapView` cells become Buttons → `HabitCheckIn.tap(habit, on:
  day, in: context)` for binary; a `DayEntrySheet` (value stepper + note) for count habits;
  `HabitHistoryView` month calendar with prev/next, from "Edit history" on the detail card.
  Allow days before `createdAt` and clamp `completionRate(from:to:now:)`'s effective start to
  `min(creationDayKey, earliestRecordKey)` — StatsMathTests: a backdated record never yields
  > 100 %. Today's rows are filtered by `createdAt <= selectedDate` when browsing back.
- **Notes as a feature.** `Habit.note` has never had UI and `HabitRecord.note` is reachable
  only through an alert on a completed day: a Description field in AddHabitView, shown under
  the row name; a note on any day through the `DayEntrySheet`; a note-indicator dot in the
  heatmap; Weekly Review lists this week's notes. No schema change; both fields already sync.
- **Pro cards** inside the existing `store.isPro` branch: `StrengthCard` (score, Δ30, Δ90),
  a weekly-bucketed strength bar chart in TrendCard's hand-rolled style (no Swift Charts),
  `BestStreaksCard`. Free tier: the detail card gains a "Strength 74" tile so the Pro chart
  has a visible referent. `ProLockedCard` names exactly the cards behind it.
- **Subscription status, honestly.** `ProStatus {lifetime, active(product, renewsOn,
  willAutoRenew), lapsed(expiredOn), never}` from `subscriptionStatusTask`; Settings shows
  plan + renewal date, "Manage Subscription", "Redeem Code". A lapsed user gets one inline
  Settings row "Pro ended on <date> — Resubscribe" and the locked cards that already exist.
  Move the `VerificationResult` / status mapping into `Shared/PurchaseOutcome.swift` so
  StrideTests cover verified / unverified-throws / pending / cancelled / lapsed. ASC offer
  codes and win-back offers are configured in ASC (an afternoon, no code).
- **Templates with targets** (`HabitTemplate` gains kind/target/unit) and `addHabit(from:)`
  stops swallowing errors with `try?`; persist `TodayView.collapsedGroups`.
- `server/seed-demo.js`: add one count habit and one 3×/week habit — every demo habit is
  binary today, so a reviewer never sees strength on a count or weekly habit. Deploy first.
- Metadata: STATISTICS paragraph gains "a strength score that recovers from a missed day" and
  "tap any day in the heatmap to fix your history"; STRIDE PRO block adds "Strength chart and
  best streaks". Pushed with `push_metadata.py`.
- Tests: `HabitScoreTests` (empty = 0; always 0…1; 30 perfect days > 0.75; 100 > 0.95; one
  miss after 60 dents < 6 points; recovery; rest days unchanged; 3×/week decays slower than
  daily under identical misses; Mon/Wed/Fri on a 3×/week habit scores 1.0 every day),
  `PurchaseOutcomeTests`, the backdating clamp, the `measure` block. Extend
  `demo_check/main.swift` to print strength and top-3 runs.

**Acceptance.** (1) StrideTests ≥ 210 green incl. the performance `measure` within its
baseline. (2) `check_demo_account.sh` prints strength / Δ30 / best runs per demo habit and
exits non-zero if any habit with ≥ 25 records in 30 days scores < 0.75. (3) On a device on the
demo account: tap a heatmap cell 20 days back → cell fills, 30-day rate, best streak and
strength change in the same render; after Sync Now the entry appears on a second device.
(4) Local StoreKit: buy Monthly → Settings reads the plan and renewal date; expire it in
Transaction Manager → one lapsed row, locked cards, nothing else. (5) The six Pro blocks list
only cards that exist in this build. (6) No new interruptive UI.

---

## M5 — 1.4.2: a Weekly Review worth opening (2 w)

- `Shared/WeeklyReviewMath.swift` (pure): `weekRange(containing:)` for any past
  Monday-anchored week; per-habit rate and strength delta vs the prior week; highlights by
  delta instead of raw rate; `atRisk(habit, now)` — times-per-week: `remaining ≥ days left
  to Sunday`; daily/specificDays: scheduled today, not done, **after the user's evening
  reminder time (18:00 if none)**; `notesOfWeek`; perfect-day count. Tests on Sunday/Monday
  boundaries, DST changeover and UTC−9 (the TimezoneTests pattern).
- `WeeklyReviewView` rebuild: ‹ › week navigation, summary ring + delta, "At risk this week"
  (tap → Today via `TodaySelection`), per-habit rows with a 7-cell strip + delta chip,
  highlights, notes. Share as an image rendered once.
- **Free, on Today:** a "2 more by Sun" badge on times-per-week rows, at-risk rows sorted first
  within their section.
- No Sunday nudge in this milestone; if ever, opt-in and Pro only.
- Extend `demo_check/main.swift` with a "last week" block; metadata Pro block: "Weekly Review
  — any week, what improved, what is at risk, your notes".

**Acceptance.** (1) `WeeklyReviewMathTests` green. (2) Demo account on a simulator with local
Pro: tap ‹ once — the per-habit percentages and highlights equal the script's "last week"
block; the at-risk list names the demo times-per-week habit with the correct "N more by
Sunday". (3) Signed out of Pro: the Today badge still shows, the review is locked, nothing
else appears.

---

## M6 — 1.5.0: skip days and vacation (4 w) — gated

The most-requested tracker feature across every comparator (Beaver, Habo, harsh, streak,
RoutineTracker) and the reviewers' top product ask. It is the first milestone with a schema
and wire change on entries, so it ships **only once M0's counters show the ≤1.3.0 snapshot
cohort at zero for eight weeks and a 426 minimum-version floor ≥ 1.3.1 is live** — a snapshot
client that does not know the field would otherwise clear every skip on each push. Both, not
either: eight quiet weeks of account-level counts cannot prove a dormant device gone, and the
floor is what refuses it when it wakes. *(Amended 2026-09-28: the cohort was ≤1.2.3; 1.3.0
pushes full snapshots too.)*

- `HabitRecord.isSkipped: Bool = false` (defaulted → lightweight migration); server column
  with the presence guard `skipped = COALESCE(excluded.skipped, habit_entries.skipped)` bound
  NULL when the key is absent; `SyncEntry.skipped: Bool?`. Semantics: a skipped day is a rest
  day for streaks and rates, the weekly goal share shrinks by `goal × skipped/7`, strength
  does not update. "Skip today" / "Unskip" in the row's context menu and accessibility
  actions and in the `DayEntrySheet` — never a third tap state on the widget or Siri (Loop's
  three-state cycle is where its skip bugs live). "Pause all habits until…" writes skipped
  records for the range. Hatched heatmap cells. Seed a skipped day in the demo account.
- Merge-import of Stride JSON (v1/v2) into a populated store lands here too, on top of the
  M2 sync rules; Habitify CSV next (the app paying users leave); Loop's zip only with a named
  zip dependency.

---

## Decisions on the contested points

| Question | Decision | Why |
|---|---|---|
| Incremental push before or after the feature work? | After one no-schema release (M1), before everything else | M1 proves the new CI and rehearsal scripts and ships the backup users need before the engine changes; M2 is then the only thing in its release. |
| Universal link or custom scheme for the magic link? | Universal link, in M1, with the `/login` page kept forever | Any installed app can claim `stride://` and receive the token (one reviewer wanted the scheme for reliability; the other wanted the link moved out of M2 — both are addressed: link, early, with the fallback). |
| What happens on logout / account switch? | *(Revised 2026-09-28.)* Different account → no sync request until the user chooses; an export is offered, then local rows are erased and the new account is pulled — no keep-and-merge in 1.3.1; same account → resume with delivery state, cursor and deletion queue intact, nothing re-uploaded; delete-account erases | Marking everything dirty on logout would push the previous account's data into the next one; and reactive `not_owned` handling cannot see rows the previous account created offline and never pushed — the server has never heard of those ids, so they would be applied into the new account. A cross-account copy, if ever wanted, is a later, explicit, re-id-based feature. |
| Full-pull deletion under incremental push | *(Revised 2026-09-28, and after Codex's second pass.)* Only on a validated snapshot (`totals` match, and ids, links and dates check out); never-delivered and held rows survive; delivered-but-absent rows go even when marked for resend, because a resend runs only after a pull on a live cursor; every pending or held row they take (descendants and groups included) is on disk in the recovery log first | A truncated or partly unusable response must not purge a store; "skip dirty rows" resurrects deletions, and so does re-sending a row whose tombstone was swept; an edit displaced by a delete from another device must stay recoverable, not only logged. |
| Delivery state under incremental push | *(2026-09-28.)* Three states: acknowledged (`syncedAt`, never cleared by sign-out or resend), held (quarantine: kept, not re-sent until edited, never deleted by a full pull) and forced resend | Quarantining by acknowledging let the full-pull rule delete every quarantined row; clearing `syncedAt` on re-login made "delivered, then deleted elsewhere" look like "never uploaded". |
| A push answered 400 | *(2026-09-28.)* Per answer: `too_many_rows` → re-chunk against `limits`; `invalid_payload` → client bug, Sentry, back off, hold nothing; bad rows arrive as 200 + `skippedReasons` and are held per reason | The server's only push 400s are envelope errors; bisection never isolates a row, it quarantines good data. |
| Edit-time precision | *(2026-09-28.)* Milliseconds from 1.3.1, both directions for ≥ 1.3.1; whole seconds accepted from, and served to, older apps | Whole seconds resolve two edits in one second by push order; a truncated pull makes a 1.3.1 device keep and acknowledge the losing edit. |
| Restore into another account; restores the server has tombstoned | *(2026-09-28.)* "Restore as new copies" (fresh ids, linkage kept) on the user's choice; held until then, never silently dropped | 1.3.0's id-keeping restore is skipped as `not_owned` in another account and wiped by the first full pull. |
| Tombstone retention | Unlimited until a 426 floor ≥ 1.3.1 retires ≤1.3.0; then 365 d; `cursor_expired` gated on the client header | Any sweep is a resurrection window for a client that cannot handle `cursor_expired` — every client through 1.3.0 (amended 2026-09-28; it said ≤1.2.3). Account-level usage data cannot prove a dormant device gone; the floor refuses it. |
| Kill switch | A global pause (503 + backoff) and a per-account snapshot request | A global "re-upload everything" would be a self-inflicted flood. |
| Stats cache invalidation | Whole-cache generation counter on debounced `didSave`, keyed by habit id | Validating per key by scanning `records` would cost what the cache saves; persisting stats in the schema is a column and a sync field for a derived number. |
| Shells before stats? | Yes — M3 (iPad/Mac) before M4 (stats) | The stats rewrite adds views; building them into a shell that is about to change is double work. |
| Skip days now or later? | M6, gated on the old cohort being gone | Both reviewers wanted it earlier; the schema change is safe only with the presence guard *and* no snapshot clients, and the guard alone does not stop a ≤1.3.0 push from clearing skips. |
| Strength score: keep the frequency-aware EMA? | Yes, shown as a plain 0–100 | Ten lines; the frequency term is what makes it fair to 3×/week habits; the user never sees the formula. |
| Watch target | Delete | Never embedded, never sold, no data path. |
| Siri intents on `HabitEntity`; single-habit/group widgets; Focus filter | Not this phase | Break existing Shortcuts / no demand / reschedule reminders from a background launch. |
| Source-scan localization test | Keep, scoped to plain literals; String Catalog migration when it fits | It targets the class that shipped (`weeks`); it is not an AST. |
| Swift Charts, CloudKit, target bump | No | Hand-rolled charts everywhere and the widget cannot use Charts; CloudKit is a live-store migration with no demo account; nothing needs iOS 18. |

## After this phase (not scheduled)

Negative / "at most" habits (Loop's open-bug cluster lives here); every-N-days / monthly
frequency (the Monday-anchored weeks need a rolling-window rewrite first); "day starts at"
offset (touches `HabitCalendar.dayKey`, the choke point behind the 1.2.1 Americas bug — not
before a negative-offset simulator sweep exists); removal of the snake_case shim and legacy
mounts once the counters read zero; additive merge for count habits; HealthKit-sourced habits
(entitlement, privacy label, Guideline 5.1.3 on uploading health-derived values); account
email change; a watch data path; macOS desktop widgets.

## Standing rules for every milestone

- Before submitting: `scripts/check_demo_account.sh`, `scripts/sync_rehearsal.sh` (M2+),
  `scripts/a11y_sweep.sh`, `StrideAppTests` on a simulator, `verify_archive.sh` via
  `ship.sh`, the six-locale What's New in `release.py`, and `push_metadata.py` in the same
  submission as any description change.
- Server changes are rehearsed on a copy of production on the host before deploying.
- Every new user-facing string goes into all five catalogs in the same commit; the
  source-scan test (M1) is the gate.
- Each milestone gets a `RELEASE-<version>.md` in the style of RELEASE-1.2.3.md: what shipped,
  why, what was found only by rehearsal, and what was deliberately not done.

## Review log (Gemini 3.1 Pro and Gemini 3.8 Flash, 2026-09-24)

Adopted: the account-switch data leak (Flash — the most important catch: resetting
`syncedAt` on logout would push the previous account's habits into the next account);
`totals` protection on full-pull deletion (Flash); chunking habits and groups against the
server caps (Flash); the global kill switch as a flood (Pro — now a pause, with a per-account
snapshot request); tombstone sweeping as a resurrection window for shipped clients (Pro — no
sweep until the 426 floor); the poison-pill chunk guard (Pro; superseded 2026-09-28 by M2's
per-answer rules, because the server's only push 400s are envelope errors and bisecting them
never isolates a row); hosted tests cannot run on a
generic CI destination (Flash — they are a local `ship.sh` gate); pin CI to the shipping Xcode
(Pro); `max(records.updatedAt)` as a cache key defeats the cache (Flash — generation counter
instead); `didSave` thrash during sync (Pro — one save per pull, debounced); file protection
for lock-screen writes (Flash); hop to the main actor in the notification delegate (Pro);
background sync after a notification action (Pro); export **and** a restore path before M2
(both); universal link out of M2 (Flash); shells before stats (Pro); the mixed-fleet race
test with a 1.2.3-shaped payload (both); deterministic widget-timeline tests, tolerance on
screenshot diffs, `measure` instead of Instruments, assert the DB write not SpringBoard's
latency (both); the `mode` field contradiction (Pro — removed); the "no nags" wording
(both — interruptive vs inline); effort +35–50 % (both).

Rejected, with reasons: dropping the universal link for a custom scheme (Pro — the scheme
can be hijacked for the token; the fallback page covers the reliability objection);
replacing the frequency-aware strength score with a 30-day percentage (Flash — the 30-day
rate already exists and is exactly the streak-or-nothing feedback users leave over; the
formula is ten lines and invisible to the user); moving skip days ahead of incremental push
(Flash — unsafe while snapshot clients exist; it is now M6 with the gate spelled out);
persisting `HabitStats` in the schema (Pro — a column and a sync field for a derived value);
dropping the source-scan test for an AST-grade tool (Flash — it targets one shipped bug class
and String Catalogs are noted as the long-term shape); cutting the Weekly Review rebuild
(Flash — it is two weeks, last, and Pro is sold on it).
