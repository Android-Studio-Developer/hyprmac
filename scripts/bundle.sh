#!/bin/sh
# Builds build/Hyprmac.app (menu-bar agent, no Dock icon) and build/hyprmacctl.
# Accessibility permission is tied to the app's signature: an ad-hoc signed rebuild
# may need the permission toggled off/on again in System Settings.
set -e
cd "$(dirname "$0")/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/Hyprmac.app
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/HyprmacCore/Defaults.swift)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/hyprmac" "$APP/Contents/MacOS/hyprmac"
cp "$BIN/hyprmacctl" build/hyprmacctl
cp "$BIN/hyprmacctl" "$APP/Contents/MacOS/hyprmacctl"  # used by the `hyprctl` stand-in
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.hyprmac.Hyprmac</string>
  <key>CFBundleName</key><string>Hyprmac</string>
  <key>CFBundleExecutable</key><string>hyprmac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
codesign --force --sign - build/hyprmacctl
echo "built $APP and build/hyprmacctl ($VERSION)"
