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
#   4. The helper samples the PNG. Nearly all transparent, or one colour, is a blank capture: the
#      app running this script has no Screen Recording permission. It prints how to grant it.
#   5. `sips -g pixelWidth -g pixelHeight`: exactly 2880×1800 (or --size), else it stops and
#      says what size the window is. 2880×1800 is a 1440×900 pt window on a 2x display (the
#      owner's 4K display at 2x): launch the DEBUG variant with `-windowSize 1440x900`
#      (StrideApp.swift, LaunchWindowSize), which sets that frame.
#   Only a capture that passes 4 and 5 is moved to <out.png>; a rejected one stays in the temp
#   dir, whose path is printed.
#
# The variant, sized for capture (quit any running instance first: `--args` reach only a new
# process):
#     open -b yyh.stride.habittracker.mactest --args -windowSize 1440x900
# The Mac App Store takes 1280×800, 1440×900, 2560×1600 or 2880×1800 (README "Store screenshots").
#
# Exit status: 0 captured; 1 capture failed or blank; 2 usage; 3 the variant is not running or has
# no on-screen window; 4 refused (not frontmost, the real app is running, more than one
# instance, an unknown --window-id); 5 wrong pixel size.
#
# Environment:
#   TMPDIR   where the helper is compiled and the capture first lands (mktemp -d)
set -euo pipefail

VARIANT_ID="yyh.stride.habittracker.mactest"
REAL_ID="yyh.stride.habittracker"

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; }

EXPECT_SIZE="2880x1800"
WINDOW_ID=""
FORCE=0
LIST=0
OUT=""
SIZE_RE='^[1-9][0-9]*x[1-9][0-9]*$'
NUM_RE='^[0-9]+$'
while [[ $# -gt 0 ]]; do
    case "$1" in
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
if [[ $LIST -eq 1 ]]; then
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
cleanup() {
    local status=$?
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

# ---- the helper: lookup by bundle id + PID, and the blank check ------------------------------
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

case "blank":
    // blank <png>: exit 1 when the image is nearly all transparent or one colour.
    guard args.count == 3 else { fail(2, "usage: blank <png>") }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail(2, "unreadable image") }
    let width = 160, height = 100
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { fail(2, "could not sample the image") }
    var transparent = 0
    var colours: [UInt32: Int] = [:]
    for i in stride(from: 0, to: pixels.count, by: 4) {
        if pixels[i + 3] < 8 { transparent += 1; continue }
        let key = UInt32(pixels[i] >> 4) << 8 | UInt32(pixels[i + 1] >> 4) << 4 | UInt32(pixels[i + 2] >> 4)
        colours[key, default: 0] += 1
    }
    let total = width * height
    let opaque = total - transparent
    let transparentPercent = transparent * 100 / total
    let dominantPercent = opaque > 0 ? (colours.values.max() ?? 0) * 100 / opaque : 100
    print("transparent=\(transparentPercent)% colours=\(colours.count) dominant=\(dominantPercent)%")
    exit(transparentPercent >= 90 || dominantPercent >= 97 || colours.count <= 2 ? 1 : 0)

default:
    fail(2, "usage: find <variant id> <real id> | blank <png>")
}
SWIFT

HELPER="$WORK/capture-helper"
if ! xcrun swiftc -swift-version 5 -o "$HELPER" "$WORK/main.swift" >"$WORK/helper-build.log" 2>&1; then
    echo "✗ could not compile the window-lookup helper:"; sed 's/^/    /' "$WORK/helper-build.log" | head -20
    exit 1
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
            echo "✗ $VARIANT_ID is not running. This script launches nothing; start it yourself:"
            echo "    open -b $VARIANT_ID --args -windowSize 1440x900"
        else
            echo "✗ $VARIANT_ID (pid $pid) has no on-screen window: minimized, closed, or on another Space."
        fi
        exit 3 ;;
    4) echo "✗ refusing: ${instances:-?} running instances of $VARIANT_ID (want exactly one)."; exit 4 ;;
    *) echo "✗ the window lookup failed (status $status):"; printf '%s\n' "$found" | sed 's/^/    /'; exit 1 ;;
esac

echo "==> $VARIANT_ID: pid $pid, $(value path)"
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
sample="$("$HELPER" blank "$SHOT" 2>&1)" || status=$?
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
