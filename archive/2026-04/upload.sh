#!/bin/bash
set -euo pipefail

PROJECT_DIR="/Users/jason/Documents/Stride"
ARCHIVE_PATH="$PROJECT_DIR/build/Stride.xcarchive"
EXPORT_PATH="$PROJECT_DIR/build/Export"

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

echo "=== Step 1/3: Archiving Stride (v1.0.0 build 7) ==="
xcodebuild archive \
  -project "$PROJECT_DIR/Stride.xcodeproj" \
  -scheme Stride \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -quiet

if [ ! -d "$ARCHIVE_PATH" ]; then
  echo "ERROR: Archive failed"
  exit 1
fi
echo "Archive OK"

echo ""
echo "=== Step 2/3: Exporting IPA ==="
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$PROJECT_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_PATH" \
  -quiet

IPA_PATH=$(find "$EXPORT_PATH" -name "*.ipa" -print -quit)
if [ -z "$IPA_PATH" ]; then
  echo "ERROR: IPA export failed"
  exit 1
fi
echo "IPA OK: $IPA_PATH"

echo ""
echo "=== Step 3/3: Uploading to App Store Connect ==="
xcrun altool --upload-app \
  -f "$IPA_PATH" \
  -t ios \
  -u "$APPLE_ID" \
  -p "@keychain:AC_PASSWORD" \
  --verbose

echo ""
echo "Done! Check App Store Connect for v1.0.0 (7)"
