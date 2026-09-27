#!/bin/bash
# Assert what must be inside a built macOS Stride.app: privacy manifest, embedded Sentry,
# and a sane Info.plist (bundle id, versions, display name).
#
#   scripts/ci/check_macos_product.sh <path/to/Stride.app>
#
# Run by CI after the StrideMac build and by scripts/verify_archive.sh on the archived app.
# The macOS app has no extension; see scripts/ci/product_checks.sh for why each check exists.
set -uo pipefail   # no -e: report every failed check, then exit on the count

[[ $# -eq 1 ]] || { echo "Usage: $0 <path/to/Stride.app>"; exit 2; }
APP="${1%/}"
[[ -d "$APP" ]] || { echo "  ✗ no app bundle at $APP"; exit 1; }

source "$(cd "$(dirname "$0")" && pwd)/product_checks.sh"

echo "Checking macOS product: $APP"
check_macos_app "$APP"

if (( CHECK_FAILED > 0 )); then
    echo "  $CHECK_FAILED check(s) failed."
    exit 1
fi
echo "  All macOS product checks passed."
