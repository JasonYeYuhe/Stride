#!/bin/bash
# selftest.sh [--keep]   the kit's own checks, offline: no simulator, no server, no port 3002.
#
# `xcrun`, `lsof` and `ps` are stubbed on PATH for the scripts under test, so app.sh and
# upgrade.sh run their real code against a fake device (plain directories) under
# $ROOT/selftest.<pid>/, with their own STRIDE_E2E_ROOT there. The xcrun stub refuses every call
# it does not know (exit 99), so nothing can reach a real simulator; the lock directories are
# never touched (app.sh only warns that nobody holds them). One line per case; exit 1 on any
# failure. --keep leaves the directory for a look. SELFTEST_KIT=<dir> runs the cases against
# another copy of the kit (e.g. an older commit's, to see a case fail before its fix).
source "$(dirname "$0")/lib.sh"

KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1
KIT="${SELFTEST_KIT:-$KIT_DIR}"
SQLITE=/usr/bin/sqlite3
[[ -x "$SQLITE" ]] || SQLITE="$(command -v sqlite3 || die "sqlite3 is required")"

T="$ROOT/selftest.$$"
rm_under_root "$T"
mkdir -p "$T/bin" "$T/fixtures" "$T/apps"
cleanup() { if [[ $KEEP -eq 0 ]]; then rm_under_root "$T"; else note "kept $T"; fi; }
trap cleanup EXIT

# ── Stubs ───────────────────────────────────────────────────────────────────────────────────
cat >"$T/bin/xcrun" <<'STUB'
#!/bin/bash
# selftest stub: a fake simulator in $FAKE (installed, running, data/, group/, devdata/ — the
# device's own data directory, with Library/UserNotifications —, device.log, launch-args (one
# line per launch: the app's arguments), pushes/<n>.json (every simctl push payload),
# launches = one action per launch: silent | session:<line suffix> | crash | fallback |
# gate | gate-nomarker | gate-nomarks | gate-proved | widget-first | edits |
# un:<fixture> (the notification stores become $FAKE_UN_FIXTURES/<fixture>)).
# push checks its payload like a reminder: aps.alert always; aps.category present, and equal to
# stride.habit.$FAKE_PUSH_KIND when that is binary or count; absent when it is none (exit 97).
set -u
F="$FAKE"
echo "xcrun $*" >>"$F/calls"
[[ "${1:-}" == simctl ]] || { echo "stub xcrun: refusing $*" >&2; exit 99; }
shift
cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    if [[ " $* " == *" -j "* ]]; then
      printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"udid":"%s","name":"iPhone 17 Pro","state":"Booted","dataPath":"%s"},{"udid":"%s","name":"iPhone 17 Pro Max","state":"Shutdown","dataPath":"%s"}]}}\n' \
        "$FAKE_UDID_PRO" "$F/devdata" "$FAKE_UDID_PROMAX" "$F/devdata-max"
    else
      printf '== Devices ==\n-- iOS 26.5 --\n    iPhone 17 Pro (%s) (Booted) \n    iPhone 17 Pro Max (%s) (Shutdown) \n' "$FAKE_UDID_PRO" "$FAKE_UDID_PROMAX"
    fi ;;
  push)
    # simctl push <udid> <bundle id> <payload file>
    [[ -f "$F/installed" ]] || { echo "stub push: the app is not installed" >&2; exit 1; }
    [[ -f "${3:-}" ]] || { echo "stub push: no payload file '${3:-}'" >&2; exit 98; }
    mkdir -p "$F/pushes"
    cp "$3" "$F/pushes/$(( $(find "$F/pushes" -name '*.json' | wc -l) + 1 )).json"
    plutil -extract aps.alert xml1 -o /dev/null "$3" 2>/dev/null || { echo "stub push: no aps.alert" >&2; exit 97; }
    category="$(plutil -extract aps.category raw -o - "$3" 2>/dev/null || true)"
    case "${FAKE_PUSH_KIND:-}" in
      none) [[ -z "$category" ]] || { echo "stub push: aps.category '$category' on a push meant to have none" >&2; exit 97; } ;;
      binary|count) [[ "$category" == "stride.habit.$FAKE_PUSH_KIND" ]] || { echo "stub push: aps.category '$category', not stride.habit.$FAKE_PUSH_KIND" >&2; exit 97; } ;;
      *) [[ -n "$category" ]] || { echo "stub push: no aps.category" >&2; exit 97; } ;;
    esac
    echo "Notification sent to '$2'" ;;
  boot|bootstatus) ;;
  terminate) rm -f "$F/running" ;;
  uninstall) rm -f "$F/installed" "$F/running" ;;
  install) echo "$2" >"$F/installed" ;;
  get_app_container)
    case "$3" in
      app) [[ -f "$F/installed" ]] || exit 1; cat "$F/installed" ;;
      data) mkdir -p "$F/data"; echo "$F/data" ;;
      group.*) mkdir -p "$F/group"; echo "$F/group" ;;
      *) exit 1 ;;
    esac ;;
  launch)
    [[ -f "$F/installed" ]] || { echo "not installed" >&2; exit 1; }
    # simctl launch [--options] <udid> <bundle id> [app arguments…]: record the app's arguments.
    while [[ "${1:-}" == --* ]]; do shift; done
    shift 2
    echo "${*:-<none>}" >>"$F/launch-args"
    action="silent"
    if [[ -s "$F/launches" ]]; then
      action="$(sed -n 1p "$F/launches")"
      sed -i '' 1d "$F/launches"
    fi
    case "$action" in
      silent) ;;
      session:*) echo "E2E 2026-10-07T00:00:00.000Z GET /v1/auth/session 200 client=ios/1.3.1(20)${action#session:}" >>"$FAKE_SERVER_LOG" ;;
      crash) echo "yyh.stride.habittracker: 4242"; exit 0 ;;
      fallback)
        mkdir -p "$F/group/Library/Application Support"
        cp "$FAKE_EMPTY_STORE" "$F/group/Library/Application Support/default.store"
        cat >>"$F/device.log" <<'LOG'
