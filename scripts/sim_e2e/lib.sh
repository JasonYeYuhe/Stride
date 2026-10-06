#!/bin/bash
# Shared by every scripts/sim_e2e/*.sh: sourced, never run. Bash 3.2 (macOS /bin/bash).
#
# The kit's guarantees live here, so no script can forget one:
#   - everything it writes lives under ONE root, $STRIDE_E2E_ROOT (default ${TMPDIR}stride-sim-e2e),
#     never under ~/Documents (iCloud-synced), and nothing outside that root is ever removed;
#   - the only server it talks to is http://127.0.0.1:3002, a COPY of server/ it started itself;
#   - the only simulators it touches are the two shared ones, by UDID.
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
