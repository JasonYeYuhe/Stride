#!/bin/bash
# Captures the RUNNING Mac test variant's main window to a PNG for the Mac App Store's
# APP_DESKTOP slot (RELEASE-1.4.1.md P3a/P3b, W0).
#
#   scripts/mac_variant/capture.sh <out.png>                    capture, assert 2880×1800
#   scripts/mac_variant/capture.sh --size 2560x1600 <out.png>   assert another exact pixel size
#   scripts/mac_variant/capture.sh --window-id <id> <out.png>   a window other than the largest
#   scripts/mac_variant/capture.sh --force <out.png>            replace an existing <out.png>
#   scripts/mac_variant/capture.sh --list                       show what it would capture, and stop
#
# It never launches, activates or quits anything, and never finds anything by the name "Stride":
# LaunchServices knows two Stride.app bundles on this Mac, and the owner's real store belongs to
# the other one (mac_variant/README.md). The target is found by bundle id,
# yyh.stride.habittracker.mactest, and its window by that process's PID.
#
# How (each step refuses rather than guesses):
#   1. A small Swift helper, compiled into a temp dir, looks the variant up with
#      NSRunningApplication: exactly one running instance, bundle id checked. It refuses while
#      anything runs as the real yyh.stride.habittracker (that app must never run here), and
#      unless the variant is the frontmost app — a store screenshot shows the active window's
#      chrome, and a window behind another app's is not what the owner is looking at.
#   2. CGWindowListCopyWindowInfo (on-screen windows only), filtered on kCGWindowOwnerPID ==
#      that PID and window layer 0. The largest is the main window; the others (Settings, an
#      attached sheet) are listed, and --window-id picks one of them instead. Window titles are
#      not read: without Screen Recording permission macOS redacts them anyway.
#   3. `screencapture -x -o -l <window id>` into the temp dir: -o drops the shadow, so the image
#      is exactly the window's frame, title bar included; -x keeps it silent.
#   4. scripts/frame_check.swift, the sweeps' blank check, reads the PNG: area-averaged, the band
#      16–88 % from the top, the detail column of a window (the whole width for a sheet alone).
#      Nearly all transparent, one or two colours, or under 0.3 % ink there is a blank capture,
#      most often because the app running this script has no Screen Recording permission. It
#      prints how to grant it. (Until 1.4.2 a nearest-neighbour 160×100 sample of the whole image.)
#   5. `sips -g pixelWidth -g pixelHeight`: exactly 2880×1800 (or --size), else it stops and
#      says what size the window is. 2880×1800 is a 1440×900 pt window on a 2x display (the
#      owner's 4K display at 2x): launch the DEBUG variant with `-windowSize 1440x900`
#      (StrideApp.swift, LaunchWindowSize), which sets that frame.
#   Only a capture that passes 4 and 5 is moved to <out.png>; a rejected one stays in the temp
#   dir, whose path is printed.
#   Before any of that, after 1, the running instance must be a DEBUG build: its executable (or
#   its Stride.debug.dylib) holds LaunchWindowSize's text, the probe mac_variant/build.sh's
#   preflight uses. The Release variant (build.sh --release) has the same bundle id, so
#   `open -b` can start it; it is a production client with no -windowSize and no demo data,
#   and capturing it is refused.
#
# The Debug variant, sized for capture, launched BY PATH (quit any running instance first:
# `--args` reach only a new process; and not `open -b`, which may start the Release variant):
#     open "$HOME/Library/Caches/Stride-build/mac-variant/DerivedData/Build/Products/Debug/Stride.app" --args -windowSize 1440x900
# (that is build.sh's default root; with STRIDE_MAC_VARIANT_ROOT, the app under that root).
# The Mac App Store takes 1280×800, 1440×900, 2560×1600 or 2880×1800 (README "Store screenshots").
#
# Exit status: 0 captured; 1 capture failed or blank; 2 usage; 3 the variant is not running or has
# no on-screen window; 4 refused (not a Debug build, not frontmost, the real app is running, more
# than one instance, an unknown --window-id); 5 wrong pixel size; 6 (--sweep) the screen is locked.
#
# THE SWEEP (RELEASE-1.4.2.md W8 and gate 10), the one mode that launches and stops the variant:
#
#   scripts/mac_variant/capture.sh --sweep <out dir> [--set paywall|review|pro|all]
#                                  [--lang <code>]... [--width full|min|both] [--activate] [--force]
#
# For each capture it launches the DEBUG variant BY PATH ($DEBUG_APP, after `build.sh --preflight`
# passes on it) with `open <path> --args -demo -stride_onboarding_completed YES -inlineCard none
# -windowSize <W>x<H> <the capture's switches>`, finds the one new instance by bundle id, waits
# STRIDE_MAC_SETTLE seconds (default 5), captures, and stops it with `kill <its pid>` — never by
# name. `-inlineCard none` comes first on every launch (the app reads only the first): no capture
# here wants Today's card, and none writes its free-cap state.
#   --set paywall  every PaywallFixture (`-paywall -paywallFixture <name>`; the variant has no
#                  products, so the fixtures are the paywall's evidence), in every --lang;
#   --set review   the Weekly Review on last week and this week (`-demoPro -openReview last|this`,
#                  DemoData.Scenario.pro), in every --lang;
#   --set pro      Statistics' Insights and Strength under `-demoPro` (English): the readable change
#                  colours on the window background (gate 8);
#   --set all      (default) all three.
#   --lang         en, es, ja, ko, zh-Hans, zh-Hant; repeatable (default all six for paywall and
#                  review); the same arguments as a11y_sweep.sh --lang.
#   --width        `full`, the 1440×900 pt store frame (2880×1800 px); `min`, the window asked for
#                  at STRIDE_MAC_MIN_WINDOW (default 600x700) — AppKit holds it at the shell's own
#                  minimum width, and 700 pt is gate 10's height (the review and paywall sheets must
#                  end inside it); or `both` (default).
# Two PNGs a sheet: <name>.png, the main window's area with the sheet over it (`screencapture -R`,
# so the sheet's fit in the window shows), and <name>_sheet.png, the sheet window alone (`-l`). A
# screen without a sheet gives the first only. Each goes through the blank check below; a blank or
# missing capture is retried once, then counted, and the sweep exits 1 if any remain.
#
# The guards, each a refusal rather than a guess:
#   - a stored session: the variant shares its container, defaults and Keychain service with the
#     Release variant (a production client), and every launch here passes `-demo`, which ERASES the
#     store without tombstones. Before launching anything the sweep looks for the variant's Keychain
#     item (`security find-generic-password -s <variant id>`, attributes only, never the secret) and
#     its `stride_session_account` default; either one refuses the run (exit 4) unless `--force` is
#     given. Sign the variant out first (Settings → Sign Out in the Debug variant).
#   - one instance at a time: before each `open` no instance may run, and the instance found after
#     it must have a pid no earlier launch had, so an old instance brought forward again can never
#     be saved under a new capture's name. If it cannot be stopped (SIGTERM, 10 s), the sweep ends.
#   - an interrupt (INT/TERM) stops the instance it launched, by that pid, never by name.
#
# It needs the variant's window ON THE CURRENT SPACE and frontmost. macOS does not let a process
# started from a background shell take the screen from the app in front (2026-11-14: launched while
# Chrome was frontmost in its own Space, the variant's windows were on another Space and could not
# be captured, `screencapture -l` says "could not create image from window"). Without --activate
# the sweep stops there (exit 3) and says so; with --activate it brings the variant forward by
# bundle id (only after checking the one instance is this Debug launch), which switches the
# owner's screen to it for every capture — about 200 launches and 20 minutes or more for `--set all`
# — after a printed warning and a 10-second countdown: run it only when nobody is using the Mac.
# Even without --activate, each `open` asks macOS to bring the variant forward; on a Mac in use it
# may take the screen for a moment on every launch.
#
# StoreKit: the StrideMac scheme's `storeKitConfiguration` (project.yml) is applied only by Xcode's
# Run action, which starts the app under its debugger with a StoreKit testing session attached.
# `open <path>`, the only launch these rules allow, gets no such session, and `xcodebuild` has no
# Run action for a Mac app; so the variant has no products, and the paywall's evidence on the Mac is
# its fixtures (`-paywallFixture`, RELEASE-1.4.2.md W8). Gate 3's purchase runs under SKTestSession
# on iOS.
#
# Environment:
#   TMPDIR                    where the helper is compiled and the capture first lands (mktemp -d)
#   STRIDE_MAC_VARIANT_ROOT   the launch command it prints, and the app --sweep launches (build.sh's root)
#   STRIDE_MAC_SETTLE         --sweep: seconds from launch to capture (default 5)
#   STRIDE_MAC_MIN_WINDOW     --sweep: the `min` width's window request, <W>x<H> pt (default 600x700)
set -euo pipefail