2026-10-07 02:09:14.456 E  Stride[39751:859c8e] [com.apple.coredata:error] CoreData: error: addPersistentStoreWithType:configuration:URL:options:error: returned error NSCocoaErrorDomain (134110)
2026-10-07 02:09:14.464 E  Stride[39751:859c8e] [yyh.stride.habittracker:ModelContainer] Failed to create ModelContainer at /fake/Stride.store: The operation couldn’t be completed. (SwiftData.SwiftDataError error 1.). Falling back to default location — user data from App Group will not be visible.
LOG
        ;;
      gate|gate-nomarker|gate-nomarks|gate-proved|widget-first)
        # A build with the store gate (the upgrade-race fix): the widget turned away, the app's
        # open (marker, then reload), the widget's open; the delivery migration's prefs.
        if [[ "$action" == widget-first ]]; then
          echo "2026-10-07 04:00:01.900 Df StrideWidgetExtension[7:8] [yyh.stride.habittracker:ModelContainer] Store opened in the extension at schema 1" >>"$F/device.log"
        else
          echo "2026-10-07 04:00:01.100 Df StrideWidgetExtension[7:8] [yyh.stride.habittracker:ModelContainer] Store not opened in the extension: waitForApp(noMarker)" >>"$F/device.log"
        fi
        echo "2026-10-07 04:00:02.200 Df Stride[9:10] [yyh.stride.habittracker:ModelContainer] Store opened by the app: marker 1 written, widgets reloaded" >>"$F/device.log"
        echo "2026-10-07 04:00:02.900 Df StrideWidgetExtension[7:8] [yyh.stride.habittracker:ModelContainer] Store opened in the extension at schema 1" >>"$F/device.log"
        P="$F/data/Library/Preferences/yyh.stride.habittracker.plist"
        plutil -replace stride_delivery_migration_v1_done -bool YES "$P"
        case "$action" in
          gate-nomarks|gate-proved) ;;
          *) plutil -replace stride_delivery_marks_unproven -bool YES "$P" ;;
        esac
        if [[ "$action" == gate-proved ]]; then
          echo "E2E 2026-10-07T00:00:01.000Z GET /v1/sync/pull?deletionsSince=2026-10-06T17:05:20.882Z 200 client=ios/1.3.1(21) user=1 pull: full out=habits:2,entries:3,groups:0,deletions:1 withheld=0 deletionsSince=1" >>"$FAKE_SERVER_LOG"
        fi
        if [[ "$action" != gate-nomarker ]]; then
          mkdir -p "$F/group/Library/Preferences"
          G="$F/group/Library/Preferences/group.yyh.stride.habittracker.plist"
          [[ -f "$G" ]] || plutil -create xml1 "$G"
          plutil -replace stride_store_schema_version -integer 1 "$G"
        fi ;;
      edits)
        # Rows pushed back and answered tombstoned: the U123 relaunch's Recovered Edits.
        mkdir -p "$F/data/Library/Application Support/SyncRecoveryLog"
        printf '{"reason":"tombstoned"}\n{"reason":"tombstoned"}\n' >>"$F/data/Library/Application Support/SyncRecoveryLog/account-1.jsonl" ;;
      un:*)
        # What the system's notification stores hold after this launch (a 1.4.0 reschedule).
        U="$F/devdata/Library/UserNotifications"
        mkdir -p "$U/$FAKE_UN_DIR"
        cp "$FAKE_UN_FIXTURES/Library.plist" "$U/"
        rm -f "$U/$FAKE_UN_DIR/"*.plist
        cp "$FAKE_UN_FIXTURES/${action#un:}/"*.plist "$U/$FAKE_UN_DIR/" ;;
    esac
    touch "$F/running"
    echo "yyh.stride.habittracker: 4242" ;;
  spawn)
    shift  # the udid
    case "${1:-}" in
      launchctl)
        # The match FIRST, then far more than a pipe buffer: `| grep -q` stops reading at the
        # match and this stub dies of SIGPIPE, as launchctl did on the device (E2E REL).
        if [[ -f "$F/running" ]]; then printf '27001\t0\tUIKitApplication:yyh.stride.habittracker[c594][rb-legacy]\n'; fi
        for i in $(seq 1 4000); do printf -- '-\t0\tcom.apple.selftest.filler.%05d.padding.padding.padding\n' "$i"; done ;;
      defaults) ;;
      log) cat "$F/device.log" 2>/dev/null || true ;;
      *) echo "stub xcrun: refusing spawn $*" >&2; exit 99 ;;
    esac ;;
  io) : >"${@: -1}" ;;
  *) echo "stub xcrun: refusing simctl $cmd $*" >&2; exit 99 ;;
