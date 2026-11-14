#!/bin/bash
# The iOS App Store screenshot sets, captured from the app on the simulators, for every locale
# (RELEASE-1.4.2.md O9 and D19; W8).
#
#   scripts/screenshots.sh [--version <x.y.z>] [--lang <code>]... [--all-langs]
#                          [--device iphone|ipad|both] [--out <dir>] [--app <Stride.app>]
#                          [extra xcodebuild args...]
#
#   --version    the folder's version (default: MARKETING_VERSION in project.yml)
#   --lang       en, es, ja, ko, zh-Hans or zh-Hant; repeatable (default: en only)
#   --all-langs  all six, en first
#   --device     which simulators (default both): "iPhone 17 Pro Max" and "iPad Pro 13-inch (M5)",
#                the screenshot devices of the global notes
#   --out        the version folder (default build/store-screenshots/<version>, where
#                scripts/store_screenshots.py expects a fresh capture)
#   --app        a Debug Stride.app to install instead of building one
#
# The frames, in the store's order (O9: the free frames first, then the two Pro ones), come from
# `scripts/a11y_sweep.sh --set store --size default`, which also locks the simulator, fixes light
# appearance and a 9:41 status bar, and puts the device back afterwards:
#   01_today, 02_stats, 03_history, 04_settings   free, the standard demo set (1.4.1's four);
#   05_weekly_review                              last week's review, `-demoPro`;
#   06_advanced_analytics                         Insights with the PRO chip, `-demoPro`.
# Each locale's launch carries `-AppleLanguages` / `-AppleLocale` (a11y_sweep.sh --lang), so the
# app's text is that locale's; the demo habits keep their English names in every locale.
#
# Laid out for scripts/store_screenshots.py, one folder per App Store locale and display type:
#   <out>/<locale>/iphone69   APP_IPHONE_67          1320×2868, as captured (iPhone 17 Pro Max)
#   <out>/<locale>/iphone65   APP_IPHONE_65          1284×2778, resized
#   <out>/<locale>/ipad13     APP_IPAD_PRO_3GEN_129  2064×2752, as captured (iPad Pro 13-inch (M5))
#   <out>/<locale>/ipad129    APP_IPAD_PRO_129       2048×2732, resized
# with <locale> en-US, es-ES, ja, ko, zh-Hans or zh-Hant. The raw captures stay in <out>/raw/.
#
# Every PNG written (raw and resized) goes through scripts/frame_check.swift, the sweep's
# blank-frame check, and its pixel size is checked against the display type; any failure exits 1.
# Nothing is uploaded: the script ends by printing the dry-run upload commands. Each `--yes` is the
# owner's go (O9), after `release.py prepare`.
#
# Until 1.4.2 this script ran generate_screenshots.swift, which draws AppKit mock-ups into
# build/ios-screenshots; store_screenshots.py refuses that folder (the stale pre-1.4.0 captures),
# and no set has used them since 1.4.0. The generator is left as it was, unused.
#
# Environment: STRIDE_A11Y_SETTLE (seconds per launch; default 8 here, as 1.4.1's store run under
# load needed more than the sweep's 4), STRIDE_SIM_LOCK_LABEL, STRIDE_A11Y_DERIVED_DATA and
# STRIDE_SPM_DIR, all as in a11y_sweep.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=ci/build_cache.sh
source "$SCRIPT_DIR/ci/build_cache.sh"

VERSION=""
LANGS=()
DEVICES="both"
OUT=""
APP=""
XCB_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)   VERSION="${2:?--version needs a value}"; shift 2 ;;
        --lang)      LANGS+=("${2:?--lang needs a value}"); shift 2 ;;
        --all-langs) LANGS=(en es ja ko zh-Hans zh-Hant); shift ;;
        --device)    DEVICES="${2:?--device needs iphone, ipad or both}"; shift 2 ;;
        --out)       OUT="${2:?--out needs a value}"; shift 2 ;;
        --app)       APP="${2:?--app needs a value}"; shift 2 ;;
        -h|--help)   awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        *)           XCB_ARGS+=("$1"); shift ;;
    esac
