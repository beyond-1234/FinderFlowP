#!/bin/bash
# FinderFlowP — build and package a shareable DMG (no Apple account needed)
# Usage:  cd ~/Downloads/FinderFlow && ./distribute.sh
# Output: build/FinderFlowP.dmg

set -e
cd "$(dirname "$0")"

APP="FinderFlowP"
BUILD_DIR="build/app"
DMG="build/$APP.dmg"
STAGING="build/dmg_stage"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  FinderFlowP — build & package"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p build

# ── 1. build (no signing) ──────────────────────────────────────────────────
echo ""
echo "▶ Building…"
xcodebuild \
    -scheme "$APP" \
    -configuration Release \
    -destination "platform=macOS" \
    CONFIGURATION_BUILD_DIR="$(pwd)/$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="" \
    2>&1 | grep -E "^(error:|warning: |Build|FAILED|SUCCEEDED)" | grep -v "^warning: No App"

APP_PATH="$BUILD_DIR/$APP.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌  Build failed — check errors above."
    exit 1
fi

echo "   Built: $APP_PATH"

# ── 2. package into DMG ────────────────────────────────────────────────────
echo ""
echo "▶ Creating DMG…"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "FinderFlowP" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" > /dev/null

rm -rf "$STAGING"

SIZE=$(du -sh "$DMG" | cut -f1)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  Done!  ($SIZE)"
echo ""
echo "  File:  $(pwd)/$DMG"
echo ""
echo "  Share it:"
echo "  → Upload to Google Drive, Dropbox, or WeTransfer"
echo "  → Send the download link to anyone"
echo ""
echo "  Recipients open it like this:"
echo "  1. Double-click FinderFlowP.dmg"
echo "  2. Drag FinderFlowP → Applications"
echo "  3. Right-click FinderFlowP.app → Open  (first time only)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
