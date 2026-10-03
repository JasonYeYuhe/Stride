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
| M2 | **1.3.1** (build 19) | 5.5 | Incremental push, cursor expiry, account-switch safety, sessions that stay signed in |
| M3 | **1.4.0** (build 20) | 3.5 | iPad and Mac as real shells, notification actions, background sync |
| M4 | **1.4.1** (build 21) | 5.5 | Habit strength score, editable history, best streaks, notes, stats that scale, subscription status |
| M5 | **1.4.2** (build 22) | 2 | A Weekly Review worth opening |
| M6 | **1.5.0** | 4 | Skip days / vacation — gated on the ≤1.2.3 cohort being gone (M0's counters) |

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
  unlimited) until a 426 minimum-version floor has retired the ≤1.2.3 cohort. A shipped
  client that pulls past the retention window has no handler for `cursor_expired` and would
  resurrect whatever was swept on its next snapshot push; tombstone rows are ~100 B, so the
  cost of keeping them is nothing. Once the floor exists, retention returns to 365 d. Pull:
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

## M2 — 1.3.1: incremental push, cursor expiry, account-switch safety (5.5 w)

**Goal.** Replace the full-snapshot push with per-row acknowledgement, chunked and
acknowledged per chunk, with the reconciler, cursor and account rules that make it safe for a
fleet that will contain ≤1.2.3 snapshot clients for months. This is the hardest milestone in
the plan; both reviewers called the first estimate a fantasy, and it is scheduled alone.

**Design** (from the sync-architecture research; the verified state is `SyncService.pushLocal`
:75-145 serialising every row on every sync, and the server's value-based two-clock guard from
1.2.3 that makes a mixed fleet safe):

- `syncedAt: Date?` on `Habit`, `HabitRecord`, `HabitGroup` (optional → lightweight
  migration, the same shape as the existing `updatedAt` addition). A row is dirty iff
  `syncedAt != (updatedAt ?? createdAt)` — **inequality, not ordering**, so a clock step
  backwards cannot strand edits. No mutation site changes: every edit already calls `touch()`
  (the 1.2.3 LWW fix depends on that). **Migration test:** a populated store copied from a
  1.2.3 device (Xcode → Devices → download container) opens under the 1.3.1 schema in a test
  before submission; fresh simulators prove nothing about live stores.
- `Shared/SyncPushPlanner.swift` (pure; in `Shared/` so the host-less tests run the real
  code — the move that fixed the reconciler in `72ccb74`). `HabitRecord` has no `habitId` and
  `Habit.records` has no inverse, so the planner walks each habit's records; fine at these
  sizes. Chunks respect **all** of M0's caps: ≤ 200 groups / ≤ 500 habits / ≤ 2,000 entries
  per request; chunk 1 = deletions + dirty groups + dirty habits + the first entries, later
  chunks entries only (the server skips an entry whose habit does not exist yet, so habits go
  first). If chunk 1 fails and chunk 2 never runs, the server holds new habits without their
  history until the next sync — peers see fewer entries temporarily, which the reconciler
  already tolerates. Acknowledge per chunk — only rows whose `updatedAt` still equals what
  was sent, and never ids in the response's `skipped`. `SyncDeletionQueue.acknowledge` only
  the delivered deletion ids. *(As built in M0: the server caps only rows — deletion lists are
  uncapped, since deleting a multi-year habit queues one id per check-in — so chunk 1 may carry
  every deletion; a 400 whose `code` is `too_many_rows` is a planner bug: re-chunk against the
  returned `limits`, never bisect or quarantine.)*
- **Poison-pill guard.** A chunk answered with 400 is bisected; a single row that still fails
  is quarantined (acknowledged, kept locally, reported to Sentry with its id) so one bad row
  cannot wedge sync forever. 429 / 5xx / `sync_paused` → retry on the next sync with jittered
  backoff, never `syncError` (today `APIClient`/`SyncService` have no retry at all).
