#!/bin/bash
# Build, sign (Developer ID + hardened runtime), notarize, staple, and zip a
# release of the app and CLI.
#
# One-time setup for notarization credentials:
#   xcrun notarytool store-credentials "capture-ndi-region" \
#     --apple-id <your-apple-id> --team-id SWS95WXK99 \
#     --password <app-specific-password from account.apple.com>
#
# Usage: Scripts/make-release.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: make-release.sh <version> (e.g. 1.0.0)}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Christopher Thoms (SWS95WXK99)}"
PROFILE="${NOTARY_PROFILE:-capture-ndi-region}"

echo "==> Building universal binaries (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release"

APP="dist/Capture NDI Region.app"
APP_ZIP="dist/Capture-NDI-Region-$VERSION.zip"
CLI_ZIP="dist/ndi-region-cli-$VERSION.zip"
rm -rf "$APP" "$APP_ZIP" "$CLI_ZIP" dist/ndi-region
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NDIRegion" "$APP/Contents/MacOS/Capture NDI Region"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Assets/DAWG.png "$APP/Contents/Resources/DAWG.png"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Capture NDI Region</string>
    <key>CFBundleDisplayName</key><string>Capture NDI Region</string>
    <key>CFBundleIdentifier</key><string>uk.co.christhoms.capturendiregion</string>
    <key>CFBundleExecutable</key><string>Capture NDI Region</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

echo "==> Signing with: $IDENTITY"
codesign --force --options runtime --timestamp \
    --entitlements Scripts/entitlements.plist \
    --sign "$IDENTITY" "$APP"
cp "$BIN/ndi-region" dist/ndi-region
codesign --force --options runtime --timestamp \
    --entitlements Scripts/entitlements.plist \
    --sign "$IDENTITY" dist/ndi-region

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo ""
    echo "!! Notarization credentials not found (profile '$PROFILE')."
    echo "!! Signed but UNNOTARIZED artifacts are in dist/. Run the one-time"
    echo "!! store-credentials command at the top of this script, then re-run."
    exit 1
fi

echo "==> Notarizing app"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$APP_ZIP"
ditto -c -k --keepParent "$APP" "$APP_ZIP"

echo "==> Notarizing CLI"
ditto -c -k --keepParent dist/ndi-region "$CLI_ZIP"
xcrun notarytool submit "$CLI_ZIP" --keychain-profile "$PROFILE" --wait
# Flat binaries can't be stapled; Gatekeeper verifies them online.

echo "==> Gatekeeper check"
spctl -a -vv "$APP" || true

echo ""
echo "Release artifacts:"
echo "  $APP_ZIP"
echo "  $CLI_ZIP"
