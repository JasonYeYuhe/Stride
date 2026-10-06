#!/bin/bash
# login-token.sh <name> <email>
#
# Mints a sign-in token in server <name>'s throwaway database exactly as server/auth.js
# createMagicLinkToken does: INSERT OR IGNORE the user (email trimmed + lower-cased), and a
# magic_link_tokens row with the sha256 of a random 32-byte hex token, 30-minute expiry,
# single-use. No email is sent; paste the token in the app's "I have a login token" field.
#
# stdout: the RAW token (one line).   stderr: {"userId":…,"email":"…"}
# Verifying it (the app's Log In, or session.sh) counts against /v1/auth/verify's limit of 10 per
# 15 min per IP; start-server.sh <name> (restart, no --fresh) resets that limit.
source "$(dirname "$0")/lib.sh"

NAME="${1:-}"
EMAIL="${2:-}"
[[ -n "$NAME" && -n "$EMAIL" ]] || die "usage: login-token.sh <name> <email>"
require_node
require_db "$NAME"
exec "$NODE" "$KIT_DIR/db-tool.js" "$(server_copy "$NAME")" login-token "$EMAIL"
