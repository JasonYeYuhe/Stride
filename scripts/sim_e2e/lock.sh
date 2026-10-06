#!/bin/bash
# lock.sh acquire pro|promax [label] [--wait [minutes]]
# lock.sh release pro|promax [label]
# lock.sh status  [pro|promax]
#
# The shared simulators' mutex: a directory, /tmp/lock-iphone-17-pro or /tmp/lock-iphone-17-pro-max,
# the convention every project on this Mac uses (mkdir is atomic). This kit also writes a
# `holder` file inside (label, pid, since), so `status` says who has it and `release` removes
# only a lock taken with the same label — never one another session created (those may be plain
# empty directories with no holder file; they are reported, never removed).
#
#   acquire    exit 0 when held (also when this label already holds it); exit 1 when someone
#              else holds it; with --wait, polls every 60 s for up to <minutes> (default 40) and
#              then prints BLOCKED and exits 2. (A 40-minute wait outlives a 10-minute foreground
#              tool call: run it in the background, or loop on plain acquire yourself.)
#   label      default "sim_e2e"; give each agent its own, e.g. "e2e-upgrade-agent".
source "$(dirname "$0")/lib.sh"

CMD="${1:-}"
WHICH="${2:-}"
shift 2 2>/dev/null || shift $#
LABEL="sim_e2e"
WAIT_MIN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait)
      WAIT_MIN=40
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then WAIT_MIN="$2"; shift; fi ;;
    -*) die "unknown option $1" ;;
    *) LABEL="$1" ;;
  esac
  shift
done
[[ "$LABEL" =~ ^[A-Za-z0-9._@:-]+$ ]] || die "bad label '$LABEL'"

lock_path() {
  case "$1" in
    pro) echo "$LOCK_PRO" ;;
    promax) echo "$LOCK_PROMAX" ;;
    *) die "which lock? pro | promax (got '$1')" ;;
  esac
}

holder_label() { sed -n 's/^label=//p' "$1/holder" 2>/dev/null | head -1; }

describe() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    echo "$dir: free"
  elif [[ -f "$dir/holder" ]]; then
    echo "$dir: held — $(tr '\n' ' ' <"$dir/holder")"
  else
    echo "$dir: held (no holder file: taken outside this kit, $(stat -f '%Sm' "$dir"))"
  fi
}

try_acquire() {
  local dir="$1"
  if mkdir "$dir" 2>/dev/null; then
    printf 'label=%s\npid=%s\nsince=%s\nby=scripts/sim_e2e/lock.sh\n' \
      "$LABEL" "$PPID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$dir/holder"
    return 0
  fi
  [[ "$(holder_label "$dir")" == "$LABEL" ]]
}

case "$CMD" in
  status)
    if [[ -n "$WHICH" ]]; then describe "$(lock_path "$WHICH")"
    else describe "$LOCK_PRO"; describe "$LOCK_PROMAX"; fi ;;
  acquire)
    DIR="$(lock_path "$WHICH")"
    DEADLINE=$(( $(date +%s) + WAIT_MIN * 60 ))
    while ! try_acquire "$DIR"; do
      if [[ $WAIT_MIN -eq 0 ]]; then
        describe "$DIR" >&2
        exit 1
      fi
      if [[ $(date +%s) -ge $DEADLINE ]]; then
        describe "$DIR" >&2
        echo "BLOCKED: $DIR still held after $WAIT_MIN min"
        exit 2
      fi
      note "$(describe "$DIR") — waiting 60 s"
      sleep 60
    done
    echo "acquired $DIR (label $LABEL)" ;;
  release)
    DIR="$(lock_path "$WHICH")"
    [[ -d "$DIR" ]] || { echo "$DIR: not held"; exit 0; }
    HOLDER="$(holder_label "$DIR")"
    [[ "$HOLDER" == "$LABEL" ]] || die "not releasing $DIR: held by '${HOLDER:-someone outside this kit}', not '$LABEL'"
    rm -f "$DIR/holder"
    rmdir "$DIR" || die "$DIR is not empty after removing its holder file; left as it is"
    echo "released $DIR" ;;
  *) die "usage: lock.sh acquire|release|status pro|promax [label] [--wait [minutes]]" ;;
esac
