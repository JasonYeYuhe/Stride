#!/bin/bash
# The App Review demo-account acceptance test, run the way a reviewer's device would:
# compile the SHIPPING sync code in Shared/ into a tiny macOS tool, sign in to production
# with the demo token, pull (read only — it never pushes), run the real SyncReconciler into an
# in-memory store, and print what the app computes (records, streaks, 30-day rates,
# createdAt, rows the reconciler rejected) for every demo habit.
#
# Run this before every submission. On 1.2.2 it would have shown six habits with no
# history — the demo ids were lower case and the timestamps had milliseconds — and the
# unit tests were green throughout. Anything with 0 records, a 0 streak on a habit that
# should have one, or createdAt == today means a reviewer will see a broken app.
#
# The token is read over SSH from the server's .env and never printed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT="$(mktemp -d -t stride-demo-check)"
trap 'rm -rf "$OUT"' EXIT

# Every Shared/*.swift, not a hand-kept list: the 1.3.1 reconciler reaches into the delivery
# state, the deletion queue and the engine's types, and the old seven-file list stopped
# compiling the day it landed. The one exclusion is SentryBootstrap.swift — it imports the
# Sentry package, which a bare swiftc has no module for.
# All the rest build for macOS as they are (SwiftUI/SwiftData/os.log only), checked 2026-09-28.
SOURCES=()
for f in "$PROJECT_DIR"/Shared/*.swift; do
  [[ "$(basename "$f")" == "SentryBootstrap.swift" ]] || SOURCES+=("$f")
done
echo "Compiling Shared/ (${#SOURCES[@]} files, not SentryBootstrap.swift) + scripts/demo_check/main.swift..."
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  "${SOURCES[@]}" "$SCRIPT_DIR"/demo_check/main.swift \
  -o "$OUT/demo-check"

DEMO_TOKEN="$(ssh -o IdentityAgent=none -o ConnectTimeout=20 -i ~/.ssh/id_ed25519 \
  azureuser@172.207.80.109 'sudo grep "^DEMO_TOKEN=" /root/stride-server/.env | cut -d= -f2- | tr -d "\"\r"')"
[[ -n "$DEMO_TOKEN" ]] || { echo "could not read DEMO_TOKEN from the server"; exit 1; }
DEMO_TOKEN="$DEMO_TOKEN" "$OUT/demo-check"
