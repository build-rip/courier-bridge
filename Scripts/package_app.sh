#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUTPUT_DIR=${COURIER_BRIDGE_OUTPUT_DIR:-"$ROOT_DIR/dist"}
BUILD_CONFIGURATION=${COURIER_BRIDGE_BUILD_CONFIGURATION:-release}
APP_NAME=${COURIER_BRIDGE_APP_NAME:-"Courier Bridge"}
PRODUCT_NAME=${COURIER_BRIDGE_PRODUCT_NAME:-courier-bridge}
BUNDLE_ID=${COURIER_BRIDGE_BUNDLE_ID:-rip.build.courier.bridge}
VERSION_NAME=${COURIER_BRIDGE_VERSION_NAME:-0.1.0}
BUILD_NUMBER=${COURIER_BRIDGE_BUILD_NUMBER:-1}
GITHUB_REPOSITORY=${COURIER_BRIDGE_GITHUB_REPOSITORY:-build-rip/courier-bridge}
ASSET_PREFIX=${COURIER_BRIDGE_RELEASE_ASSET_PREFIX:-Courier-Bridge-}
ASSET_SUFFIX=${COURIER_BRIDGE_RELEASE_ASSET_SUFFIX:-.zip}
ENABLE_CODESIGN=${COURIER_BRIDGE_CODESIGN_IDENTITY:-}

BUILD_DIR="$ROOT_DIR/.build/$BUILD_CONFIGURATION"
EXECUTABLE_PATH="$BUILD_DIR/$PRODUCT_NAME"
APP_BUNDLE_PATH="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_PATH="$APP_BUNDLE_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"
SOURCE_ICON_PATH="$ROOT_DIR/icon.svg"
ICONSET_PATH="$OUTPUT_DIR/AppIcon.iconset"
ICON_PNG_PATH="$OUTPUT_DIR/icon.png"
ICON_ICNS_PATH="$OUTPUT_DIR/AppIcon.icns"
ZIP_PATH="$OUTPUT_DIR/${ASSET_PREFIX}${VERSION_NAME}-${BUILD_NUMBER}${ASSET_SUFFIX}"

mkdir -p "$OUTPUT_DIR"

swift build -c "$BUILD_CONFIGURATION" --product "$PRODUCT_NAME"

if [[ ! -f "$EXECUTABLE_PATH" ]]; then
  echo "Expected executable not found at $EXECUTABLE_PATH" >&2
  exit 1
fi

if [[ ! -f "$SOURCE_ICON_PATH" ]]; then
  echo "Expected source icon not found at $SOURCE_ICON_PATH" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE_PATH" "$ZIP_PATH" "$ICONSET_PATH" "$ICON_PNG_PATH" "$ICON_ICNS_PATH"
mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"

cp "$EXECUTABLE_PATH" "$MACOS_PATH/$APP_NAME"
chmod +x "$MACOS_PATH/$APP_NAME"

shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$RESOURCES_PATH/"
done
shopt -u nullglob

qlmanage -t -s 1024 -o "$OUTPUT_DIR" "$SOURCE_ICON_PATH" >/dev/null
mv "$OUTPUT_DIR/$(basename "$SOURCE_ICON_PATH").png" "$ICON_PNG_PATH"

mkdir -p "$ICONSET_PATH"
sips -z 16 16 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG_PATH" --out "$ICONSET_PATH/icon_512x512.png" >/dev/null
cp "$ICON_PNG_PATH" "$ICONSET_PATH/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_PATH" -o "$ICON_ICNS_PATH"

cp "$SOURCE_ICON_PATH" "$RESOURCES_PATH/icon.svg"
cp "$ICON_ICNS_PATH" "$RESOURCES_PATH/AppIcon.icns"

cat > "$CONTENTS_PATH/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION_NAME</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CourierGitHubRepository</key>
    <string>$GITHUB_REPOSITORY</string>
    <key>CourierReleaseAssetPrefix</key>
    <string>$ASSET_PREFIX</string>
    <key>CourierReleaseAssetSuffix</key>
    <string>$ASSET_SUFFIX</string>
</dict>
</plist>
EOF

if [[ -n "$ENABLE_CODESIGN" ]]; then
  codesign --force --deep --options runtime --sign "$ENABLE_CODESIGN" "$APP_BUNDLE_PATH"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE_PATH" "$ZIP_PATH"

echo "App bundle: $APP_BUNDLE_PATH"
echo "Archive: $ZIP_PATH"
