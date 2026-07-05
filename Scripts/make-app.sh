#!/bin/bash
# Assemble NDI Region.app from the SPM release build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="dist/NDI Region.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NDIRegion "$APP/Contents/MacOS/NDI Region"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Assets/DAWG.png "$APP/Contents/Resources/DAWG.png"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>NDI Region</string>
    <key>CFBundleDisplayName</key><string>NDI Region</string>
    <key>CFBundleIdentifier</key><string>uk.co.christhoms.ndiregion</string>
    <key>CFBundleExecutable</key><string>NDI Region</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"
