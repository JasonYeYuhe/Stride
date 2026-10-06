#!/bin/bash
# account.sh <name> revoke-user <id|email>     delete every session of the user
#                                              stdout {"userId","email","revokedSessions"}
# account.sh <name> lookup <id|email>          stdout {"userId","email","sessions"} (live ones)
# account.sh <name> request-snapshot <userId>  arm a one-shot 409 snapshot_required for the
#                                              account's next push/pull from a 1.3.1+ app
#                                              (the row ops/request-snapshot.js writes)
# account.sh <name> row-error-trigger          install sync_rehearsal's row_error injection: an
#                                              entry INSERT whose note is REHEARSAL_ROW_ERROR fails
#
# revoke-user is what a sign-out everywhere (or an expiry) leaves behind: the app's stored token
# then gets {user:null} from the launch session check and 401 from sync. request-snapshot and
# row-error-trigger reuse scripts/sync_rehearsal/accounts.js, with its directory guard pointed at
# $ROOT/servers. All refuse a database that is not under $ROOT/servers/.
source "$(dirname "$0")/lib.sh"

NAME="${1:-}"
CMD="${2:-}"
ARG="${3:-}"
[[ -n "$NAME" && -n "$CMD" ]] || die "usage: account.sh <name> revoke-user <id|email> | lookup <id|email> | request-snapshot <userId> | row-error-trigger"
require_node
require_db "$NAME"
COPY="$(server_copy "$NAME")"

case "$CMD" in
  revoke-user|lookup)
    [[ -n "$ARG" ]] || die "$CMD needs a user id or email"
    exec "$NODE" "$KIT_DIR/db-tool.js" "$COPY" "$CMD" "$ARG" ;;
  request-snapshot)
    [[ "$ARG" =~ ^[0-9]+$ ]] || die "request-snapshot needs a numeric user id (account.sh $NAME lookup <email>)"
    STRIDE_REHEARSAL_ROOT="$ROOT/servers" "$NODE" "$PROJECT_DIR/scripts/sync_rehearsal/accounts.js" "$COPY" request-snapshot "$ARG"
    echo ;;
  row-error-trigger)
    STRIDE_REHEARSAL_ROOT="$ROOT/servers" "$NODE" "$PROJECT_DIR/scripts/sync_rehearsal/accounts.js" "$COPY" row-error-trigger
    echo ;;
  *) die "unknown command $CMD" ;;
esac