- **Skipped rows.** Act on the push response's `skippedReasons` (added in M0), not on the id
  alone: `tombstoned` / `tombstoned_habit` → acknowledge and drop (if the habit is also absent
  locally, delete the entry); `missing_field` / `row_error` → quarantine like a poison row;
  `unknown_habit` / `skipped_habit` → keep dirty and retry once the habit lands, then
  acknowledge and report; `invalid_value` *(amended after M1: added to the server in M1's
  completion round — a number no app can produce, outside the bounds in server/DEPLOY.md)* →
  quarantine: keep it locally, stop re-sending it until the user edits it (a new
  `updatedAt`), show it in the sync diagnostics — but do **not** record it as delivered, since
  the server does not hold it and the full-pull deletion pass below removes acknowledged rows
  the server lacks; hold the `skipped_habit` entries of a new habit quarantined this way with
  their habit instead of retrying them; `not_owned` / `not_owned_habit` are the previous
  account's rows after
  "keep the habits on this device" — give those habits (and their entries and groups) new
  UUIDs and push again, **never acknowledge them**, or the full-pull deletion pass removes the
  data the user chose to keep. Back off on `code` `sync_paused` (503) and `rate_limited` (429)
  using `retryAfterSeconds` / `Retry-After`. `409 snapshot_required` is sent once per request
  (support re-arms it with `ops/request-snapshot.js` if a device lost it).
- **Reconciler.** Set `syncedAt = updatedAt` wherever remote state is applied (habit
  update/insert, entry update/insert including the id-alignment path, group update/insert) —
  otherwise the device's own push returns through the 60 s overlap at whole-second precision,
  looks dirty again, and every row echoes forever. Add the local-newer guard the entry branch
  has to the habit and group branches. The reconciler saves once per pull, so a pull is one
  `didSave`, not thousands.
- **Full-pull deletion rule.** The deletion pass runs **only if the response's `totals`
  equal the arrays it carries** — a truncated body or a timed-out query must abort the sync,
  never purge the local store. Then: a row absent from the pull is deleted locally **unless it
  has never been acknowledged (`syncedAt == nil`)**. A never-uploaded row survives (a partially
  failed first upload followed by a full pull cannot delete it); an acknowledged row that the
  server no longer has was deleted on another device and goes, even if it carries an offline
  edit — the edit is lost and logged. "Skip all dirty rows" would resurrect deletions on a
  device whose cursor expired.
- **Cursor age.** `SyncService.sync()` clears a cursor older than retention − 10 d locally and
  handles the server's `409 cursor_expired` the same way: full pull **first**, then push.
  `snapshot_required` (per-account, support only) marks every row dirty; `sync_paused`
  backs off.
- **Account switch — the data-leak fix.** Today "local data merges into whichever account
  signs in": User A signs out, User B signs in on the same device, and A's habits are pushed
  into B's account. Store the signed-in account id locally; on sign-in with a **different**
  account, present a choice **as part of the sign-in flow the user just started**: "Keep the
  habits on this device and add them to this account" or "Start from this account's data"
  (erases local rows first). Same account again (re-login) → `resetSyncState(context:)` sets
  `syncedAt = nil` everywhere and the full upload proceeds as today. `deleteAccount` erases
  local data. Settings gains **"Full resync"** (mark all dirty + clear cursor) as the user's
  escape hatch. A snapshot is "everything dirty": one code path.
- **Sign-in that stays.** `AuthService.needsReauth` on 401 → an inline "Sign in again to keep
  syncing" row on Today (today the only signal is a red footer in Settings); pairs with M0's
  sliding sessions. **Sync status where the user works:** one line under Today's progress card
  — "synced 2 min ago" / "offline — 3 changes waiting" / "sync paused" — from the planner's
  dirty count.
- **Known limitation, documented in the release record:** count-habit values merge by
  last-write-wins per entry, not additively — 3 glasses logged offline on the phone and 5 on
  the iPad resolve to whichever was edited later, not 8. Additive merge is a later design.

