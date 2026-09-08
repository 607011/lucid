#!/bin/bash
# Builds Lucid.app (via build_app.sh) and packages it into a distributable
# .dmg in ./build/. Used by the release GitHub Action, but works locally
# too: ./Scripts/build_dmg.sh [version]
set -euo pipefail

APP_NAME="Lucid"
VERSION="${1:-${APP_VERSION:-1.0}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/build/$APP_NAME.app"
DMG_PATH="$PROJECT_DIR/build/$APP_NAME-$VERSION.dmg"

APP_VERSION="$VERSION" "$SCRIPT_DIR/build_app.sh"

echo "==> Creating DMG at $DMG_PATH"
rm -f "$DMG_PATH"

STAGING_DIR="$(mktemp -d)/dmg"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$(dirname "$STAGING_DIR")"

echo ""
echo "Done: $DMG_PATH"
