#!/bin/bash
# Dynamic Type sweep: capture every tab of Stride, plus the Pro paywall and a habit's History, at
# one text size on a simulator, as PNGs a person reviews before a release.
#
#   scripts/a11y_sweep.sh [--size <content size>|default] [--out <dir>] [--device <name|UDID>]
#                         [--app <path to Stride.app>] [--lang <code>]
#                         [--set core|history|sync|all] [extra xcodebuild args...]
#
#   --size    a `simctl ui content_size` value (default: accessibility-extra-extra-extra-large,
#             the largest one). `default` means `large`, the size a fresh device ships with; that
#             mode is the store-screenshot layout check (M1 acceptance 7): a set taken before a
#             Dynamic Type change and one after must match up to sub-pixel text rendering.
#   --out     where the PNGs go (default: build/a11y/<size>/, with `default` for `large`, plus
#             `-<lang>` when --lang is given).
#   --device  the simulator (default "iPhone 17 Pro Max", the screenshot device — see the
#             global notes; the E2E kit holds "iPhone 17 Pro", and from 1.4.0 the hosted tests
#             run on "iPhone 17" under /tmp/lock-iphone-17, scripts/ci/run_hosted_tests.sh). An
#             existing simulator is always reused: this never creates, erases or clones one.
#             The iPad captures (RELEASE-1.4.0.md D7) use "iPad Pro 13-inch (M5)". CLI Pulse's
#             capture script drives that iPad and takes no lock, so check it is not in use first.
#   --app     skip the build and install this .app instead — e.g. one built from another
#             checkout, to capture a before/after pair from the same script. It must be a
#             Debug build: `-demo`, `-paywall` and `-openHistory` are compiled out of Release.
#   --lang    run every launch in this system language: en, es, ja, ko, zh-Hans or zh-Hant
#             (`-AppleLanguages (<code>)` plus the matching `-AppleLocale`, e.g. ja_JP). The in-app
#             picker is pinned to "System Default" for the launch (`-stride_app_language ""`, the
#             argument domain again), so a language picked on the device earlier cannot win.
#             Without --lang the launches carry no language arguments at all, as before.
#   --set     which captures: `core` (the tabs, the paywall and History — the 1.3.0 set plus
#             1.4.1's), `history` (History alone, for RELEASE-1.4.1.md gate 8), `sync` (the M2 sync
#             UI, below) or `all` (default).
#   Anything else is passed to xcodebuild (the package-cache flags, typically).
#
# What it does: builds Stride (Debug, its own derived data) unless --app is given; boots the
# simulator if it is not booted; sets the content size, light appearance and a fixed 9:41
# status bar (so two runs diff cleanly); launches with `-demo -tab <n>` for Today, Stats and
# Settings, with `-demo -paywall` for the paywall and with `-demo -openHistory` for History;
# captures each with `simctl io screenshot`.
# Stats is captured seven times: the top, then scrolled to Insights, the 8-week trend, Strength,
# the top 5 streaks (1.4.1), By Weekday and the Activity heatmap with the DEBUG-only
# `-statsScrollTo <anchor>` (StatsView).
# The default-size run (`--size default`) also takes the habit's detail card at the two sizes
# between it and the accessibility ones, which no run of its own covers:
# 02_stats_detail_extra-large.png and 02_stats_detail_extra-extra-extra-large.png. The card's
# header keeps Edit history and Share beside the name only while the name's widest word fits
# there (DetailCardHeaderLayout), so these are the sizes where it changes. The habit shown is
# "Morning Run", the demo set's first. The header depends on the width too: for the narrow case
# add `--device "iPhone 17e"` (about 390 pt, the narrowest iPhone simulator on this Mac in
# 2026-10) and `--lang es`, whose "Editar historial" is the widest button. The hosted
# StatsRenderTests measure the header at 375 pt.
# History (RELEASE-1.4.1.md D6; gate 8 needs it at default and AX5 sizes) is a shell sheet that only
# a tap opens, so it comes from the DEBUG-only `-openHistory <habit name | index>
# [-historyDay <days from today>]` (StrideApp.launchHistoryRequest), over Stats (`-tab 1`, where
# "Edit history" is), for "Read 30 min", the demo set's second habit:
#   05_history             today, a checked day: the toggle on and the note field open;
#   05_history_past        twenty days back (`-historyDay -20`), older than the demo set's 15 days
#                          of check-ins: an unchecked day, whose note field says to check in first;
#   05_history*_at_historyEditor
#                          at accessibility sizes only: the same two scrolled to the day's editor
#                          (`-scrollTo historyEditor`, SweepScroll), which sits below the month
#                          grid there. The grid itself stops growing at accessibility2.
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
#     where the app scrolls itself on launch: Stats, via `-statsScrollTo`; History and the sync
#     screens, via `-scrollTo`. The first version of this script took the top of each screen
#     only, and at accessibility-XXXL that proved nothing about the charts 1.3.0 made scale —
#     they start two screens down (the 2026-09-27 baseline needed two to three screens of
#     scrolling). Still top-only: Today's lower rows,
#     the Settings habit rows and the paywall price cards; review those by scrolling the booted
#     simulator.
#   - Insights, the 8-week trend, Strength and the top 5 streaks are Pro-only. On a simulator
#     with no purchase (the normal case) 02_stats_insights, _trend, _strength and _beststreaks
#     all show the "Advanced Analytics" locked card.
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
#   STRIDE_A11Y_DERIVED_DATA  derived data for the build (default
#                             ~/Library/Caches/Stride-build/a11y-dd, persistent and shared by every
#                             checkout; until 1.4.1 it was build/a11y/DerivedData, inside iCloud).
#                             Builds into it take its lock (build_lock_path in
#                             scripts/ci/build_cache.sh), so an iPhone and an iPad sweep started
#                             together build one after the other; Swift packages come from the
#                             shared checkout (spm_cache_args, same file).
#   STRIDE_SPM_DIR            the shared Swift package checkout (scripts/ci/build_cache.sh)
#   STRIDE_A11Y_SETTLE        seconds to wait after each launch before capturing (default 4)
#   STRIDE_SIM_LOCK_ROOT      directory for the per-device mutex `lock-<device-slug>` (default
#                             /tmp, the root every project and scripts/sim_e2e/lock.sh use; it
#                             was $TMPDIR before 1.4.0, which excluded nobody). Several agents
#                             or scripts share these simulators; the lock is a directory because
#                             mkdir is atomic. The slug keeps a-z, 0-9 and '-' only:
#                             /tmp/lock-ipad-pro-13-inch-m5, /tmp/lock-iphone-17-pro-max.
#   STRIDE_SIM_LOCK_LABEL     your lock label. When the device's lock is already held under it
#                             (its holder file says label=<it>, e.g. `scripts/sim_e2e/lock.sh
#                             acquire promax <it>`), the sweep runs inside that hold and leaves it
#                             held. Otherwise the sweep takes the lock itself, with a holder file.
#   STRIDE_SIM_LOCK_WAIT      minutes to wait for someone else's lock (default 40); then the
#                             sweep prints BLOCKED and exits 2, touching nothing.
#   (scripts/ci/sim_lock.sh has the lock's details.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=ci/sim_lock.sh
source "$SCRIPT_DIR/ci/sim_lock.sh"
# shellcheck source=ci/build_cache.sh
source "$SCRIPT_DIR/ci/build_cache.sh"

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
case "$SET" in core|history|sync|all) ;; *) echo "✗ Unknown --set '$SET' (core, history, sync or all)"; exit 2 ;; esac
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
    DERIVED="${STRIDE_A11Y_DERIVED_DATA:-$HOME/Library/Caches/Stride-build/a11y-dd}"
    spm_cache_args "$PROJECT_DIR" "${XCB_ARGS[@]+"${XCB_ARGS[@]}"}" || exit 1
    DD_LOCK="$(build_lock_path "$DERIVED")"
    build_lock_take "$DD_LOCK" "a11y_sweep.sh build" || exit 1
    trap 'build_lock_release "$DD_LOCK"' EXIT
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
        "${SPM_ARGS[@]+"${SPM_ARGS[@]}"}" \
        "${XCB_ARGS[@]+"${XCB_ARGS[@]}"}" > "$LOG" 2>&1; then
        grep -E "error:" "$LOG" | head -20 | sed 's/^/    /' || true
        echo "✗ Build failed. Full log: $LOG"
        exit 1
    fi
    rm -f "$LOG"
    # A private copy, taken while the lock is held: the derived data is shared by every
    # checkout, and the install happens only after the simulator's lock and a boot, by which
    # time another checkout's sweep may have rebuilt the app there. The lock is released before
    # the simulator's lock is taken, so a sweep never holds one while waiting for the other.
    APP_COPY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/stride-a11y-app.XXXXXX")"
    ditto "$DERIVED/Build/Products/Debug-iphonesimulator/Stride.app" "$APP_COPY_DIR/Stride.app"
    build_lock_release "$DD_LOCK"
    trap 'rm -rf "$APP_COPY_DIR"' EXIT
    APP="$APP_COPY_DIR/Stride.app"
