#!/bin/bash
# The M2 sync rehearsal (DEV-PLAN-1.3.md M2, Acceptance (1)): the SHIPPING sync engine from
# Shared/ compiled into a macOS tool, driving in-memory "devices" against a real local server.
#
# Why this exists next to the suites: 1.2.3's record says the sync bugs that mattered were found
# by rehearsal, not by suites — the reconciler's tests were green against a hand-copied replica
# while the shipping code was wrong. So nothing here is a copy: the tool compiles Shared/*.swift
# (the same files the app and widget build) plus scripts/sync_rehearsal/, and talks to
# `NODE_ENV=test node index.js` from THIS tree's server/ over HTTP.
#
# What it guarantees about the server it starts:
#   - a COPY of server/ in a temp dir, node_modules symlinked: db.js hard-codes <dir>/stride.db,
#     so the rehearsal gets a fresh throwaway database and server/stride.db is never opened;
#   - bound to 127.0.0.1 on a free port; never production, never a remote host;
#   - no .env copied, RESEND_API_KEY / SENTRY_DSN empty (dotenv never overrides a variable that
#     is present), the pause flag inside the temp dir — no mail, no Sentry, no real switch;
#   - the production sync rate limit (60 / min / account) switched ON, which NODE_ENV=test
#     would otherwise bypass, so "no 429" means something;
#   - accounts are inserted straight into the temp database (sync_rehearsal/accounts.js, the
#     server suite's createTestUser / createTestSession), so no email is involved;
#   - killed by PID (never pkill) and the temp dir removed on exit, unless
#     STRIDE_REHEARSAL_KEEP=1, which keeps it and prints where.
#
# Run it before every submission next to check_demo_account.sh. Exit 0 = every check passed;
# SKIPPED rows are parts of M2 that are not built yet and say so.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

NODE="$(command -v node || true)"
[[ -n "$NODE" ]] || { echo "node is required (the local server)"; exit 1; }
[[ -d "$PROJECT_DIR/server/node_modules" ]] || { echo "run npm install in server/ first"; exit 1; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/stride-sync-rehearsal.XXXXXX")"
ROOT="$(cd "$ROOT" && pwd -P)"
SERVER_PID=""
cleanup() {
  local status=$?
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ "${STRIDE_REHEARSAL_KEEP:-0}" == "1" ]]; then
    echo "kept: $ROOT (server log: $ROOT/server.log)"
  else
    rm -rf "$ROOT"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "Copying server/ to a throwaway directory..."
rsync -a --exclude node_modules --exclude 'stride.db*' --exclude '.env*' --exclude SYNC_PAUSED \
  --exclude .DS_Store --exclude test "$PROJECT_DIR/server/" "$ROOT/server/"
ln -s "$PROJECT_DIR/server/node_modules" "$ROOT/server/node_modules"
[[ ! -e "$ROOT/server/stride.db" ]] || { echo "refusing: a database was copied"; exit 1; }

PORT="$("$NODE" -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
BASE="http://127.0.0.1:$PORT"

echo "Starting the local server on $BASE..."
(
  cd "$ROOT/server"
  exec env -u SYNC_PAUSED -u SYNC_PAUSE_RETRY_AFTER_SECONDS -u SYNC_AUTH_FAILURE_LIMIT_PER_15MIN \
    -u GLOBAL_RATE_LIMIT_PER_15MIN -u DEMO_TOKEN \
    NODE_ENV=test PORT="$PORT" BIND_HOST=127.0.0.1 SYNC_PAUSE_FILE="$ROOT/SYNC_PAUSED" \
    RESEND_API_KEY= SENTRY_DSN= SENTRY_TRACES_SAMPLE_RATE= SYNC_RATE_LIMIT_PER_MIN=60 \
    "$NODE" "$ROOT/server/index.js"
) >"$ROOT/server.log" 2>&1 &
SERVER_PID=$!

# Compile while the server boots. Every Shared/ file but SentryBootstrap.swift (it imports the
# Sentry SDK, which a plain swiftc build does not have) — the whole of Shared/, so a file the
# engine starts depending on can never be left out the way check_demo_account.sh's list was.
echo "Compiling Shared/ + scripts/sync_rehearsal/..."
SOURCES=()
for f in "$PROJECT_DIR"/Shared/*.swift; do
  [[ "$(basename "$f")" == "SentryBootstrap.swift" ]] || SOURCES+=("$f")
done
SOURCES+=("$SCRIPT_DIR"/sync_rehearsal/*.swift)
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -module-name SyncRehearsal \
  "${SOURCES[@]}" -o "$ROOT/sync-rehearsal"

for _ in $(seq 1 300); do
  curl -sf "$BASE/health" >/dev/null 2>&1 && break
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "the local server exited:"; cat "$ROOT/server.log"; exit 1; }
  sleep 0.2
done
curl -sf "$BASE/health" >/dev/null || { echo "the local server did not come up:"; cat "$ROOT/server.log"; exit 1; }
[[ -f "$ROOT/server/stride.db" ]] || { echo "the server did not create its throwaway database"; exit 1; }

set +e
STRIDE_REHEARSAL_BASE="$BASE" \
STRIDE_REHEARSAL_SERVER_DIR="$ROOT/server" \
STRIDE_REHEARSAL_ROOT="$ROOT" \
STRIDE_REHEARSAL_HELPER="$SCRIPT_DIR/sync_rehearsal/accounts.js" \
STRIDE_REHEARSAL_NODE="$NODE" \
  "$ROOT/sync-rehearsal"
STATUS=$?
set -e

if [[ $STATUS -ne 0 ]]; then
  echo
  echo "Last lines of the server log:"
  tail -n 40 "$ROOT/server.log"
fi
exit $STATUS
