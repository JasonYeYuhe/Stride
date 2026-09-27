#!/bin/bash
# Assert, in what is ACTUALLY about to be uploaded, everything a green build does not prove.
#
#   scripts/verify_archive.sh <path.xcarchive> <ios|macos>          (1) the archive's contents
#   scripts/verify_archive.sh --exported <export dir> <ios|macos>   (2) the export's signature
#
# build-appstore.sh runs (1) after each `xcodebuild archive` and (2) after the App Store
# export, and aborts the release before any upload on a non-zero exit. CI builds a Debug
# product on a different machine with a different toolchain; only this sees the Release build
# that ships.
#
# Two modes because the archive and the upload are signed by different identities.
# `xcodebuild archive` with automatic signing signs with the DEVELOPMENT identity and profile
# (1.2.3's archive: "Authority=Apple Development", get-task-allow true); the uploaded binary is
# re-signed at export with Apple Distribution and the App Store profile. Export does not change
# the bundle's contents, so contents are checked once, on the archive; anything the signature
# or the profile decides must be read from the export, or it describes the wrong profile.
#
# (1) contents (the shared checks are in scripts/ci/product_checks.sh, with their history):
#   - iOS: PlugIns/StrideWidgetExtension.appex embedded, with its own privacy manifest and
#     versions equal to the app's; macOS: the Contents/ layout;
#   - the app's PrivacyInfo.xcprivacy, CFBundleIdentifier, numeric versions, and
#     CFBundleDisplayName (absent from the 1.2.3 app — nothing set it until 1.3.0);
#   - Sentry.framework embedded, the SDK merged/linked into the executable, and the DSN
#     compiled in (1.2.0 shipped with the SDK linked and never started).
# (2) signature, on the .ipa (iOS) or the .pkg's Stride.app (macOS) that export produced:
#   - signed by Apple Distribution, get-task-allow not true (a development-signed binary
#     would be refused at upload, after the long part of the run);
#   - associated domains: ONLY when the project's entitlements file declares
#     com.apple.developer.associated-domains (M1's one-tap sign-in adds it), the signed app
#     must carry the same list. A capability missing from the App Store provisioning profile
#     can drop it at signing time, and then universal links silently open Safari instead of
#     the app. The check switches itself on the day the entitlement is added; nothing to
#     remember.
set -uo pipefail   # no -e: report every failed check, then exit on the count

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

