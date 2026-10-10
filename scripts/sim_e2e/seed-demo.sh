#!/bin/bash
# seed-demo.sh <name>
#
# Runs the COPY's seed-demo.js against the COPY's throwaway database: demo@stride-review.com with
# six habits and ~30 days of realistic check-ins (the App Store review account's data). cwd is the
# copy (no .env there for dotenv), env -i, and no DEMO_TOKEN, so seed-demo makes a fresh random
# REUSABLE login token valid for a year — in this database only.
#
# Re-running wipes and recreates the demo account's habits, entries, tombstones, tokens and
# sessions (seed-demo's own behaviour): a signed-in demo device then gets user=null.
#
# stdout: the reusable demo token (paste it in "I have a login token"; it is not used up, and
#         is the way around /v1/auth/verify's 10-per-15-min limit for the demo account).
# stderr: seed-demo.js's own report.
source "$(dirname "$0")/lib.sh"

NAME="${1:-}"
[[ -n "$NAME" ]] || die "usage: seed-demo.sh <name>"
require_node
require_db "$NAME"
COPY="$(server_copy "$NAME")"
[[ -f "$COPY/seed-demo.js" ]] || die "no seed-demo.js in $COPY"
if ls "$COPY"/.env* >/dev/null 2>&1; then die "refusing: an .env file is in the copy"; fi

OUT="$(cd "$COPY" && env -i NODE_ENV=test "$NODE" "$COPY/seed-demo.js")"
echo "$OUT" >&2
# A here-string, not echo | sed | head -1: no pipe to break under pipefail (lib.sh header).
TOKEN="$(sed -n 's/^  Token: \([0-9a-f]\{16,\}\)$/\1/p' <<<"$OUT")"
TOKEN="${TOKEN%%$'\n'*}"
[[ -n "$TOKEN" ]] || die "seed-demo.js printed no token"
echo "$TOKEN"
