#!/bin/bash
# sql.sh <name> "<read-only SQL>" [--json]
#
# One read-only statement against server <name>'s throwaway database (better-sqlite3 opened
# readonly; anything but a reader statement is refused). Safe while the server runs (WAL).
# stdout: a header line and rows, columns separated by |, NULL for null; --json: one JSON object
# per row.
#   sql.sh e2e "SELECT id, email FROM users"
#   sql.sh e2e "SELECT h.name, e.date, e.value FROM habit_entries e JOIN habits h ON h.id = e.habit_id ORDER BY e.date"
source "$(dirname "$0")/lib.sh"

NAME="${1:-}"
SQL="${2:-}"
[[ -n "$NAME" && -n "$SQL" ]] || die 'usage: sql.sh <name> "<read-only SQL>" [--json]'
require_node
require_db "$NAME"
exec "$NODE" "$KIT_DIR/db-tool.js" "$(server_copy "$NAME")" sql "$SQL" "${3:-}"
