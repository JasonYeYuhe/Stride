#!/bin/bash
# Dynamic Type sweep: capture every tab of Stride, plus the Pro paywall, at one text size on a
# simulator, as PNGs a person reviews before a release.
#
#   scripts/a11y_sweep.sh [--size <content size>|default] [--out <dir>] [--device <name|UDID>]
#                         [--app <path to Stride.app>] [extra xcodebuild args...]
#
#   --size    a `simctl ui content_size` value (default: accessibility-extra-extra-extra-large,
#             the largest one). `default` means `large`, the size a fresh device ships with; that
#             mode is the store-screenshot layout check (M1 acceptance 7): a set taken before a
#             Dynamic Type change and one after must match up to sub-pixel text rendering.
#   --out     where the PNGs go (default: build/a11y/<size>/, with `default` for `large`).
#   --device  the simulator (default "iPhone 17 Pro Max", the screenshot device — see the
#             global notes; the hosted tests hold "iPhone 17 Pro"). An existing simulator is
#             always reused: this never creates, erases or clones one.
#   --app     skip the build and install this .app instead — e.g. one built from another
#             checkout, to capture a before/after pair from the same script.
#   Anything else is passed to xcodebuild (the package-cache flags, typically).
#
# What it does: builds Stride (Debug, its own derived data) unless --app is given; boots the
# simulator if it is not booted; sets the content size, light appearance and a fixed 9:41
# status bar (so two runs diff cleanly); launches with `-demo -tab <n>` for Today, Stats and
# Settings and with `-demo -paywall` for the paywall; captures each with `simctl io screenshot`.
# The simulator's previous content size, appearance, status bar and boot state are ALWAYS put
# back (trap), because the same device takes the App Store screenshots — a sweep that died
# half-way used to leave it at the largest text size, and the next screenshot run would have
# uploaded that.
#
# Known limits (read before trusting a "looks fine"):
#   - A screenshot is the first screen only, and `simctl` has no touch input to scroll with.
#     At accessibility-XXXL most of what the 1.3.0 Dynamic Type work changes is below the fold:
#     the Stats weekday chart and heatmap, the Settings habit rows, the paywall price cards
#     (the 2026-09-27 baseline needed two to three screens of scrolling for each). Review those
#     by scrolling the booted simulator; the PNGs here prove the top of each screen only.
#   - The paywall's prices come from whatever StoreKit answers `simctl launch` (not Xcode's
#     scheme configuration). On 2026-09-27 they loaded; if they do not, the PNG shows the
#     spinner where the price cards go — raise STRIDE_A11Y_SETTLE or review them in Xcode.
#   - `-demo` REPLACES the app's data on that simulator with the demo set (DemoData.populate).
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
XCB_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --size)   SIZE="${2:?--size needs a value}"; shift 2 ;;
        --out)    OUT="${2:?--out needs a value}"; shift 2 ;;
        --device) WANT="${2:?--device needs a value}"; shift 2 ;;
        --app)    APP="${2:?--app needs a value}"; shift 2 ;;
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
# -stride_onboarding_completed YES lands in UserDefaults' argument domain for this launch only,
# so StrideApp skips the first-run onboarding cover without writing anything to the device.
capture() {
    local file="$1"; shift
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" "$BUNDLE_ID" -demo -stride_onboarding_completed YES "$@" >/dev/null
    sleep "$SETTLE"
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/$file" >/dev/null 2>&1
    echo "    ✓ $file"
}
capture 01_today.png    -tab 0
capture 02_stats.png    -tab 1
capture 03_settings.png -tab 2
capture 04_paywall.png  -tab 0 -paywall

echo "✓ $(ls "$OUT"/*.png | wc -l | tr -d ' ') PNGs at $SIZE in $OUT"
