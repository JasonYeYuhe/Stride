#!/bin/bash
# Dynamic Type sweep: capture every tab of Stride, plus the Pro paywall, at one text size on a
# simulator, as PNGs a person reviews before a release.
#
#   scripts/a11y_sweep.sh [--size <content size>|default] [--out <dir>] [--device <name|UDID>]
#                         [--app <path to Stride.app>] [--lang <code>] [--set core|sync|all]
#                         [extra xcodebuild args...]
#
#   --size    a `simctl ui content_size` value (default: accessibility-extra-extra-extra-large,
#             the largest one). `default` means `large`, the size a fresh device ships with; that
#             mode is the store-screenshot layout check (M1 acceptance 7): a set taken before a
#             Dynamic Type change and one after must match up to sub-pixel text rendering.
#   --out     where the PNGs go (default: build/a11y/<size>/, with `default` for `large`, plus
#             `-<lang>` when --lang is given).
#   --device  the simulator (default "iPhone 17 Pro Max", the screenshot device — see the
#             global notes; the hosted tests hold "iPhone 17 Pro"). An existing simulator is
#             always reused: this never creates, erases or clones one.
#   --app     skip the build and install this .app instead — e.g. one built from another
#             checkout, to capture a before/after pair from the same script. It must be a
#             Debug build: `-demo` and `-paywall` are compiled out of Release.
#   --lang    run every launch in this system language: en, es, ja, ko, zh-Hans or zh-Hant
#             (`-AppleLanguages (<code>)` plus the matching `-AppleLocale`, e.g. ja_JP). The in-app
#             picker is pinned to "System Default" for the launch (`-stride_app_language ""`, the
#             argument domain again), so a language picked on the device earlier cannot win.
#             Without --lang the launches carry no language arguments at all, as before.
#   --set     which captures: `core` (the tabs and the paywall, the 1.3.0 set), `sync` (the M2
#             sync UI, below) or `all` (default).
#   Anything else is passed to xcodebuild (the package-cache flags, typically).
#
# What it does: builds Stride (Debug, its own derived data) unless --app is given; boots the
# simulator if it is not booted; sets the content size, light appearance and a fixed 9:41
# status bar (so two runs diff cleanly); launches with `-demo -tab <n>` for Today, Stats and
# Settings and with `-demo -paywall` for the paywall; captures each with `simctl io screenshot`.
# Stats is captured five times: the top, then scrolled to Insights, the 8-week trend, By Weekday
# and the Activity heatmap with the DEBUG-only `-statsScrollTo <anchor>` (StatsView).
# The `sync` set (1.3.1, DEV-PLAN-1.3.md M2 phase C) draws every new sync state from its DEBUG
# launch scenario, since none of them can be produced on a simulator with no server:
#   10_today_sync_<state>  Today's line under the progress card, `-syncStatus <state>` for
#                          signInAgain, paused, offline, waiting, held, synced, justSynced
#                          (SyncStatusRow.swift; drawn whatever the session says).
#   11_account_<case>      the account screen as the sheet a one-tap sign-in link opens,
#                          `-demoScenario accountConflict | accountUnknownOwner` (fake accounts,
#                          no request; AccountChoiceRouter.demoRequest).
#   12_settings_sync_<s>   Settings' Sync section, `-demoScenario heldRows | recoveredEdits |
#                          syncPaused | syncAll` (SyncSectionDemo; seeds held rows and recovery-
#                          log lines into the demo store when Settings appears).
#   13_settings_deleteAccount  Delete Account's last step (export offer + final button),
#                          `-demoScenario deleteAccount` (a fake signed-in owner; buttons only close).
#   14_restore_handover    the restore's hand-over step "Before You Restore",
#                          `-demoScenario restoreHandover` (a fake previous owner).
#   *_at_<anchor>          at accessibility sizes only: the same screen scrolled to a row with the
#                          DEBUG-only `-scrollTo <anchor>` (SweepScroll in SyncSectionView.swift) —
#                          the account screen's holdings / export / choice buttons, every Sync row
#                          of `syncAll`, and the lower rows of the two sheets (`<anchor>@bottom`
#                          scrolls a row to the bottom edge instead of the top). These replace the
#                          `*_scrollN` frames phase C swiped by hand, which went stale with the
#                          first fix after them and could not be re-taken by the script.
# Not reachable from a launch argument, so not captured: the Settings row that reopens the account
# screen (needs a real signed-in owner conflict).
# The recovery log lives outside the SwiftData store, so `-demo` does not erase it: lines a
# `recoveredEdits` run seeded used to stay on the device and draw "Recovered Edits (3)" into the
# next 03_settings and into the App Store screenshots taken on the same simulator. The sweep
# therefore removes the app's SyncRecoveryLog directory before the first capture and after the
# last, and ends with a plain `-demo` launch that replaces the seeded held rows with the standard
# set. On this screenshot simulator the only writer of either is a DEBUG scenario.
# The simulator's previous content size, appearance, status bar and boot state are ALWAYS put
# back (trap), because the same device takes the App Store screenshots — a sweep that died
# half-way used to leave it at the largest text size, and the next screenshot run would have
# uploaded that.
#
# Known limits (read before trusting a "looks fine"):
#   - `simctl` has no touch input to scroll with, so a screen is captured below the fold only
#     where the app scrolls itself on launch: Stats, via `-statsScrollTo`. The first version of
#     this script took the top of each screen only, and at accessibility-XXXL that proved
#     nothing about the charts 1.3.0 made scale — they start two screens down (the 2026-09-27
#     baseline needed two to three screens of scrolling). Still top-only: Today's lower rows,
#     the Settings habit rows and the paywall price cards; review those by scrolling the booted
#     simulator.
#   - Insights and the 8-week trend are Pro-only. On a simulator with no purchase (the normal
#     case) 02_stats_insights and 02_stats_trend both show the "Advanced Analytics" locked card.
#   - The paywall's prices come from whatever StoreKit answers `simctl launch` (not Xcode's
#     scheme configuration). On 2026-09-27 they loaded; if they do not, the PNG shows the
#     spinner where the price cards go — raise STRIDE_A11Y_SETTLE or review them in Xcode.
#   - `-demo` REPLACES the app's data on that simulator with the demo set (DemoData.populate:
#     habits, check-ins AND groups — a leftover group once drew a header into the default set).
#   - At the default size the account screen and the Settings Sync section are captured top-only
#     (the `*_at_<anchor>` frames are taken at accessibility sizes, where the fold matters). In the
#     heldRows state the Discard rows are below the fold at every size; `syncAll`'s anchors show
#     them.
#
# Environment:
#   STRIDE_A11Y_DERIVED_DATA  derived data for the build (default build/a11y/DerivedData)
#   STRIDE_A11Y_SETTLE        seconds to wait after each launch before capturing (default 4)
#   STRIDE_SIM_LOCK_ROOT      directory for the per-device mutex `lock-<device-slug>` (default
#                             $TMPDIR). Several agents or scripts share these simulators; the
#                             lock is a directory because mkdir is atomic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SIZE="accessibility-extra-extra-extra-large"
OUT=""
WANT="iPhone 17 Pro Max"
APP=""
LANG_CODE=""
SET="all"
XCB_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --size)   SIZE="${2:?--size needs a value}"; shift 2 ;;
        --out)    OUT="${2:?--out needs a value}"; shift 2 ;;
        --device) WANT="${2:?--device needs a value}"; shift 2 ;;
        --app)    APP="${2:?--app needs a value}"; shift 2 ;;
        --lang)   LANG_CODE="${2:?--lang needs a value}"; shift 2 ;;
        --set)    SET="${2:?--set needs a value}"; shift 2 ;;
        -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        *)        XCB_ARGS+=("$1"); shift ;;
    esac