esac
STUB
cat >"$T/bin/lsof" <<'STUB'
#!/bin/bash
echo "$FAKE_SERVER_PID"
STUB
cat >"$T/bin/ps" <<'STUB'
#!/bin/bash
if [[ "$*" == "-o command= -p $FAKE_SERVER_PID" ]]; then echo "node $FAKE_SERVER_COPY/index.js"; exit 0; fi
exec /bin/ps "$@"
STUB
chmod +x "$T/bin/"*

# ── Fixtures ────────────────────────────────────────────────────────────────────────────────
make_app() {  # make_app <dir> <version> <build>
  mkdir -p "$1"
  plutil -create xml1 "$1/Info.plist"
  plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$1/Info.plist"
  plutil -insert CFBundleShortVersionString -string "$2" "$1/Info.plist"
  plutil -insert CFBundleVersion -string "$3" "$1/Info.plist"
}
make_app "$T/apps/123/Stride.app" 1.2.3 17
make_app "$T/apps/130/Stride.app" 1.3.0 19
make_app "$T/apps/131/Stride.app" 1.3.1 20

make_store() {  # make_store <file> <checksum> <habits> <records> [syncedAt-column]
  local f="$1" i
  plutil -create xml1 "$T/fixtures/meta.plist"
  plutil -insert NSStoreModelVersionChecksumKey -string "$2" "$T/fixtures/meta.plist"
  local col=""
  [[ "${5:-}" == synced ]] && col=", ZSYNCEDAT TIMESTAMP"
  "$SQLITE" "$f" "CREATE TABLE ZHABIT (Z_PK INTEGER PRIMARY KEY$col); CREATE TABLE ZHABITRECORD (Z_PK INTEGER PRIMARY KEY$col);
    CREATE TABLE ZHABITGROUP (Z_PK INTEGER PRIMARY KEY$col);
    CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR(255), Z_PLIST BLOB);
    INSERT INTO Z_METADATA VALUES (1, 'selftest', readfile('$T/fixtures/meta.plist'));"
  for ((i = 0; i < $3; i++)); do "$SQLITE" "$f" "INSERT INTO ZHABIT DEFAULT VALUES"; done
  for ((i = 0; i < $4; i++)); do "$SQLITE" "$f" "INSERT INTO ZHABITRECORD DEFAULT VALUES"; done
}
make_store "$T/fixtures/old.store" OLDMODEL= 2 3
make_store "$T/fixtures/empty.store" NEWMODEL= 0 0 synced
# A 1.3.0 store with its rows' stamps (Core Data seconds since 2001): 2 habits and 3 records long
# before the old app's last sync (2026-10-06T17:06:20Z), and 1 record 1 minute before it — not
# marked (SyncDeliveryMigration.margin). 5 rows qualify.
"$SQLITE" "$T/fixtures/stamped.store" "CREATE TABLE ZHABIT (Z_PK INTEGER PRIMARY KEY, ZUPDATEDAT TIMESTAMP, ZCREATEDAT TIMESTAMP);
  CREATE TABLE ZHABITRECORD (Z_PK INTEGER PRIMARY KEY, ZUPDATEDAT TIMESTAMP, ZDATE TIMESTAMP);
  CREATE TABLE ZHABITGROUP (Z_PK INTEGER PRIMARY KEY, ZUPDATEDAT TIMESTAMP, ZCREATEDAT TIMESTAMP);
  INSERT INTO ZHABIT VALUES (1, 800000000, 700000000), (2, NULL, 700000000);
  INSERT INTO ZHABITRECORD VALUES (1, 800000000, 800000000), (2, NULL, 800000000), (3, 800000000, 800000000),
    (4, $(( $(date -j -u -f '%Y-%m-%dT%H:%M:%S' 2026-10-06T17:05:20 +%s) - 978307200 )), 800000000);"

plutil -create xml1 "$T/fixtures/prefs.plist"
plutil -insert stride_last_sync_time -string 2026-10-06T17:06:20Z "$T/fixtures/prefs.plist"
plutil -insert stride_sync_cursor -string 2026-10-06T17:05:20.882Z "$T/fixtures/prefs.plist"
cp "$T/fixtures/prefs.plist" "$T/fixtures/prefs-done.plist"
plutil -insert stride_delivery_migration_v1_done -bool YES "$T/fixtures/prefs-done.plist"

# The notification stores (1.4.0, upgrade.sh --reminders), as NSKeyedArchiver archives shaped like
# the simulator's (notifications.py's header: Library.plist and Categories.plist as observed, the
# pending records with the keys from the runtime's strings). D is a daily habit, M a Mon/Wed/Fri
# one. Each fixture directory is one state of <device data>/Library/UserNotifications/<dir>/.
REM_D="AAAAAAAA-1111-4111-8111-111111111111"
REM_M="BBBBBBBB-2222-4222-8222-222222222222"
UN_DIR="F0AB2993-CD02-4147-A3E7-730A50DBA06C"
/usr/bin/python3 -I - "$T/fixtures/un" "$REM_D" "$REM_M" "$UN_DIR" "$BUNDLE_ID" <<'PY'
import os, plistlib, sys
from plistlib import UID
out, D, M, un_dir, bundle = sys.argv[1:6]

