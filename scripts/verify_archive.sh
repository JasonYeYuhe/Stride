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
#   - every other top-level key of the project's entitlements file, with the same value
#     (1.4.0): the App Sandbox, the app group, and on the Mac files.user-selected.read-write,
#     whose absence through 1.3.1 left Restore's open panel dead (check_all_entitlements). On
#     macOS the file must still declare the sandbox and that key.
# Both modes: the required-reason APIs each shipped privacy manifest declares, exactly
# (check_required_reasons, 1.4.1): the app's, and on iOS the widget's. The archive is checked
# because it is what was built; the export because it is what is uploaded.
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

# The required-reason API declarations each manifest must hold, as "<category> <reason>" with the
# category's NSPrivacyAccessedAPICategory prefix dropped. Exactly these: a reason missing is an
# API the binary uses without saying why (App Store Connect's ITMS-91053 mail, then a
# rejection), and one more than these is a reason nobody here checked the code for. A change to
# either manifest changes this list in the same commit, after grepping what the target compiles.
#
# The app (Stride and StrideMac ship the same Stride/PrivacyInfo.xcprivacy):
#   UserDefaults CA92.1    UserDefaults.standard: settings, the sync cursor, the local queue;
#   UserDefaults 1C8F.1    the App Group suite shared with the widget;
#   FileTimestamp C617.1   DataExportService.removeExportFiles reads .creationDateKey and
#                          .contentModificationDateKey of its own export directories in tmp
#                          (since 1.4.0, declared since 1.4.1);
#   SystemBootTime 35F9.1  StoreOpenRetry (Shared/SharedModelContainer.swift) times its retries
#                          with ProcessInfo.systemUptime (since 1.3.1, declared since 1.4.1).
# The widget (StrideWidget/PrivacyInfo.xcprivacy; it compiles Shared/ but SentryBootstrap.swift,
# and none of Stride/Sources):
#   UserDefaults 1C8F.1    it queues a deleted entry id in the App Group suite;
#   SystemBootTime 35F9.1  Shared/SharedModelContainer.swift is compiled in.
APP_REQUIRED_REASONS="UserDefaults CA92.1
UserDefaults 1C8F.1
FileTimestamp C617.1
SystemBootTime 35F9.1"
WIDGET_REQUIRED_REASONS="UserDefaults 1C8F.1
SystemBootTime 35F9.1"

# declared_reasons <PrivacyInfo.xcprivacy>  — "<category> <reason>" per declared reason, one per
# line, sorted, the category's NSPrivacyAccessedAPICategory prefix dropped. Fails on a file that
# is not a plist or whose NSPrivacyAccessedAPITypes is not the documented array of dictionaries.
declared_reasons() {
    plutil -convert json -o - "$1" 2>/dev/null | /usr/bin/python3 -I -c '
import json, sys
prefix = "NSPrivacyAccessedAPICategory"
lines = []
for entry in json.load(sys.stdin).get("NSPrivacyAccessedAPITypes", []):
    category = entry["NSPrivacyAccessedAPIType"]
    if category.startswith(prefix):
        category = category[len(prefix):]
    reasons = entry["NSPrivacyAccessedAPITypeReasons"]
    if not reasons:
        lines.append(category + " <no reason>")
    lines.extend(category + " " + reason for reason in reasons)
print("\n".join(sorted(lines)))
' 2>/dev/null
}

# check_required_reasons <label> <PrivacyInfo.xcprivacy> <expected lines>
# Every expected "<category> <reason>" declared, and nothing else. Prints one ✓/✗ line per
# expected reason and one ✗ per unexpected one.
check_required_reasons() {
    local label="$1" manifest="$2" expected="$3" declared line
    if [[ ! -f "$manifest" ]]; then
        fail "$label: no PrivacyInfo.xcprivacy at $manifest, so no required-reason API is declared"
        return
    fi
    if ! declared="$(declared_reasons "$manifest")"; then
        fail "$label: could not read NSPrivacyAccessedAPITypes from $manifest"
        return
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if grep -qxF "$line" <<<"$declared"; then
            pass "$label: privacy manifest declares $line"
        else
            fail "$label: privacy manifest does not declare $line (NSPrivacyAccessedAPICategory${line% *} with reason ${line#* })"
        fi
    done <<<"$expected"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! grep -qxF "$line" <<<"$expected"; then
            fail "$label: privacy manifest declares $line, which verify_archive.sh does not expect — check the code, then update *_REQUIRED_REASONS"
        fi
    done <<<"$declared"
}