done

LABEL="$SIZE"
[[ "$SIZE" == "default" ]] && SIZE="large"
case "$SIZE" in
    extra-small|small|medium|large|extra-large|extra-extra-large|extra-extra-extra-large) ;;
    accessibility-medium|accessibility-large|accessibility-extra-large) ;;
    accessibility-extra-extra-large|accessibility-extra-extra-extra-large) ;;
    *) echo "✗ Unknown content size '$SIZE' (see: xcrun simctl help ui)"; exit 2 ;;
esac
case "$SET" in core|sync|all) ;; *) echo "✗ Unknown --set '$SET' (core, sync or all)"; exit 2 ;; esac
# The language for every launch, in the argument domain (nothing is written to the device).
LANG_ARGS=()
if [[ -n "$LANG_CODE" ]]; then
    case "$LANG_CODE" in
        en) LOCALE_ID=en_US ;; es) LOCALE_ID=es_ES ;; ja) LOCALE_ID=ja_JP ;; ko) LOCALE_ID=ko_KR ;;
        zh-Hans) LOCALE_ID=zh_CN ;; zh-Hant) LOCALE_ID=zh_TW ;;
        *) echo "✗ Unknown --lang '$LANG_CODE' (en, es, ja, ko, zh-Hans, zh-Hant)"; exit 2 ;;
    esac
    LANG_ARGS=(-AppleLanguages "($LANG_CODE)" -AppleLocale "$LOCALE_ID" -stride_app_language "")
    LABEL="$LABEL-$LANG_CODE"
fi
OUT="${OUT:-$PROJECT_DIR/build/a11y/$LABEL}"
SETTLE="${STRIDE_A11Y_SETTLE:-4}"

