#!/bin/bash
set -euo pipefail

# Stride - App Store Build & Upload Script
# Usage: ./scripts/build-appstore.sh [ios|macos|all] [--upload]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_DIR/Stride.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build/appstore"

# App Store Connect credentials — from scripts/.env (gitignored), as asc_api.py reads them.
# They used to be hardcoded here, with the .p8 path pointing inside iCloud Drive's Downloads
# folder; see the note in appstore_metadata.py.
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
fi
: "${ASC_API_KEY_ID:?set ASC_API_KEY_ID in scripts/.env}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID in scripts/.env}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH in scripts/.env}"
API_KEY_ID="$ASC_API_KEY_ID"
API_ISSUER="$ASC_ISSUER_ID"
API_KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"
TEAM_ID="${ASC_TEAM_ID:-KHMK6Q3L3K}"

# Parse arguments
PLATFORM="${1:-all}"
UPLOAD=false
if [[ "${2:-}" == "--upload" ]] || [[ "${1:-}" == "--upload" ]]; then
    UPLOAD=true
    if [[ "${1:-}" == "--upload" ]]; then
        PLATFORM="all"
    fi
fi

# Preflight: can we actually sign right now?
# A locked login keychain fails ~20 minutes into the archive with the useless
# "errSecInternalComponent"; this reproduces it in one second, before any work.
# (Measured 2026-09-08: no-timeout does NOT guarantee the keychain stays unlocked.)
preflight_signing() {
    local probe; probe="$(mktemp -t stride-sigtest)"
    cp /bin/echo "$probe"
    if ! codesign -f -s "Apple Distribution: Yuhe Ye (${TEAM_ID})" "$probe" >/dev/null 2>&1; then
        rm -f "$probe"
        echo "  ✗ Cannot codesign: the login keychain is locked."
        echo "    security show-keychain-info ~/Library/Keychains/login.keychain-db"
        echo "    -> 'User interaction is not allowed.' confirms it."
        echo "    Unlock the screen (or the keychain) and re-run. No agent can do this for you."
        exit 1
    fi
    rm -f "$probe"
    echo "  ✓ Signing identity usable"
}
preflight_signing

# Preflight: has the INSTALLED Xcode's license been accepted?
# Every Xcode update silently un-accepts it, and then every xcodebuild and xcrun call
# dies with "You have not agreed to the Xcode license agreements" — the archive, the
# export, even `xcrun dwarfdump`. Measured 2026-09-15: Xcode updated to 27.0 at 07:28
# and nothing could build until the owner re-accepted. Accepting needs sudo, so this
# is owner-only; the job here is to say so in the first second instead of mid-build.
preflight_xcode_license() {
    if ! xcodebuild -license check >/dev/null 2>&1; then
        local xv; xv="$(defaults read /Applications/Xcode.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo '?')"
        echo "  ✗ The Xcode ${xv} license has not been accepted (usually: Xcode was just updated)."
        echo "    Run in a terminal:  sudo xcodebuild -license accept"
        echo "    After a major Xcode update also run:  xcodebuild -runFirstLaunch"
        echo "    Both need your password. No agent can do this for you."
        exit 1
    fi
    echo "  ✓ Xcode license accepted"
}
preflight_xcode_license

# Archives that archived fine but whose dSYMs did not make it to Sentry. Newline-separated
# string rather than an array: /bin/bash on macOS is 3.2, where an empty array trips set -u.
DSYM_FAILED=""

# Regenerate Xcode project
echo "  Regenerating Xcode project..."
cd "$PROJECT_DIR" && xcodegen generate --quiet 2>/dev/null || xcodegen generate

VERSION=$(grep 'MARKETING_VERSION:' "$PROJECT_DIR/project.yml" | head -1 | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d ' ')
BUILD_NUM=$(grep 'CURRENT_PROJECT_VERSION:' "$PROJECT_DIR/project.yml" | head -1 | sed 's/.*: *\([0-9]*\)/\1/' | tr -d ' ')

