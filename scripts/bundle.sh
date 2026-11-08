#!/bin/bash
# Builds a release Paella.app into dist/ (ad-hoc signed, no sandbox).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUNDLE_ID="com.guzman.Paella"
APP="dist/Paella.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Paella"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Paella"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>es</string><string>de</string><string>fr</string><string>it</string><string>ja</string><string>pt-BR</string><string>zh-Hans</string></array>
    <key>CFBundleExecutable</key><string>Paella</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>Paella</string>
    <key>CFBundleDisplayName</key><string>Paella</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local build</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP"
echo "Built $APP"