# Resolve to ONE UDID (same rule as scripts/ci/run_hosted_tests.sh: a name can exist under
# several runtimes, so prefer a booted one, then the newest runtime).
UDID="$(xcrun simctl list devices available -j | WANT="$WANT" /usr/bin/python3 -c '
import json, os, re, sys
want = os.environ["WANT"]
found = []
for runtime, devs in json.load(sys.stdin)["devices"].items():
    if ".SimRuntime.iOS-" not in runtime:
        continue
    version = tuple(int(x) for x in re.findall(r"\d+", runtime.split("iOS-")[-1]))
    found += [(d, version) for d in devs if want in (d["udid"], d["name"])]
found.sort(key=lambda dv: (dv[0]["state"] == "Booted", dv[1]), reverse=True)
print(found[0][0]["udid"] if found else "")
')" || { echo "✗ xcrun simctl list failed (CoreSimulator wedged? killall -9 com.apple.CoreSimulator.CoreSimulatorService)"; exit 1; }
if [[ -z "$UDID" ]]; then
    echo "✗ No available iOS simulator named '$WANT'. This script never creates one."
    exit 1
fi
NAME="$(xcrun simctl list devices available | grep -F "$UDID" | sed -E 's/^ *(.*) \([0-9A-F-]{36}\).*/\1/' | head -1)"

# ---- build (outside the lock: it does not touch the simulator) ----------------------------
if [[ -z "$APP" ]]; then
    DERIVED="${STRIDE_A11Y_DERIVED_DATA:-$PROJECT_DIR/build/a11y/DerivedData}"
    LOG="$(mktemp "${TMPDIR:-/tmp}/stride-a11y-build.XXXXXX")"
    echo "==> Building Stride (Debug) into $DERIVED"
    # CODE_SIGNING_ALLOWED=NO: a simulator runs unsigned apps, and the sweep must not depend on
    # the login keychain being unlocked (see the global notes on codesign under a locked screen).
    if ! xcodebuild build \
        -project "$PROJECT_DIR/Stride.xcodeproj" \
        -scheme Stride \
        -configuration Debug \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DERIVED" \
        ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
        CODE_SIGNING_ALLOWED=NO \
        "${XCB_ARGS[@]+"${XCB_ARGS[@]}"}" > "$LOG" 2>&1; then
        grep -E "error:" "$LOG" | head -20 | sed 's/^/    /' || true
        echo "✗ Build failed. Full log: $LOG"
        exit 1
    fi
    rm -f "$LOG"
    APP="$DERIVED/Build/Products/Debug-iphonesimulator/Stride.app"
