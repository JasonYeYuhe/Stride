#!/bin/bash
# app.sh <command> <udid> …   — the app on one of the two shared simulators.
#
# <udid>: pro | promax | the UDID of iPhone 17 Pro / 17 Pro Max. Any other device is refused.
# Hold the device's lock (lock.sh acquire pro|promax <label>) while you use it; app.sh warns when
# nobody holds it. It never creates, erases, deletes or shuts down a simulator, and never resets
# the simulator Keychain (other projects' items live there). A shut-down device is booted.
#
#   install <udid> <app>        install (over an installed one = in-place upgrade: the data and
#                               app-group containers stay), then mark onboarding done:
#                               simctl spawn defaults write <bundle> stride_onboarding_completed YES
#   reset <udid> <app>          terminate, uninstall, install as above. NOT a clean slate: the
#                               session token lives in the simulator KEYCHAIN, which an uninstall
#                               keeps — see `clean`.
#   clean <udid> <server> <app> [--revoke]
#                               reset, cold launch, and read the launch session check from server
#                               <server>'s E2E log (GET /v1/auth/session after the launch). The app
#                               makes that check ONLY when a token is stored (lib.sh,
#                               launch_session_check), so:
#                                 no check within $STRIDE_E2E_SESSION_WAIT s (30)
#                                                  → no token: clean, exit 0 — if the app is still
#                                                    running (a crash says nothing: exit 1).
#                                 user=null        → a dead token, which 1.3.0+ deletes on that
#                                                    answer: reset again (its "Sign in again" state
#                                                    goes with the reinstall) and re-check.
#                                 user=<id>        → a LIVE session of this server: with --revoke,
#                                                    revoke the user's sessions, relaunch (the app
#                                                    drops the token), reset, re-check; without,
#                                                    exit 3 and say so.
#                                 no user=         → a check without a Bearer: clean, exit 0.
#                               Needs a 1.3.0+ <app>. 1.2.3 never drops a dead token (null
#                               forever), so `clean` refuses it and prints the documented path:
#                               clean with a 1.3.0+ build, then `reset` to the 1.2.3 build. Up to
#                               3 rounds.
#   version <udid>              the INSTALLED app's version, "1.3.0 (19)"
#   launch <udid>               cold launch (--terminate-running-process); prints the pid
#   terminate <udid>            stop the app (no error when it is not running)
#   shot <udid> <png>           screenshot of the device
#   container <udid>            the DATA container path (it changes on every in-place install:
#                               always ask again, never reuse an old path)
#   group <udid>                the APP GROUP container path (the SwiftData store lives here)
#   prefs <udid> [app|group]    plutil -p of the app's preferences plist (default app) — read the
#                               file: `simctl spawn … defaults read` answers from a cache and misleads
#   store <udid> <destdir>      copy the SwiftData store (Stride.store, -shm, -wal) out of the app
#                               group container into <destdir> (terminate the app first for a
#                               consistent copy; it warns when the app is running), and warn about
#                               any default.store in the app group or data container: the app ran
#                               on SharedModelContainer's fallback store (lib.sh, fallback_stores)
#   exports <udid> [destdir]    list the export directories (tmp/StrideExport-*) in the data
#                               container, and copy them into <destdir> if given
#   running <udid>              exit 0 when the app is running
source "$(dirname "$0")/lib.sh"

CMD="${1:-}"
[[ -n "$CMD" && -n "${2:-}" ]] || die "usage: app.sh install|reset|clean|version|launch|terminate|shot|container|group|prefs|store|exports|running <udid> …"
UDID="$(resolve_udid "$2")"
shift 2

warn_lock() {
  local dir
  dir="$(lock_dir_for_udid "$UDID")"
  [[ -d "$dir" ]] || note "WARNING: nobody holds $dir — take it first: scripts/sim_e2e/lock.sh acquire $(udid_alias "$UDID") <label>"
}

