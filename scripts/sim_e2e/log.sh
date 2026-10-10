#!/bin/bash
# log.sh <name> [n]            the last n (default 40) E2E request lines of server <name>
# log.sh <name> mark           the log's current line count: a mark to read from later
# log.sh <name> since <mark>   the E2E lines written after that mark
# log.sh <name> path           the log file's path (it also holds the server's own output)
#
# Mark before an action in the app, read "since" after it: that is the request trail of that one
# action. Line format: see e2e-request-log.js or README.md.
source "$(dirname "$0")/lib.sh"

NAME="${1:-}"
[[ -n "$NAME" ]] || die "usage: log.sh <name> [n] | mark | since <mark> | path"
LOG="$(server_home "$NAME")/server.log"
[[ -f "$LOG" ]] || die "no log for server '$NAME' ($LOG)"
case "${2:-40}" in
  mark) wc -l <"$LOG" | tr -d ' ' ;;
  path) echo "$LOG" ;;
  since)
    M="${3:-}"
    [[ "$M" =~ ^[0-9]+$ ]] || die "since needs a mark from 'log.sh $NAME mark'"
    tail -n +"$((M + 1))" "$LOG" | grep '^E2E ' || true ;;
  *)
    N="${2:-40}"
    [[ "$N" =~ ^[0-9]+$ ]] || die "unknown argument $N"
    grep '^E2E ' "$LOG" | tail -n "$N" || true ;;
esac