# check_manifest_reasons <app> — both modes: the app's manifest, and on iOS the widget's.
check_manifest_reasons() {
    local app="${1%/}"
    if [[ "$PLATFORM" == "ios" ]]; then
        check_required_reasons "Stride.app" "$app/PrivacyInfo.xcprivacy" "$APP_REQUIRED_REASONS"
        check_required_reasons "appex" "$app/PlugIns/StrideWidgetExtension.appex/PrivacyInfo.xcprivacy" \
            "$WIDGET_REQUIRED_REASONS"
    else
        check_required_reasons "Stride.app (macOS)" "$app/Contents/Resources/PrivacyInfo.xcprivacy" \
            "$APP_REQUIRED_REASONS"
    fi
}

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
        check_all_entitlements "$entitlements" "$key"
    fi
    rm -f "$entitlements"
}

# entitlement_value <plist> <key>  — the key's value as comparable text: a scalar as PlistBuddy
# prints it, an array as its entries, sorted, one per line. Empty when the key is absent.
entitlement_value() {
    plist_get "$1" ":$2" | sed -e 's/^ *//' -e '/^Array {$/d' -e '/^}$/d' | sort
}

# check_all_entitlements <signed entitlements plist> <key already checked above>
# Every top-level key of the project's entitlements file, with the same value, in the signed app
# (RELEASE-1.4.0.md D5). The associated-domains check above was the only one, and it could not
# see what 1.3.0 and 1.3.1 shipped without: StrideMac.entitlements had the App Sandbox and no
# com.apple.security.files.user-selected.* entitlement, so AppKit refused to show an open or save
# panel and Restore from Backup did nothing on the Mac. 1.4.0 adds the key (Restore and the menu
# Export need it); this makes a key that the file declares and signing drops — a profile without
# the capability, a CODE_SIGN_ENTITLEMENTS that moved — fail before the upload, whichever key it
# is. Extra keys in the signed app (application-identifier, team-identifier) are signing's own.
# On macOS the file itself must also still declare the two keys the Mac's panels depend on: a key
# deleted from the project would otherwise pass here as "nothing to compare".
check_all_entitlements() {
    local signed_plist="$1" skip="$2" key expected signed checked=0
    local keys
    # `plutil -p` prints each top-level key as `  "key" => …` at exactly two spaces.
    keys="$(plutil -p "$ENTITLEMENTS" 2>/dev/null | sed -n 's/^  "\([^"]*\)" => .*$/\1/p')"
    if [[ -z "$keys" ]]; then
        fail "could not read the keys of $(basename "$ENTITLEMENTS")"
        return
    fi
    if [[ "$PLATFORM" == "macos" ]]; then
        for key in com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write; do
            if echo "$keys" | grep -qxF "$key"; then
                pass "$(basename "$ENTITLEMENTS") declares $key"
            else
                fail "$(basename "$ENTITLEMENTS") no longer declares $key — the Mac's open and save panels need it"
            fi
        done
    fi
    while IFS= read -r key; do
        [[ -z "$key" || "$key" == "$skip" ]] && continue
        checked=$((checked + 1))
        expected="$(entitlement_value "$ENTITLEMENTS" "$key")"
        signed="$(entitlement_value "$signed_plist" "$key")"
        if [[ -z "$signed" ]]; then
            fail "$key declared in $(basename "$ENTITLEMENTS") but absent from the signed app"
        elif [[ "$signed" != "$expected" ]]; then
            fail "$key differs: signed [$(echo $signed)], project [$(echo $expected)]"
        else
            pass "signed app carries $key [$(echo $signed)]"
        fi
    done <<< "$keys"
    if (( checked == 0 )); then
        pass "no other key in $(basename "$ENTITLEMENTS") to compare"
    fi
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
    check_manifest_reasons "$APP"
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
check_manifest_reasons "$APP"

if (( CHECK_FAILED > 0 )); then
    echo "  ✗ $CHECK_FAILED check(s) failed — this archive must not be uploaded."
    exit 1
fi
echo "  ✓ Archive verified."
