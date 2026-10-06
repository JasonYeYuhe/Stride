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
# selftest stub: a fake simulator in $FAKE (installed, running, data/, group/, device.log,
# launches = one action per launch: silent | session:<line suffix> | crash | fallback).
set -u
F="$FAKE"
echo "xcrun $*" >>"$F/calls"
[[ "${1:-}" == simctl ]] || { echo "stub xcrun: refusing $*" >&2; exit 99; }
shift
cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    printf '== Devices ==\n-- iOS 26.5 --\n    iPhone 17 Pro (%s) (Booted) \n    iPhone 17 Pro Max (%s) (Shutdown) \n' "$FAKE_UDID_PRO" "$FAKE_UDID_PROMAX" ;;
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

plutil -create xml1 "$T/fixtures/prefs.plist"
plutil -insert stride_last_sync_time -string 2026-10-06T17:06:20Z "$T/fixtures/prefs.plist"
plutil -insert stride_sync_cursor -string 2026-10-06T17:05:20.882Z "$T/fixtures/prefs.plist"
cp "$T/fixtures/prefs.plist" "$T/fixtures/prefs-done.plist"
plutil -insert stride_delivery_migration_v1_done -bool YES "$T/fixtures/prefs-done.plist"

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
export STRIDE_E2E_SESSION_WAIT=2
export PATH="$T/bin:$PATH"

# A fresh fake device: <installed app> [launch actions…]; the group holds the old store.
device() {
  local app="$1"; shift
  rm_under_root "$FAKE"
  mkdir -p "$FAKE/group" "$FAKE/data/Library/Preferences"
  cp "$T/fixtures/old.store" "$FAKE/group/Stride.store"
  cp "$T/fixtures/prefs.plist" "$FAKE/data/Library/Preferences/$BUNDLE_ID.plist"
  echo "$app" >"$FAKE/installed"
  : >"$FAKE/calls"; : >"$FAKE/device.log"; : >"$FAKE/launches"
  echo "2026-10-07 02:09:13.395 Df Stride[39751:859c8e] [com.apple.xpc:connection] activating connection" >"$FAKE/device.log"
  local a
  for a in "$@"; do echo "$a" >>"$FAKE/launches"; done
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

echo "selftest: $PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