echo "================================================"
echo "  Stride - App Store Build v${VERSION} (${BUILD_NUM})"
echo "  Platform: ${PLATFORM}"
echo "  Upload: ${UPLOAD}"
echo "================================================"
echo ""

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- iOS Build (includes Widget) ---
build_ios() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Building iOS (includes Widget)..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local ARCHIVE="$BUILD_DIR/Stride-iOS.xcarchive"
    local EXPORT="$BUILD_DIR/ios-export"

    echo "[1/3] Archiving iOS target..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "Stride" \
        -configuration Release \
        -archivePath "$ARCHIVE" \
        -destination "generic/platform=iOS" \
        -quiet \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$API_KEY_PATH" \
        -authenticationKeyID "$API_KEY_ID" \
        -authenticationKeyIssuerID "$API_ISSUER" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Automatic

    echo "  ✓ Archive: $ARCHIVE"

    # dSYMs: keep a permanent copy and upload to Sentry NOW, before anything else can
    # delete this archive (this script rm -rf's build/appstore on its next run — which is
    # exactly how 1.2.1's only dSYM was lost, leaving its one real crash unreadable).
    # Deliberately non-fatal: a Sentry outage must not block a release, and the copy
    # under build/dsyms/ lets the upload be retried. Failures are reported in the summary.
    if ! "$SCRIPT_DIR/upload_dsyms.sh" "$ARCHIVE"; then
        DSYM_FAILED="${DSYM_FAILED}${ARCHIVE}"$'\n'
    fi

    echo "[2/3] Exporting for App Store..."
    cat > "$BUILD_DIR/ExportOptions-iOS.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions-iOS.plist" \
        -exportPath "$EXPORT" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$API_KEY_PATH" \
        -authenticationKeyID "$API_KEY_ID" \
        -authenticationKeyIssuerID "$API_ISSUER" \
        -quiet 2>&1 || true

    echo "  ✓ Export: $EXPORT"

    if [[ "$UPLOAD" == true ]]; then
        echo "[3/3] Uploading iOS to App Store Connect..."
        upload_to_appstore "$ARCHIVE" "ios"
    else
        echo "[3/3] Skipping upload (use --upload to enable)"
    fi
    echo ""
}

# --- macOS Build ---
build_macos() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Building macOS..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local ARCHIVE="$BUILD_DIR/Stride-macOS.xcarchive"
    local EXPORT="$BUILD_DIR/macos-export"

    echo "[1/3] Archiving macOS target..."
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "StrideMac" \
        -configuration Release \
        -archivePath "$ARCHIVE" \
        -quiet \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$API_KEY_PATH" \
        -authenticationKeyID "$API_KEY_ID" \
        -authenticationKeyIssuerID "$API_ISSUER" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Automatic

    echo "  ✓ Archive: $ARCHIVE"

    # dSYMs: keep a permanent copy and upload to Sentry NOW, before anything else can
    # delete this archive (this script rm -rf's build/appstore on its next run — which is
    # exactly how 1.2.1's only dSYM was lost, leaving its one real crash unreadable).
    # Deliberately non-fatal: a Sentry outage must not block a release, and the copy
    # under build/dsyms/ lets the upload be retried. Failures are reported in the summary.
    if ! "$SCRIPT_DIR/upload_dsyms.sh" "$ARCHIVE"; then
        DSYM_FAILED="${DSYM_FAILED}${ARCHIVE}"$'\n'
    fi

    echo "[2/3] Exporting for App Store..."
    cat > "$BUILD_DIR/ExportOptions-macOS.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions-macOS.plist" \
        -exportPath "$EXPORT" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$API_KEY_PATH" \
        -authenticationKeyID "$API_KEY_ID" \
        -authenticationKeyIssuerID "$API_ISSUER" \
        -quiet 2>&1 || true

    echo "  ✓ Export: $EXPORT"

    if [[ "$UPLOAD" == true ]]; then
        echo "[3/3] Uploading macOS to App Store Connect..."
        upload_to_appstore "$ARCHIVE" "macos"
    else
        echo "[3/3] Skipping upload (use --upload to enable)"
    fi
    echo ""
}

# --- Upload function ---
upload_to_appstore() {
    local ARCHIVE_PATH="$1"
    local PLATFORM="$2"

    if [[ ! -f "$API_KEY_PATH" ]]; then
        echo "  ERROR: API key not found at $API_KEY_PATH"
        return 1
    fi

    echo "  Uploading via xcodebuild..."

    local UPLOAD_PLIST="$BUILD_DIR/ExportOptions-${PLATFORM}-upload.plist"
    cat > "$UPLOAD_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$UPLOAD_PLIST" \
        -exportPath "$BUILD_DIR/${PLATFORM}-upload" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$API_KEY_PATH" \
        -authenticationKeyID "$API_KEY_ID" \
        -authenticationKeyIssuerID "$API_ISSUER" \
        2>&1

    echo "  ✓ Upload complete for $PLATFORM"
}

# --- Execute ---
case "$PLATFORM" in
    ios)
        build_ios
        ;;
    macos)
        build_macos
        ;;
    all)
        build_ios
        build_macos
        ;;
    *)
        echo "Usage: $0 [ios|macos|all] [--upload]"
        exit 1
        ;;
esac

# --- Summary ---
echo "================================================"
echo "  Build Complete!"
echo "================================================"
echo ""
echo "  Archives:"
ls -1 "$BUILD_DIR"/*.xcarchive 2>/dev/null | while read f; do echo "    $f"; done
echo ""
if [[ "$UPLOAD" == false ]]; then
    echo "  To upload: $0 $PLATFORM --upload"
fi
if [[ -n "$DSYM_FAILED" ]]; then
    echo ""
    echo "  ⚠️  dSYMs were NOT uploaded to Sentry for:"
    printf '%s' "$DSYM_FAILED" | sed 's/^/      /'
    echo "     Crashes from this build will be unsymbolicated until they are."
    echo "     Local copies are under build/dsyms/ — see the retry command printed above."
fi
echo ""
