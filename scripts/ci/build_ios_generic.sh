#!/bin/bash
# Build the shipping iOS app for a generic device and check what ended up inside it.
#
#   scripts/ci/build_ios_generic.sh <derived-data-dir> [extra xcodebuild args...]
#
# A device destination needs no simulator runtime, which is what kept iOS out of CI until
# 1.3.0 (the old ci.yml comment: runners had no runtime matching their SDK). Unsigned —
# CODE_SIGNING_ALLOWED=NO — because the point is the bundle's CONTENTS: whether the widget
# is embedded, whether the privacy manifests and Info.plist keys made it in. Signing is
# verified on the real archive by scripts/verify_archive.sh.
#
# Shared by CI (.github/workflows/ci.yml) and the pre-push hook, so both run exactly this.
# Run from anywhere; it works on the repo it lives in.
set -euo pipefail

[[ $# -ge 1 ]] || { echo "Usage: $0 <derived-data-dir> [extra xcodebuild args...]"; exit 2; }
DERIVED="$1"; shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

PRODUCTS="$DERIVED/Build/Products/Debug-iphoneos"

# Start from empty products. An incremental build never deletes a resource that has left the
# project: with the widget's PrivacyInfo.xcprivacy taken out of project.yml, the pre-push
# hook's persistent derived data still held last build's copy inside the appex and the check
# passed (measured 2026-09-26). Intermediates stay, so this costs a relink and the copy
# phases, not a recompile. (CI starts from nothing anyway.)
rm -rf "$PRODUCTS"

echo "Building Stride (Debug, generic/platform=iOS) into $DERIVED"
# -configuration explicitly: the products path below depends on it, and xcodebuild would
# otherwise take whatever the scheme's run action says.
xcodebuild build \
    -project "$PROJECT_DIR/Stride.xcodeproj" \
    -scheme Stride \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    -quiet \
    CODE_SIGNING_ALLOWED=NO \
    "$@"

"$SCRIPT_DIR/check_ios_product.sh" "$PRODUCTS/Stride.app"
