# Stride v1.3.0 — release record

App ID `6761262334`, bundle `yyh.stride.habittracker`. **In progress**: M0 (server, CI, ops)
is done and the server half is live. The 1.3.0 client (DEV-PLAN-1.3.md M1) is built — `0a59bf3`
plus the completion round `3fed14b` — and **build 18 is uploaded for iOS and macOS**, with the
1.3.0 version records, What's New and descriptions in App Store Connect (2026-09-27). **Not
submitted**: the device checks, the privacy-page publication and the owner's go are open
([TODO](#todo--before-130-is-submitted-m1)).

1.2.3 (build 17) has been `READY_FOR_SALE` on iOS and macOS since 2026-09-17. This release
follows [DEV-PLAN-1.3.md](DEV-PLAN-1.3.md): M0 lands everything the incremental-push client
(1.3.1) will depend on, while every shipped app keeps working unchanged; M1 is 1.3.0 itself.

## M0 — shipped ahead of the build (server, CI, ops)

Branch `m0/server-ci-ops`. The server half is three commits — `b384fe6` (contract),
`2911f87` (ops), `44f863f` (rehearsal script) — rehearsed on a copy of production and
**deployed 2026-09-27 10:25 UTC**. It reaches every installed app without an update, and is
additive for all of them: shipped apps decode only `ok` from a push.

### The sync contract the 1.3.1 client will build on — `b384fe6`

Today every app pushes its whole history on every sync, so a row the server silently dropped
came back next time and nobody noticed. Once apps send only what changed (M2), a silent drop
is a row that never syncs. So:

- **A push says what it did not apply, and why.** `{ok, applied, skipped:{habits,entries,
  groups}, skippedReasons}`. The reason decides the client's action — `tombstoned` means drop
  it, `unknown_habit` / `skipped_habit` mean retry once the habit lands, `not_owned*` means
  rows from the previous account after an account switch (re-id them), `missing_field` /
  `row_error` mean quarantine. One bad row never fails the request: SQLite errors are caught
  per row and reported as `row_error`, because the 1.3.1 client backs off on 5xx, and a row
  that 500'd its chunk would have stopped that account for good. *(M1's completion round adds
  `invalid_value` — a number no app can produce — also quarantine; built and tested, not yet
  deployed. See [Numbers that cannot crash](#numbers-from-sync-that-cannot-crash-the-app).)*
- **A pull says how much there is.** `totals:{habits,entries,groups}`, read in the same
  transaction as the arrays, so a client deletes local rows missing from a full pull only when
  the pull is provably complete.
- **Tombstones are no longer swept.** An app ≤ 1.2.3 that pulls past a swept window cannot be
  told (it has no `cursor_expired` handler) and pushes the deleted rows back on its next
  snapshot. They stay until a 426 minimum-version floor retires that cohort.
- **A pause switch, not a snapshot switch.** A flag file on the host answers every sync request
  `503 sync_paused` with `Retry-After`; support can ask *one* account for a full re-upload
  (`409 snapshot_required`, one-shot, recorded). There is no global re-upload switch — it would
  have every app push its whole history in the same minute.
- **Rate limits by account.** Sync is limited per account (60/min) and exempt from the global
  per-IP limiter, which a household behind one address could exhaust; requests without a
  session keep a per-IP limit.
- **Sliding sessions.** A Bearer session with less than 15 days left extends to 30 days (at
  most one write per ~15 days per session). This removes the silent day-30 logout that
  surfaced only as a red Settings footer.
- **The AASA file** for one-tap sign-in from the email link (M1), served now because Apple's
  CDN caches it for hours.
- **Counters that decide when the old paths can go**: hits on the snake_case shim, habits
  arriving without `kind`, the legacy `/sync` `/auth` `/habits` mounts, and accounts per
  client build (`ops/usage-report.js`). These numbers, not a date, decide when the shim, the
  legacy mounts, the 426 floor and tombstone sweeping can return.

Server suite 302 → 375, `npm run typecheck` now covers `lib/` and `ops/`. The operator's view
of all of it — every status code a client can get and who can get it, the pause switch,
snapshot requests, the usage report — is in [server/DEPLOY.md](server/DEPLOY.md).

### Ops — `2911f87`, `44f863f`

- **`backup.sh` is in the repo** (it lived only on the host). It refuses a missing or empty
  database — `sqlite3` on a missing path creates an empty one and backs it up with
  `integrity_check: ok`, so fourteen such nights would have aged out every real backup — counts
  users in what it wrote, and prunes only nightly files: the old glob also expired the
  predeploy/preseed rollback points after 14 days.
- **Nightly restore drill** (04:10 UTC): restores the newest backup into a private temp
  directory, integrity and foreign-key checks, fails on a missed night, an empty database or
  users halving overnight. Sentry message plus cron check-in once `SENTRY_DSN` exists.
- **Daily demo-account top-up** (03:50 UTC), see the decisions below.
- **`scripts/rehearse_server.sh`**: the prod-copy rehearsal, scripted. It is now step 3 of the
  deploy procedure and must pass before the real rsync.
- `scripts/ops/check_email_auth.sh`: SPF / DKIM / DMARC for the magic-link sender.

### Deploy verification (production, 2026-09-27)

- Rehearsal on a copy of production: **20/20** checks passed.
- `GET /.well-known/apple-app-site-association` → 200 `application/json`.
- Demo account full pull: `totals` 6 / 133 / 0, equal to the array lengths.
- Push with one entry whose habit does not exist → 200, the id in `skipped.entries`, reason
  `unknown_habit`.
- `GET /v1/sync/pull?since=<400 days ago>` → 409 with `X-Stride-Client: ios/1.3.1(19)`, 200
  without it.
- A 20-day-old session's `expires_at` moved from now + 10 d to now + 30 d.
- Root crontab gained the 03:50 top-up and 04:10 drill; ColorArchive's lines untouched, the
  old crontab saved in `/root/backups`. First runs: `backup.sh` integrity ok, users 4; the
  top-up added 43 check-ins, a re-run added 0; the restore drill ok.
- `scripts/check_demo_account.sh` green again. It had been **stale (exit 3)**: the last demo
  check-in was 2026-09-16, and streaks count back from today with one day of grace.

### CI and project — `4d59f4f`

- **One Apple job on the `xcode-27` image**, pinned to the Xcode major that ships (it fails
  rather than test another compiler): XcodeGen drift check, a generic-iOS build with product
  checks (widget embedded, both privacy manifests, Info.plist, Sentry), `StrideTests` on
  macOS, a macOS build with product checks, and the hosted tests on a simulator. A cheap
  `Changed areas` job decides which halves run; `release/**` is covered.
- **Pre-push hook** (`scripts/install-git-hooks.sh`): the drift check and the generic iOS
  build + product check before Apple-side commits leave the Mac — the gate that does not
  depend on a preview runner.
- **`StrideAppTests`**, a hosted suite (`APIClient`, `SyncService.sync` ordering,
  `AuthService`, `NotificationService`, `StoreService`) through injected seams — never the
  host app's Keychain, defaults or notification store. A `ship.sh` gate.
- **`verify_archive.sh`**, two modes: the archive's contents, and the Distribution-signed
  export — signer, no `get-task-allow`, associated domains. The 1.2.3 archive is signed
  *Apple Development* with `get-task-allow`; only the export carries the Distribution
  signature, so that is where entitlements can be asserted.
- **`build-appstore.sh`**: a failed export is now fatal (it was `|| true` since the script's
  first commit), and uploads are queued until every platform has passed both gates, so
  `all --upload` sends nothing to App Store Connect unless iOS *and* macOS pass. `ship.sh` is
  one call to it.
- `generateEmptyDirectories: false`: a local-only empty folder put a group into the committed
  project that a clean checkout could not reproduce, and the drift check failed on it.
- `CFBundleDisplayName` added to both apps (the 1.2.3 archives had none); `1C8F.1` (app-group
  defaults) added to the app's privacy manifest.
- `Configuration.storekit` wired into the Stride and StrideMac run actions.
- Root hygiene: the April 2026 notes and the v1.0 upload script moved to `archive/2026-04/`
  (not `docs/`, which GitHub Pages publishes); `README.md` added.

### StrideWatch removed

The watchOS target is gone from `project.yml`, and `StrideWatch/` from the tree. It was never
embedded — no "Embed Watch Content" phase, absent from the 1.2.3 archive — so no user ever
had it; it had no path to the server; and it was never sold. It still cost a build and a
place in every accessibility and localization pass. The sources are in git history, last
present at `ab9e854`. Comments and three dead `#elseif os(watchOS)` branches remain in
`Shared/` (harmless; clean up when those files are next touched).

### Decisions and deviations from DEV-PLAN-1.3.md

| Plan said | Done | Why |
|---|---|---|
| Push returns `skipped` ids | Also `skippedReasons` per id | The same "skipped" needs opposite client actions (drop vs retry vs re-id). With ids alone, a keep-and-merge after an account switch would acknowledge the old account's rows and the next full pull would delete what the user chose to keep. |
| Array caps of 500 habits / 5,000 entries / 200 groups | Same caps; **deletion lists uncapped** | Deleting history queues one tombstone per record, and M2 sends every deletion in the first chunk. The 5 MB body limit still bounds them, as it always has. |
| Caps for every request | **Only for `X-Stride-Client` ≥ 1.3.1**, like `cursor_expired` | A shipped app cannot split a push; for it a 400 is as fatal as a 413, and it would never sync again. |
| Errors as `{error:code}` | A `code` always; apps with no header get the **human sentence in `error`** | 1.2.3 prints `error` verbatim in the Settings footer. With a valid header: `{error:code, code, message}` — so **1.3.0's `APIClient` must display `message ?? error`** (an M1 item), or 1.3.0 users read `rate_limited`. |
| Add `Stride/PrivacyInfo.xcprivacy` to the widget | The widget has **its own manifest** (`1C8F.1` only, no collection) | The app's manifest declares email and habit content the widget never collects; ASC combines both into one report anyway. |
| Weekly cron re-seeding the demo account | **Daily top-up** that only inserts | `seed-demo.js` deletes the account's sessions and re-creates its habits under new ids: on a timer it would sign a reviewer out mid-review and replace everything on their device. And weekly is too slow — two days without a check-in zero every streak (`check_demo_account.sh` exit 3). The top-up never writes on or before a day the reviewer un-checked something, and leaves habits the reviewer created alone. |
| A new Azure VM snapshot | **None; the existing weekly incremental snapshots** | `pull-offsite.sh` on the Mac already takes one weekly and keeps four (09-05, 09-11, 09-17, 09-24), under $1/month. DEPLOY.md documents a manual one before OS upgrades. |
| Owner action: wipe `stride.db` on the DO droplet | **Nothing to wipe** | The droplet was destroyed on 2026-08-30 with its database (the owner's ledger); DEPLOY.md had said until 2026-09-26 that it was kept. |
| ASC check on intro offers; M1 disclosure line if kept | **ASC has none**; `Configuration.storekit` and `setup_iap.py` aligned to that | Production Monthly ($2.99) and Yearly ($19.99) carry no introductory offer, so there is no Guideline 3.1.2 exposure and **no disclosure line is needed in M1**. The local config and the setup script still described $0.99 / $9.99 intro offers; they now match production. |
| `verify_archive.sh` called by `ship.sh` | Called by `build-appstore.sh` for each platform (which `ship.sh` calls), with the associated-domains check on the **export** | See "CI and project" — the archive is development-signed. DEV-PLAN-1.3.md amended. |
| Hosted tests only as a local `ship.sh` gate | Also a CI step on the preview image | Costs nothing when the runner exists; `ship.sh` remains the gate that does not depend on it. |
| Acceptance (3): delete `embed: true` → red | **Set `embed: false`** → red | In XcodeGen 2.45.3 an app's extension dependencies embed by default, so deleting the line changes nothing and the check correctly stays green. DEV-PLAN-1.3.md amended. |

## Owner actions still open

- [ ] **Sentry project for the server.** Create `stride-server` (Node/Express) in org
  `jason-yeyuhe`, add `SENTRY_DSN=` to `/root/stride-server/.env`,
  `sudo pm2 restart stride-server --update-env`, then run
  `ops/restore-drill.js` once without `--dry-run-sentry`. Until then a failed drill — and so a
  failed backup night — is visible only in `/root/backups/stride-restore-drill.log`.
- [ ] **Sentry uptime monitor** on `https://stride-api.colorarchive.me/health`: 1-minute
  interval, 10 s timeout, downtime threshold 2, recovery 1, email. It is the org's second
  monitor, $1/month pay-as-you-go (set a PAYG budget ≥ $1). Acceptance (5): stop pm2 for
  150 s → exactly one alert, then a resolve.
- [ ] **DMARC** at Namecheap: `_dmarc.stride.colorarchive.me TXT "v=DMARC1; p=quarantine;
  adkim=r; aspf=r; rua=mailto:<owner address>"` (or `p=none` with `rua` for two weeks first),
  then `scripts/ops/check_email_auth.sh`.
- [ ] **The ASC `.p8` keys**: move the two `AuthKey_*.p8` files out of iCloud Drive's
  Downloads into the out-of-repo secrets directory (mode 600), and `chmod 600
  ~/private_keys/AuthKey_*.p8` (currently 644) — or point `scripts/.env`'s `ASC_KEY_PATH` at
  the secrets directory and remove `~/private_keys`.
- [ ] **DigitalOcean console**: the Droplets page is empty and the September invoice (due
  1 October) is $0.00; then `ssh-keygen -R 143.198.85.72`.
- [ ] Once 1.2.3 is settled: delete the `stride-predeploy-20260915-*`, `-20260916-*` and
  `stride-preseed-20260916-*` files in `/root/backups` by hand; they no longer expire.

## TODO — CI evidence (M0 acceptance 3)

_Not yet run. Fill in with run links._

- [ ] First push of this branch: the `xcode-27` label gets a runner (note queue time);
  `Require Xcode 27` prints 27.x; XcodeGen install, drift check, package resolve, iOS build +
  check, `StrideTests` on macOS, macOS build + check and hosted tests all green.
- [ ] A server-only and a docs-only push skip the Apple job.
- [ ] A scratch branch with `embed: false` on the widget dependency turns the Apple job (and
  the pre-push hook) red with "PlugIns/StrideWidgetExtension.appex missing".
- [ ] If the jobs become required checks, `Changed areas` must be required too.
- [x] **Before any hosted run in CI or `ship.sh`**: the XCTest guard in
  `Shared/SentryBootstrap.swift` (landed in `4d59f4f`, with DEBUG builds reporting as
  `development`). Hosted tests launch the real app, which starts Sentry with
  the production DSN; the 2026-09-27 test runs filed abnormal sessions against live 1.2.3+17
  (ignore that release's sessions from 08:00–11:00 UTC that day; Sentry cannot delete them).

## M1 — the 1.3.0 client

Branch `release/1.3.0`, built 2026-09-27 as eight parallel pieces (plurals and catalogs,
Dynamic Type, reminders, the large widget, backup/restore/erase, one-tap sign-in, Settings and
the small items, the accessibility sweep), then reviewed adversarially and put through two fix
passes. No schema change: every model is as 1.2.3 left it. Commits: `0a59bf3` (the client),
then the [completion round](#completion-round) (`3fed14b`, with the server half in `55c8c72`), which closed
what a completeness review of `0a59bf3` found still open.

### Plurals, and the English catalog that did not exist

- **`Localizable.stringsdict` in six `.lproj`s**, including a new `Shared/en.lproj`. 22 keys:
  every count the plan listed, plus the restore preview's `%lld habits` / `%lld groups` and
  the two five-argument Stats/Share VoiceOver labels (Spanish read "racha de 1 días" inside
  them). ja/ko/zh get a single `other` form built from their existing translation, so every
  language has the same keys.
- **A plural key lives only in the stringsdict.** When a key is in both files Foundation returns
  the stringsdict form — proved on a scratch bundle and kept as a test — so a `.strings` copy
  is dead text that drifts. `testNoKeyIsInBothFiles` enforces it.
- **Choosing English in the in-app picker did nothing on a non-English device.** With no
  `en.lproj`, `LanguageManager.bundle` for English fell back to the system language, so every
  `appLocalized` string — VoiceOver announcements, Settings values, sync and restore errors —
  stayed Japanese (or whatever the device ran). An older archive confirms `en.lproj` never
  shipped. Found while adding the English plurals; fixed by the same files.
- **The plural form follows the locale, not the bundle** — found by the review, running the
  suites under `-testLanguage ja`: `String(localized:bundle:)` with the Spanish bundle on a
  Japanese device returned "Racha de 1 días", because the plural rule comes from
  `Locale.current`. `appLocalized` now passes `locale:` from a new `LanguageManager.stringLocale`
  (the picked language, or `<resolved language>_<device region>` for System). The mutation run
  with `locale:` removed failed on exactly those five strings.
- **`weeks`** (in no catalog, so English in every language) and the **share card's "1 días de
  racha"** became unit-only, count-bearing keys — `"days (unit after %lld)"`,
  `"day streak (label under %lld)"` — because the number is drawn separately and larger, and
  merging the two into one `Text` would move pixels at the default size.
- **`LocalizationSourceScanTests`** rebuilds runtime keys from `Stride/Sources` and
  `StrideWidget/Sources` (the Mirror rule, not `-exportLocalizations`) and fails on a literal
  with no ja entry, on a string literal inside an interpolation, and on an interpolated
  expression it cannot type. Widened after review to `ProgressView`, `Link`, `ShareLink`,
  `help`, `shortTitle:` and friends, where it immediately found three AppShortcut titles
  ("Complete Habit", "Check Streak", "List Habits") in no catalog.
- Today's week strip reads weekday names from `appCalendar`, and two Stats labels format with
  the app's locale, so they follow the picker. The widget's gallery placeholder is eight
  habits named after the templates: the gallery preview had been English everywhere.

### Dynamic Type

- The 8–10 pt fonts go through a new `scaledSystemFont(size:relativeTo:)` (`@ScaledMetric`).
  SwiftUI has no `Font.system(size:relativeTo:)`, and `.caption2` is 11 pt, which would have
  moved every chart label at the default size.
- One breakpoint, `isAccessibilitySize`: the 12-week heatmap becomes a horizontally scrolling
  strip that opens on the current week; the 8-week trend and By Weekday become one row per
  item; the four streak tiles stack; the Today progress ring (which read "1…") moves under its
  text; the week strip (which split "21" and "Mon" across lines) scrolls; the paywall price
  cards (which broke "Life/tim/e" and "$19.9/9") stack. Decorative 50–60 pt symbols scale
  relative to `.largeTitle`, capped at `.accessibility2`.
- **`scripts/a11y_sweep.sh`** captures Today, Stats, Settings and the paywall at a chosen
  content size on iPhone 17 Pro Max under a mutex, and restores size, appearance, status bar
  and boot state from an EXIT trap — the same device takes the store screenshots. `-paywall`
  opens the paywall at launch and is compiled only into DEBUG, so a store build has no path
  that shows a sheet without a tap.

### Reminders on a fresh install

A reminder switched on in the New Habit sheet was scheduled while permission was still
`.notDetermined`, and never delivered; the only permission request lived behind the Settings
Daily Reminder toggle. Save now settles permission first, so the system prompt appears over
the sheet at the moment of the user's own tap. On "Don't Allow" the sheet stays open once with
the footer Settings already shows, and nothing has been saved yet, so the next Save cannot
insert a duplicate. The habit keeps `reminderEnabled`, and the launch pass schedules it once
notifications are allowed. The review then found the other half: the first grant scheduled
only the habit being saved, so habits restored or synced earlier stayed silent until the next
launch. A grant now schedules every reminder-on habit in the store.

### The large widget, and a midnight that does not depend on WidgetKit

- `.systemLarge` (eight rows at default text size, fewer at larger sizes, measured by
  rendering the real views at the smallest iOS 17 large widget) and `.systemExtraLarge` (iPad,
  two columns). macOS desktop widgets are not built.
- **Rollover.** `Shared/WidgetTimelinePlan.swift` is pure and hands WidgetKit two entries, now
  and the next local midnight, with `.after(midnight + 1 h)` as the safety net. The midnight
  entry's rows come from each habit's own `isCompletedOn` / `currentStreak`, called with UTC
  day-keys the plan builds itself: `HabitCalendar.dayKey`'s idempotency shortcut reads an
  instant exactly on a UTC midnight as tomorrow in negative-offset zones. Midnight is
  `startOfDay(startOfDay(now) + 36 h)`, correct on 23- and 25-hour days, on days with no 00:00
  (São Paulo 2018) and on a skipped day (Samoa 2011). A failed store read retries in 15 minutes
  instead of showing "No habits yet" until tomorrow.
- Yes/no rows are `Toggle(isOn:intent:)`, so the tap shows at once; count habits stay
  `Button(intent:)` through `HabitCheckIn.tap`, so a tap adds one and never deletes the day
  (the 1.2.3 fix), and part-way to the goal they draw a partial ring.

### Backup, restore and erase

- **Export v2** (`Shared/DataBackup.swift`): every model field, groups, and each habit's
  records with their ids and edit times; sorted keys, deterministic order, timestamps rounded
  to milliseconds, so `export(restore(export(store)))` is byte-identical and the test asserts
  it. The export folds rows that share an id: the pre-1.2.3 lowercase-id bug left duplicate
  `Habit` rows in real stores, and exported verbatim they make a file restore must reject — the
  user would find out only when they need it. CSV keeps the five 1.2.3 columns in place and
  appends value, target, unit and schedule, with a UTF-8 BOM so Excel shows emoji and CJK.
  Both are `Transferable` items that serialise only when the user picks a destination; the old
  Settings body ran both serialisations on every render.
- **Restore into an empty store only**, with a preview and a confirmation. It keeps ids,
  `createdAt` and `updatedAt` and never calls `touch()` — restored rows are the account's own
  rows, and re-stamping them would make a months-old backup win every conflict. A 1.2.3 export,
  a newer schema, a damaged file and "not a backup" each get their own sentence; out-of-range
  numbers (which would trap in `Int(value)` elsewhere) are rejected as damaged. Restore
  withdraws any queued sync deletion of the ids it brings back, and waits out a sync in flight,
  whose pull would otherwise have removed what it just inserted.
- **Erase Local Data**: when a session exists — a loaded user *or* a stored token, since an
  offline session check leaves only the token — it syncs once, and if that sync fails it
  erases nothing and says so; otherwise it signs out and clears the cursor, then deletes.
  Signing out first matters: a signed-in incremental cursor would never re-fetch, and the next
  pull would not bring the account back.

### One-tap sign-in, and the server's error codes

- `applinks:stride-api.colorarchive.me` in both apps' entitlements (an entitlement, not a
  plist key). `Shared/LoginLink.swift` accepts only https, that host, path exactly `/login`,
  one token of 16–512 url-safe characters. Both `.onOpenURL` and `onContinueUserActivity` are
  wired, a second delivery of the same tap is ignored (the token is single-use), and a link
  arriving on a device that already has a session is ignored and logged without the token.
  `/login` keeps the copy-paste page, and the login sheet now accepts a pasted full link.
- The review found `GET /session` answers 200 `{user:null}` for a dead session, which the
  client treated as "offline, keep the token": such a device ignored every login link. A
  `{user:null}` now deletes the token, as a 401 does.
- `APIClient` sends `X-Stride-Client: ios|macos/<version>(<build>)` (omitted rather than sent
  malformed), decodes `{error, code?, message?}`, shows `message ?? error`, and gives
  `sync_paused` and `rate_limited` their own translated sentences, so no raw code reaches the
  Settings footer.

### Small items

- The SAVE badge is computed from the real prices, rounded down: 44% at $2.99 / $19.99.
- The share card renders once in `.task`; Weekly Review has an empty state and its Stats
  toolbar button hides with no habits.
- **Analytics removed**: `AnalyticsService`, every call site, the Settings toggle, and the
  `ProductInteraction` entry in the privacy manifest. The appID was a placeholder; nothing was
  ever sent.

### Completion round

A completeness review of `0a59bf3` against the plan listed what was still open; this round
closed it (commit: `3fed14b`).

#### Numbers from sync that cannot crash the app

- **The gap.** Restore was bounded, but sync was not: `TodayView` and `StrideShortcuts` formatted
  amounts with `String(Int(value))`, which traps on ±infinity or |value| ≥ 9.2e18, and
  `/v1/sync/push` stored `value` / `targetValue` unchecked. One bad row pushed by anything —
  a third-party client, a corrupted store — would crash every device on that account that
  pulled it, which is the opposite of M1's goal.
- **Client: `Shared/SafeNumber.swift`, which never traps.** `amount` formats as before ("8",
  "2.5", "1000000"), shows "—" for NaN / ±inf and `%.3g` from 1e15 up; `wholeNumber(_:in:)` is a
  clamped truncation, safe even for `Int.min...Int.max` (where `Double(Int.max)` rounds up to
  2^63); `unitInterval` clamps to 0…1. Today's five amount sites and the Shortcuts formatter
  use it (the Shortcuts `amount` name stays, so the localization scan still matches), Today's
  count ring clamps `habit.progress` — `Habit.progress` has no floor, so a negative synced value
  drew the ring below zero — and AddHabitView reads the target through
  `wholeNumber(…, in: 1...Int(DataBackup.maxAmount))`, keeping targets above the stepper's
  1,000. Every other `Int(…)` in the app, widget and `Shared/` was checked: rates in [0,1] by
  construction, dates, and `Int(habit.sortOrder)`, whose every writer is bounded. 8
  `SafeNumberTests`, including an end-to-end model test with absurd synced check-ins.
- **Server: `invalid_value`.** `routes/sync.js` bounds every pushed number, read once in either
  casing (so the snake_case counters are not doubled): entry `value` and habit `targetValue`
  finite within ±1e9 (= `DataBackup.checkAmount`, negatives included, so nothing a 1.3.0
  restore accepts is refused — refusing a negative would let the next full pull delete it);
  habit `sortOrder` whole within ±1e15 (every app decodes it as a Swift `Int`, and one fraction
  fails the whole pull); group `sortOrder` finite within ±1e15; `reminderHour` 0…23,
  `reminderMinute` 0…59, `timesPerWeek` 1…7, `activeDaysMask` 0…127, whole. Absent or null
  still takes the column default; strings and booleans are invalid. A failing row is skipped
  with reason `invalid_value` and the rest of the push applies, still 200 for every client —
  a shipped app decodes only `ok`. Drop reasons and ownership reasons win over it; entries of a
  refused new habit read `skipped_habit`. **Pull is deliberately not filtered**: a 1.2.3 app
  deletes whatever a full pull lacks, so hiding a stored bad row would delete it on every old
  device. Server suite 375 → 394 (19 bound tests, both casings, raw `1e999`, and a legacy
  headerless snapshot with one bad habit and one bad entry that applies the rest).
  [server/DEPLOY.md](server/DEPLOY.md)'s contract section lists the reason, what a 1.3.1
  client does with it (quarantine), and a pre-deploy audit SQL. **Deployed 2026-09-27**
  (`55c8c72`): production audit 0 / 0 / 0, rehearsal 20/20 (the demo account's 176 real
  entries pushed back 1.2.3-shaped, nothing skipped), and a live push of `value: 1e19` on a
  real demo habit answered `invalid_value` with nothing stored.
- **`AuthService.loginWithSessionToken` removed**, with its one test. No app code ever called
  it (`git log -S`); it came with `f27321a` for a web-login redirect that was never built, and
  it would have stored a token straight from a URL if anyone wired it. Sign-in from a link goes
  only through `handleLoginLink`, which verifies the token with the server.

#### Dynamic Type, VoiceOver and the gates

- **The last fixed symbols**: LoginView (56 pt) and OnboardingView (72 pt) use
  `scaledSystemFont(…, relativeTo: .largeTitle)` capped at `.accessibility2`, like the rest.
  Weekly Review's ring (a 36 pt number in a 120 pt circle, which the plan did not list) became
  `@ScaledMetric` in its own view, so the cap is in the environment the metrics read; its
  "This Week" caption gained a one-line limit and an inset, because a render showed "Esta
  semana" already running into the old ring's stroke at xxxLarge. Old and new ring renders are
  byte-identical at the default size; AX5 renders identical to AX2.
- **Widget count rows** carry the progress in `accessibilityValue` — a percentage rounded
  **down**, so 999 of 1,000 is never read as "100%, not completed" — then the streak phrase.
  VoiceOver used to say only "not completed" at 6 of 8. System-formatted, no new key.
- **A hole in the localization gate**: `case ",", "{", "}" where depth == 0` guarded only `}`, so
  a comma inside nested parentheses ended the ternary scan and `Text(f(a, b) ? "A" : "B")`
  escaped it (the compiler had been warning). Fixed and pinned by a test that fails on the old
  line; a probe ternary in WeeklyReviewView failed the gate, and the widened scan found nothing
  new in the real sources.
- zh-Hant description: 習慣群組 → 習慣分組, the app's own term.

#### Evidence the first sweep could not give

- **`-demo` is deterministic, and DEBUG-only**: `DemoData.populate` clears the store with
  `DataBackup.eraseLocalData(in:)`, groups and orphaned check-ins included — the leftover
  "Morning" group had put a header into the default-size sweep. `-demo` itself is now inside
  `#if DEBUG` (it was not, since 1.0): `StrideApp` is compiled into StrideMac, where
  `open -a Stride --args -demo` reached a Release build and wiped the real store with no
  tombstones — on a signed-in account the next push spread the demo set everywhere. Only
  `a11y_sweep.sh` passes it, on a Debug build. DEBUG-only `-demoScenario
  plurals|weekly` puts one exact number on screen: one habit with one check-in today, and one
  3-a-week habit with a 4-week current and 5-week best streak.
- **Stats below the fold**: DEBUG-only `-statsScrollTo detail|insights|trend|weekday|heatmap`
  (anchors that are `.id`s, compiled out of Release), and `a11y_sweep.sh` captures Stats five
  times — four distinct views without Pro, since insights and trend both land on the locked
  card (the XXXL files are byte-identical, so no capture shows the trend chart's labels). At XXXL: By Weekday switches to full day names at body size; the heatmap's letters,
  cells (≈31 pt against 14) and legend scale, and 10 of its 12–13 week columns are visible,
  ending at the current week, so the strip scrolls. At the default size every new capture
  matches the baseline's hand-scrolled one within sub-pixel tolerance: insights, weekday and
  heatmap 0 pixels, trend 12 pixels, none by more than 16/255.
- **Acceptance (1) and (2) on screen**, iPhone 17 Pro Max, in English, Spanish and Japanese:
  "1 day streak" / "Racha de 1 día" / "1日連続"; Settings "1 check-in" / "1 registro" /
  "1回チェックイン"; the weekly habit's Stats tiles "4 weeks / 5 weeks", "4 semanas / 5
  semanas", "4 週 / 5 週". No screen shows "1 days", "1 check-ins", "Racha de 1 días" or "1
  hábitos".
- **Not shown**, and why: the widget line (`simctl` cannot place a widget — a device check);
  the Pro-only Insights and 8-week trend at XXXL (no purchase on the simulator: both captures
  are the locked card); Today's lower rows and the Settings habit rows at XXXL were captured
  by hand-swiping, since only Stats scrolls itself on launch — every Today row wraps and
  nothing is cut off.

### Verification

Runs for `0a59bf3`, on the shared tree, 2026-09-27, before the orchestrator's merge:

- `StrideTests` on macOS: **179 tests, 0 failures** (119 when M1 started; plan floor 160). The two
  localization suites also pass under `-testLanguage ja -testRegion JP` (12/0; 19 failures
  before the locale fix).
- Hosted `StrideAppTests` on iPhone 17 Pro, run as `STRIDE_HOSTED_ALL=1` once (212/0, the
  StrideTests suite on iOS included) and last on its own: **54 passed, 0 failed**.
- `scripts/ci/build_ios_generic.sh`: all product checks pass. StrideMac builds.
- Mutation checks, each restored afterwards: a naive `startOfDay + 24 h` midnight fails 12 of
  14 widget-plan tests; restore stamping `updatedAt = Date()` fails the round trip; removing
  three review fixes at once fails exactly six new hosted tests; `appLocalized` without
  `locale:` fails five assertions under ja; `Text("Zzz test")` fails the source scan.
- **Default text size, against the pre-M1 baseline** (`a11y_sweep.sh --size default`): Today
  and Stats 0 pixels differ, Settings 8 pixels, none by more than 16/255 (sub-pixel text); the paywall differs only inside the SAVE badge (the
  computed "SAVE 44%"). Acceptance (7) holds. The baseline run first had to move a leftover
  store aside: `DemoData.populate` did not delete groups (fixed in the completion round).
- On the simulator by hand: erase, restore from a v2 file (preview, then both habits, the group
  and the streak back), the v1-file error, the paywall and Settings at accessibility-XXXL.

Completion round, each agent on its own derived data while the others edited the same tree:

- `StrideTests` on macOS: **188 tests, 0 failures**, and 188/0 again under `-testLanguage ja
  -testRegion JP`.
- Server: `npm run typecheck` clean, **394/394**.
- Hosted `StrideAppTests`: **53/0 on the combined tree** (the fixer's run, after
  `testMalformedDeepLinkTokenIsNeverStored` went with `loginWithSessionToken`); earlier 53/0 and
  54/0 were on partial trees. Server 394/394 again after the ±1e9 amount bound; `StrideTests`
  188/0; generic iOS build with product checks and StrideMac pass on the same tree.
- Generic iOS build with product checks, a Release simulator build (the `#if DEBUG` launch
  arguments compile out), StrideMac: all pass.
- Mutation and probe checks: the old scan guard fails the new scanner test twice; a probe ternary
  with nested commas fails the gate.
- `a11y_sweep.sh` at accessibility-XXXL and at default on iPhone 17 Pro Max, and the plural
  acceptance captures (18 PNGs, `-demoScenario`) in en / es / ja — described in
  [Evidence](#evidence-the-first-sweep-could-not-give). These images come from the shared tree
  mid-round; the sweep is re-run on the merged tree before submission.

### Decisions and deviations from DEV-PLAN-1.3.md

| Plan said | Done | Why |
|---|---|---|
| Restore inserts with `touch()` so the next push carries it | Keeps the backup's timestamps; never `touch()` | A backup is the account's own history; stamping it now would let an old file beat newer edits on every other device. 1.3.0 still pushes the whole store on every sync, so restored rows reach the server regardless. |
| Records carry `{date, value, note}` (+ createdAt in an early draft) | Also `id` and `updatedAt`; no `createdAt` | `HabitRecord` has no creation time; M1 does not change the schema, so the file invents none. |
| `+N more` stays only on medium | Also on large, as the last of its rows | A list that stops at eight looks complete; a ninth habit would look lost. |
| Route `appLocalized` through `NSLocalizedString` if stringsdict is skipped | Not needed; `locale:` added instead | `String(localized:bundle:)` does read the stringsdict; what was wrong was the plural *rule*, which follows the locale. |
| Sweep on "the shared iPhone 17 Pro" | iPhone 17 Pro Max | The Pro is held by hosted test runs; the Pro Max is the screenshot device. |
| `.xcstrings` migration "here if it fits" | M3 | The `.strings` + `.stringsdict` split is covered by parity and no-overlap tests. |
| Acceptance (1): the **medium** widget shows "1 remaining" | Checked on **small and large** | `HabitEntry.statusText` is drawn only by those two; the medium widget has no status line. It also needs a habit not yet done today — with the one habit done the line reads "All done! 🎉". DEV-PLAN-1.3.md amended. |
| (not in the plan) | The server bounds pushed numbers: `invalid_value` | The plan assumed the server validated what it stores; `/v1/sync/push` did not, and one absurd number crashes every device on the account that pulls it. The client's `SafeNumber` makes 1.3.0 survive such a row; the bound stops new ones reaching ≤ 1.2.3 devices. M2's skip-reason handling amended. |

### Deliberately not done

- **Restoring ids the server has tombstoned — until M2.** A habit deleted on another device
  and synced comes back locally, then goes again on the first full pull after sign-in (the
  push skips it as `tombstoned`). Re-keying it needs M2's per-row push acknowledgement, and
  whether a restore should undo another device's deletion is a product question. The other
  half — a deletion still *queued* on this device — is fixed: restore withdraws it.
- **Merge-import** into a populated store: M6+, under M2's sync rules.
- **Plural rules in SwiftUI `Text` on a device language Stride does not ship** (fr, ru) — M3,
  with the String Catalog. `appLocalized` is fixed (such a device resolves to
  `en_<region>`), but the widget and `LocalizedStringKey` still take the rule from
  `Locale.current`, which could read "0 habit" in French. Setting the root `\.locale` would also
  turn dates English on those devices, and whether iOS already hands the app `en_FR` was not
  checked; decide on a French device.
- **AppShortcut phrases** are English in every language — M3: they need `AppShortcuts.strings`
  (or a String Catalog), a different mechanism from `Localizable`. Their short titles are
  translated since this release.
- CSV cells starting with `=`, `+`, `-` or `@` are written as typed: the data is the user's
  own, and a leading quote would corrupt ordinary notes such as "- felt good".
- **After a sync's 401, `AuthService.currentUser` stays set** while the token is gone
  (pre-existing): Settings shows signed in with no session, and Erase refuses safely and says
  to log out. Until M2's `needsReauth`, which observes the 401.
- **Out-of-range rows already stored on the server** keep being served on pull (filtering them
  would delete them on every 1.2.3 device); ≤ 1.2.3 devices on such an account can still crash
  until the row is repaired by hand, which is what the pre-deploy audit is for. A ≤ 1.2.3
  device that already holds a bad value locally crashes until it updates.
- **Negative amounts are stored and served**: no UI writes one, but none traps on one
  (`String(Int(-3))` is fine, a negative ring draws nothing, a target ≤ 0 is guarded), and a
  1.3.0 restore accepts them down to −1e9. The first cut of the bounds refused them, which
  would have made a restored habit with a negative target vanish: skipped on push, its entries
  `skipped_habit`, then deleted locally by the next full pull. Server and restore now agree
  (±1e9).
- AddHabitView still truncates a fractional target (2.5 → 2) when the edit sheet is saved, as
  1.2.3 did.
- ~~`AuthService.loginWithSessionToken` has no caller … a removal candidate.~~ Removed in the
  completion round, with its test.
- The Mac shows "Go to Settings → Stride" for notifications, as it did before; "System
  Settings" would be a new key.

## TODO — before 1.3.0 is submitted (M1)

### Code still open

All six items found after `0a59bf3` are closed in the completion round:

- [x] `Shared/DemoData.swift` clears groups too, so `-demo` is deterministic.
- [x] Widget count rows: the progress is in `accessibilityValue`.
- [x] `TodayView` / `StrideShortcuts` format through `SafeNumber`; the server refuses
  `invalid_value`.
- [x] `LoginView` / `OnboardingView` symbols (and the Weekly Review ring) scale, capped.
- [x] `docs/privacy.html` rewritten to match the binary: no analytics, Sentry crash reports,
  what the optional account stores; last updated 2026-09-27. A review then found sentry-cocoa
  8.58.3's defaults sending more than the page said — an event per sync-server 5xx
  (`enableCaptureFailedRequests`), a breadcrumb per request with its URL, status and the pull's
  `since` cursor (`enableNetworkBreadcrumbs`; `beforeSend` clears `event.request`, not
  breadcrumbs), and screen/tap breadcrumbs (`enableAutoBreadcrumbTracking`). Those three are
  turned off in `Shared/SentryBootstrap.swift`; the page now also discloses the per-launch
  session record (the crash-free-rate denominator, kept on) and the StoreKit
  verification-error report, which names the product.
- [x] DEV-PLAN-1.3.md amended: restore keeps timestamps, `+N more` on large, acceptance (1)'s
  widget, `invalid_value` in M2.

### Publication and privacy (owner)

- [ ] **Privacy policy online**: `docs/privacy.html` reaches GitHub Pages only when `main` is
  updated, and the public `stride-site` repo holds a copy; both are publications, so they need
  the owner's go. The stride-site copy is the one that matters for review: the app's Settings
  link, the six descriptions and ASC's `privacyPolicyUrl` all point at
  `jasonyeyuhe.github.io/stride-site/privacy`. Copy it there before submission.
- [ ] **ASC App Privacy**: remove "Product Interaction" (analytics); keep Email Address and
  Other User Content (linked, app functionality) and Crash Data / Other Diagnostic Data (not
  linked) — the same as `Stride/PrivacyInfo.xcprivacy`.

### Server (`invalid_value`) — deployed 2026-09-27

- [x] Before the rsync: the audit SQL in DEPLOY.md's contract section against the production
  backup — all three counts (entry, habit, group) 0. It checks the whole-number fields for
  fractions too, and `habit_groups` (an `inf` group `sortOrder` is served as `null` and fails
  every app's pull decode). A non-zero count is an account whose ≤ 1.2.3 devices can already
  crash or fail to pull; push can no longer change that row, so repair it by hand.
- [x] `scripts/rehearse_server.sh`: its "1.2.3-shaped snapshot of the real account → 200,
  nothing skipped" check now also proves the demo account holds no out-of-bounds row; a FAIL
  with `invalid_value` means the demo data or `seed-demo.js` writes one. (Optional: a
  rehearsal check that pushes `targetValue: 1e19` and expects `invalid_value` with 200.)
- [ ] After the deploy, watch the request log's `reasons=` for `invalid_value` on real
  accounts: a client writing bad numbers, or a device re-sending a row it pulled before.

### Device checks (simulators cannot do these)

- [ ] Acceptance (9): request a link on a device with a Release/TestFlight build (Debug talks to
  `localhost:3002`) and tap it in Apple Mail — signed in, no paste — and in Gmail (the
  copy-paste page). Allow a few hours for Apple's CDN to fetch the AASA after installing.
- [ ] Acceptance (5): fresh install, New Habit → Reminder on → Save shows the system prompt
  before the sheet closes, and the reminder fires.
- [ ] Acceptance (6): place Large (and Extra Large on an iPad) from the gallery; a yes/no row
  flips at once on tap; VoiceOver on a Toggle row does not double "switch"; leave it overnight
  and see the header date and rows flip at midnight.
- [ ] Restore from a file in iCloud Drive that is not downloaded yet.

### Release mechanics

- [x] Provisioning: automatic signing (`-allowProvisioningUpdates`) enabled Associated Domains
  on its own — no portal step. Both exports: Distribution-signed, no `get-task-allow`,
  `applinks:stride-api.colorarchive.me` (`verify_archive.sh --exported`).
- [x] Re-run StrideTests, hosted tests and the default-size sweep on the merged tree (the hosted
  suite passed 53/0 on the combined working tree before the commit); CI green; `check_demo_account.sh` green.
- [x] Version: 1.3.0 (18), `60394a1`; CI green on that commit (Apple job on Xcode 27, 4m40s).
- [x] `scripts/push_metadata.py 1.3.0`: the six descriptions now say small, medium and large (and
  extra large on iPad), with the tap-to-check claim extended to large. The Spanish description
  is 3,989 of 4,000 characters.
- [x] `scripts/release.py prepare 1.3.0` — both version records `PREPARE_FOR_SUBMISSION`, What's
  New in six locales; `build-appstore.sh all --upload` — build 18 uploaded on both platforms
  (iOS `VALID` in TestFlight the same evening).
- [ ] **`scripts/release.py finish 1.3.0 18` — only with the owner's go**, after the device checks.
  ⚠️ `push_metadata.py` used to submit for review as a side effect (and cancel any waiting
  submission); since `d66d200` it only pushes metadata, so `finish` is the one submitting step. The sign-in line in What's New assumes the device check above passes; if the link
  does not open the app in Mail, drop that bullet before `prepare`.
- [ ] Screenshots: only if the store set should show the large widget; the default-size app
  screens did not change.