VARIANT_ID="yyh.stride.habittracker.mactest"
REAL_ID="yyh.stride.habittracker"
# The Debug variant build.sh builds, and the text only DEBUG code holds (build.sh DEBUG_ONLY_PROBE).
DEBUG_APP="${STRIDE_MAC_VARIANT_ROOT:-$HOME/Library/Caches/Stride-build/mac-variant}/DerivedData/Build/Products/Debug/Stride.app"
DEBUG_ONLY_PROBE="[LaunchWindowSize]"

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; }

EXPECT_SIZE="2880x1800"
WINDOW_ID=""
FORCE=0
LIST=0
OUT=""
SWEEP_DIR=""
SWEEP_SET="all"
SWEEP_LANGS=()
SWEEP_WIDTH="both"
ACTIVATE=0
SIZE_RE='^[1-9][0-9]*x[1-9][0-9]*$'
NUM_RE='^[0-9]+$'
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sweep)
            [[ $# -ge 2 ]] || { echo "✗ --sweep needs an output directory"; exit 2; }
            SWEEP_DIR="$2"; shift 2 ;;
        --set)
            case "${2:-}" in paywall|review|pro|all) SWEEP_SET="$2" ;; *) echo "✗ --set paywall, review, pro or all"; exit 2 ;; esac
            shift 2 ;;
        --lang)
            case "${2:-}" in en|es|ja|ko|zh-Hans|zh-Hant) SWEEP_LANGS+=("$2") ;; *) echo "✗ --lang en, es, ja, ko, zh-Hans or zh-Hant"; exit 2 ;; esac
            shift 2 ;;
        --width)
            case "${2:-}" in full|min|both) SWEEP_WIDTH="$2" ;; *) echo "✗ --width full, min or both"; exit 2 ;; esac
            shift 2 ;;
        --activate) ACTIVATE=1; shift ;;
        --size)
            [[ $# -ge 2 ]] || { echo "✗ --size needs <W>x<H> in pixels, e.g. 2560x1600"; exit 2; }
            [[ "$2" =~ $SIZE_RE ]] || { echo "✗ --size '$2' is not <W>x<H> in pixels"; exit 2; }
            EXPECT_SIZE="$2"; shift 2 ;;
        --window-id)
            [[ $# -ge 2 ]] || { echo "✗ --window-id needs a number (see --list)"; exit 2; }
            [[ "$2" =~ $NUM_RE ]] || { echo "✗ --window-id '$2' is not a number"; exit 2; }
            WINDOW_ID="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        --list) LIST=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "✗ unknown option $1 (--help)"; exit 2 ;;
        *)
            [[ -z "$OUT" ]] || { echo "✗ one output file only (got '$OUT' and '$1')"; exit 2; }
            OUT="$1"; shift ;;
    esac
done
if [[ -n "$SWEEP_DIR" ]]; then
    [[ -z "$OUT" && $LIST -eq 0 && -z "$WINDOW_ID" ]] || { echo "✗ --sweep takes no output file, --list or --window-id"; exit 2; }
elif [[ $LIST -eq 1 ]]; then
    [[ -z "$OUT" ]] || { echo "✗ --list captures nothing; drop '$OUT'"; exit 2; }
else
    [[ -n "$OUT" ]] || { echo "✗ no output file (usage: capture.sh [--size WxH] [--window-id N] [--force] <out.png>)"; exit 2; }
    case "$OUT" in
        *.png|*.PNG) ;;
        *) echo "✗ $OUT: the output must be a .png"; exit 2 ;;
    esac
    if [[ -e "$OUT" && $FORCE -eq 0 ]]; then
        echo "✗ $OUT exists; pass --force to replace it"; exit 2
    fi
    [[ ! -d "$OUT" ]] || { echo "✗ $OUT is a directory"; exit 2; }
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stride-capture.XXXXXX")"
KEEP_WORK=0
# --sweep: the pid of the variant instance it launched and has not stopped yet.
LAUNCHED_PID=""
cleanup() {
    local status=$?
    # An interrupted sweep stops what it launched: that pid only, never anything by name.
    if [[ -n "$LAUNCHED_PID" ]] && kill -0 "$LAUNCHED_PID" 2>/dev/null; then
        echo "  stopping the variant this sweep launched (pid $LAUNCHED_PID)"
        kill "$LAUNCHED_PID" 2>/dev/null || true
    fi
    if [[ $KEEP_WORK -eq 1 ]]; then echo "  (kept: $WORK)"; else rm -rf "$WORK"; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

screen_recording_help() {
    cat <<EOF
  A blank or failed window capture almost always means the app running this script (Terminal,
  iTerm, or the Claude app) has no Screen Recording permission. The owner grants it:
    System Settings → Privacy & Security → Screen & System Audio Recording → turn on that app,
    then quit and reopen it (the grant applies to new processes only), and run this again.
  Revoke it again when the captures are done (RELEASE-1.4.1.md P3b).
EOF
}

# ---- the helper: lookup by bundle id + PID ---------------------------------------------------
cat >"$WORK/main.swift" <<'SWIFT'
import AppKit
import CoreGraphics
import ImageIO

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "find":
    // find <variant bundle id> <real bundle id>: key=value lines, windows largest first.
    guard args.count == 4 else { fail(2, "usage: find <variant id> <real id>") }
    let variantID = args[2], realID = args[3]
    print("real_running=\(NSRunningApplication.runningApplications(withBundleIdentifier: realID).count)")
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: variantID)
    print("instances=\(apps.count)")
    guard let app = apps.first else { exit(3) }
    guard apps.count == 1, app.bundleIdentifier == variantID, variantID != realID else { exit(4) }
    let pid = app.processIdentifier
    print("pid=\(pid)")
    print("path=\(app.bundleURL?.path ?? "?")")
    let front = NSWorkspace.shared.frontmostApplication
    print("frontmost=\(front?.bundleIdentifier ?? "none")")
    print("frontmost_pid=\(front?.processIdentifier ?? -1)")
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                          kCGNullWindowID) as? [[String: Any]] ?? []
    var windows: [(id: Int, width: Int, height: Int, x: Int, y: Int)] = []
    for window in info {
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let id = (window[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
        windows.append((id, Int(rect.width), Int(rect.height), Int(rect.minX), Int(rect.minY)))
    }
    windows.sort { $0.width * $0.height > $1.width * $1.height }
    for w in windows { print("window=\(w.id) \(w.width)x\(w.height) at \(w.x),\(w.y)") }
    exit(windows.isEmpty ? 3 : 0)

default:
    fail(2, "usage: find <variant id> <real id>")
}
SWIFT

HELPER="$WORK/capture-helper"
if ! xcrun swiftc -swift-version 5 -o "$HELPER" "$WORK/main.swift" >"$WORK/helper-build.log" 2>&1; then
    echo "✗ could not compile the window-lookup helper:"; sed 's/^/    /' "$WORK/helper-build.log" | head -20
    exit 1
fi
# The blank check (header, step 4): the sweeps' own, scripts/frame_check.swift.
FRAME_CHECK="$WORK/frame_check"
if ! xcrun swiftc -O -o "$FRAME_CHECK" "$(cd "$(dirname "$0")/.." && pwd)/frame_check.swift" >"$WORK/frame-build.log" 2>&1; then
    echo "✗ could not compile scripts/frame_check.swift:"; sed 's/^/    /' "$WORK/frame-build.log" | head -20
    exit 1
fi

# ---- --sweep (header): launch by path, capture, stop by pid ----------------------------------
if [[ -n "$SWEEP_DIR" ]]; then
    if ioreg -n Root -d1 -a | grep -A1 IOConsoleLocked | grep -q '<true/>'; then
        echo "✗ the screen is locked, so no window can be captured: pending the owner's unlocked screen."
        exit 6
    fi
    [[ -d "$DEBUG_APP" ]] || { echo "✗ no Debug variant at $DEBUG_APP: run scripts/mac_variant/build.sh"; exit 3; }
    if ! "$(cd "$(dirname "$0")" && pwd)/build.sh" --preflight "$DEBUG_APP" >"$WORK/preflight.log" 2>&1; then
        tail -15 "$WORK/preflight.log" | sed 's/^/    /'
        echo "✗ the variant's preflight failed: not launching it"
        exit 4
    fi
    sweep_found() { "$HELPER" find "$VARIANT_ID" "$REAL_ID" 2>&1 || true; }
    sweep_value() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }
    found="$(sweep_found)"
    if [[ "$(sweep_value "$found" real_running)" != "0" ]]; then
        echo "✗ refusing: the REAL $REAL_ID is running; it must never run here (mac_variant/README.md)."
        exit 4
    fi
    if [[ "$(sweep_value "$found" instances)" != "0" ]]; then
        echo "✗ a $VARIANT_ID instance is already running: quit it first (--args reach only a new process)."
        exit 4
    fi
    # A stored session (header): `-demo` erases the store this container shares with the Release
    # variant, a production client. The Keychain is asked for the item's attributes only.
    session=()
    if security find-generic-password -s "$VARIANT_ID" >/dev/null 2>&1; then
        session+=("a Keychain item for service $VARIANT_ID")
    fi
    prefs="$HOME/Library/Containers/$VARIANT_ID/Data/Library/Preferences/$VARIANT_ID.plist"
    if [[ -f "$prefs" ]] && /usr/libexec/PlistBuddy -c 'Print :stride_session_account' "$prefs" >/dev/null 2>&1; then
        session+=("stride_session_account in its defaults")
    fi
    if [[ ${#session[@]} -gt 0 ]]; then
        if [[ $FORCE -eq 0 ]]; then
            echo "✗ refusing: the variant holds a stored session ($(IFS=";"; echo "${session[*]}")). Every launch here passes"
            echo "  -demo, which erases the store it shares with the Release variant (a production client),"
            echo "  without tombstones. Sign the variant out first, or pass --force to run anyway."
            exit 4
        fi
        echo "⚠ --force: running over a stored session ($(IFS=";"; echo "${session[*]}"))."
    fi
    if [[ $ACTIVATE -eq 1 ]]; then
        echo "⚠ --activate brings the variant to the front for EVERY capture: about 200 launches and 20+"
        echo "  minutes of this Mac's screen for --set all. Do not use the Mac meanwhile. Ctrl-C to stop."
        for left in 10 9 8 7 6 5 4 3 2 1; do printf '\r  starting in %2d s ' "$left"; sleep 1; done
        echo
    else
        echo "  (each launch still asks macOS to bring the variant forward; on a Mac in use it may take"
        echo "   the screen for a moment every time)"
    fi
    SETTLE="${STRIDE_MAC_SETTLE:-5}"
    MIN_WINDOW="${STRIDE_MAC_MIN_WINDOW:-600x700}"
    [[ "$MIN_WINDOW" =~ $SIZE_RE ]] || { echo "✗ STRIDE_MAC_MIN_WINDOW '$MIN_WINDOW' is not <W>x<H>"; exit 2; }
    case "$SWEEP_WIDTH" in full) WIDTHS=(full) ;; min) WIDTHS=(min) ;; *) WIDTHS=(full min) ;; esac
    [[ ${#SWEEP_LANGS[@]} -gt 0 ]] || SWEEP_LANGS=(en es ja ko zh-Hans zh-Hant)
    real_app="$(cd "$DEBUG_APP" && pwd -P)"
    mkdir -p "$SWEEP_DIR"
    GEOMETRY="$SWEEP_DIR/geometry.txt"
    FAILED=()
    TAKEN=0
    SEEN_PIDS=" "

    # stop_variant <pid>: SIGTERM to that pid only, then wait for it to go. One that will not stop
    # ends the sweep: the next launch would find two instances, or bring this one forward again.
    stop_variant() {
        kill "$1" 2>/dev/null || true
        local i
        for i in $(seq 1 40); do
            if ! kill -0 "$1" 2>/dev/null; then
                [[ "$LAUNCHED_PID" == "$1" ]] && LAUNCHED_PID=""
                return 0
            fi
            sleep 0.25
        done
        echo "✗ pid $1 still runs 10 s after SIGTERM: stopping the sweep (stop it yourself, by that pid)"
        LAUNCHED_PID=""
        exit 1
    }

    # launch_variant <args...>: `open` the Debug variant by path; sets `pid` to the NEW instance's.
    # Refuses when an instance already runs, or when the one found has a pid an earlier launch had.
    launch_variant() {
        found="$(sweep_found)"
        if [[ "$(sweep_value "$found" instances)" != "0" ]]; then
            echo "✗ an instance (pid $(sweep_value "$found" pid)) runs before this launch: stopping the sweep"
            exit 4
        fi
        open "$DEBUG_APP" --args "$@"
        pid=""
        for _ in $(seq 1 40); do
            found="$(sweep_found)"
            pid="$(sweep_value "$found" pid)"
            [[ -n "$pid" ]] && break
            sleep 0.25
        done
        [[ -n "$pid" ]] || return 1
        LAUNCHED_PID="$pid"
        if [[ "$SEEN_PIDS" == *" $pid "* ]]; then
            echo "✗ the instance found (pid $pid) is one an earlier launch made: stopping the sweep"
            stop_variant "$pid"
            exit 4
        fi
        SEEN_PIDS+="$pid "
        local path
        path="$(sweep_value "$found" path)"
        if [[ "$(cd "$path" 2>/dev/null && pwd -P)" != "$real_app" ]]; then
            echo "✗ refusing: the running $VARIANT_ID (pid $pid) is $path, not the Debug variant launched"
            stop_variant "$pid"
            exit 4
        fi
    }

    # sweep_one <name> <width> <lang> <switches...>
    sweep_one() {
        local name="$1" width="$2" lang="$3"; shift 3
        local frame=1440x900 locale_id dir attempt main sheet line id dims x y rest ok
        [[ "$width" == min ]] && frame="$MIN_WINDOW"
        case "$lang" in
            en) locale_id=en_US ;; es) locale_id=es_ES ;; ja) locale_id=ja_JP ;; ko) locale_id=ko_KR ;;
            zh-Hans) locale_id=zh_CN ;; zh-Hant) locale_id=zh_TW ;;
        esac
        # The same language arguments as a11y_sweep.sh --lang.
        local lang_args=(-AppleLanguages "($lang)" -AppleLocale "$locale_id" -stride_app_language "")
        dir="$SWEEP_DIR/$width-$lang"
        mkdir -p "$dir"
        for attempt in 1 2; do
            if ! launch_variant -demo -stride_onboarding_completed YES -inlineCard none \
                    -windowSize "$frame" "${lang_args[@]}" "$@"; then
                echo "    ⚠ $name: the variant did not start"
                continue
            fi
            sleep "$SETTLE"
            if [[ $ACTIVATE -eq 1 ]]; then
                osascript -e "tell application id \"$VARIANT_ID\" to activate" >/dev/null 2>&1 || true
                sleep 1
            fi
            found="$(sweep_found)"
            if [[ "$(sweep_value "$found" pid)" != "$pid" ]]; then
                echo "✗ the instance changed under the capture (pid $(sweep_value "$found" pid), launched $pid): stopping"
                stop_variant "$pid"
                exit 4
            fi
            if [[ "$(sweep_value "$found" frontmost_pid)" != "$pid" ]] || ! grep -q '^window=' <<<"$found"; then
                stop_variant "$pid"
                echo "✗ the variant's window is not on screen and in front (frontmost: $(sweep_value "$found" frontmost))."
                echo "  macOS keeps a background launch off the owner's current Space. Pending: run this again"
                echo "  with --activate while nobody uses the Mac, or with the variant's Space in front."
                exit 3
            fi
            # Largest first: the main window, then the sheet when one is up.
            main="$(sed -n 's/^window=//p' <<<"$found" | sed -n 1p)"
            sheet="$(sed -n 's/^window=//p' <<<"$found" | sed -n 2p)"
            read -r id dims _ rest <<<"$main"
            x="${rest%,*}"; y="${rest#*,}"
            ok=1
            screencapture -x -R "$x,$y,${dims%x*},${dims#*x}" "$dir/$name.png" 2>/dev/null || ok=0
            [[ $ok -eq 1 ]] && "$FRAME_CHECK" "$dir/$name.png" >/dev/null 2>&1 || ok=0
            line="$width-$lang/$name window=$dims at $x,$y"
            if [[ -n "$sheet" && $ok -eq 1 ]]; then
                local sid sdims srest sx sy
                read -r sid sdims _ srest <<<"$sheet"
                sx="${srest%,*}"; sy="${srest#*,}"
                screencapture -x -o -l "$sid" "$dir/${name}_sheet.png" 2>/dev/null || ok=0
                [[ $ok -eq 1 ]] && "$FRAME_CHECK" --full-width "$dir/${name}_sheet.png" >/dev/null 2>&1 || ok=0
                # Does the sheet end inside the window (gate 10's 700-pt check)?
                local bottom=$(( y + ${dims#*x} )) sbottom=$(( sy + ${sdims#*x} ))
                line+=" sheet=$sdims at $sx,$sy $( (( sbottom <= bottom )) && echo "inside ($(( bottom - sbottom )) pt to spare)" || echo "OVERFLOWS by $(( sbottom - bottom )) pt")"
            fi
            stop_variant "$pid"
            if [[ $ok -eq 1 ]]; then
                echo "$line" >>"$GEOMETRY"
                TAKEN=$((TAKEN + 1))
                echo "    ✓ $width-$lang/$name ($line)"
                return 0
            fi
            echo "    ⚠ $name: blank or failed capture; retrying"
        done
        FAILED+=("$width-$lang/$name")
        echo "    ✗ $width-$lang/$name"
    }

    : >"$GEOMETRY"
    echo "==> Sweep of $DEBUG_APP (set $SWEEP_SET; ${SWEEP_LANGS[*]}; ${WIDTHS[*]}) into $SWEEP_DIR"
    for width in "${WIDTHS[@]}"; do
        if [[ "$SWEEP_SET" == paywall || "$SWEEP_SET" == all ]]; then
            for lang in "${SWEEP_LANGS[@]}"; do
                for fixture in loading loadFailed trial ineligible unknownEligibility noOffer pro yen \
                               purchasing pending restored nothingFound restoreFailed purchaseFailed unlocked; do
                    sweep_one "30_paywall_$fixture" "$width" "$lang" -paywall -paywallFixture "$fixture"
                done
            done
        fi
        if [[ "$SWEEP_SET" == review || "$SWEEP_SET" == all ]]; then
            for lang in "${SWEEP_LANGS[@]}"; do
                sweep_one 25_review_last "$width" "$lang" -demoPro -openReview last
                sweep_one 25_review_this "$width" "$lang" -demoPro -openReview this
            done
        fi
        if [[ "$SWEEP_SET" == pro || "$SWEEP_SET" == all ]]; then
            for anchor in insights strength; do
                sweep_one "22_stats_pro_$anchor" "$width" en -demoPro -tab 1 -statsScrollTo "$anchor"
            done
        fi
    done
    # Back to the plain demo set in the variant's own container, then stopped.
    if launch_variant -demo -stride_onboarding_completed YES -inlineCard none; then
        sleep "$SETTLE"
        stop_variant "$pid"
    fi
    echo "✓ $TAKEN capture(s) in $SWEEP_DIR; geometry in $GEOMETRY"
    if [[ ${#FAILED[@]} -gt 0 ]]; then
        echo "✗ ${#FAILED[@]} failed or blank:"; printf '    %s\n' "${FAILED[@]}"
        exit 1
    fi
    exit 0
fi

# ---- 1–2. the variant, by bundle id; its windows, by PID -------------------------------------
status=0
found="$("$HELPER" find "$VARIANT_ID" "$REAL_ID" 2>&1)" || status=$?
value() { printf '%s\n' "$found" | sed -n "s/^$1=//p" | head -1; }
real_running="$(value real_running)"
instances="$(value instances)"
pid="$(value pid)"
windows="$(printf '%s\n' "$found" | sed -n 's/^window=//p')"

if [[ "${real_running:-0}" != "0" ]]; then
    echo "✗ refusing: $real_running process(es) run as the REAL $REAL_ID on this Mac."
    echo "  That app opens the owner's real store and must never run here (mac_variant/README.md)."
    echo "  Quit it (the owner decides how), then capture the variant."
    exit 4
fi
case "$status" in
    0) ;;
    3)
        if [[ "${instances:-0}" == "0" ]]; then
            echo "✗ $VARIANT_ID is not running. This script launches nothing; start the Debug variant"
            echo "  yourself, by its path (\`open -b\` may start the Release variant, a production client):"
            echo "    open \"$DEBUG_APP\" --args -windowSize 1440x900"
        else
            echo "✗ $VARIANT_ID (pid $pid) has no on-screen window: minimized, closed, or on another Space."
        fi
        exit 3 ;;
    4) echo "✗ refusing: ${instances:-?} running instances of $VARIANT_ID (want exactly one)."; exit 4 ;;
    *) echo "✗ the window lookup failed (status $status):"; printf '%s\n' "$found" | sed 's/^/    /'; exit 1 ;;
esac

app_path="$(value path)"
echo "==> $VARIANT_ID: pid $pid, $app_path"

# The Debug variant only. The Release variant shares the bundle id and the container, talks to
# production, and has no -windowSize: the screenshot pass must never attach to it.
exe_name=""
# PlistBuddy prints "File Doesn't Exist, Will Create" on stdout for a missing file, so look first.
if [[ -f "$app_path/Contents/Info.plist" ]]; then
    exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
fi
exe="$app_path/Contents/MacOS/${exe_name:-Stride}"
debug_build=0
for bin in "$exe" "$exe.debug.dylib"; do
    if [[ -f "$bin" ]] && grep -a -q -F -- "$DEBUG_ONLY_PROBE" "$bin"; then debug_build=1; break; fi
done
if [[ $debug_build -ne 1 ]]; then
    echo "✗ refusing: the running variant has no DEBUG-only code (no \"$DEBUG_ONLY_PROBE\" in $exe"
    echo "  or its debug dylib). It is the Release variant, a production client without -windowSize"
    echo "  or demo data, or a Debug build older than -windowSize. Quit it (⌘Q), then launch the"
    echo "  Debug variant by its path, rebuilt with build.sh if it is old:"
    echo "    open \"$DEBUG_APP\" --args -windowSize 1440x900"
    exit 4
fi
echo "    build: Debug (\"$DEBUG_ONLY_PROBE\" compiled in, so -windowSize works)"
echo "    frontmost: $(value frontmost) (pid $(value frontmost_pid))"
echo "    on-screen windows (largest first; points):"
printf '%s\n' "$windows" | sed 's/^/      /'

if [[ -n "$WINDOW_ID" ]]; then
    line="$(printf '%s\n' "$windows" | awk -v id="$WINDOW_ID" '$1 == id { print; exit }')"
    [[ -n "$line" ]] || { echo "✗ --window-id $WINDOW_ID is not one of the variant's on-screen windows above"; exit 4; }
else
    line="$(printf '%s\n' "$windows" | head -1)"
fi
wid="${line%% *}"
points="$(printf '%s\n' "$line" | awk '{ print $2 }')"
echo "    target: window $wid, $points pt"

if [[ $LIST -eq 1 ]]; then exit 0; fi

if [[ "$(value frontmost_pid)" != "$pid" ]]; then
    echo "✗ refusing: the frontmost app is $(value frontmost), not $VARIANT_ID (pid $pid)."
    echo "  Bring the variant forward (click its window), then run this again. It is already"
    echo "  running, so this only activates it: osascript -e 'tell application id \"$VARIANT_ID\" to activate'"
    exit 4
fi

# ---- 3. the capture ------------------------------------------------------------------------
SHOT="$WORK/capture.png"
if ! screencapture -x -o -l "$wid" "$SHOT" 2>"$WORK/screencapture.err" || [[ ! -s "$SHOT" ]]; then
    echo "✗ screencapture -l $wid failed: $(tr '\n' ' ' <"$WORK/screencapture.err")"
    screen_recording_help
    exit 1
fi

# ---- 4. blank? -----------------------------------------------------------------------------
status=0
# A window other than the main one (--window-id: Settings, a sheet) has no sidebar column.
width_flag=()
[[ -n "$WINDOW_ID" ]] && width_flag=(--full-width)
sample="$("$FRAME_CHECK" "${width_flag[@]+"${width_flag[@]}"}" "$SHOT" 2>&1)" || status=$?
if [[ $status -ne 0 ]]; then
    KEEP_WORK=1
    if [[ $status -eq 1 ]]; then
        echo "✗ the capture is blank ($sample)."
        screen_recording_help
    else
        echo "✗ could not read the capture back: $sample"
    fi
    exit 1
fi

# ---- 5. exact pixel size -------------------------------------------------------------------
dims="$(sips -g pixelWidth -g pixelHeight "$SHOT" | awk '/pixelWidth:/ { w = $2 } /pixelHeight:/ { h = $2 } END { print w "x" h }')"
if [[ "$dims" != "$EXPECT_SIZE" ]]; then
    KEEP_WORK=1
    echo "✗ the capture is $dims px, not $EXPECT_SIZE (window $wid is $points pt)."
    echo "  Size the window to the pixel size ÷ the display's scale: for 2880x1800 on a 2x display,"
    echo "  quit the variant and relaunch it with -windowSize 1440x900. Or pass --size for another"
    echo "  APP_DESKTOP size (1280x800, 1440x900, 2560x1600, 2880x1800)."
    exit 5
fi

mkdir -p "$(dirname "$OUT")"
mv -f "$SHOT" "$OUT"
echo "✓ $OUT: $dims px, window $wid of $VARIANT_ID (pid $pid); $sample"
