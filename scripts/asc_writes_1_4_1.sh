#!/bin/bash
# The owner-approved App Store Connect writes for Stride 1.4.1 (2026-10-22: "同意 A–E，定价也按你推荐的来"),
# in order, stopping at the first failure. Run it yourself, in a terminal, from the repo root:
#
#   scripts/asc_writes_1_4_1.sh
#
# Every step is re-runnable: each one reads what is live and changes only what differs, so after a
# failure, fix the cause and run the whole script again.
#   1. in-app purchase copy: Yearly without "save 44%", Lifetime in all six languages (iap_copy.py)
#   2. pricing: Lifetime 39.99 USD, Billing Grace Period on (iap_pricing.py); the free trial waits for 1.4.2
#   3. the 1.4.1 version records on iOS and macOS, with What's New (release.py prepare)
#   4. store metadata, the Mac's own promotional text, localized names and subtitles (push_metadata.py --app-info)
#   5. App Review notes from docs/review-notes-1.4.1.md (review_notes.py; the demo sign-in fields are kept)
#   6. screenshots: Mac APP_DESKTOP ×4, iOS 4 sizes × 4 (store_screenshots.py, en-US)
#   7. a read-back of both records (release.py show)
# It uploads no build and submits nothing: that is build-appstore.sh all --upload, then
# release.py finish, after the last gates, each with its own go.
set -euo pipefail
cd "$(dirname "$0")/.."
S=build/store-screenshots/1.4.1

step() { echo; echo "━━ $* ━━"; }

step "1/7 in-app purchase copy";  python3 scripts/iap_copy.py --yes
step "2/7 pricing";               python3 scripts/iap_pricing.py --yes
step "3/7 version records";       python3 scripts/release.py prepare 1.4.1
step "4/7 store metadata";        python3 scripts/push_metadata.py 1.4.1 --app-info
step "5/7 review notes";          python3 scripts/review_notes.py 1.4.1 --yes
step "6/7 screenshots (Mac)"
python3 scripts/store_screenshots.py upload --platform MAC_OS --version 1.4.1 \
    --set APP_DESKTOP "$S"/mac/01.png "$S"/mac/02.png "$S"/mac/03.png "$S"/mac/04.png --yes
step "6/7 screenshots (iOS)"
sets=()
for pair in APP_IPHONE_67:iphone69 APP_IPHONE_65:iphone65 APP_IPAD_PRO_3GEN_129:ipad13 APP_IPAD_PRO_129:ipad129; do
    sets+=(--set "${pair%%:*}" "$S/${pair##*:}"/01_today.png "$S/${pair##*:}"/02_stats.png \
                               "$S/${pair##*:}"/03_history.png "$S/${pair##*:}"/04_settings.png)
done
python3 scripts/store_screenshots.py upload --platform IOS --version 1.4.1 "${sets[@]}" --yes
step "7/7 read-back";             python3 scripts/release.py show 1.4.1

echo
echo "✓ All 1.4.1 App Store Connect writes done. Nothing was submitted."
