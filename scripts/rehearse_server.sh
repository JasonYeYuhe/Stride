#!/usr/bin/env bash
# Rehearse the working tree's server/ on a COPY of production, on the production host, before
# deploying it. Nothing here touches the live process or the live database.
#
# 1.2.3's rehearsal is what caught 133 demo entries with a NULL updated_at: the test suite's
# database never has the shapes an upgraded production database has (columns added by ALTER
# TABLE, rows written by seed scripts rather than pushes). So: copy the code and an online
# .backup of stride.db into /root/rehearsal-<stamp>, start it on 127.0.0.1:3199 with no .env
# (no Sentry, no email, no APM), run server/ops/rehearsal-checks.js against it as the App Review
# demo account, print the server log, and delete everything. Exit status = the checks'.
#
#   scripts/rehearse_server.sh
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=azureuser@172.207.80.109
SSH_OPTS=(-o IdentityAgent=none -o ConnectTimeout=20 -i "$HOME/.ssh/id_ed25519")
STAMP="$(date +%Y%m%d-%H%M%S)"
R="/root/rehearsal-$STAMP"

echo "==> copying server/ to $HOST:$R"
rsync -az --exclude node_modules --exclude '*.db' --exclude '*.db-shm' --exclude '*.db-wal' \
  --exclude .env --exclude test --exclude SYNC_PAUSED --exclude .DS_Store \
  -e "ssh ${SSH_OPTS[*]}" --rsync-path="sudo mkdir -p $R && sudo rsync" \
  server/ "$HOST:$R/"

echo "==> starting the copy on 127.0.0.1:3199 against a .backup of production"
set +e
ssh "${SSH_OPTS[@]}" "$HOST" "sudo bash -s" <<REMOTE
set -uo pipefail
cd "$R"
ln -s /root/stride-server/node_modules node_modules
sqlite3 /root/stride-server/stride.db ".backup '$R/stride.db'"
env -i PATH=/usr/bin:/bin HOME=/root NODE_ENV=production PORT=3199 DD_TRACE_ENABLED=false \
  /usr/bin/node index.js > "$R/server.log" 2>&1 &
PID=\$!
for i in \$(seq 1 120); do curl -sf http://127.0.0.1:3199/health >/dev/null && break; sleep 1; done
REHEARSAL_DIR="$R" /usr/bin/node "$R/ops/rehearsal-checks.js"
RC=\$?
kill -TERM \$PID; wait \$PID 2>/dev/null
echo "---- rehearsal server log (tail) ----"; tail -40 "$R/server.log"
cd / && rm -rf "$R"
exit \$RC
REMOTE
RC=$?
set -e
[[ $RC -eq 0 ]] && echo "✓ rehearsal passed — safe to deploy" || echo "✗ rehearsal FAILED (exit $RC) — do not deploy"
exit $RC