class Archiver:
    def __init__(self):
        self.objects, self.classes, self.strings = ["$null"], {}, {}
    def cls(self, name):
        if name not in self.classes:
            self.objects.append({"$classname": name, "$classes": [name, "NSObject"]})
            self.classes[name] = UID(len(self.objects) - 1)
        return self.classes[name]
    def slot(self):
        self.objects.append(None)
        return len(self.objects) - 1
    def ref(self, v):
        if v is None:
            return UID(0)
        if isinstance(v, str):
            if v not in self.strings:
                self.objects.append(v)
                self.strings[v] = UID(len(self.objects) - 1)
            return self.strings[v]
        if isinstance(v, (bool, int)):
            self.objects.append(v)
            return UID(len(self.objects) - 1)
        i = self.slot()
        if isinstance(v, list):
            self.objects[i] = {"NS.objects": [self.ref(x) for x in v], "$class": self.cls("NSMutableArray")}
        elif "$components" in v:   # an NSDateComponents: its fields inline, as NSCoder writes ints
            self.objects[i] = dict(v["$components"], **{"$class": self.cls("NSDateComponents")})
        else:
            self.objects[i] = {"NS.keys": [self.ref(k) for k in v], "NS.objects": [self.ref(x) for x in v.values()],
                               "$class": self.cls("NSMutableDictionary")}
        return UID(i)

def dump(root, *path):
    a = Archiver()
    top = a.ref(root)
    os.makedirs(os.path.join(out, *path[:-1]), exist_ok=True)
    with open(os.path.join(out, *path), "wb") as f:
        plistlib.dump({"$version": 100000, "$archiver": "NSKeyedArchiver", "$top": {"root": top},
                       "$objects": a.objects}, f, fmt=plistlib.FMT_BINARY)

def req(rid, category=None, weekday=None, key="AppNotificationIdentifier"):
    r = {key: rid, "UNNotificationTriggerType": "Calendar", "TriggerRepeats": True}
    if category:
        r["SBSPushStoreNotificationCategoryKey"] = category
    comps = {"NS.hour": 20, "NS.minute": 0}
    if weekday:
        comps["NS.weekday"] = weekday
    r["TriggerDateComponents"] = {"$components": comps}
    return r

P = "stride.habit.reminder."
EVENING = req("stride.daily.evening")
CATEGORIES = [
    {"Identifier": "stride.habit.binary", "Actions": [{"Identifier": "stride.action.done", "Title": "Mark Done"},
                                                      {"Identifier": "stride.action.snooze", "Title": "Snooze 1 Hour"}]},
    {"Identifier": "stride.habit.count", "Actions": [{"Identifier": "stride.action.add1", "Title": "Add 1"},
                                                     {"Identifier": "stride.action.snooze", "Title": "Snooze 1 Hour"}]},
]
weekly = lambda cat, days=(2, 4, 6): [req(P + M + "." + str(w), cat, w) for w in days]

dump({bundle: un_dir, "com.apple.other": "11111111-0000-0000-0000-000000000000"}, "Library.plist")
# 1.3.x: one bare daily id per habit, no category, no registered categories.
dump([req(P + D), req(P + M), EVENING], "old", "PendingNotifications.plist")
# 1.4.0 as D4 wants it.
dump([req(P + D, "stride.habit.binary")] + weekly("stride.habit.count") + [EVENING], "new-ok", "PendingNotifications.plist")
dump(CATEGORIES, "new-ok", "Categories.plist")
# The conversion never happened: both bare ids left, categories registered.
dump([req(P + D, "stride.habit.binary"), req(P + M, "stride.habit.count"), EVENING], "new-legacy", "PendingNotifications.plist")
dump(CATEGORIES, "new-legacy", "Categories.plist")
# Converted, but the bare id of the M/W/F habit is still pending (the prune missed it).
dump([req(P + D, "stride.habit.binary"), req(P + M, "stride.habit.count")] + weekly("stride.habit.count"), "new-extra", "PendingNotifications.plist")
dump(CATEGORIES, "new-extra", "Categories.plist")
# The daily habit got weekday triggers too.
dump([req(P + D + "." + str(w), "stride.habit.binary", w) for w in range(1, 8)] + weekly("stride.habit.count"), "new-dailyweekly", "PendingNotifications.plist")
dump(CATEGORIES, "new-dailyweekly", "Categories.plist")
# Right requests, no categories registered.
dump([req(P + D, "stride.habit.binary")] + weekly("stride.habit.count"), "new-nocats", "PendingNotifications.plist")
# One weekday request carries a category nobody registered.
dump([req(P + D, "stride.habit.binary"), req(P + M + ".2", "stride.habit.count", 2), req(P + M + ".4", "stride.habit.weird", 4),
      req(P + M + ".6", "stride.habit.count", 6)], "new-badcat", "PendingNotifications.plist")
dump(CATEGORIES, "new-badcat", "Categories.plist")
# Right ids under a record key the decoder does not know: the strings fallback decides.
dump([req(P + D, "stride.habit.binary", key="SomeFutureIdKey")]
     + [req(P + M + "." + str(w), "stride.habit.count", w, key="SomeFutureIdKey") for w in (2, 4, 6)],
     "new-strings", "PendingNotifications.plist")
dump(CATEGORIES, "new-strings", "Categories.plist")
PY

