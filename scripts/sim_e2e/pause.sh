#!/bin/bash
# pause.sh <name> on [retryAfterSeconds] | off | status
#
# The sync pause switch of server <name> (server/lib/syncPause.js): its flag file is
# <copy>/SYNC_PAUSED (the server runs with SYNC_PAUSE_FILE pointing there, never at the real
# switch). Read on every request, so no restart: while on, every /v1/sync/* answers
# 503 {code: sync_paused, retryAfterSeconds} with Retry-After (default 900 s, or the number given).
# The flag survives a restart without --fresh.
source "$(dirname "$0")/lib.sh"

NAME="${1:-}"
CMD="${2:-}"
[[ -n "$NAME" && -n "$CMD" ]] || die "usage: pause.sh <name> on [retryAfterSeconds] | off | status"
COPY="$(server_copy "$NAME")"
[[ -d "$COPY" ]] || die "no server '$NAME' (start-server.sh $NAME --fresh)"
FLAG="$COPY/SYNC_PAUSED"
under_root "$FLAG" || die "refusing $FLAG"

case "$CMD" in
  on)
    SECS="${3:-}"
    if [[ -n "$SECS" ]]; then
      [[ "$SECS" =~ ^[1-9][0-9]*$ ]] || die "retryAfterSeconds must be a positive integer"
      printf '%s' "$SECS" >"$FLAG"
    else
      : >"$FLAG"
    fi
    echo "paused (retryAfterSeconds=${SECS:-900})" ;;
  off)
    rm -f "$FLAG"
    echo "not paused" ;;
  status)
    if [[ -f "$FLAG" ]]; then
      S="$(cat "$FLAG")"
      echo "paused (retryAfterSeconds=${S:-900})"
    else
      echo "not paused"
    fi ;;
  *) die "unknown command $CMD" ;;
esac
