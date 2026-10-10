#!/bin/bash
# start-server.sh <name> [--fresh] [--test-hooks]
#
# Starts a throwaway COPY of this tree's server/ on 127.0.0.1:3002, where Debug builds of the app
# point (APIClient.defaultBaseURL = http://localhost:3002). Detached: it keeps running after this
# script exits, until stop-server.sh <name>.
#
#   --fresh       wipe $ROOT/servers/<name> first: new copy, NEW EMPTY DATABASE, empty log.
#   (no --fresh)  restart: the code is re-copied, the database (and a pause flag) are kept.
#                 Restarting also resets the in-memory limiters, including /v1/auth/verify's
#                 10 per 15 min per IP.
#   --test-hooks  mount server/lib/testHooks.js (STRIDE_TEST_HOOKS=1; loopback only).
#
# The copy: rsync of server/ without node_modules, stride.db*, .env*, SYNC_PAUSED, .DS_Store and
# test/; node_modules is a symlink to server/node_modules; db.js opens <copy>/stride.db, so the
# real server/stride.db is never opened. The request log (e2e-request-log.js) is added to the
# COPY's index.js only. Environment: env -i, so nothing is inherited — NODE_ENV=test PORT=3002
# BIND_HOST=127.0.0.1 SYNC_PAUSE_FILE=<copy>/SYNC_PAUSED RESEND_API_KEY= SENTRY_DSN= — and no .env
# exists in the copy for dotenv to read: no mail, no Sentry, no production anything.
#
# Refuses when anything else listens on 3002 (it never kills a process it did not start).
# A running server of the SAME name is stopped first (that is the restart); another kit server
# must be stopped with stop-server.sh.
#
# stdout: KEY=value lines (NAME, PID, BASE, COPY, DB, LOG, PAUSE_FILE).
source "$(dirname "$0")/lib.sh"

NAME="${1:-}"
[[ -n "$NAME" ]] || die "usage: start-server.sh <name> [--fresh] [--test-hooks]"
shift
FRESH=0
HOOKS=0
for a in "$@"; do
  case "$a" in
    --fresh) FRESH=1 ;;
    --test-hooks) HOOKS=1 ;;
    *) die "unknown option $a" ;;
  esac
done
require_node
[[ -d "$PROJECT_DIR/server/node_modules" ]] || die "run npm install in server/ first"

HOME_DIR="$(server_home "$NAME")"
COPY="$(server_copy "$NAME")"
LOG="$HOME_DIR/server.log"
PIDFILE="$HOME_DIR/server.pid"

# ── Who holds 3002? ─────────────────────────────────────────────────────────────────────────
LISTENERS="$(port_listeners)"
if [[ -n "$LISTENERS" ]]; then
  OWN=""
  [[ -f "$PIDFILE" ]] && OWN="$(cat "$PIDFILE")"
  if [[ -n "$OWN" && "$LISTENERS" == "$OWN" ]] && is_kit_server_pid "$NAME" "$OWN"; then
    note "server '$NAME' is running (pid $OWN): stopping it for the restart"
    "$KIT_DIR/stop-server.sh" "$NAME" >&2
  else
    for p in $LISTENERS; do
      note "port $PORT is held by pid $p: $(ps -o command= -p "$p" 2>/dev/null || echo '?')"
    done
    die "port $PORT is taken by something this script did not start for '$NAME' — not touching it. If it is another kit server, stop it with stop-server.sh <its name>; otherwise report it."
  fi
fi
[[ -z "$(port_listeners)" ]] || die "port $PORT is still taken"

# ── The copy ────────────────────────────────────────────────────────────────────────────────
if [[ $FRESH -eq 1 ]]; then
  rm_under_root "$HOME_DIR"
fi
mkdir -p "$COPY"
under_root "$COPY" || die "refusing copy dir $COPY"
rsync -a --delete \
  --exclude node_modules --exclude 'stride.db*' --exclude '.env*' --exclude SYNC_PAUSED \
  --exclude .DS_Store --exclude test \
  "$PROJECT_DIR/server/" "$COPY/"