fi
[[ -d "$APP" ]] || { echo "✗ No app at $APP"; exit 1; }
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

# ---- the simulator: lock, remember, change, and always put back ---------------------------
LOCK="${STRIDE_SIM_LOCK_ROOT:-/tmp}/lock-$(sim_lock_slug "$NAME")"
LOCK_RC=0
sim_lock_take "$LOCK" a11y_sweep || LOCK_RC=$?
[[ $LOCK_RC -eq 0 ]] || exit "$LOCK_RC"
# Until restore() below takes over: a signal during the next lines must not strand the lock.
trap 'sim_lock_release; [[ -n "${APP_COPY_DIR:-}" ]] && rm -rf "$APP_COPY_DIR"' EXIT

APP_COPY_DIR="${APP_COPY_DIR:-}"
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
    if [[ "$SET" == sync || "$SET" == all ]] && declare -f clear_recovery_log >/dev/null; then clear_recovery_log || true; fi
    [[ $WAS_BOOTED -eq 0 ]] && xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    # Only a lock this run took (never the caller's STRIDE_SIM_LOCK_LABEL hold).
    sim_lock_release
    [[ -n "$APP_COPY_DIR" ]] && rm -rf "$APP_COPY_DIR"
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
if [[ "$SET" == core || "$SET" == all ]]; then
    capture 01_today.png    -tab 0
    capture 02_stats.png    -tab 1
    if [[ "$SIZE" == large ]]; then
        # The sizes between the default and the accessibility ones (header), then back.
        for between in extra-large extra-extra-extra-large; do
            xcrun simctl ui "$UDID" content_size "$between"
            capture "02_stats_detail_$between.png" -tab 1 -statsScrollTo detail
        done
        xcrun simctl ui "$UDID" content_size "$SIZE"
    fi
    capture 02_stats_insights.png -tab 1 -statsScrollTo insights
    capture 02_stats_trend.png    -tab 1 -statsScrollTo trend
    capture 02_stats_strength.png -tab 1 -statsScrollTo strength
    capture 02_stats_beststreaks.png -tab 1 -statsScrollTo beststreaks
    capture 02_stats_weekday.png  -tab 1 -statsScrollTo weekday
    capture 02_stats_heatmap.png  -tab 1 -statsScrollTo heatmap
    capture 03_settings.png -tab 2
    capture 04_paywall.png  -tab 0 -paywall
fi
if [[ "$SET" != sync ]]; then
    # History (header): over Stats, on today and twenty days back; at accessibility sizes each
    # again at its editor, which the month grid pushes below the fold there.
    HISTORY_HABIT="Read 30 min"
    capture 05_history.png      -tab 1 -openHistory "$HISTORY_HABIT"
    capture 05_history_past.png -tab 1 -openHistory "$HISTORY_HABIT" -historyDay -20
    if [[ "$SIZE" == accessibility-* ]]; then
        capture 05_history_at_historyEditor.png -tab 1 -openHistory "$HISTORY_HABIT" -scrollTo historyEditor
        capture 05_history_past_at_historyEditor.png -tab 1 -openHistory "$HISTORY_HABIT" -historyDay -20 \
            -scrollTo historyEditor
    fi
fi
if [[ "$SET" == sync || "$SET" == all ]]; then
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
