#!/bin/bash
# Shared by every scripts/sim_e2e/*.sh: sourced, never run. Bash 3.2 (macOS /bin/bash).
#
# The kit's guarantees live here, so no script can forget one:
#   - everything it writes lives under ONE root, $STRIDE_E2E_ROOT (default ${TMPDIR}stride-sim-e2e),
#     never under ~/Documents (iCloud-synced), and nothing outside that root is ever removed;
#   - the only server it talks to is http://127.0.0.1:3002, a COPY of server/ it started itself;
#   - the only simulators it touches are the two shared ones, by UDID.
#
# Under pipefail, never `cmd | grep -q …` or `cmd | head -1`: the reader exits at its first line,
# cmd's next write dies of SIGPIPE, and the pipeline is 141, i.e. false, whatever grep found
# (E2E REL: `app.sh running` said "not running" 3 times of 3 with the app up). Capture the output
# first and match on the variable, or let the reader read to the end (grep … >/dev/null).
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "$KIT_DIR/../.." && pwd -P)"
KIT_NAME="sim_e2e/$(basename "$0")"

BUNDLE_ID="${STRIDE_BUNDLE_ID:-yyh.stride.habittracker}"
# The app group of every shipped build (Stride/Stride.entitlements, unchanged since 1.0). build.sh
# prints the group the built binary actually carries; the SwiftData store lives in its container.
APP_GROUP="${STRIDE_APP_GROUP:-group.yyh.stride.habittracker}"

# Debug builds call http://localhost:3002 (APIClient.defaultBaseURL), so the port is fixed and
# only one kit server can run at a time.
PORT=3002
BASE="http://127.0.0.1:$PORT"

UDID_PRO="F5510EA3-65E5-45D2-8E64-C599625E0873"      # iPhone 17 Pro
UDID_PROMAX="F54C8C41-12C7-4D02-A579-B2633C3330EF"   # iPhone 17 Pro Max
LOCK_PRO="/tmp/lock-iphone-17-pro"
LOCK_PROMAX="/tmp/lock-iphone-17-pro-max"

