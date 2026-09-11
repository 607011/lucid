#!/bin/bash
# Builds Lucid and packages it as a proper .app bundle in ./build/.
set -euo pipefail

APP_NAME="Lucid"
BUNDLE_ID="de.olau.lucid"
# Overridable so CI can stamp the actual release version (e.g. from a
# "v1.0.0" git tag) instead of this placeholder.
APP_VERSION="${APP_VERSION:-1.0}"
APP_BUILD="${APP_BUILD:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Universal (arm64 + x86_64) build output lands in a different directory
# than a plain single-arch `swift build -c release`.
BUILD_DIR="$PROJECT_DIR/.build/apple/Products/Release"
APP_DIR="$PROJECT_DIR/build/$APP_NAME.app"

echo "==> Building universal (arm64 + x86_64) release binary..."
cd "$PROJECT_DIR"
swift build -c release --arch arm64 --arch x86_64

echo "==> Assembling app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© $(date +%Y)</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "Done: $APP_DIR (version $APP_VERSION, build $APP_BUILD)"
echo ""
echo "Install:"
echo "  cp -R \"$APP_DIR\" /Applications/"
