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
ZIP_PATH="$OUTPUT_DIR/${ASSET_PREFIX}${VERSION_NAME}-${BUILD_NUMBER}${ASSET_SUFFIX}"

mkdir -p "$OUTPUT_DIR"

swift build -c "$BUILD_CONFIGURATION"

if [[ ! -f "$EXECUTABLE_PATH" ]]; then
  echo "Expected executable not found at $EXECUTABLE_PATH" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE_PATH" "$ZIP_PATH"
mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"

cp "$EXECUTABLE_PATH" "$MACOS_PATH/$APP_NAME"
chmod +x "$MACOS_PATH/$APP_NAME"

shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$RESOURCES_PATH/"
done
shopt -u nullglob

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