die() { echo "$KIT_NAME: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

NODE="$(command -v node || true)"

# ── The root ────────────────────────────────────────────────────────────────────────────────
_default_root() {
  local t="${TMPDIR:-/tmp/}"
  echo "${t%/}/stride-sim-e2e"
}
_ROOT_RAW="${STRIDE_E2E_ROOT:-$(_default_root)}"
case "$_ROOT_RAW" in
  /*) ;;
  *) die "STRIDE_E2E_ROOT must be an absolute path (got $_ROOT_RAW)" ;;
esac
# The path the root WILL have: its deepest existing ancestor resolved (symlinks and all), plus the
# rest. Checked before anything is created, so a refused root leaves no directory behind.
_resolve_future() {
  local p="${1%/}" rest=""
  while [[ -n "$p" && ! -d "$p" ]]; do
    rest="/$(basename "$p")$rest"
    p="$(dirname "$p")"
  done
  echo "$(cd "${p:-/}" && pwd -P)$rest" | sed 's#^//#/#'
}
_check_root() {
  local home_real
  home_real="$(cd "$HOME" && pwd -P)"
  case "$1" in
    "$home_real/Documents"|"$home_real/Documents/"*|"$home_real/Library/Mobile Documents"*|"$home_real/Library/CloudStorage"*)
      die "refusing root $1: it is iCloud-synced; build output and E2E state must live elsewhere" ;;
    /|/tmp|/private/tmp|/var|/private/var|"$home_real"|"$PROJECT_DIR"|"$PROJECT_DIR"/*)
      die "refusing root $1: use a dedicated directory" ;;
  esac
}
_check_root "$(_resolve_future "$_ROOT_RAW")"
mkdir -p "$_ROOT_RAW"
ROOT="$(cd "$_ROOT_RAW" && pwd -P)"
_check_root "$ROOT"
export STRIDE_E2E_ROOT="$ROOT"

# Absolute, symlink-free form of a path whose parent exists.
abspath() {
  local p="$1" parent
  parent="$(cd "$(dirname "$p")" && pwd -P)" || return 1
  echo "$parent/$(basename "$p")"
}

# Is $1 strictly inside the root? (resolved; the path's parent must exist)
under_root() {
  local full
  full="$(abspath "$1" 2>/dev/null)" || return 1
  case "$full" in "$ROOT"/?*) return 0 ;; *) return 1 ;; esac
}

# The only recursive delete in the kit: refuses anything that is not strictly inside the root.
rm_under_root() {
  local p="$1"
  [[ -e "$p" || -L "$p" ]] || return 0
  under_root "$p" || die "refusing to remove $p: not under $ROOT"
  rm -rf "$(abspath "$p")"
}

# ── Servers ─────────────────────────────────────────────────────────────────────────────────
check_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad server name '$name' (letters, digits, . _ -)"
}
server_home() { check_name "$1"; echo "$ROOT/servers/$1"; }     # pid file, log
server_copy() { check_name "$1"; echo "$ROOT/servers/$1/server"; } # the copy of server/

# PIDs listening on the kit port (IPv4 or IPv6), one per line; empty when free.
port_listeners() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u || true; }

# Is $2 the kit's node process for server $1? (its command line runs the copy's index.js)
is_kit_server_pid() {
  local name="$1" pid="$2" cmd
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  [[ "$cmd" == *" $(server_copy "$name")/index.js" ]]
}

# Fails unless server $1 is running AND is what listens on 3002. Prints its pid.
require_running() {
  local name="$1" home pid listeners
  home="$(server_home "$name")"
  [[ -f "$home/server.pid" ]] || die "server '$name' is not running (no pid file; start-server.sh $name)"
  pid="$(cat "$home/server.pid")"
  is_kit_server_pid "$name" "$pid" || die "server '$name' is not running (pid $pid is not its index.js)"
  listeners="$(port_listeners)"
  [[ "$listeners" == "$pid" ]] || die "port $PORT is held by pid(s) [$(echo "$listeners" | tr '\n' ' ')], not by server '$name' (pid $pid)"
  echo "$pid"
}

require_db() {
  local name="$1" copy
  copy="$(server_copy "$name")"
  [[ -f "$copy/stride.db" ]] || die "server '$name' has no database yet (start-server.sh $name --fresh)"
  under_root "$copy/stride.db" || die "refusing $copy/stride.db: not under $ROOT/servers"
}

require_node() { [[ -n "$NODE" ]] || die "node is required"; }

# ── Simulators ──────────────────────────────────────────────────────────────────────────────
# Accepts pro | promax | the UDID of either; prints the UDID. Anything else is refused.
resolve_udid() {
  case "$1" in
    pro|"$UDID_PRO") echo "$UDID_PRO" ;;
    promax|"$UDID_PROMAX") echo "$UDID_PROMAX" ;;
    *) die "refusing simulator '$1': only iPhone 17 Pro ($UDID_PRO) and iPhone 17 Pro Max ($UDID_PROMAX)" ;;
  esac
}
lock_dir_for_udid() {
  case "$1" in
    "$UDID_PRO") echo "$LOCK_PRO" ;;
    "$UDID_PROMAX") echo "$LOCK_PROMAX" ;;
  esac
}
udid_alias() { [[ "$1" == "$UDID_PRO" ]] && echo pro || echo promax; }

# The device's own data directory (…/CoreSimulator/Devices/<udid>/data), from simctl's `dataPath`:
# the system stores live there, not in the app's containers — UserNotifications among them.
device_data_dir() {
  local json dir
  json="$(xcrun simctl list devices -j)" || die "xcrun simctl list devices -j failed"
  dir="$(/usr/bin/python3 -I -c '
import json, sys
for devs in json.loads(sys.stdin.read())["devices"].values():
    for d in devs:
        if d.get("udid") == sys.argv[1]:
            print(d.get("dataPath", ""))
            raise SystemExit(0)
' "$1" <<<"$json")" || die "could not read simctl's device list"
  [[ -n "$dir" && -d "$dir" ]] || die "no data directory for simulator $1 (simctl dataPath '${dir}')"
  echo "$dir"
}

# The decoder of the UserNotifications stores (notifications.py's header has the format).
notifications_py() { /usr/bin/python3 -I "$KIT_DIR/notifications.py" "$@"; }

# ── App bundles ─────────────────────────────────────────────────────────────────────────────
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

check_app() {
  local app="$1" bid
  [[ -d "$app" && -f "$app/Info.plist" ]] || die "no app bundle at '$app' (build.sh prints one)"
  bid="$(plist_value "$app/Info.plist" CFBundleIdentifier || true)"
  [[ "$bid" == "$BUNDLE_ID" ]] || die "$app is ${bid:-?}, not $BUNDLE_ID"
}

# "1.3.1 (20)": CFBundleShortVersionString (CFBundleVersion) of an .app.
app_version() {
  echo "$(plist_value "$1/Info.plist" CFBundleShortVersionString || echo '?') ($(plist_value "$1/Info.plist" CFBundleVersion || echo '?'))"
}

# Is dotted version $1 at least $2? Numeric parts; a missing part is 0 (1.3 = 1.3.0).
version_ge() {
  local IFS=.
  local -a a=($1) b=($2)
  local i x y
  for i in 0 1 2 3; do
    x="${a[$i]:-0}"; x="${x//[^0-9]/}"; x=$((10#${x:-0}))
    y="${b[$i]:-0}"; y="${y//[^0-9]/}"; y=$((10#${y:-0}))
    if (( x > y )); then return 0; fi
    if (( x < y )); then return 1; fi
  done
  return 0
}

# ── The launch session check (app.sh clean) ──────────────────────────────────────────────────
# Stride asks GET /v1/auth/session at launch ONLY when a session token is stored: AuthService's
# init, `if tokenStore.read() != nil { Task { await checkSession() } }` (1.3.1
# Stride/Sources/Services/AuthService.swift:104; the same guard in 1.3.0 at :47 and 1.2.3 at :22).
# A signed-out device sends nothing at all, so silence after a launch IS the "no token" answer —
# the first kit read it as "the app is not reaching the server" and failed every clean device
# (E2E U123 and REL, 5 of 5).
SESSION_WAIT="${STRIDE_E2E_SESSION_WAIT:-30}"
[[ "$SESSION_WAIT" =~ ^[0-9]+$ ]] || die "STRIDE_E2E_SESSION_WAIT must be whole seconds (got $SESSION_WAIT)"

# The first GET /v1/auth/session line in <log> after line <mark>, waited for up to <seconds>
# (default $SESSION_WAIT). Prints none (the check carried no Bearer) | null | <user id> | silent.
launch_session_check() {
  local log="$1" mark="$2" secs="${3:-$SESSION_WAIT}" line="" ticks=0
  while :; do
    # awk on the file, not tail | grep | head: no pipe to break (see the header).
    line="$(awk -v m="$mark" 'NR > m && /^E2E [^ ]+ GET \/v1\/auth\/session /{ print; exit }' "$log")"
    [[ -n "$line" ]] && break
    (( ticks >= secs * 2 )) && break
    sleep 0.5
    ticks=$((ticks + 1))
  done
  if [[ -z "$line" ]]; then echo silent; return 0; fi
  note "  session check: $line"
  case "$line" in
    *" user=null"*) echo null ;;
    *" user="[0-9]*) sed -n 's/.* user=\([0-9][0-9]*\).*/\1/p' <<<"$line" ;;
    *) echo none ;;
  esac
}

# ── Stores ──────────────────────────────────────────────────────────────────────────────────
# SharedModelContainer's fallback: when opening Stride.store throws, it builds
# ModelContainer(for: schema), SwiftData's DEFAULT location: <app group>/Library/Application
# Support/default.store for an app with an app group (the 1.3.1 upgrade race, E2E U123 and MIG),
# the data container's Library/Application Support/default.store for one built without it.
# Every default.store* under <dir>, one path per line (nothing when there is none).
fallback_stores() {
  [[ -d "$1" ]] || return 0
  find "$1" \( -name 'default.store' -o -name 'default.store-*' \) -print 2>/dev/null | sort || true
}
