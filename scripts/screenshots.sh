#!/bin/bash
set -euo pipefail

# Stride - Screenshot Generation & Validation
# Usage: ./scripts/screenshots.sh
#
# Generates promotional screenshots for App Store submission.
# Outputs to build/ios-screenshots/
#
# Required sizes for App Store:
#   iPhone 6.7" (1290x2796) - iPhone 15 Pro Max
#   iPhone 6.5" (1284x2778) - iPhone 14 Plus
#   iPad Pro 12.9" (2048x2732)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_DIR/build/ios-screenshots"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Stride - Screenshot Generator"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Generate via Swift script
echo "Generating screenshots..."
swift "$SCRIPT_DIR/generate_screenshots.swift"

echo ""

# Validate output
echo "Validating..."
EXPECTED_FILES=("01_today_6.7.png" "02_stats_6.7.png" "03_widgets_6.7.png")
ALL_OK=true

for f in "${EXPECTED_FILES[@]}"; do
    FILE="$OUT_DIR/$f"
    if [[ -f "$FILE" ]]; then
        SIZE=$(sips -g pixelWidth -g pixelHeight "$FILE" 2>/dev/null | tail -2 | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
        echo "  ✓ $f ($SIZE)"
    else
        echo "  ✗ $f MISSING"
        ALL_OK=false
    fi
done

echo ""
if $ALL_OK; then
    echo "All screenshots generated successfully!"
    echo "Output: $OUT_DIR"
else
    echo "WARNING: Some screenshots are missing!"
    exit 1
fi
echo ""
echo "Next steps:"
echo "  1. Review screenshots in $OUT_DIR"
echo "  2. Upload to App Store Connect via Transporter or ASC web UI"
echo ""