fi
[[ -d "$APP" ]] || { echo "✗ No app at $APP"; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

# ---- the simulator: lock, remember, change, and always put back ---------------------------
SLUG="$(tr '[:upper:] ' '[:lower:]-' <<<"$NAME")"
LOCK="${STRIDE_SIM_LOCK_ROOT:-${TMPDIR:-/tmp}}/lock-$SLUG"
echo "==> Waiting for $LOCK"
until mkdir "$LOCK" 2>/dev/null; do sleep 15; done

WAS_BOOTED=0
PREV_SIZE=""
PREV_LOOK=""
restore() {
    local status=$?
    if [[ -n "$PREV_SIZE" ]]; then
        xcrun simctl ui "$UDID" content_size "$PREV_SIZE" >/dev/null 2>&1 \
            || echo "⚠ Could not restore content size $PREV_SIZE on $NAME — set it by hand."
    fi
    [[ -n "$PREV_LOOK" ]] && xcrun simctl ui "$UDID" appearance "$PREV_LOOK" >/dev/null 2>&1 || true
    xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    # A sync run that died half-way still takes its seeded recovery log with it.
    if [[ "$SET" != core ]] && declare -f clear_recovery_log >/dev/null; then clear_recovery_log || true; fi
    [[ $WAS_BOOTED -eq 0 ]] && xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    rmdir "$LOCK" 2>/dev/null || true
    exit $status
}
trap restore EXIT
trap 'exit 130' INT TERM

if xcrun simctl list devices | grep -F "$UDID" | grep -q "(Booted)"; then
    WAS_BOOTED=1
else
    echo "==> Booting $NAME"
    xcrun simctl boot "$UDID"
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null

# Read before writing: the trap restores whatever these were, so a value we could not read
# (unknown/unsupported) is left alone rather than "restored" to something invented.
cur="$(xcrun simctl ui "$UDID" content_size 2>/dev/null || true)"
[[ "$cur" =~ ^(extra-|small|medium|large|accessibility-) ]] && PREV_SIZE="$cur"
cur="$(xcrun simctl ui "$UDID" appearance 2>/dev/null || true)"
[[ "$cur" == light || "$cur" == dark ]] && PREV_LOOK="$cur"

echo "==> $NAME ($UDID): content size $SIZE (was ${PREV_SIZE:-unknown}), light, 9:41"
xcrun simctl ui "$UDID" content_size "$SIZE"
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl install "$UDID" "$APP"

mkdir -p "$OUT"
# The recovery log a `recoveredEdits` scenario seeds (see the header): gone before the first
# capture, so 03_settings shows no Recovered Edits row, and again after the last.
clear_recovery_log() {
    local data
    data="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null)" || return 0
    rm -rf "$data/Library/Application Support/SyncRecoveryLog"
}
clear_recovery_log
# -stride_onboarding_completed YES lands in UserDefaults' argument domain for this launch only,
# so StrideApp skips the first-run onboarding cover without writing anything to the device.
capture() {
    local file="$1"; shift
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -demo -stride_onboarding_completed YES \
        "${LANG_ARGS[@]+"${LANG_ARGS[@]}"}" "$@" >/dev/null
    sleep "$SETTLE"
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/$file" >/dev/null 2>&1
    echo "    ✓ $file"
}
if [[ "$SET" != sync ]]; then
    capture 01_today.png    -tab 0
    capture 02_stats.png    -tab 1
    capture 02_stats_insights.png -tab 1 -statsScrollTo insights
    capture 02_stats_trend.png    -tab 1 -statsScrollTo trend
    capture 02_stats_weekday.png  -tab 1 -statsScrollTo weekday
    capture 02_stats_heatmap.png  -tab 1 -statsScrollTo heatmap
    capture 03_settings.png -tab 2
    capture 04_paywall.png  -tab 0 -paywall
fi
if [[ "$SET" != core ]]; then
    for state in signInAgain paused offline waiting held synced justSynced; do
        capture "10_today_sync_$state.png" -tab 0 -syncStatus "$state"
    done
    # Below the fold only where there is one: accessibility sizes.
    SCROLLED=0
    [[ "$SIZE" == accessibility-* ]] && SCROLLED=1
    for case in conflict unknownOwner; do
        scenario="account$(tr '[:lower:]' '[:upper:]' <<<"${case:0:1}")${case:1}"
        capture "11_account_$case.png" -tab 0 -demoScenario "$scenario"
        if [[ $SCROLLED -eq 1 ]]; then
            for anchor in accountHoldings accountExport accountChoices; do
                capture "11_account_${case}_at_$anchor.png" -tab 0 -demoScenario "$scenario" -scrollTo "$anchor"
            done
        fi
    done
    for scenario in heldRows recoveredEdits syncPaused syncAll; do
        # Each state on its own: `recoveredEdits` otherwise leaves its three lines for the
        # `syncPaused` capture after it (the first run drew "Recovered Edits (3)" there).
        xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        clear_recovery_log
        capture "12_settings_sync_$scenario.png" -tab 2 -demoScenario "$scenario"
    done
    if [[ $SCROLLED -eq 1 ]]; then
        # `syncAll` re-seeds the same three lines on every launch (it clears them first).
        for anchor in syncPaused syncHeld syncConvertible-not_owned syncConvertible-tombstoned \
                      syncRecovered syncFullResync; do
            capture "12_settings_sync_syncAll_at_$anchor.png" -tab 2 -demoScenario syncAll -scrollTo "$anchor"
        done
    fi
    # The two sheets, over a Settings with no seeded rows behind them.
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    clear_recovery_log
    capture 13_settings_deleteAccount.png -tab 2 -demoScenario deleteAccount
    capture 14_restore_handover.png       -tab 2 -demoScenario restoreHandover
    if [[ $SCROLLED -eq 1 ]]; then
        # deleteExport is taken bottom-aligned (`@bottom`): the message fills the first frame, and
        # what sits between it and the export rows is the "Signed in as" address line.
        capture 13_settings_deleteAccount_at_deleteExport.png -tab 2 -demoScenario deleteAccount -scrollTo deleteExport@bottom
        for anchor in deleteRecoveredEdits deleteConfirm; do
            capture "13_settings_deleteAccount_at_$anchor.png" -tab 2 -demoScenario deleteAccount -scrollTo "$anchor"
        done
        capture 14_restore_handover_at_handoverRestore.png -tab 2 -demoScenario restoreHandover -scrollTo handoverRestore
    fi
    # Put the store back to the plain demo set (the scenarios above seeded held rows into it),
    # then drop the seeded recovery log: the next screenshot run on this device starts clean.
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -demo -stride_onboarding_completed YES >/dev/null
    sleep "$SETTLE"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    clear_recovery_log
fi

echo "✓ $(ls "$OUT"/*.png | wc -l | tr -d ' ') PNGs at $SIZE in $OUT"