**Tests.** `StrideTests/SyncPushPlannerTests.swift` (in-memory container, the
SyncReconcileTests pattern): fresh store → chunks with groups+habits+entries+deletions; after
ack → empty plan; one touched record → exactly that entry and no habit; edit during an
in-flight push → still dirty after ack; pulled rows are not dirty (the echo test, including
whole-second rounding and the id-alignment path); pull kept a newer local value → still dirty;
600 dirty habits → two habit chunks; 2,500 entries → chunk 2 entries-only; failure at chunk k
→ < k acknowledged, ≥ k dirty, retry resumes at k; a 400 on a chunk bisects to one quarantined
row; clock step backwards → still dirty; `resetSyncState` → all dirty; server `skipped` ids
acknowledged and reported; full-pull deletion aborts on a `totals` mismatch, keeps
never-acknowledged rows and removes acknowledged-but-absent ones; a partial payload still
encodes all six arrays. `StrideAppTests` (hosted, local gate): `SyncService.sync` ordering,
401 → `needsReauth`, 429/5xx/`sync_paused` → backoff, `snapshot_required` → all dirty, the
account-switch choice erases or keeps. **`scripts/sync_rehearsal.sh`** (the
`check_demo_account.sh` compile-Shared/-into-a-tool pattern): two in-memory stores as two
devices against `NODE_ENV=test node index.js`, interleaving edit/push/pull/delete/offline
sequences — including a 1.2.3-shaped snapshot device — asserting both stores and the server
converge and that each push carried only the changed rows (count rows and bytes). Run before
every submission next to the demo check — 1.2.3's record says the bugs that mattered were
found by rehearsal, not by suites.

**Release mechanics.** M0's server contract must be live before submission (verify `skipped`
and `totals` with curl). What's New tells users to make a backup first (M1 shipped it).

**Acceptance.** (1) `sync_rehearsal.sh` passes: a second sync with no edits pushes 0/0/0; one
tap → next push carries exactly 1 entry and 0 habits; a 2,500-entry first upload completes in
2 requests with no 429; a failure injected at chunk 2 leaves chunk 1 acknowledged and the
retry sends only chunk 2; a poisoned row is quarantined and the rest of the chunk lands; two
devices plus a 1.2.3-shaped snapshot device converge after interleaved edits/deletes; a
truncated full pull deletes nothing. (2) StrideTests ≥ 180 green incl. `SyncPushPlannerTests`;
StrideAppTests green; the 1.2.3 device-store migration test green. (3)
`check_demo_account.sh` green with the streaks in RELEASE-1.2.3.md. (4) Mixed-fleet check on
real builds: a 1.2.3 device and a 1.3.1 device on one test account, tap one habit on each,
sync both — both show both taps. (5) Sign out of account A, sign into account B on the same
device → the choice appears; "Start from this account's data" leaves none of A's habits on the
device or in B's account. (6) Revoking the session server-side shows the Today row on next
foreground; flipping the pause switch shows "sync paused" and no error. (7) No new
interruptive UI.

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
and wire change on entries, so it ships **only once M0's counters show the ≤1.2.3 snapshot
cohort at zero for eight weeks and a 426 minimum-version floor is live** — a snapshot client
that does not know the field would otherwise clear every skip on each push.

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
| What happens on logout / account switch? | Different account → the user chooses keep-and-merge or start-fresh; same account → full re-upload; delete-account erases | Marking everything dirty on logout would push the previous account's data into the next one. |
| Full-pull deletion under incremental push | Only when `totals` match; never-acknowledged rows survive; acknowledged-but-absent rows go | A truncated response must not purge a store; "skip dirty rows" resurrects deletions. |
| Tombstone retention | Unlimited until a 426 floor retires ≤1.2.3; then 365 d; `cursor_expired` gated on the client header | Any sweep is a resurrection window for a client that cannot handle `cursor_expired`. |
| Kill switch | A global pause (503 + backoff) and a per-account snapshot request | A global "re-upload everything" would be a self-inflicted flood. |
| Stats cache invalidation | Whole-cache generation counter on debounced `didSave`, keyed by habit id | Validating per key by scanning `records` would cost what the cache saves; persisting stats in the schema is a column and a sync field for a derived number. |
| Shells before stats? | Yes — M3 (iPad/Mac) before M4 (stats) | The stats rewrite adds views; building them into a shell that is about to change is double work. |
| Skip days now or later? | M6, gated on the old cohort being gone | Both reviewers wanted it earlier; the schema change is safe only with the presence guard *and* no snapshot clients, and the guard alone does not stop a ≤1.2.3 push from clearing skips. |
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
sweep until the 426 floor); the poison-pill chunk guard (Pro); hosted tests cannot run on a
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
