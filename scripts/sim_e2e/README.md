# sim_e2e — the simulator end-to-end kit

Real Debug builds of Stride in the two shared simulators, against a throwaway local copy of
`server/`. This is how releases are tested from 1.3.1 on: no TestFlight and no owner device
pass (decided 2026-10-07). The kit covers simulator end-to-end runs, in-place upgrades from real
old builds, container migrations on stores written by old apps, and mixed fleets where an old and
a new app share one account.

The kit from the 1.3.1 runs (RELEASE-1.3.1.md, "The simulator end-to-end run") lived in a
session's scratchpad and was lost with it. This one is committed and does the same things.

**Any release that changes a SwiftData model must pass `upgrade.sh`, the in-place upgrade release
gate, before it is submitted** ([below](#release-gate-the-in-place-upgrade-upgradesh)).

Bash 3.2 (`/bin/bash`) plus small node helpers. Every script but `selftest.sh` prints its usage
when called without arguments, and every script's header comment is its full reference.

## Rules the kit enforces (and the ones it cannot)

- **stride-api is never contacted.** Debug builds call `http://localhost:3002`
  (`APIClient.defaultBaseURL`). Every script talks to `http://127.0.0.1:3002` only. The server
  there is a **copy** of `server/` with a **fresh database**, `NODE_ENV=test`, and no `.env`, started
  with `env -i`, so it has no mail, no Sentry and no production settings. Never point a test app
  or script at `stride-api.colorarchive.me`. Never open a login URL in Safari. Never read, copy
  or source `server/.env` or any production file.
- **The app itself does report to Sentry.** `SentryBootstrap.start()` skips only XCTest runs, so
  every kit launch of a Debug build opens a session (and sends any error or crash) to the
  stride-apple Sentry project, under environment `development` (E2E MIG). Filter on
  `environment:production` when reading release health or issues during a kit run.
- **Port 3002 is the kit's alone.** `start-server.sh` refuses when anything it did not start
  listens there, and never kills it. Stop and report instead. Only one kit server runs at a time.
  Always stop yours at the end (`stop-server.sh`).
- **One root.** All state lives under `$STRIDE_E2E_ROOT` (default `${TMPDIR}stride-sim-e2e`,
  resolved, e.g. `/private/var/folders/…/T/stride-sim-e2e`): server copies, databases, logs,
  DerivedData and worktrees. The kit refuses a root under `~/Documents`, which is iCloud-synced,
  and its only recursive delete refuses any path outside the root. Every DB script refuses a
  database that is not under `$ROOT/servers/`.
- **Two simulators only:** iPhone 17 Pro `F5510EA3-65E5-45D2-8E64-C599625E0873` (alias `pro`) and
  iPhone 17 Pro Max `F54C8C41-12C7-4D02-A579-B2633C3330EF` (alias `promax`). `app.sh` refuses any
  other device. It never creates, erases, deletes or shuts down a simulator, and never runs
  `simctl keychain reset`, because other projects' items are in that Keychain. It may boot a
  shut-down one.
- **Hold the device lock** while you use a device: `lock.sh acquire pro <label>`. If someone else
  holds it, poll every 60 s for up to 40 min (`--wait`), then report BLOCKED. Release only your
  own lock. `scripts/a11y_sweep.sh` takes the same `/tmp/lock-<device>` from 1.4.0; to run it
  inside your own hold, pass `STRIDE_SIM_LOCK_LABEL=<label>`.
- **The hosted tests are not run on the kit's devices.** From 1.4.0 `run_hosted_tests.sh` uses
  "iPhone 17" under `/tmp/lock-iphone-17`. A hosted run installs an unsigned build over the kit's:
  its launch removes every pending `stride.habit.reminder.*` request on the device and spends the
  data container's once-per-install flags. If one ever lands on `pro`/`promax`, `app.sh reset`
  the device; a plain reinstall keeps the spent flags.
- If **CoreSimulator wedges**, run `killall -9 com.apple.CoreSimulator.CoreSimulatorService`.
- The kit never edits app or server code, and never pushes.

## Layout of the root

```
$ROOT/
  servers/<name>/server/        the copy of server/ (node_modules → server/node_modules symlink)
  servers/<name>/server/stride.db   its throwaway database
  servers/<name>/server/SYNC_PAUSED its pause flag (pause.sh)
  servers/<name>/server.log     the server's output + the E2E request lines
  servers/<name>/server.pid
  builds/<label>/dd/            DerivedData of build.sh <label> (current, v1.2.3, v1.3.0, …)
  builds/<label>/build.log
  worktrees/<label>/            a detached worktree of a ref, only while it builds
  upgrades/<label>/             one upgrade.sh run: report.txt, before/ and after/ store copies,
                                devicelog.txt, prefs, first-launch.png, requests.txt; with
                                --reminders also reminders-{before,after}/ (the notification
                                stores) and reminders-{before,after,check}.txt
  push/                         every app.sh notify payload (<UTC time>-<pid>-<kind>.json)
  scratch/                      upgrade.sh's and app.sh reminders' throwaway copies, removed after each read
  selftest.<pid>/               selftest.sh's fake device and stubs, removed when it ends
```

## Quick start

```bash
K=scripts/sim_e2e
$K/start-server.sh e2e --fresh                  # copy + fresh DB on 127.0.0.1:3002
$K/seed-demo.sh e2e                             # optional: demo@stride-review.com with history
APP=$($K/build.sh current)                      # 1.3.1 (20) from this tree
OLD=$($K/build.sh v1.3.0)                       # 1.3.0 (19) from the tag
$K/lock.sh acquire pro my-agent
$K/app.sh clean pro e2e "$APP" --revoke         # installed, launched, signed out, no stale token
TOKEN=$($K/login-token.sh e2e a@example.com)    # paste it in "I have a login token"
# … drive the UI (recipe below) …
M=$($K/log.sh e2e mark); # … tap Sync Now … ; $K/log.sh e2e since "$M"
$K/sql.sh e2e "SELECT id, name FROM habits"
$K/stop-server.sh e2e
$K/lock.sh release pro my-agent
$K/selftest.sh                                  # the kit's own offline checks (no simulator)
```

## Release gate: the in-place upgrade (upgrade.sh)

**What it guards against.** E2E U123 and MIG (2026-10-07), with 1.3.1 (20): on the first launch
after an in-place upgrade from 1.2.3 or 1.3.0, chronod launched `StrideWidgetExtension` together
with the app. `StrideWidget.init()` touches `SharedModelContainer.modelContainer`, so both
processes opened and migrated the same App Group `Stride.store`. The app's `ModelContainer` failed
with CoreData **134110** (underlying **134100**, "the store version hashes didn't migrate"), and
`SharedModelContainer`'s catch fell back to `ModelContainer(for: schema)`: a **new, empty**
`<App Group>/Library/Application Support/default.store`.

- The user saw "Start Your Journey", with every habit hidden.
- `SyncDeliveryMigration.runOnceIfNeeded` was spent on the empty store. It set its done flag,
  stamped 0 rows and pinned nothing.
- On the next launch the real (by then migrated) store opened with every row `syncedAt=nil` and
  pushed the whole store. Recovered Edits filled with rows deleted elsewhere.

It failed 4 of 4 times with the widget in the build and 0 of 2 without it. The one-process
migration test (`testARealDeviceStoreOpensUnderTheNewSchema`) passes on the very same stores, so
**only a real in-place upgrade of the stock build on a simulator shows this**. Never strip the
widget to make the gate pass.

**The fix it checks (from `ac1fbec`).** Only the app opens, creates or migrates the store. After
its own open it writes `stride_store_schema_version` to the App Group prefs, logs "Store opened by
the app", and reloads the widgets. The widget opens the store only when that marker equals its own
schema and the file was written with its own models; until then it logs "Store not opened in the
extension: waitForApp(…)" and draws "Open Stride to see your habits". When it opens, it logs
"Store opened in the extension". `upgrade.sh` reads all three lines.

**Two widget situations, both worth a run.** U123 needs no widget on the home screen: chronod
launches the extension with the app even then (the no-widget runs of 2026-10-07 log
`StrideWidgetExtension` within a second of the app), and 1.3.1 (20)'s `StrideWidget.init()`
opened the store then. That is the default state of the simulators. Since
the fix the extension touches the store only to draw a placed widget (its timeline) or to run its
check-in, so without a placed widget the run proves the extension's launch no longer migrates the
store, but never meets the gate: `upgrade.sh` prints "the gate was not exercised". To exercise it,
place a Stride widget on the home screen while the OLD app is installed (recipe below, after
`reset`, which removes it with the app). The in-place install then reloads it before the app
starts, so the log shows the widget turned away, the app's open, then the widget's open.

**The gate.** Before submitting a build that changes any `@Model`, run `upgrade.sh` from every
shipped version still in use (today 1.2.3 and 1.3.0) to the candidate, on a synced store, with
`--server` and `--relaunch`. Every run must PASS (exit 0). It is a race: a fix that removes it by
design (one opener, or a coordinated migration) should pass every time. Run each pair at least 3
times, with and without a placed widget; one PASS proves little.

```bash
K=scripts/sim_e2e
NEW=$($K/build.sh current); OLD=$($K/build.sh v1.3.0)        # then again with v1.2.3
$K/start-server.sh gate --fresh; DEMO=$($K/seed-demo.sh gate)  # reusable demo token
$K/lock.sh acquire pro gate
$K/app.sh clean pro gate "$NEW" --revoke                       # signed out, no stale token
$K/app.sh reset pro "$OLD"; $K/app.sh launch pro
# UI: sign in with $DEMO, Sync Now. For the delivery marks to be exercised, make the LAST old-app
# sync at least 5 minutes after the rows last changed (SyncDeliveryMigration.margin): the seeded
# history is old enough once the seed is 5 minutes old. The Keychain keeps the session across
# `reset`, so later runs come back signed in and sync at launch: no second sign-in.
# Optional: place a Stride widget (recipe below) to exercise the gate.
# Terminate the old app only once its sync is in the prefs FILE (gotcha below):
until $K/app.sh prefs pro app | grep -q '"stride_last_sync_time"'; do sleep 2; done
$K/app.sh terminate pro
# Then, as "another device", delete one of the account's check-ins, so the first 1.3.1 pull has a
# deletion to apply quietly (it would come back as a recovered edit after U123's fallback):
T=$($K/session.sh gate demo@stride-review.com)                  # once; reuse it for every run
E=$($K/sql.sh gate "SELECT id FROM habit_entries WHERE date < date('now', '-3 days') LIMIT 1" | tail -1)
curl -s -H "Authorization: Bearer $T" -H 'X-Stride-Client: ios/1.3.1(20)' -H 'Content-Type: application/json' \
     --data "{\"habits\":[],\"entries\":[],\"deletedEntryIds\":[\"$E\"]}" http://127.0.0.1:3002/v1/sync/push
$K/upgrade.sh pro "$OLD" "$NEW" --server gate --relaunch      # exit 0 PASS, 3 FAIL
```

**Placing a Stride widget** (iPhone 17 Pro, iOS 26.5, 2026-10-07; screenshot before every tap):
HOME → long-press an empty spot (≈201,600, 1.5 s) → Edit (≈71,33) → Add Widget (≈147,92) →
the search field (≈201,204) → `text` "Stride" (the first time, a "slide to type" tip covers the
results: Continue, ≈201,829) → the Stride row (≈114,254) → Add Widget (≈201,790) → Done
(≈329,33). It lands on page 1 and **survives `app.sh reset`**: SpringBoard keeps it across the
uninstall and install of the same bundle, so every later run has it until you remove it
(long-press it → Edit Home Screen → its "−" → Remove → Done). Remove it when you are done: the
simulators are shared.

```
upgrade.sh <udid> <old app> <new app> [--wait <s>] [--server <name>] [--label <name>] [--relaunch]
           [--reminders <daily habit id>,<Mon/Wed/Fri habit id>]
upgrade.sh check-log <device log>       the device-log check alone, on a saved log
upgrade.sh check-gate <device log>      the store-gate order alone, on a saved log
upgrade.sh check-dir <dir>              the default.store check alone, on a directory
upgrade.sh counts <store dir | file>    row counts + model checksum of a saved store
upgrade.sh prefs <plist | listing>      its stride_delivery_* entries
upgrade.sh check-reminders <listing | dir> <daily id>,<M/W/F id>
                                        the after-upgrade reminder check alone, on an
                                        `app.sh reminders` listing or a directory of the plists
```

### Reminder habits (`--reminders`, from 1.4.0)

1.4.0 changes what a reminder is (RELEASE-1.4.0.md D4): a specific-days habit gets one weekly
trigger per day, `stride.habit.reminder.<id>.<w>` (w = 1 Sun … 7 Sat), instead of 1.3.x's single
daily `stride.habit.reminder.<id>`, which a daily habit keeps; requests carry the category
`stride.habit.binary` or `stride.habit.count`, both registered at launch. The first 1.4.0 launch
after the upgrade converts what 1.3.x left. `--reminders` checks that conversion against the
system's own store, not an app log line:

- **Where it is read.** `<device data>/Library/UserNotifications/<dir>/PendingNotifications.plist`
  and `Categories.plist`; `Library.plist` beside them maps the bundle id to `<dir>`. The device
  data directory is simctl's `dataPath`. Scratch copies only, decoded by `notifications.py`
  (python3 plistlib; NSKeyedArchiver). `app.sh reminders <udid> [destdir]` prints the same
  listing for any run.
- **Before the install** (part of the starting point): both habits' bare ids are pending. Anything
  else exits 1.
- **After the first launch**, re-read up to `STRIDE_E2E_REMINDER_TRIES` times (10), every
  `STRIDE_E2E_REMINDER_PAUSE` s (3), because the daemon writes the file after the app's removes
  and adds. PASS needs all of:
  - the Mon/Wed/Fri habit has exactly `.2`, `.4` and `.6`, and no bare id;
  - the daily habit keeps exactly its bare id;
  - both categories are registered in `Categories.plist`;
  - when the records show categories at all, those four requests carry one of the two.
- **The record format was inferred, not observed.** No simulator here had ever held a pending
  request when this was written: the request records' keys (`AppNotificationIdentifier`,
  `SBSPushStoreNotificationCategoryKey`) come from the iOS 26.5 runtime's UserNotificationsCore
  strings; `Library.plist` and `Categories.plist` were observed. When no record decodes, the
  listing says `decoded-requests strings` and the ids come from the archive's strings, which
  still decide the id checks; request categories are then a NOTE. Check the first real run's
  `reminders-after.txt` against `plutil -p reminders-after/PendingNotifications.plist`.

**The starting point**, on the OLD build, after `app.sh reset <dev> <old app>` (the uninstall
removes the notification permission with the app):

1. Allow notifications. `simctl privacy` cannot grant them, so: in the app, turn on a habit's
   reminder, and answer the system prompt **Allow** with the iOS Simulator MCP
   (`mcp__Claude_Code_iOS_Simulator__control`, screenshot, then tap). An in-place install keeps
   the permission.
2. Create two habits with reminders on: one daily, and one on specific days **Mon, Wed and Fri**.
   Sign in and sync as usual (the gate's scenario).
3. Read their ids: `sql.sh <server> "SELECT id, name FROM habits"` after the sync, or the two
   `stride.habit.reminder.<id>` lines of `app.sh reminders <dev>`.
4. `app.sh reminders <dev>` shows both bare ids pending. Then run
   `upgrade.sh <dev> <old> <new> --server <name> --relaunch --reminders <daily id>,<M/W/F id>`.

A run without `--reminders` reads no notification store, so devices without reminder habits (every
gate run before 1.4.0) work as before.

**Starting point:** `<udid>` runs `<old app>` (the same version and build) over a store it has
synced, with no `default.store` in either container. `app.sh reset` gives that: an uninstall
removes the containers. `upgrade.sh` refuses any other starting point (exit 1).

**What it does:**

1. Terminates the app. Copies `Stride.store` (with `-wal` and `-shm`) to `before/` and prints its
   sha1, row counts and model checksum. Saves the prefs.
2. Runs `xcrun simctl install <new app>` **in place**: no uninstall, so the containers stay. It
   checks the store files are byte-identical after the install. A change there means something
   opened the store before the app did.
3. Cold launches, waits `--wait` seconds (default 20), takes `first-launch.png`, checks the app is
   still running, then terminates it.
4. Checks and prints:
   - **The device log**, from just before the install (`xcrun simctl spawn <udid> log show
     --start …`, the Stride processes and the app's subsystem). It fails on any of these, in any
     Stride process, the widget included:
     - CoreData 134110/134100;
     - "Failed to create ModelContainer … Falling back to default location", the fallback up to
       1.3.1 (20);
     - "Could not open the store", the no-fallback open's error screen (the upgrade-race fix). It
       leaves no `default.store`, but the user sees no habits either.

     The widget's own "Extension could not open the store" is printed, not failed on.
   - **Every `default.store*`** anywhere in the app group container and the data container, with
     the rows of each.
   - **`Stride.store` before and after**: rows of `ZHABIT`, `ZHABITRECORD` and `ZHABITGROUP`, the
     rows with `ZSYNCEDAT` set, and the model checksum. A changed checksum means the store was
     migrated. Rows are read with sqlite3 from a scratch copy, never from the device's files.
   - **The app's `stride_delivery_*` prefs.** A good upgrade of a synced store shows
     `stride_delivery_migration_v1_done`. When rows were stamped it also shows
     `stride_delivery_marks_unproven`, `…_unverified` and `…_deletions_since`. "done" with no marks
     and 0 rows stamped is the U123 signature, unless no row was 5+ minutes older than the last
     sync.
   - **With `--server <name>`:** that server's E2E lines of the launch. After a good upgrade with
     stamped rows, the first full pull carries `?deletionsSince=` and no whole-store push follows.
   - **The store gate** (`check-gate`), in the same device log. It fails when the widget's "Store
     opened in the extension" comes before the app's "Store opened by the app", or when the widget
     was turned away and the app never logged its open. It prints how often the widget was turned
     away before the app's open (with the reasons, e.g. `2 waitForApp(noMarker)`), or a NOTE that
     the gate was not exercised (no widget placed), and whether the widget opened afterwards. A
     log with no gate line at all is a build before the gate, and passes this check.
   - **The marker:** `stride_store_schema_version` in the App Group prefs
     (`group-prefs-after.txt`). Missing in a build with the gate fails: the widget would wait
     forever.
   - **The delivery marks.** From `before/` and the old prefs it counts the rows the migration must
     mark: stamped at least 5 minutes before `stride_last_sync_time`. When there are any, the run
     fails unless the marks wait in the prefs (`stride_delivery_marks_unproven`) or the first full
     pull asked `?deletionsSince=` (the marks' proof ran and cleared them). Neither is U123's
     signature: the migration ran on another store.
   - **Recovered edits:** the lines of the data container's
     `Library/Application Support/SyncRecoveryLog/*.jsonl`. Any new line fails: the gate's
     scenario edits nothing on the upgraded device, so a recovered edit is a row pushed back that
     was deleted elsewhere (U123's relaunch had 17).
5. **With `--relaunch`:** a second cold launch, `relaunch.png`, the relaunch's requests
   (`requests-relaunch.txt`) and the recovered edits again. U123's store switch showed only here:
   the whole store pushed, 17 rows answered `tombstoned`.

**Exit codes:**

- **0 PASS:** no fallback, no widget open before the app's, the marker written (in a build with
  the gate), the qualifying rows marked, no recovered edit.
- **3 FAIL:** a failed open in the log, any `default.store`, the app not running after the wait,
  a widget open before the app's, no marker, qualifying rows left unmarked, or a recovered edit.
- **1:** the run could not be made.

Everything lands in `$ROOT/upgrades/<label>/` (default `<UTC time>-<pro|promax>`), with
`report.txt` holding the printed report.

The `check-*`, `counts` and `prefs` commands need no simulator. Use them on saved evidence; on the
U123 evidence they give:

| input | result |
|---|---|
| `check-log …/U123/devicelog-max-131-first-launch.txt` | exit 3, 8 lines in `Stride` |
| `check-log …/MIG/logstream-130-to-131-nowidget-launch1.txt` | exit 0 |
| `counts …/U123/store-1.2.3` | 7 habits, 135 records, model `OmVVWLSe…` (pre-1.3.1) |
| `counts …/MIG/store-after-123-to-131-withwidget` | 7 / 135, model `iZdeoUTu…`: migrated, though the app ran on the fallback |

## Scripts

### build.sh: Debug simulator builds, ad-hoc signed

```
build.sh current                     the working tree, as it is
build.sh <git-ref> [--keep-worktree] a tag/branch/commit, e.g. v1.2.3, v1.3.0
build.sh clean-worktrees             git worktree remove every kit worktree, then prune
```

- **stdout:** the `.app` path, as the last line.
- **stderr:** version (build), bundle id, app group, source commit, and the entitlement checks.

The build command is:

```
xcodebuild build -project <src>/Stride.xcodeproj -scheme Stride -sdk iphonesimulator -configuration Debug \
  -derivedDataPath $ROOT/builds/<label>/dd -destination 'generic/platform=iOS Simulator' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER=
```

The build is then checked, and no path is printed unless both checks pass:

- the binary has a `__entitlements` section
  (`otool -arch arm64 -l <app>/Stride | grep "sectname __entitlements"`);
- `application-identifier` is in
  `<dd>/Build/Intermediates.noindex/Stride.build/Debug-iphonesimulator/Stride.build/Stride.app-Simulated.xcent`.

A ref is built from a detached worktree at `$ROOT/worktrees/<label>`. `Stride.xcodeproj` is
committed in every tag. The worktree is removed with `git worktree remove` after the build;
`--keep-worktree` keeps it. Rebuilding a label is incremental.

**Never build with `CODE_SIGNING_ALLOWED=NO`.** Without entitlements:

- the simulator Keychain refuses the session token (`-34018`), so the app shows "Signed in" and
  never syncs;
- without the app group, the store silently falls back to the data container.

Builds made 2026-10-07 with Xcode 27.0, by the 1.3.1 (20) tree at `7f764fa`:

| label | version (build) | app |
|---|---|---|
| current | 1.3.1 (20) | `$ROOT/builds/current/dd/Build/Products/Debug-iphonesimulator/Stride.app` |
| v1.3.0 | 1.3.0 (19) | `$ROOT/builds/v1.3.0/dd/Build/Products/Debug-iphonesimulator/Stride.app` |
| v1.2.3 | 1.2.3 (17) | `$ROOT/builds/v1.2.3/dd/Build/Products/Debug-iphonesimulator/Stride.app` |

All three have bundle id `yyh.stride.habittracker` and app group `group.yyh.stride.habittracker`.

### start-server.sh / stop-server.sh: the local server

```
start-server.sh <name> [--fresh] [--test-hooks]
stop-server.sh <name>
```

- `--fresh` wipes `$ROOT/servers/<name>` and starts a new copy with an **empty database**.
- Without `--fresh` it **restarts**: the code is re-copied from `server/` and the database and a
  pause flag are kept. A running server of the same name is stopped first. A restart also resets
  the in-memory limiters, including `/v1/auth/verify`'s **10 per 15 min per IP**.
- `--test-hooks` mounts `server/lib/testHooks.js` (`POST /__test/sweep-tombstones`, loopback only).
- **stdout:** `NAME= PID= BASE= COPY= DB= LOG= PAUSE_FILE=` lines.

How the copy is made:

- `rsync` of `server/`, excluding `node_modules`, `stride.db*`, `.env*`, `SYNC_PAUSED`,
  `.DS_Store` and `test/`. `node_modules` is a symlink to `server/node_modules`.
- `db.js` opens `<copy>/stride.db`, so `server/stride.db` is never opened.
- The request log (`e2e-request-log.js`) is copied in, and one line is injected right after
  `const app = express();` in the **copy's** `index.js`.
- It is started detached as `env -i NODE_ENV=test PORT=3002 BIND_HOST=127.0.0.1
  SYNC_PAUSE_FILE=<copy>/SYNC_PAUSED RESEND_API_KEY= SENTRY_DSN= node <copy>/index.js`.
- It waits for `/health`, then checks that the listener on 3002 is that pid, that the database
  was created in the copy, and that the request log mounted.

`stop-server.sh` sends SIGTERM to the pid in the pid file, but only if that pid is still the
copy's `index.js`. It sends SIGKILL after 20 s, then confirms 3002 is free, and exits 1 if
something else holds it. The copy, database and log stay until the next `--fresh`.

Under `NODE_ENV=test` the global and per-account sync limiters are bypassed. The
`/v1/auth/verify` limit (10 / 15 min / IP) and `/v1/auth/request-link` (3 / 15 min) are not.

### seed-demo.sh: demo history

```
seed-demo.sh <name>
```

Runs the **copy's** `seed-demo.js` with cwd = the copy, `env -i` and no `DEMO_TOKEN`. It creates
`demo@stride-review.com` with 6 habits and about 130 check-ins over 30 days. Running it again
wipes and recreates that account's data, tokens and sessions.

- **stdout:** a fresh **reusable** demo login token, valid 1 year, in this database only. It is
  not used up, so repeated sign-ins with it avoid minting new tokens.
- **stderr:** seed-demo's report.
- The 10 / 15 min verify limit still applies to every sign-in.

### login-token.sh: a sign-in token

```
login-token.sh <name> <email>
```

Writes what `server/auth.js` `createMagicLinkToken` writes:

- `INSERT OR IGNORE` the user, with the email trimmed and lower-cased;
- a `magic_link_tokens` row holding the sha256 of a random 32-byte hex token, with a 30-minute
  expiry, single-use.

No mail is sent.

- **stdout:** the RAW token. Paste it in the app's "I have a login token" field.
- **stderr:** `{"userId":…,"email":"…"}`.

### session.sh: a Bearer token for "another device"

```
session.sh <name> <email>
```

Mints a login token and `POST`s it to `http://127.0.0.1:3002/v1/auth/verify` with curl.

- **stdout:** the session token.
- **stderr:** `{"userId","email"}`.
- Each call uses one of the 10 verifies per 15 min.

Use it to push and pull as another device:

```bash
T=$(scripts/sim_e2e/session.sh e2e a@example.com)
curl -s -H "Authorization: Bearer $T" -H 'X-Stride-Client: ios/1.3.1(20)' http://127.0.0.1:3002/v1/sync/pull
curl -s -H "Authorization: Bearer $T" -H 'X-Stride-Client: ios/1.3.1(20)' -H 'Content-Type: application/json' \
     --data '{"habits":[],"entries":[…],"deletedEntryIds":[…]}' http://127.0.0.1:3002/v1/sync/push
```

Drop `X-Stride-Client` to behave like 1.2.3, or send `ios/1.3.0(19)` to behave like 1.3.0. The
server gates `aliases`, `deletionsSince`, ms timestamps, `cursor_expired`, `snapshot_required`
and the S4 hold-back on the client version.

### account.sh: sessions and support switches

```
account.sh <name> revoke-user <id|email>     delete every session of the user
account.sh <name> lookup <id|email>          {"userId","email","sessions"} (live sessions)
account.sh <name> request-snapshot <userId>  one-shot 409 snapshot_required for the next 1.3.1+ push/pull
account.sh <name> row-error-trigger          entry INSERTs with note REHEARSAL_ROW_ERROR fail (row_error)
```

- `revoke-user` is what a sign-out everywhere, or an expiry, leaves behind. The app's token then
  gets `{user:null}` at the launch session check and 401 from sync.
- `request-snapshot` and `row-error-trigger` run `scripts/sync_rehearsal/accounts.js`, with its
  directory guard pointed at `$ROOT/servers`.

### pause.sh: the sync pause switch

```
pause.sh <name> on [retryAfterSeconds] | off | status
```

The flag file `<copy>/SYNC_PAUSED` is read on every request. While it exists, every
`/v1/sync/*` request answers `503 {code: sync_paused, retryAfterSeconds}` with a `Retry-After`
header (default 900 s). The flag survives a restart without `--fresh`.

### sql.sh: read-only queries

```
sql.sh <name> "<SQL>" [--json]
```

Runs one read-only statement on the throwaway database. better-sqlite3 opens it `readonly`, and
any statement that is not a reader is refused. It is safe while the server runs.

- **stdout:** a header line and `|`-separated rows (`NULL` for null), or one JSON object per row
  with `--json`.
- The tables are `users`, `sessions`, `magic_link_tokens`, `habits`, `habit_entries`,
  `habit_groups`, `deletion_tombstones` (`entity_type`, `entity_id`, `habit_id`, `entry_date`),
  `sync_snapshot_requests` and `user_clients`.

### log.sh: the request trail

```
log.sh <name> [n]            last n (40) E2E lines
log.sh <name> mark           current line count
log.sh <name> since <mark>   E2E lines after the mark
log.sh <name> path           the log file
```

Take a `mark`, do one thing in the app, then read `since`: that is the request trail of that
one action.

### lock.sh: the shared-simulator mutex

```
lock.sh acquire pro|promax [label] [--wait [minutes]]
lock.sh release pro|promax [label]
lock.sh status [pro|promax]
```

The lock is a directory, `/tmp/lock-iphone-17-pro` or `/tmp/lock-iphone-17-pro-max`, the same
convention every project on this Mac uses. `mkdir` is atomic.

- The kit writes a `holder` file (label, pid, since) inside the directory.
- `acquire` exits 1 when someone else holds the lock. With `--wait` it polls every 60 s, for up
  to 40 min by default, then prints `BLOCKED` and exits 2. That is longer than a foreground tool
  call, so run it in the background.
- `release` removes only a lock with your label. A lock without a holder file was taken outside
  the kit and is never removed.
- Give each agent its own label. The default is `sim_e2e`.

### app.sh: the app on a device

`<udid>` is `pro`, `promax`, or either UDID.

```
app.sh install <udid> <app>        install (over an existing one = in-place upgrade, data kept) +
                                   simctl spawn defaults write yyh.stride.habittracker stride_onboarding_completed -bool YES
app.sh reset <udid> <app>          terminate, uninstall, install (see the Keychain gotcha)
app.sh clean <udid> <server> <app> [--revoke]
                                   reset + cold launch + read the launch session check (below)
app.sh version <udid>              the INSTALLED app's version, e.g. "1.3.0 (19)"
app.sh launch <udid> [-- <arg>…]   cold launch (--terminate-running-process) with these app
                                   arguments; prints the pid
app.sh notify <udid> <habitId|-> <binary|count|none> [day]
                                   a simctl push shaped like a 1.4.0 habit reminder (below)
app.sh reminders <udid> [destdir]  the system's notification stores for the app, decoded (below)
app.sh terminate <udid>
app.sh running <udid>              exit 0 when the app is running
app.sh shot <udid> <png>           screenshot
app.sh container <udid>            DATA container (path changes on every in-place install: ask again)
app.sh group <udid>                APP GROUP container (group.yyh.stride.habittracker)
app.sh prefs <udid> [app|group]    plutil -p of the prefs plist FILE
app.sh store <udid> <destdir>      copy Stride.store(+-shm/-wal) out of the app group container;
                                   warns about any default.store in either container
app.sh exports <udid> [destdir]    list (and copy) tmp/StrideExport-* in the data container
```

`clean` decides from the first `GET /v1/auth/session` in the server's E2E log after the launch.
The app makes that check at launch **only when a session token is stored**. In `AuthService`'s
init, `if tokenStore.read() != nil { Task { await checkSession() } }`: 1.3.1 at
`AuthService.swift:104`, 1.3.0 at `:47`, 1.2.3 at `:22`. A signed-out device sends nothing at all,
so silence is the "no token" answer.

| after the launch | meaning | what `clean` does |
|---|---|---|
| no session check within `$STRIDE_E2E_SESSION_WAIT` s (default 30) | no token in the Keychain | done, exit 0, if the app is still running. If it is not, the launch proved nothing: exit 1 |
| `user=null` | a dead token (another server's DB, or revoked). 1.3.0+ deletes it on this answer | reinstall, check again |
| `user=<id>` | a live session on this server | with `--revoke`: revoke-user, relaunch (the app drops the token), reinstall, check again. Without: exit 3 |
| a check with no `user=` | a check without a Bearer | done, exit 0 |

- **`clean` needs a 1.3.0+ build.** 1.2.3 never drops a dead token: it answers `user=null` on
  every launch. `clean` refuses a build below 1.3.0 before it reinstalls anything, and prints the
  documented path: `app.sh clean <udid> <server> <1.3.0+ app>`, then `app.sh reset <udid> <1.2.3
  app>`. The uninstall keeps the Keychain, which is empty by then.
- **Silence cannot tell "no token" from "a token, but the request never reached 3002".**
  `require_running` makes sure the kit's server is the one on 3002. A token that remained would
  show as "Signed in" in Settings at the next step.

**Launch arguments** (1.4.0). Everything after `--` goes to the app, and into UserDefaults'
argument domain for that launch only: `app.sh launch pro -- -tab 1`, or D7's DEBUG
background-handler argument. stdout stays the pid alone (upgrade.sh reads it); the arguments are
echoed on stderr. Arguments without `--` are refused.

**`notify`: the notification actions without waiting for a reminder** (RELEASE-1.4.0.md D7, the
router matrix). It writes a payload under `$ROOT/push/` and runs
`xcrun simctl push <udid> yyh.stride.habittracker <file>`:

```json
{
  "aps": {
    "alert": {"body": "category stride.habit.binary, habitId <id>, day 2026-10-10", "title": "Stride E2E push"},
    "category": "stride.habit.binary",
    "sound": "default",
    "thread-id": "<id>"
  },
  "day": "2026-10-10",
  "habitId": "<id>"
}
```

- `binary` / `count` set `aps.category` to `stride.habit.binary` / `stride.habit.count`, which
  gives the banner Mark Done / Add 1 and Snooze 1 Hour. `none` sets no category: a 1.3.x-shaped
  banner with no buttons.
- `-` leaves out `habitId` (and `thread-id`), as a 1.3.x request has none.
- `day` is top-level, as on a snooze (`yyyy-MM-dd`, the day the reminder was for).
- Neither the id nor the day is validated: malformed and lower-case ids are router cases too.
- The banner appears only once notifications are allowed (the starting point under "Reminder
  habits") and only while Stride is not frontmost, since the app has no `willPresent`: press HOME
  first. Expand the banner (long-press it with the iOS Simulator MCP) to reach its actions.
- A push proves the router and the action handler, not the scheduling. D7 keeps one real fire: two
  reminders two minutes ahead, the app terminated and the device locked.

**`reminders`: what the system holds.** It copies `PendingNotifications.plist`,
`DeliveredNotifications.plist` and `Categories.plist` of the app's
`<device data>/Library/UserNotifications/<dir>/` into `<destdir>` (or a scratch directory), and
prints one tab-separated line per fact:

```
source              <the directory read>
decoded-requests    records | strings | none
request             <id>  <category | - | ?>  <trigger, e.g. weekday=2 hour=20 minute=0 repeats>
decoded-delivered   records | strings
delivered           <id>  <category>  <trigger>
decoded-categories  records | strings | none
category            <id>  <action ids>
```

D7's "exactly 3 pending weekday triggers" for a Mon/Wed/Fri habit is three `request` lines
`stride.habit.reminder.<id>.2/.4/.6` and no bare `stride.habit.reminder.<id>`. Delivered banners
withdrawn by a check-in disappear from the `delivered` lines. `notifications.py`'s header has
the archive format and what was inferred rather than observed.

### selftest.sh: the kit's own checks, offline

```
selftest.sh [--keep]
```

It runs `app.sh` and `upgrade.sh` for real against a fake device: plain directories under
`$ROOT/selftest.<pid>/`, with `xcrun`, `lsof` and `ps` stubbed on `PATH`. The `xcrun` stub refuses
any call it does not know, so no simulator, server, port or lock is touched. It takes under a
minute (93 cases; 30 s on a heavily loaded Mac on 2026-10-10).

It covers:

- `bash -n` and `node --check` on every script;
- `app.sh running` with 200 KB of `launchctl list` after the match (the SIGPIPE false negative);
- every `app.sh clean` branch but `--revoke`, including no session check from a 1.3.x build
  (clean), a crash at launch, and a 1.2.3 build (refused before anything is reinstalled);
- `upgrade.sh`'s checks on fixtures (the error-screen line and the widget's note included), a PASS
  run, a FAIL run (134110 in the log plus a `default.store` in the app group), and the refused
  starting point;
- the store gate's checks: `check-gate` on five logs (the gate held, the widget first, the app
  never opened, a build before the gate, no widget request), and runs that pass with the gate, the
  marker, the marks and a quiet relaunch, or fail on a missing marker, a widget open first,
  unmarked rows, or recovered edits on the relaunch;
- `app.sh store`'s warning about an app-group `default.store`;
- 1.4.0: `app.sh launch -- <args>` (the stub records the app's arguments; arguments without `--`
  are refused); `app.sh notify` for each kind, with and without a day, a lower-case id, an unknown
  kind, and a not-installed app (the stub's `push` records every payload and refuses one without
  `aps.category`, or with the wrong one, unless the case means `none`); `app.sh reminders` through
  `Library.plist` and by the directory scan, and with no store yet; `check-reminders` on seven
  fixture stores (NSKeyedArchiver archives built by the selftest: the conversion, none, a bare id
  left, a daily habit given weekdays, no categories, an unregistered category, unknown record
  keys); and `upgrade.sh --reminders` runs that pass, fail, or are refused at the starting point,
  plus a run without the flag that reads no store.

Run it after any change to the kit. `SELFTEST_KIT=<dir>` runs the same cases against another copy
of the kit. The kit at `aa8d8fd` fails 15 of them, the cases these fixes are for, and the kit at
`ac1fbec` fails the 13 store-gate cases.

## The E2E request line

`start-server.sh` injects `e2e-request-log.js` into the copy. It writes one line per request
when the response finishes. `GET /health` is not logged.

```
E2E <iso> <METHOD> <path> <status> client=<X-Stride-Client|-> [user=<id>|null] [error=<code>]
    [push: applied=habits:…,entries:…,groups:… skipped=habits:…,… skippedReasons=<json>|- aliases=<json>|-
           sentHabits=… sentEntries=… sentGroups=… sentDeletedHabitIds=… sentDeletedEntryIds=… sentDeletedGroupIds=…]
    [pull: full|since out=habits:…,entries:…,groups:…,deletions:… withheld=<n> deletionsSince=<n>|incomplete|-]
```

- **`<path>`:** every query value is `[REDACTED]` except `since` and `deletionsSince`, which are
  the pull cursors.
- **`user=`:** the owner of the request's Bearer token **when it arrived**, read with a plain
  SELECT that never slides or deletes the session. `null` means the server does not know the
  token, or it expired. There is no `user=` when no Bearer was sent. On `/v1/auth/verify` it is
  the user who signed in.
- **`error=`:** the `code` (or `error`) of a 4xx/5xx JSON answer, e.g. `sync_paused`,
  `snapshot_required`, `cursor_expired`, `Unauthorized`.
- **`sent…=`:** a count, then up to 8 items as `[ID8@day=value,…]` (entries) or `[ID8,…]`, cut
  with `…+N`. `ID8` is the first 8 characters of the id. `push: body-not-read` means the push was
  refused before its body was parsed (pause, 401, 429).
- **`withheld`:** entry deletions held back from an app below 1.3.1 because the same pull carries
  that day's replacement (E2E S4).
- **`deletionsSince`:** a 1.3.1 full pull's deletion list size, or `incomplete`.

Example:

```
E2E 2026-10-06T16:46:03.753Z POST /v1/sync/push 200 client=ios/1.3.1(20) user=1 push: applied=habits:0,entries:1,groups:0 skipped=habits:0,entries:0,groups:0 skippedReasons=- aliases=- sentHabits=0 sentEntries=1[AFCEE62A@2026-10-08=1] sentGroups=0 sentDeletedHabitIds=0 sentDeletedEntryIds=1[338F10BF] sentDeletedGroupIds=0
E2E 2026-10-06T16:45:54.099Z GET /v1/sync/pull?since=2026-10-01T00:00:00.000Z 200 client=ios/1.3.1(20) user=1 pull: since out=habits:0,entries:28,groups:0,deletions:0 withheld=0 deletionsSince=-
E2E 2026-10-06T16:45:54.395Z GET /v1/sync/pull 503 client=ios/1.3.1(20) user=1 error=sync_paused
```

How each version syncs, as seen in the log:

- **1.3.1:** pushes only changed rows. An idle sync pushes `0/0/0` or nothing. It pulls with ms
  cursors and `?deletionsSince=` on its first full pull after an upgrade.
- **1.3.0 and 1.2.3:** push their **whole store** on every sync, and pull with
  `since` = last pull − 60 s.
- **1.3.0:** sends `X-Stride-Client: ios/1.3.0(19)`.
- **1.2.3:** sends no client header (`client=-`) and gets error sentences instead of codes.

## UI recipe (iPhone 17 Pro, 1.3.1). Verify every tap by screenshot

Use `mcp__Claude_Code_iOS_Simulator__control`. Load it with ToolSearch
`select:mcp__Claude_Code_iOS_Simulator__control`. Use screenshot, tap, swipe, text and button.
Never use `attach`.

- **Take a screenshot before every tap.** These coordinates were right for 1.3.1 on 2026-09-29
  and **drift between versions and builds**; the screenshot decides.
- Wait about 2 s after tab switches and sheet presentations, and 2–3 s after `text`.

**iPhone 17 Pro (402×874 pt)**

| action | where |
|---|---|
| Tab bar | Today (115,820) · Stats (201,820) · Settings (286,820) |
| Sign in | Settings → Account "Sign In" (≈160,523) → "I have a login token" (≈201,526) → Token field (≈201,462) → `text` the token → wait 3 s → "Log In" (≈201,410 with the keyboard up) |
| Sync Now | Settings → (≈130,576) |
| Log Out | Settings → (≈110,628) |
| Create a habit | Today "+" (364,84) → name field (201,303) → `text` → Save (351,100) |
| Check in | the row's circle on the right. The first row is at ≈(353,418) when signed in |
| Delete a habit | Settings → Active Habits → swipe the row left → Delete |

**iPhone 17 Pro Max (440×956 pt):** tab bar Today (134,903) · Stats (220,903) · Settings (306,903).
Find everything else by screenshot.

**Triggering a sync.** There is no pull-to-refresh. Use one of:

- Settings → Sync Now;
- HOME, then `xcrun simctl launch <udid> yyh.stride.habittracker` (foreground);
- a cold launch (`app.sh launch`).

Then read `log.sh <name> since <mark>`.

## Gotchas

**Keychain, signing and containers**

- **The session token survives uninstall.** It is in the simulator Keychain. A reinstalled app
  can come back signed in, or showing "Sign in again" after it drops a dead token. Use
  `app.sh clean`, never a bare `reset`, when you need a signed-out device. 1.2.3 never drops a
  dead token: clean with a 1.3.0+ build first, then `reset` to 1.2.3.
- **Ad-hoc signing only.** `CODE_SIGNING_ALLOWED=NO` gives an app with no entitlements: Keychain
  `-34018`, "Signed in" that never syncs, and a store outside the app group.
- **The data container's folder name changes on an in-place install.** Call
  `app.sh container` again and check its contents. Never reuse a path from before the install.
- **`simctl spawn … defaults read` misleads.** Read the plist file: `app.sh prefs`. Writing with
  `simctl spawn … defaults write`, as `install` does for onboarding, works.
- **The store is `Stride.store`, not `default.store`.** It sits at the root of the APP GROUP
  container (`SharedModelContainer.storeURL`). When opening it throws, `SharedModelContainer`
  falls back to `ModelContainer(for: schema)`, SwiftData's default location:
  - **`<App Group>/Library/Application Support/default.store`**, next to the untouched
    `Stride.store`, for an app that has its app group. That is the upgrade race (E2E U123): the app
    ran on an empty store. A check of the data container misses it.
  - **`<data container>/Library/Application Support/default.store`** for a build without the app
    group entitlement.

  `app.sh store` warns about a `default.store` anywhere in either container, and `upgrade.sh`
  fails on one.
- **`plutil -extract` cannot read the entitlements' keys,** because it splits key paths on the
  dots in `com.apple.security.application-groups`. Use
  `PlistBuddy -c 'Print :com.apple.security.application-groups:0'`.

- **Terminate the old app only once its sync is in the prefs file.** The simulator's cfprefsd
  writes the plist lazily. Two gate runs on 2026-10-07 (R5, R6) terminated the old app 6 s after
  its sync: the file still had no `stride_last_sync_time`, the in-place install lost what
  cfprefsd had not written, and the 1.3.1 launch found a never-synced store. It pushed the row
  deleted elsewhere, which came back `tombstoned`: one recovered edit, and a FAIL that says
  nothing about the store open. `upgrade.sh` prints "the old app has never synced" for such a
  starting point; poll `app.sh prefs <udid> app` for `stride_last_sync_time` before you
  terminate. Reruns that waited passed.

**Server and network**

- **`/v1/auth/verify` allows 10 per 15 min per IP.** That covers the app's Log In and
  `session.sh` together. When you hit it: `start-server.sh <name>` (restart, DB kept).
- **localhost.** The app calls `localhost:3002` and the server binds `127.0.0.1` only. The
  simulator falls back from `::1` to IPv4 by itself, so this needs nothing.
- **A restart re-copies the server code** from the working tree. The database and pause flag stay.

**Simulators and builds**

- **The shared simulators may be shut down** (both were on 2026-10-07). `app.sh` boots one when
  it needs it, and never shuts one down.
- **The builds are fat binaries** (x86_64 + arm64), because the destination is generic. Keep
  `-arch arm64` on `otool`.

## Cleaning up

- `stop-server.sh <name>` when you are done. It is mandatory.
- `lock.sh release <device> <label>`.
- `build.sh clean-worktrees` if a build failed half-way and left a worktree.

The built apps under `$ROOT/builds` are reused by later runs. They are build output in TMPDIR,
not repo files. `$ROOT/upgrades/<label>/` is the evidence of an `upgrade.sh` run. Copy what a doc
cites into the repo before the root goes.
