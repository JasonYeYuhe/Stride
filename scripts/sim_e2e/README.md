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
  own lock.
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
                                devicelog.txt, prefs, first-launch.png, requests.txt
  scratch/                      upgrade.sh's throwaway store copies, removed after each read
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

**The gate.** Before submitting a build that changes any `@Model`, run `upgrade.sh` from every
shipped version still in use (today 1.2.3 and 1.3.0) to the candidate, on a synced store. Every run
must PASS (exit 0). It is a race: a fix that removes it by design (one opener, or a coordinated
migration) should pass every time. Run each pair at least 3 times; one PASS proves little.

```bash
K=scripts/sim_e2e
NEW=$($K/build.sh current); OLD=$($K/build.sh v1.3.0)        # then again with v1.2.3
$K/start-server.sh gate --fresh; DEMO=$($K/seed-demo.sh gate)  # reusable demo token
$K/lock.sh acquire pro gate
$K/app.sh clean pro gate "$NEW" --revoke                       # signed out, no stale token
$K/app.sh reset pro "$OLD"; $K/app.sh launch pro
# UI: sign in with $DEMO, Sync Now. For the delivery marks to be exercised, make the LAST old-app
# sync at least 5 minutes after the rows last changed (SyncDeliveryMigration.margin).
$K/upgrade.sh pro "$OLD" "$NEW" --server gate                  # exit 0 PASS, 3 FAIL
```

```
upgrade.sh <udid> <old app> <new app> [--wait <s>] [--server <name>] [--label <name>]
upgrade.sh check-log <device log>       the device-log check alone, on a saved log
upgrade.sh check-dir <dir>              the default.store check alone, on a directory
upgrade.sh counts <store dir | file>    row counts + model checksum of a saved store
upgrade.sh prefs <plist | listing>      its stride_delivery_* entries
```

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

**Exit codes:**

- **0 PASS:** no fallback.
- **3 FAIL:** a failed open in the log, any `default.store`, or the app not running after the
  wait.
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
app.sh launch <udid>               cold launch (--terminate-running-process); prints the pid
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

### selftest.sh: the kit's own checks, offline

```
selftest.sh [--keep]
```

It runs `app.sh` and `upgrade.sh` for real against a fake device: plain directories under
`$ROOT/selftest.<pid>/`, with `xcrun`, `lsof` and `ps` stubbed on `PATH`. The `xcrun` stub refuses
any call it does not know, so no simulator, server, port or lock is touched. It takes about 12 s.

It covers:

- `bash -n` and `node --check` on every script;
- `app.sh running` with 200 KB of `launchctl list` after the match (the SIGPIPE false negative);
- every `app.sh clean` branch but `--revoke`, including no session check from a 1.3.x build
  (clean), a crash at launch, and a 1.2.3 build (refused before anything is reinstalled);
- `upgrade.sh`'s checks on fixtures (the error-screen line and the widget's note included), a PASS
  run, a FAIL run (134110 in the log plus a `default.store` in the app group), and the refused
  starting point;
- `app.sh store`'s warning about an app-group `default.store`.

Run it after any change to the kit. `SELFTEST_KIT=<dir>` runs the same cases against another copy
of the kit. The kit at `aa8d8fd` fails 15 of them, the cases these fixes are for.

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
