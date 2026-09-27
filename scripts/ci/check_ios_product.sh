#!/bin/bash
# Assert what must be inside a built iOS Stride.app: the embedded widget extension, a
# privacy manifest in both the app and the appex, and a sane Info.plist in each.
#
#   scripts/ci/check_ios_product.sh <path/to/Stride.app>
#
# Run by CI after `xcodebuild build -scheme Stride -destination generic/platform=iOS`, by
# the pre-push hook (scripts/git-hooks/pre-push), and — on the archived app — by
# scripts/verify_archive.sh. A build that is green but ships without the widget is exactly
# how 1.2.0 and 1.2.1 went out; see scripts/ci/product_checks.sh for the history.
set -uo pipefail   # no -e: report every failed check, then exit on the count

[[ $# -eq 1 ]] || { echo "Usage: $0 <path/to/Stride.app>"; exit 2; }
APP="${1%/}"
[[ -d "$APP" ]] || { echo "  ✗ no app bundle at $APP"; exit 1; }

source "$(cd "$(dirname "$0")" && pwd)/product_checks.sh"

echo "Checking iOS product: $APP"
check_ios_app "$APP"

if (( CHECK_FAILED > 0 )); then
    echo "  $CHECK_FAILED check(s) failed."
    exit 1
fi
echo "  All iOS product checks passed."