MODE="archive"
if [[ "${1:-}" == "--exported" ]]; then MODE="exported"; shift; fi
if [[ $# -ne 2 || ( "$2" != "ios" && "$2" != "macos" ) ]]; then
    echo "Usage: $0 <path.xcarchive> <ios|macos>"
    echo "       $0 --exported <export dir> <ios|macos>"
    exit 2
fi
PLATFORM="$2"

source "$SCRIPT_DIR/ci/product_checks.sh"

# Must match CODE_SIGN_ENTITLEMENTS of the Stride / StrideMac target in project.yml.
if [[ "$PLATFORM" == "ios" ]]; then
    ENTITLEMENTS="$PROJECT_DIR/Stride/Stride.entitlements"
else
    ENTITLEMENTS="$PROJECT_DIR/StrideMac/StrideMac.entitlements"
fi

# check_signature <signed .app>  — mode (2); see the header.
check_signature() {
    local app="$1" authority entitlements
    authority="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    if [[ "$authority" == "Apple Distribution:"* ]]; then
        pass "signed by $authority"
    else
        fail "signed by '${authority:-<unsigned>}', expected Apple Distribution"
    fi
    entitlements="$(mktemp -t stride-entitlements)"
    # `:-` asks for the XML plist form on stdout.
    codesign -d --entitlements :- "$app" > "$entitlements" 2>/dev/null
    if [[ "$(plist_get "$entitlements" :get-task-allow)" == "true" ]]; then
        fail "get-task-allow is true — a development-signed binary"
    else
        pass "get-task-allow not set"
    fi

    # Associated domains (self-activating). PlistBuddy, not `plutil -extract`: plutil reads
    # the dots in the key as a nested key path, finds nothing, and the check would have
    # stayed "inactive" forever after M1 added the key.
    local key="com.apple.developer.associated-domains" expected signed
    if [[ ! -f "$ENTITLEMENTS" ]]; then
        fail "entitlements file not found: $ENTITLEMENTS (did CODE_SIGN_ENTITLEMENTS move?)"
    else
        expected="$(plist_get "$ENTITLEMENTS" ":$key")"
        if [[ -z "$expected" ]]; then
            pass "no $key in $(basename "$ENTITLEMENTS") yet — entitlement check inactive"
        else
            signed="$(plist_get "$entitlements" ":$key")"
            # PlistBuddy prints an array as "Array {" / one entry per line / "}"; compare entries.
            expected="$(echo "$expected" | sed -n 's/^ *\([a-z]*:.*\)$/\1/p' | sort)"
            signed="$(echo "$signed" | sed -n 's/^ *\([a-z]*:.*\)$/\1/p' | sort)"
            if [[ -z "$signed" ]]; then
                fail "$key declared in $(basename "$ENTITLEMENTS") but absent from the signed app"
            elif [[ "$signed" != "$expected" ]]; then
                fail "$key differs: signed [$(echo $signed)], project [$(echo $expected)]"
            else
                pass "signed app carries $key [$(echo $signed)]"
            fi
        fi
    fi
    rm -f "$entitlements"
}

if [[ "$MODE" == "exported" ]]; then
    EXPORT="${1%/}"
    echo "Verifying the signature of the $PLATFORM export: $EXPORT"
    # Fails closed: no export product means nothing was verified, not that nothing is wrong.
    WORK="$(mktemp -d -t stride-verify-export)"
    trap 'rm -rf "$WORK"' EXIT
    if [[ "$PLATFORM" == "ios" ]]; then
        PRODUCT="$EXPORT/Stride.ipa"
        [[ -f "$PRODUCT" ]] && ditto -x -k "$PRODUCT" "$WORK" 2>/dev/null
        APP="$WORK/Payload/Stride.app"
    else
        PRODUCT="$EXPORT/Stride.pkg"
        # expand-full wants a directory that does not exist yet.
        [[ -f "$PRODUCT" ]] && pkgutil --expand-full "$PRODUCT" "$WORK/pkg" >/dev/null 2>&1
        APP="$(find "$WORK/pkg" -maxdepth 3 -type d -name Stride.app -path '*/Payload/*' 2>/dev/null | head -1)"
    fi
    if [[ ! -f "$PRODUCT" ]]; then
        echo "  ✗ no $(basename "$PRODUCT") in $EXPORT — did the export fail?"
        exit 1
    fi
    if [[ -z "$APP" || ! -d "$APP" ]]; then
        echo "  ✗ could not find Stride.app inside $PRODUCT"
        exit 1
    fi
    check_signature "$APP"
    if (( CHECK_FAILED > 0 )); then
        echo "  ✗ $CHECK_FAILED check(s) failed — this export must not be uploaded."
        exit 1
    fi
    echo "  ✓ Export verified."
    exit 0
fi

ARCHIVE="${1%/}"

echo "Verifying $PLATFORM archive: $ARCHIVE"

if [[ ! -f "$ARCHIVE/Info.plist" ]]; then
    echo "  ✗ not an archive (no Info.plist): $ARCHIVE"
    exit 1
fi
APP_REL="$(plist_get "$ARCHIVE/Info.plist" :ApplicationProperties:ApplicationPath)"
APP="$ARCHIVE/Products/${APP_REL:-Applications/Stride.app}"
if [[ ! -d "$APP" ]]; then
    echo "  ✗ no application in the archive at $APP"
    exit 1
fi

# The platform argument must match what is in the archive: an iOS check passing on a macOS
# archive (or the reverse) would be a green light for the wrong thing.
if [[ -d "$APP/Contents/MacOS" ]]; then actual="macos"; else actual="ios"; fi
if [[ "$actual" != "$PLATFORM" ]]; then
    echo "  ✗ asked to verify $PLATFORM, but $APP is a $actual app"
    exit 1
fi

case "$PLATFORM" in
    ios)
        check_ios_app "$APP"
        ;;
    macos)
        check_macos_app "$APP"
        ;;
esac

if (( CHECK_FAILED > 0 )); then
    echo "  ✗ $CHECK_FAILED check(s) failed — this archive must not be uploaded."
    exit 1
fi
echo "  ✓ Archive verified."
