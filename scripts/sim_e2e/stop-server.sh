#!/bin/bash
# stop-server.sh <name>
#
# Stops the kit server <name>: SIGTERM to the pid in its pid file — only if that pid is still the
# copy's `node …/servers/<name>/server/index.js` — then SIGKILL after 20 s, then confirms port 3002
# is free. It never signals anything else, and never looks up a process by name. The copy, its
# database and its log stay (start-server.sh <name> restarts on them; --fresh wipes them).
#
# Exit 0 when the server is stopped (or was not running) and 3002 is free; 1 otherwise.
source "$(dirname "$0")/lib.sh"

NAME="${1:-}"
[[ -n "$NAME" ]] || die "usage: stop-server.sh <name>"
HOME_DIR="$(server_home "$NAME")"
PIDFILE="$HOME_DIR/server.pid"

if [[ -f "$PIDFILE" ]]; then
  PID="$(cat "$PIDFILE")"
  if is_kit_server_pid "$NAME" "$PID"; then
    kill -TERM "$PID" 2>/dev/null || true
    for _ in $(seq 1 100); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$PID" 2>/dev/null && is_kit_server_pid "$NAME" "$PID"; then
      note "pid $PID did not exit within 20 s of SIGTERM: SIGKILL"
      kill -KILL "$PID" 2>/dev/null || true
      sleep 0.5
    fi
    echo "stopped server '$NAME' (pid $PID)"
  else
    echo "server '$NAME' was not running (pid file named $PID, which is not its index.js)"
  fi
  rm -f "$PIDFILE"
else
  echo "server '$NAME' was not running (no pid file)"
fi

for _ in $(seq 1 25); do
  [[ -z "$(port_listeners)" ]] && break
  sleep 0.2
done
LISTENERS="$(port_listeners)"
if [[ -n "$LISTENERS" ]]; then
  for p in $LISTENERS; do
    note "port $PORT is still held by pid $p: $(ps -o command= -p "$p" 2>/dev/null || echo '?')"
  done
  die "port $PORT is NOT free (not touching a process this kit did not start for '$NAME')"
fi
echo "port $PORT is free"