ensure_booted() {
  local list state
  # One sed over the captured list: `| grep` would end the script silently under set -e when the
  # device is missing, and `| head -1` can break the pipe (lib.sh header).
  list="$(xcrun simctl list devices)" || die "xcrun simctl list devices failed"
  state="$(sed -n "/$UDID/s/.*(\([A-Za-z]*\)) *\$/\1/p" <<<"$list")"
  state="${state%%$'\n'*}"
  [[ -n "$state" ]] || die "simulator $UDID not found"
  if [[ "$state" != "Booted" ]]; then
    note "simulator $UDID is $state: booting it"
    xcrun simctl boot "$UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$UDID" -b >/dev/null
  fi
}

# Captured, then matched: `launchctl list | grep -q` died of SIGPIPE under pipefail (141) and
# answered "not running" with the app up (E2E REL, 3 of 3; lib.sh header).
is_running() {
  local list
  list="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null || true)"
  [[ "$list" == *"UIKitApplication:$BUNDLE_ID["* ]]
}

do_terminate() { xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true; }

do_install() {
  local app="$1"
  check_app "$app"
  ensure_booted
  xcrun simctl install "$UDID" "$app"
  xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" stride_onboarding_completed -bool YES
  echo "installed $(app_version "$app") on $UDID"
}

do_reset() {
  local app="$1"
  check_app "$app"
  ensure_booted
  do_terminate
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  do_install "$app"
}

do_launch() {
  ensure_booted
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" | sed -n 's/^.*: *\([0-9][0-9]*\)$/\1/p'
}

