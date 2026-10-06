#!/bin/bash
# session.sh <name> <email>
#
# A Bearer session token for <email> on server <name>, signed in the way the app signs in: mints
# a login token (login-token.sh) and POSTs it to http://127.0.0.1:3002/v1/auth/verify with curl.
# Use it to act as "another device": pushes and pulls with curl, e.g.
#
#   TOKEN=$(scripts/sim_e2e/session.sh e2e a@example.com)
#   curl -s -H "Authorization: Bearer $TOKEN" -H 'X-Stride-Client: ios/1.3.1(20)' \
#        http://127.0.0.1:3002/v1/sync/pull
#
# stdout: the session token.  stderr: {"userId","email"}.
# Each call uses one of /v1/auth/verify's 10 per 15 min per IP (the app's Log In shares it);
# start-server.sh <name> without --fresh resets it.
source "$(dirname "$0")/lib.sh"

NAME="${1:-}"
EMAIL="${2:-}"
[[ -n "$NAME" && -n "$EMAIL" ]] || die "usage: session.sh <name> <email>"
require_node
require_running "$NAME" >/dev/null
LOGIN="$("$KIT_DIR/login-token.sh" "$NAME" "$EMAIL" 2>/dev/null)" || die "could not mint a login token"
BODY="$("$NODE" -e 'process.stdout.write(JSON.stringify({ token: process.argv[1] }))' "$LOGIN")"
RESP="$(curl -sS --max-time 10 -X POST "$BASE/v1/auth/verify" -H 'Content-Type: application/json' \
  --data "$BODY" -w '\n%{http_code}')" || die "verify request failed"
CODE="${RESP##*$'\n'}"
JSON="${RESP%$'\n'*}"
[[ "$CODE" == "200" ]] || die "verify answered $CODE: $JSON"
echo "$JSON" | "$NODE" -e '
  let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
    const r = JSON.parse(s);
    if (!r.sessionToken) { console.error("no sessionToken in the answer"); process.exit(1); }
    process.stderr.write(JSON.stringify({ userId: r.user.id, email: r.user.email }) + "\n");
    process.stdout.write(r.sessionToken + "\n");
  });'
