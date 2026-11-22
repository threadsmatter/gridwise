#!/bin/bash
# Builds Gridwise.app in this folder from the Swift package. Needs Xcode or the Command Line Tools
# (xcode-select --install). Run it again after pulling changes.
#   ./build.sh            build Gridwise.app here
#   ./build.sh install    also copy it to ~/Applications and open it
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/Gridwise.app"
cd "$HERE"
swift build -c release
rm -rf "$APP" "$HERE/.build/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Gridwise" "$APP/Contents/MacOS/Gridwise"
swift "$HERE/make_icon.swift" "$HERE/.build/AppIcon.iconset"
iconutil -c icns "$HERE/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
VERSION="$(cat "$HERE/VERSION" 2>/dev/null || echo 0.1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Gridwise</string>
  <key>CFBundleDisplayName</key><string>Gridwise</string>
  <key>CFBundleIdentifier</key><string>io.github.gridwise.mac</string>
  <key>CFBundleExecutable</key><string>Gridwise</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Gridwise looks for solar inverters on your home network so it can tell you what it found. It only listens for their replies and never changes their settings.</string>
</dict>
</plist>
PLIST
# Signed with your Apple Development certificate if Xcode has one, so rebuilds keep the same identity and
# the Keychain stops asking each time. Otherwise ad-hoc: enough to run on the Mac that built it, but the
# Keychain asks once per build. A copy given to someone else needs "Open Anyway" in System Settings >
# Privacy & Security the first time (see README).
ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -n "$ID" ] && codesign --force --sign "$ID" "$APP" 2>/dev/null; then
  echo "Signed with your Apple Development certificate"
else
  codesign --force --sign - "$APP"
  echo "Signed ad-hoc"
fi
echo "Built: $APP"
if [ "${1:-}" = "install" ]; then
  mkdir -p "$HOME/Applications"
  osascript -e 'tell application id "io.github.gridwise.mac" to quit' >/dev/null 2>&1 || true   # let a running copy close first
  for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Gridwise >/dev/null || break; sleep 0.5; done
  rm -rf "$HOME/Applications/Gridwise.app" && cp -R "$APP" "$HOME/Applications/Gridwise.app"
  open "$HOME/Applications/Gridwise.app"
  echo "Installed and opened: $HOME/Applications/Gridwise.app"
fi