[[ -L "$COPY/node_modules" ]] || { rm_under_root "$COPY/node_modules"; ln -s "$PROJECT_DIR/server/node_modules" "$COPY/node_modules"; }
if ls "$COPY"/.env* >/dev/null 2>&1; then die "refusing: an .env file is in the copy"; fi
if [[ $FRESH -eq 1 && -e "$COPY/stride.db" ]]; then die "refusing: a database was copied"; fi

# The request log, into the COPY's index.js only (anchor: the one `const app = express();`).
cp "$KIT_DIR/e2e-request-log.js" "$COPY/e2e-request-log.js"
"$NODE" - "$COPY/index.js" <<'EOF'
const fs = require("fs");
const file = process.argv[2];
const anchor = "const app = express();";
let src = fs.readFileSync(file, "utf8");
const n = src.split(anchor).length - 1;
if (n !== 1) { console.error(`expected exactly one "${anchor}" in ${file}, found ${n}`); process.exit(1); }
src = src.replace(anchor, `${anchor}\nrequire("./e2e-request-log")(app); // sim_e2e: this COPY only (scripts/sim_e2e/start-server.sh)`);
fs.writeFileSync(file, src);
EOF
grep -q 'require("./e2e-request-log")(app)' "$COPY/index.js" || die "the request log was not injected"
if grep -q 'e2e-request-log' "$PROJECT_DIR/server/index.js"; then die "server/index.js mentions the request log: the source tree was modified"; fi

# ── Start, detached ─────────────────────────────────────────────────────────────────────────
mkdir -p "$HOME_DIR"
MARK=1
if [[ -f "$LOG" ]]; then MARK=$(( $(wc -l <"$LOG") + 1 )); fi
echo "=== sim_e2e start $(date -u +%Y-%m-%dT%H:%M:%SZ) name=$NAME fresh=$FRESH test-hooks=$HOOKS ===" >>"$LOG"
HOOK_ENV="STRIDE_TEST_HOOKS=0"
[[ $HOOKS -eq 1 ]] && HOOK_ENV="STRIDE_TEST_HOOKS=1"
(
  cd "$COPY"
  exec nohup env -i NODE_ENV=test PORT="$PORT" BIND_HOST=127.0.0.1 \
    SYNC_PAUSE_FILE="$COPY/SYNC_PAUSED" RESEND_API_KEY= SENTRY_DSN= "$HOOK_ENV" \
    "$NODE" "$COPY/index.js"
) >>"$LOG" 2>&1 </dev/null &
PID=$!
echo "$PID" >"$PIDFILE"

for _ in $(seq 1 150); do
  curl -sf "$BASE/health" >/dev/null 2>&1 && break
  kill -0 "$PID" 2>/dev/null || { tail -n +"$MARK" "$LOG" >&2; rm -f "$PIDFILE"; die "the server exited during startup"; }
  sleep 0.2
done
curl -sf "$BASE/health" >/dev/null 2>&1 || { tail -n +"$MARK" "$LOG" >&2; die "the server did not answer /health within 30 s (pid $PID left running; stop-server.sh $NAME)"; }
[[ "$(port_listeners)" == "$PID" ]] || die "something other than pid $PID answers on $PORT"
is_kit_server_pid "$NAME" "$PID" || die "pid $PID is not the copy's index.js"
[[ -f "$COPY/stride.db" ]] || die "the server did not create its database in the copy"
# grep without -q reads to the end, so tail never meets a closed pipe (lib.sh header).
tail -n +"$MARK" "$LOG" | grep "\[sim_e2e\] request log mounted" >/dev/null || die "the request log did not mount (see $LOG)"
if [[ $HOOKS -eq 1 ]]; then
  tail -n +"$MARK" "$LOG" | grep "\[test-hooks\] mounted" >/dev/null || die "--test-hooks: the hooks did not mount (see $LOG)"
fi

echo "NAME=$NAME"
echo "PID=$PID"
echo "BASE=$BASE"
echo "COPY=$COPY"
echo "DB=$COPY/stride.db"
echo "LOG=$LOG"
echo "PAUSE_FILE=$COPY/SYNC_PAUSED"
