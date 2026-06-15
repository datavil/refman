#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Refman"
PRODUCT_NAME="Refman"
AGENT_NAME="refman-agent"
CONFIGURATION="${CONFIGURATION:-release}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-app.refman.Refman}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME"
swift build -c "$CONFIGURATION" --product "$AGENT_NAME"

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
PRODUCT_BINARY="$BIN_DIR/$PRODUCT_NAME"
AGENT_BINARY="$BIN_DIR/$AGENT_NAME"

if [[ ! -x "$PRODUCT_BINARY" ]]; then
    echo "error: missing executable: $PRODUCT_BINARY" >&2
    exit 1
fi

if [[ ! -x "$AGENT_BINARY" ]]; then
    echo "error: missing executable: $AGENT_BINARY" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

install -m 755 "$PRODUCT_BINARY" "$MACOS_DIR/$PRODUCT_NAME"
install -m 755 "$AGENT_BINARY" "$MACOS_DIR/$AGENT_NAME"

shopt -s nullglob
for resource_bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$resource_bundle" "$RESOURCES_DIR/"
done
shopt -u nullglob

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$PRODUCT_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

if [[ "${SKIP_CODESIGN:-0}" != "1" ]] && command -v codesign >/dev/null; then
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "Created $APP_DIR"