# The children's root, server and device.
export STRIDE_E2E_ROOT="$T/root"
mkdir -p "$T/root/servers/st/server"
export FAKE_SERVER_PID=999999
export FAKE_SERVER_COPY="$T/root/servers/st/server"
export FAKE_SERVER_LOG="$T/root/servers/st/server.log"
echo "$FAKE_SERVER_PID" >"$T/root/servers/st/server.pid"
: >"$FAKE_SERVER_LOG"
: >"$FAKE_SERVER_COPY/stride.db"
export FAKE="$T/dev"
export FAKE_UDID_PRO="$UDID_PRO" FAKE_UDID_PROMAX="$UDID_PROMAX"
export FAKE_EMPTY_STORE="$T/fixtures/empty.store"
export FAKE_UN_FIXTURES="$T/fixtures/un" FAKE_UN_DIR="$UN_DIR"
export STRIDE_E2E_SESSION_WAIT=2
export STRIDE_E2E_REMINDER_TRIES=2 STRIDE_E2E_REMINDER_PAUSE=0
export PATH="$T/bin:$PATH"

# A fresh fake device: <installed app> [launch actions…]; the group holds the old store. No
# notification store until un_install puts one there.
device() {
  local app="$1"; shift
  rm_under_root "$FAKE"
  mkdir -p "$FAKE/group" "$FAKE/data/Library/Preferences" "$FAKE/devdata/Library"
  cp "${STORE_FIXTURE:-$T/fixtures/old.store}" "$FAKE/group/Stride.store"
  cp "$T/fixtures/prefs.plist" "$FAKE/data/Library/Preferences/$BUNDLE_ID.plist"
  echo "$app" >"$FAKE/installed"
  : >"$FAKE/calls"; : >"$FAKE/device.log"; : >"$FAKE/launches"; : >"$FAKE/launch-args"
  echo "2026-10-07 02:09:13.395 Df Stride[39751:859c8e] [com.apple.xpc:connection] activating connection" >"$FAKE/device.log"
  local a
  for a in "$@"; do echo "$a" >>"$FAKE/launches"; done
}

# un_install <fixture>: the device's notification stores become that fixture (as the stub's
# un:<fixture> launch action does), with Library.plist mapping the app to its directory.
un_install() {
  local u="$FAKE/devdata/Library/UserNotifications"
  mkdir -p "$u/$UN_DIR"
  cp "$T/fixtures/un/Library.plist" "$u/"
  cp "$T/fixtures/un/$1/"*.plist "$u/$UN_DIR/"
}

# ── Cases ───────────────────────────────────────────────────────────────────────────────────
PASSED=0
FAILED=0
# expect <name> <exit status> <ERE the output must match, or ""> <command…>
expect() {
  local name="$1" want="$2" pat="$3" out rc=0
  shift 3
  out="$("$@" 2>&1)" || rc=$?
  if [[ $rc -eq $want ]] && { [[ -z "$pat" ]] || grep -Eq -- "$pat" <<<"$out"; }; then
    echo "ok    $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL  $name (exit $rc, wanted $want${pat:+, and output matching /$pat/})"
    tail -15 <<<"$out" | sed 's/^/      | /'
    FAILED=$((FAILED + 1))
  fi
}
NEW="$T/apps/131/Stride.app"
OLD130="$T/apps/130/Stride.app"
OLD123="$T/apps/123/Stride.app"