data_container() { xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || die "the app is not installed on $UDID"; }
group_container() { xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" "$APP_GROUP" 2>/dev/null || die "no $APP_GROUP container on $UDID (app not installed, or built without entitlements)"; }

installed_app() { xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app 2>/dev/null || die "the app is not installed on $UDID"; }

case "$CMD" in
  install)
    [[ -n "${1:-}" ]] || die "usage: app.sh install <udid> <app>"
    warn_lock; do_install "$1" ;;
  reset)
    [[ -n "${1:-}" ]] || die "usage: app.sh reset <udid> <app>"
    warn_lock; do_reset "$1" ;;
  clean)
    SERVER="${1:-}"; APP="${2:-}"; REVOKE=0
    [[ "${3:-}" == "--revoke" ]] && REVOKE=1
    [[ -n "$SERVER" && -n "$APP" ]] || die "usage: app.sh clean <udid> <server> <app> [--revoke]"
    check_app "$APP"
    # Below 1.3.0 a launch cannot clean the device: 1.2.3 never drops a dead token (user=null on
    # every launch). The documented path, refused here before anything is reinstalled: clean with
    # a 1.3.0+ build, then `reset` to the old one — the uninstall keeps the Keychain, empty by then.
    version_ge "$(plist_value "$APP/Info.plist" CFBundleShortVersionString || echo 0)" 1.3.0 \
      || die "clean needs a 1.3.0+ build: $APP is $(app_version "$APP"), which never drops a dead session token. Clean with a 1.3.0+ build, then reset to this one:
  scripts/sim_e2e/app.sh clean $(udid_alias "$UDID") $SERVER <1.3.0+ app> [--revoke]
  scripts/sim_e2e/app.sh reset $(udid_alias "$UDID") $APP"
    warn_lock
    require_running "$SERVER" >/dev/null
    LOG="$(server_home "$SERVER")/server.log"
    for ROUND in 1 2 3; do
      do_reset "$APP" >&2
      MARK="$(wc -l <"$LOG" | tr -d ' ')"
      do_launch >/dev/null
      RESULT="$(launch_session_check "$LOG" "$MARK")"
      case "$RESULT" in
        silent)
          # No check = no stored token (lib.sh, launch_session_check) — unless the app died before
          # AuthService ran, which proves nothing either way.
          is_running || die "no session check within $SESSION_WAIT s of the launch, and the app is not running: it crashed or never started, so the Keychain state is unknown (app.sh shot, the device log)"
          echo "clean: no session token on $UDID (round $ROUND: no session check within $SESSION_WAIT s of the launch, which the app makes only with a stored token); the app is installed, launched and signed out"
          exit 0 ;;
        none)
          echo "clean: no session token on $UDID (round $ROUND: the launch session check carried none); the app is installed, launched and signed out"
          exit 0 ;;
        null)
          note "round $ROUND: the app sent a dead session token (user=null); reinstalling" ;;
        *)
          if [[ $REVOKE -eq 0 ]]; then
            echo "NOT clean: the app is signed in as user $RESULT on server '$SERVER' (token in the simulator Keychain). Re-run with --revoke to end that session." >&2
            exit 3
          fi
          note "round $ROUND: signed in as user $RESULT — revoking its sessions and relaunching"
          "$KIT_DIR/account.sh" "$SERVER" revoke-user "$RESULT" >&2
          MARK="$(wc -l <"$LOG" | tr -d ' ')"
          do_launch >/dev/null
          note "  after revoke: $(launch_session_check "$LOG" "$MARK")" ;;
      esac
    done
    die "still not clean after 3 rounds (the session checks are above)" ;;
  version)
    ensure_booted
    app_version "$(installed_app)" ;;
  launch)
    warn_lock; do_launch ;;
  terminate)
    do_terminate; echo "terminated (if it was running)" ;;
  running)
    is_running ;;
  shot)
    [[ -n "${1:-}" ]] || die "usage: app.sh shot <udid> <png>"
    xcrun simctl io "$UDID" screenshot --type=png "$1" >/dev/null 2>&1 || die "screenshot failed"
    echo "$1" ;;
  container)
    data_container ;;
  group)
    group_container ;;
  prefs)
    case "${1:-app}" in
      app) PLIST="$(data_container)/Library/Preferences/$BUNDLE_ID.plist" ;;
      group) PLIST="$(group_container)/Library/Preferences/$APP_GROUP.plist" ;;
      *) die "prefs: app | group" ;;
    esac
    [[ -f "$PLIST" ]] || die "no $PLIST (nothing written yet?)"
    plutil -p "$PLIST" ;;
  store)
    DEST="${1:-}"
    [[ -n "$DEST" ]] || die "usage: app.sh store <udid> <destdir>"
    is_running && note "WARNING: the app is running; the copy may be mid-write (app.sh terminate $UDID first)"
    GRP="$(group_container)"
    mkdir -p "$DEST"
    N=0
    for f in "$GRP"/*.store "$GRP"/*.store-shm "$GRP"/*.store-wal; do
      [[ -f "$f" ]] || continue
      cp -p "$f" "$DEST/"
      echo "$DEST/$(basename "$f")"
      N=$((N + 1))
    done
    [[ $N -gt 0 ]] || die "no *.store in $GRP"
    DATA="$(data_container)"
    # Anywhere in either container: the upgrade race's fallback sits in the APP GROUP's
    # Library/Application Support, next to the real Stride.store (E2E U123), not in the data
    # container where a build without the app group puts it.
    FB="$(fallback_stores "$GRP")"
    if [[ -n "$FB" ]]; then
      note "WARNING: a default.store in the APP GROUP container — Stride.store failed to open and the app ran on SharedModelContainer's empty fallback store (the upgrade race; upgrade.sh checks for it):"
      note "$(sed 's/^/  /' <<<"$FB")"
    fi
    FB="$(fallback_stores "$DATA")"
    if [[ -n "$FB" ]]; then
      note "WARNING: a default.store in the DATA container — the app ran without its app group (built without entitlements?):"
      note "$(sed 's/^/  /' <<<"$FB")"
    fi ;;
  exports)
    DATA="$(data_container)"
    FOUND=0
    for d in "$DATA"/tmp/StrideExport-*; do
      [[ -d "$d" ]] || continue
      FOUND=1
      ls -la "$d"
      if [[ -n "${1:-}" ]]; then mkdir -p "$1"; cp -Rp "$d" "$1/"; fi
    done
    [[ $FOUND -eq 1 ]] || echo "no tmp/StrideExport-* in $DATA" ;;
  *) die "unknown command $CMD" ;;
esac