done
[[ ${#LANGS[@]} -gt 0 ]] || LANGS=(en)
case "$DEVICES" in
    iphone) DEVICE_KEYS=(iphone) ;;
    ipad)   DEVICE_KEYS=(ipad) ;;
    both)   DEVICE_KEYS=(iphone ipad) ;;
    *) echo "✗ --device must be iphone, ipad or both (got '$DEVICES')"; exit 2 ;;
esac
asc_locale() {
    case "$1" in
        en) echo en-US ;; es) echo es-ES ;; ja|ko|zh-Hans|zh-Hant) echo "$1" ;;
        *) return 1 ;;
    esac
}
for lang in "${LANGS[@]}"; do
    asc_locale "$lang" >/dev/null || { echo "✗ Unknown --lang '$lang' (en, es, ja, ko, zh-Hans, zh-Hant)"; exit 2; }
done
if [[ -z "$VERSION" ]]; then
    VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\} *$/\1/p' "$PROJECT_DIR/project.yml" | head -1)"
    [[ -n "$VERSION" ]] || { echo "✗ No MARKETING_VERSION in project.yml; pass --version"; exit 2; }
fi
OUT="${OUT:-$PROJECT_DIR/build/store-screenshots/$VERSION}"
export STRIDE_A11Y_SETTLE="${STRIDE_A11Y_SETTLE:-8}"
FRAMES=(01_today 02_stats 03_history 04_settings 05_weekly_review 06_advanced_analytics)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stride-screenshots.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- one Debug build for every run (a11y_sweep.sh would build once per call) --------------
if [[ -z "$APP" ]]; then
    DERIVED="${STRIDE_A11Y_DERIVED_DATA:-$HOME/Library/Caches/Stride-build/a11y-dd}"
    spm_cache_args "$PROJECT_DIR" "${XCB_ARGS[@]+"${XCB_ARGS[@]}"}" || exit 1
    DD_LOCK="$(build_lock_path "$DERIVED")"
    build_lock_take "$DD_LOCK" "screenshots.sh build" || exit 1
    trap 'build_lock_release "$DD_LOCK"; rm -rf "$WORK"' EXIT
    echo "==> Building Stride (Debug) into $DERIVED"
    if ! xcodebuild build -project "$PROJECT_DIR/Stride.xcodeproj" -scheme Stride -configuration Debug \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
        ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
        "${SPM_ARGS[@]+"${SPM_ARGS[@]}"}" "${XCB_ARGS[@]+"${XCB_ARGS[@]}"}" > "$WORK/build.log" 2>&1; then
        grep -E "error:" "$WORK/build.log" | head -20 | sed 's/^/    /' || true
        echo "✗ Build failed"
        exit 1
    fi
    # A private copy while the lock is held (a11y_sweep.sh does the same, for the same reason).
    ditto "$DERIVED/Build/Products/Debug-iphonesimulator/Stride.app" "$WORK/Stride.app"
    build_lock_release "$DD_LOCK"
    trap 'rm -rf "$WORK"' EXIT
    APP="$WORK/Stride.app"
fi
[[ -d "$APP" ]] || { echo "✗ No app at $APP"; exit 1; }

FRAME_CHECK="$WORK/frame_check"
xcrun swiftc -O -o "$FRAME_CHECK" "$SCRIPT_DIR/frame_check.swift" >"$WORK/frame_check.log" 2>&1 \
    || { cat "$WORK/frame_check.log"; echo "✗ Could not compile scripts/frame_check.swift"; exit 1; }

device_name() { [[ "$1" == iphone ]] && echo "iPhone 17 Pro Max" || echo "iPad Pro 13-inch (M5)"; }

