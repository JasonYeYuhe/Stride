#!/bin/bash
set -euo pipefail

# Stride - App Store Build & Upload Script
# Usage: ./scripts/build-appstore.sh [ios|macos|all] [--upload]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_DIR/Stride.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build/appstore"

# App Store Connect credentials
API_KEY_ID="DMMFP6XTXX"
API_ISSUER="c5671c11-49ec-47d9-bd38-5e3c1a249416"
API_KEY_PATH="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Downloads/AuthKey_${API_KEY_ID}.p8"
TEAM_ID="KHMK6Q3L3K"

# Parse arguments
PLATFORM="${1:-all}"
UPLOAD=false
if [[ "${2:-}" == "--upload" ]] || [[ "${1:-}" == "--upload" ]]; then
    UPLOAD=true
    if [[ "${1:-}" == "--upload" ]]; then
        PLATFORM="all"
    fi
fi

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
        CODE_SIGN_STYLE=Automatic \
        CODE_SIGN_IDENTITY="Apple Distribution"

    echo "  ✓ Archive: $ARCHIVE"

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
echo ""