for f in "$KIT"/*.sh; do expect "bash -n $(basename "$f")" 0 "" /bin/bash -n "$f"; done
if [[ -n "$NODE" ]]; then
  for f in "$KIT"/*.js; do expect "node --check $(basename "$f")" 0 "" "$NODE" --check "$f"; done
fi
# ast.parse, not py_compile: nothing may be written into the kit (no __pycache__).
for f in "$KIT"/*.py; do
  expect "python3 parse $(basename "$f")" 0 "" /usr/bin/python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f"
done

device "$NEW"; touch "$FAKE/running"
expect "app.sh running: the app is up (launchctl list, match first, 200 KB after it)" 0 "" "$KIT/app.sh" running pro
rm -f "$FAKE/running"
expect "app.sh running: the app is down" 1 "" "$KIT/app.sh" running pro

device "$NEW" silent
expect "clean 1.3.1, no token stored: no session check is the clean answer" 0 "^clean: no session token" \
  "$KIT/app.sh" clean pro st "$NEW"
device "$NEW" "session: user=null" silent
expect "clean 1.3.1, a dead token: reinstall, then clean in round 2" 0 "round 2" \
  "$KIT/app.sh" clean pro st "$NEW"
device "$NEW" "session:"
expect "clean 1.3.1, a session check without a Bearer: clean" 0 "^clean: .*carried none" \
  "$KIT/app.sh" clean pro st "$NEW"
device "$NEW" "session: user=7"
expect "clean 1.3.1, a live session without --revoke: exit 3" 3 "signed in as user 7" \
  "$KIT/app.sh" clean pro st "$NEW"
device "$NEW" crash
expect "clean 1.3.1, the app died at launch: not called clean" 1 "the app is not running" \
  "$KIT/app.sh" clean pro st "$NEW"
device "$NEW" silent
expect "clean 1.2.3: refused with the documented path" 1 "needs a 1\.3\.0\+ build.*" \
  "$KIT/app.sh" clean pro st "$OLD123"
expect "clean 1.2.3: nothing was uninstalled" 1 "" grep -q uninstall "$FAKE/calls"

printf '%s\n' \
  "2026-10-07 02:09:14.456 E  Stride[1:2] [com.apple.coredata:error] CoreData: error: … returned error NSCocoaErrorDomain (134110)" \
  "2026-10-07 02:09:14.464 E  Stride[1:2] [yyh.stride.habittracker:ModelContainer] Failed to create ModelContainer at /x/Stride.store: … Falling back to default location" \
  >"$T/fixtures/fallback.log"
echo "2026-10-07 02:09:14.457 Df Stride[1:2] [x] <NSManagedObjectContext: 0x109134100> saved" >"$T/fixtures/hex.log"
expect "check-log: CoreData 134110 and the fallback line" 3 "STORE OPEN FAILED — 2 line" \
  "$KIT/upgrade.sh" check-log "$T/fixtures/fallback.log"
expect "check-log: a hex address holding 134100 is not a marker" 0 "no CoreData" \
  "$KIT/upgrade.sh" check-log "$T/fixtures/hex.log"
printf '%s\n' \
  "2026-10-07 02:09:14.300 E  StrideWidgetExtension[7:8] [yyh.stride.habittracker:ModelContainer] Extension could not open the store: …" \
  >"$T/fixtures/widget.log"
expect "check-log: the widget's own failed open is printed, not failed on" 0 "widget \(not failed on\)" \
  "$KIT/upgrade.sh" check-log "$T/fixtures/widget.log"
echo "2026-10-07 02:09:14.464 E  Stride[1:2] [yyh.stride.habittracker:ModelContainer] Could not open the store: … Not falling back: the app shows the error screen." \
  >"$T/fixtures/errorscreen.log"
expect "check-log: the no-fallback open's error screen fails" 3 "STORE OPEN FAILED — 1 line" \
  "$KIT/upgrade.sh" check-log "$T/fixtures/errorscreen.log"
expect "counts: rows and model checksum of a pre-1.3.1 store" 0 "habits=2 records=3 groups=0 .*no ZSYNCEDAT.*model=OLDMODEL=" \
  "$KIT/upgrade.sh" counts "$T/fixtures/old.store"
expect "prefs: stride_delivery_* entries, and the no-marks hint" 0 "stride_delivery_migration_v1_done.*" \
  "$KIT/upgrade.sh" prefs "$T/fixtures/prefs-done.plist"
mkdir -p "$T/grp/Library/Application Support"; cp "$T/fixtures/empty.store" "$T/grp/Library/Application Support/default.store"
expect "check-dir: a default.store in an app group's Library/Application Support" 3 "FALLBACK STORE" \
  "$KIT/upgrade.sh" check-dir "$T/grp"

device "$OLD130" silent
expect "upgrade 1.3.0 → 1.3.1, the store opens: PASS" 0 "^PASS: 1\.3\.0 \(19\) → 1\.3\.1 \(20\)" \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --server st --label pass
expect "upgrade: it installed in place (no uninstall)" 1 "" grep -q uninstall "$FAKE/calls"
device "$OLD130" fallback
expect "upgrade 1.3.0 → 1.3.1, the fallback store: FAIL, exit 3" 3 "^FAIL: .*failed store open in the device log.*default\.store in the app group" \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --label fail
expect "app.sh store: warns about the app group's default.store" 0 "default\.store in the APP GROUP" \
  "$KIT/app.sh" store pro "$T/storecopy"
device "$NEW"
expect "upgrade: refused when the device does not run the old app" 1 "runs 1\.3\.1 \(20\), not the old app" \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --label wrong-start

# The store gate (review round of the upgrade-race fix): the order in the device log, the marker,
# the delivery marks and the recovered edits.
G='[yyh.stride.habittracker:ModelContainer]'
printf '%s\n' \
  "2026-10-07 04:00:01.100 Df StrideWidgetExtension[7:8] $G Store not opened in the extension: waitForApp(noMarker)" \
  "2026-10-07 04:00:01.300 Df StrideWidgetExtension[7:8] $G Store not opened in the extension: waitForApp(noMarker)" \
  "2026-10-07 04:00:02.200 Df Stride[9:10] $G Store opened by the app: marker 1 written, widgets reloaded" \
  "2026-10-07 04:00:02.900 Df StrideWidgetExtension[7:8] $G Store opened in the extension at schema 1" \
  >"$T/fixtures/gate.log"
expect "check-gate: turned away twice, then the app's open, then the widget's" 0 "turned away before the app's open: 2 waitForApp\(noMarker\)" \
  "$KIT/upgrade.sh" check-gate "$T/fixtures/gate.log"
printf '%s\n' \
  "2026-10-07 04:00:01.900 Df StrideWidgetExtension[7:8] $G Store opened in the extension at schema 1" \
  "2026-10-07 04:00:02.200 Df Stride[9:10] $G Store opened by the app: marker 1 written, widgets reloaded" \
  >"$T/fixtures/gate-first.log"
expect "check-gate: the widget's open before the app's fails" 3 "THE WIDGET OPENED THE STORE FIRST" \
  "$KIT/upgrade.sh" check-gate "$T/fixtures/gate-first.log"
echo "2026-10-07 04:00:01.100 Df StrideWidgetExtension[7:8] $G Store not opened in the extension: waitForApp(noMarker)" \
  >"$T/fixtures/gate-noapp.log"
expect "check-gate: the widget asked, the app never opened: fails" 3 "never logged its open" \
  "$KIT/upgrade.sh" check-gate "$T/fixtures/gate-noapp.log"
expect "check-gate: a build before the gate is not failed on" 0 "no gate line" \
  "$KIT/upgrade.sh" check-gate "$T/fixtures/hex.log"
echo "2026-10-07 04:00:02.200 Df Stride[9:10] $G Store opened by the app: marker 1 written, widgets reloaded" >"$T/fixtures/gate-nowidget.log"
expect "check-gate: no widget request at all is a note, not a failure" 0 "gate was not exercised" \
  "$KIT/upgrade.sh" check-gate "$T/fixtures/gate-nowidget.log"

export STORE_FIXTURE="$T/fixtures/stamped.store"
device "$OLD130" gate silent
expect "upgrade with the gate, marker, marks and a quiet relaunch: PASS" 0 "^PASS: .*no recovered edits" \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --server st --label gate-pass --relaunch
expect "upgrade with the gate: the marker is read from the App Group prefs" 0 "stride_store_schema_version = 1" \
  cat "$T/root/upgrades/gate-pass/report.txt"
expect "upgrade with the gate: 5 rows qualify (the one inside the margin does not)" 0 "must mark .*: 5$" \
  cat "$T/root/upgrades/gate-pass/report.txt"
device "$OLD130" gate-nomarker
expect "upgrade: the app opened the store but wrote no marker: FAIL" 3 "^FAIL: .*no store schema marker" \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --label gate-nomarker
device "$OLD130" widget-first
expect "upgrade: the widget opened the store before the app: FAIL" 3 "^FAIL: .*before the app had" \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --label widget-first
device "$OLD130" gate-nomarks
expect "upgrade: qualifying rows, no mark and no ?deletionsSince=: FAIL (U123's signature)" 3 "^FAIL: .*marked none of 5 qualifying rows" \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --server st --label gate-nomarks
device "$OLD130" gate-proved
expect "upgrade: the marks' proof already ran (?deletionsSince= in the first pull): PASS" 0 "first full pull asked \?deletionsSince=" \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --server st --label gate-proved
device "$OLD130" gate edits
expect "upgrade --relaunch: recovered edits on the relaunch: FAIL" 3 "^FAIL: .*2 recovered edit\(s\) after the relaunch" \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --server st --label gate-edits --relaunch
unset STORE_FIXTURE

# 1.4.0 (RELEASE-1.4.0.md D7, design review kit-push-and-launch-args): launch arguments, pushes
# shaped like a habit reminder, and the system's notification stores.
device "$NEW"
expect "app.sh launch -- <args>: the pid alone on stdout, the arguments noted" 0 "^4242$" \
  "$KIT/app.sh" launch pro -- -tab 2 -stride_onboarding_completed YES
expect "app.sh launch -- <args>: the app got exactly those arguments" 0 "" \
  grep -qx -- "-tab 2 -stride_onboarding_completed YES" "$FAKE/launch-args"
expect "app.sh launch with no arguments: the app gets none" 0 "" \
  "$KIT/app.sh" launch pro
expect "app.sh launch with no arguments: none recorded" 0 "" grep -qx -- "<none>" "$FAKE/launch-args"
expect "app.sh launch: arguments without -- are refused" 1 "the app's arguments follow --" \
  "$KIT/app.sh" launch pro -tab 2

expect "app.sh notify binary with a day: pushed" 0 "pushed .*-binary\.json" \
  env FAKE_PUSH_KIND=binary "$KIT/app.sh" notify pro "$REM_D" binary 2026-10-10
expect "  … aps.category stride.habit.binary" 0 "^stride\.habit\.binary$" plutil -extract aps.category raw -o - "$FAKE/pushes/1.json"
expect "  … top-level habitId" 0 "^$REM_D$" plutil -extract habitId raw -o - "$FAKE/pushes/1.json"
expect "  … aps.thread-id is the habit" 0 "^$REM_D$" plutil -extract aps.thread-id raw -o - "$FAKE/pushes/1.json"
expect "  … top-level day" 0 "^2026-10-10$" plutil -extract day raw -o - "$FAKE/pushes/1.json"
expect "app.sh notify count: stride.habit.count, no day" 0 "pushed" \
  env FAKE_PUSH_KIND=count "$KIT/app.sh" notify pro "$REM_M" count
expect "  … no day key without a day" 1 "" plutil -extract day raw -o - "$FAKE/pushes/2.json"
expect "app.sh notify - none: a 1.3.x-shaped banner (no category, no habitId)" 0 "pushed" \
  env FAKE_PUSH_KIND=none "$KIT/app.sh" notify pro - none
expect "  … no habitId" 1 "" plutil -extract habitId raw -o - "$FAKE/pushes/3.json"
REM_D_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"$REM_D")"
expect "app.sh notify: a lower-case id is pushed as it is (a router case)" 0 "pushed" \
  env FAKE_PUSH_KIND=binary "$KIT/app.sh" notify pro "$REM_D_LOWER" binary
expect "  … habitId unchanged" 0 "^$REM_D_LOWER$" plutil -extract habitId raw -o - "$FAKE/pushes/4.json"
expect "app.sh notify: an unknown kind is refused before any push" 1 "binary \| count \| none" \
  "$KIT/app.sh" notify pro "$REM_D" weekly
expect "  … and nothing was pushed" 1 "" grep -q "simctl push .* $BUNDLE_ID .*-weekly" "$FAKE/calls"
expect "stub: a push without aps.category is refused unless it is meant to have none" 1 "simctl push failed" \
  env FAKE_PUSH_KIND=binary "$KIT/app.sh" notify pro "$REM_D" none
rm -f "$FAKE/installed"
expect "app.sh notify: refused when the app is not installed" 1 "not installed" \
  "$KIT/app.sh" notify pro "$REM_D" binary

TAB=$'\t'
device "$NEW"
expect "app.sh reminders: no notification store yet is an error, with the reason" 1 "nothing was scheduled or registered" \
  "$KIT/app.sh" reminders pro
un_install old
expect "app.sh reminders: Library.plist names the directory; the 1.3.x requests decoded" 0 "request${TAB}stride\.habit\.reminder\.$REM_D${TAB}-${TAB}hour=20 minute=0 repeats" \
  "$KIT/app.sh" reminders pro "$T/remcopy"
expect "  … and the copies landed in <destdir>" 0 "" test -f "$T/remcopy/PendingNotifications.plist"
rm -f "$FAKE/devdata/Library/UserNotifications/Library.plist"
expect "app.sh reminders: no Library.plist, so the one directory holding stride.habit. ids" 0 "found by scanning" \
  "$KIT/app.sh" reminders pro

expect "check-reminders: D4's conversion" 0 "exactly \.2 \.4 \.6 and no bare id" \
  "$KIT/upgrade.sh" check-reminders "$T/fixtures/un/new-ok" "$REM_D,$REM_M"
expect "check-reminders: the categories are read from the records" 0 "the requests carry stride\.habit\.binary stride\.habit\.count" \
  "$KIT/upgrade.sh" check-reminders "$T/fixtures/un/new-ok" "$REM_D,$REM_M"
expect "check-reminders: lower-case ids are upper-cased (Habit.id.uuidString)" 0 "registered" \
  "$KIT/upgrade.sh" check-reminders "$T/fixtures/un/new-ok" "$(tr '[:upper:]' '[:lower:]' <<<"$REM_D,$REM_M")"
expect "check-reminders: no conversion at all fails" 3 "MON/WED/FRI HABIT .* want exactly" \
  "$KIT/upgrade.sh" check-reminders "$T/fixtures/un/new-legacy" "$REM_D,$REM_M"
expect "check-reminders: the bare id left beside .2 .4 .6 fails" 3 "MON/WED/FRI HABIT" \
  "$KIT/upgrade.sh" check-reminders "$T/fixtures/un/new-extra" "$REM_D,$REM_M"
expect "check-reminders: a daily habit given weekday triggers fails" 3 "DAILY HABIT" \
  "$KIT/upgrade.sh" check-reminders "$T/fixtures/un/new-dailyweekly" "$REM_D,$REM_M"
expect "check-reminders: no categories registered fails" 3 "NO Categories\.plist" \
  "$KIT/upgrade.sh" check-reminders "$T/fixtures/un/new-nocats" "$REM_D,$REM_M"
expect "check-reminders: a request with an unregistered category fails" 3 "carries category 'stride\.habit\.weird'" \
  "$KIT/upgrade.sh" check-reminders "$T/fixtures/un/new-badcat" "$REM_D,$REM_M"
expect "check-reminders: unknown record keys fall back to the archive's strings" 0 "strings fallback" \
  "$KIT/upgrade.sh" check-reminders "$T/fixtures/un/new-strings" "$REM_D,$REM_M"
expect "check-reminders: one id is refused" 1 "<daily habit id>,<Mon/Wed/Fri habit id>" \
  "$KIT/upgrade.sh" check-reminders "$T/fixtures/un/new-ok" "$REM_D"

device "$OLD130" un:new-ok; un_install old
expect "upgrade --reminders: the 1.3.x ids converted, categories registered: PASS" 0 "^PASS: .*the reminders converted" \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --label rem-pass --reminders "$REM_D,$REM_M"
expect "upgrade --reminders: before and after kept as evidence" 0 "" \
  test -f "$T/root/upgrades/rem-pass/reminders-before/PendingNotifications.plist" -a -f "$T/root/upgrades/rem-pass/reminders-after/Categories.plist"
device "$OLD130" un:new-legacy; un_install old
expect "upgrade --reminders: no conversion: FAIL, exit 3" 3 "^FAIL: .*the reminders were not converted" \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --label rem-legacy --reminders "$REM_D,$REM_M"
device "$OLD130" silent
expect "upgrade --reminders: no notification store on the old build: refused (exit 1)" 1 "Reminder habits" \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --label rem-nostore --reminders "$REM_D,$REM_M"
device "$OLD130" silent; un_install new-ok
expect "upgrade --reminders: a starting point that is not the old build's two ids: refused" 1 "starting point is not" \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --label rem-wrongstart --reminders "$REM_D,$REM_M"
device "$OLD130" silent; un_install old
expect "upgrade without --reminders reads no notification store" 0 "^PASS: " \
  "$KIT/upgrade.sh" pro "$OLD130" "$NEW" --wait 0 --label rem-off
expect "  … and wrote no reminders evidence" 1 "" test -e "$T/root/upgrades/rem-off/reminders-before.txt"

echo "selftest: $PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