# ---- capture: one store-set sweep per locale and device ----------------------------------
FAILED=0
for lang in "${LANGS[@]}"; do
    for key in "${DEVICE_KEYS[@]}"; do
        raw="$OUT/raw/$lang/$key"
        echo "==> $lang, $(device_name "$key")"
        rm -rf "$raw"
        if ! "$SCRIPT_DIR/a11y_sweep.sh" --set store --size default --lang "$lang" \
                --device "$(device_name "$key")" --app "$APP" --out "$raw"; then
            echo "✗ The store sweep failed for $lang on $(device_name "$key") (above)"
            FAILED=1
        fi
    done
done

# ---- lay out, resize, check ----------------------------------------------------------------
# <display folder> <raw device> <pixel size, or "" to keep the capture's>
LAYOUT=("iphone69 iphone 1320x2868 keep" "iphone65 iphone 1284x2778 resize"
        "ipad13 ipad 2064x2752 keep" "ipad129 ipad 2048x2732 resize")
WRITTEN=()
for lang in "${LANGS[@]}"; do
    locale="$(asc_locale "$lang")"
    for entry in "${LAYOUT[@]}"; do
        read -r folder key size mode <<<"$entry"
        [[ " ${DEVICE_KEYS[*]} " == *" $key "* ]] || continue
        dest="$OUT/$locale/$folder"
        rm -rf "$dest"
        mkdir -p "$dest"
        for frame in "${FRAMES[@]}"; do
            src="$OUT/raw/$lang/$key/$frame.png"
            if [[ ! -f "$src" ]]; then
                echo "  ✗ $lang/$key/$frame.png was not captured"
                FAILED=1
                continue
            fi
            if [[ "$mode" == keep ]]; then
                cp "$src" "$dest/$frame.png"
            else
                sips -z "${size#*x}" "${size%x*}" "$src" --out "$dest/$frame.png" >/dev/null
            fi
            dims="$(sips -g pixelWidth -g pixelHeight "$dest/$frame.png" | awk '/pixelWidth:/ { w = $2 } /pixelHeight:/ { h = $2 } END { print w "x" h }')"
            if [[ "$dims" != "$size" ]]; then
                echo "  ✗ $locale/$folder/$frame.png is $dims, not $size"
                FAILED=1
            fi
            WRITTEN+=("$dest/$frame.png")
        done
    done
done

echo "==> Blank-frame check of all ${#WRITTEN[@]} PNGs"
if [[ ${#WRITTEN[@]} -gt 0 ]]; then
    if ! "$FRAME_CHECK" "${WRITTEN[@]}" > "$WORK/frames.txt"; then
        grep -v '^ok' "$WORK/frames.txt" | sed 's/^/  ✗ /'
        FAILED=1
    else
        echo "  ✓ none blank"
    fi
fi

if [[ $FAILED -ne 0 ]]; then
    echo "✗ Not a complete set: fix the above before any upload."
    exit 1
fi

echo ""
echo "✓ ${#WRITTEN[@]} PNGs in $OUT (${#LANGS[@]} locale(s): ${LANGS[*]})."
echo "  Dry runs (no --yes; the owner's go per --yes, after \`release.py prepare\`):"
for lang in "${LANGS[@]}"; do
    locale="$(asc_locale "$lang")"
    line="  scripts/store_screenshots.py upload --platform IOS --version $VERSION --locale $locale"
    for entry in "${LAYOUT[@]}"; do
        read -r folder key size mode <<<"$entry"
        [[ " ${DEVICE_KEYS[*]} " == *" $key "* ]] || continue
        case "$folder" in
            iphone69) type=APP_IPHONE_67 ;; iphone65) type=APP_IPHONE_65 ;;
            ipad13) type=APP_IPAD_PRO_3GEN_129 ;; ipad129) type=APP_IPAD_PRO_129 ;;
        esac
        line+=" --set $type"
        for frame in "${FRAMES[@]}"; do line+=" $OUT/$locale/$folder/$frame.png"; done
    done
    echo "$line"
done
