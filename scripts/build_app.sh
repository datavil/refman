#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Refman"
PRODUCT_NAME="Refman"
AGENT_NAME="refman-agent"
CONFIGURATION="${CONFIGURATION:-release}"
ARCHITECTURES="${ARCHITECTURES:-$(uname -m)}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-app.refman.Refman}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-14.0}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

PRODUCT_BINARIES=()
AGENT_BINARIES=()
RESOURCE_BIN_DIR=""

for architecture in $ARCHITECTURES; do
    case "$architecture" in
        arm64|x86_64) ;;
        *)
            echo "error: unsupported architecture: $architecture" >&2
            exit 1
            ;;
    esac

    TRIPLE="$architecture-apple-macosx$MACOS_DEPLOYMENT_TARGET"
    swift build -c "$CONFIGURATION" --triple "$TRIPLE" --product "$PRODUCT_NAME"
    swift build -c "$CONFIGURATION" --triple "$TRIPLE" --product "$AGENT_NAME"

    BIN_DIR="$(swift build -c "$CONFIGURATION" --triple "$TRIPLE" --show-bin-path)"
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

    PRODUCT_BINARIES+=("$PRODUCT_BINARY")
    AGENT_BINARIES+=("$AGENT_BINARY")
    RESOURCE_BIN_DIR="$BIN_DIR"
done

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [[ ${#PRODUCT_BINARIES[@]} -eq 1 ]]; then
    install -m 755 "${PRODUCT_BINARIES[0]}" "$MACOS_DIR/$PRODUCT_NAME"
    install -m 755 "${AGENT_BINARIES[0]}" "$MACOS_DIR/$AGENT_NAME"
else
    lipo -create "${PRODUCT_BINARIES[@]}" -output "$MACOS_DIR/$PRODUCT_NAME"
    lipo -create "${AGENT_BINARIES[@]}" -output "$MACOS_DIR/$AGENT_NAME"
    chmod 755 "$MACOS_DIR/$PRODUCT_NAME" "$MACOS_DIR/$AGENT_NAME"
fi

shopt -s nullglob
for resource_bundle in "$RESOURCE_BIN_DIR"/*.bundle; do
    cp -R "$resource_bundle" "$RESOURCES_DIR/"
done
shopt -u nullglob

# App icon: render the code-drawn icon to a PNG, then assemble an .icns so the
# bundle shows the logo in Finder/Dock (the runtime icon only covers launch).
ICON_PNG="$(mktemp -t refman-icon).png"
"$MACOS_DIR/$PRODUCT_NAME" --export-icon "$ICON_PNG"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_PNG" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$ICON_PNG" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    <string>$MACOS_DEPLOYMENT_TARGET</string>
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
