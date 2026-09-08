#!/bin/bash
# Generates Resources/AppIcon.icns from the coffee-cup icon design in
# generate_icon.swift. Run this whenever the icon design changes; the
# resulting .icns is checked into the repo so build_app.sh doesn't need
# to regenerate it on every build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES_DIR="$PROJECT_DIR/Resources"

WORK_DIR="$(mktemp -d)"
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
mkdir -p "$RESOURCES_DIR"

render() {
    local px="$1"
    local name="$2"
    swift "$SCRIPT_DIR/generate_icon.swift" "$ICONSET_DIR/$name" "$px"
}

# Each size is rendered directly at its target resolution (the glyph is
# vector-based), rather than downscaled from a single master, so small
# sizes like 16x16 stay crisp.
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$WORK_DIR"

echo "Wrote $RESOURCES_DIR/AppIcon.icns"
