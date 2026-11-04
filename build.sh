#!/bin/zsh
# Builds NotchPad.app and installs it to ~/Applications. Needs only Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/NotchPad.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NotchPad" "$APP/Contents/MacOS/NotchPad"
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NotchPad</string>
  <key>CFBundleDisplayName</key><string>NotchPad</string>
  <key>CFBundleIdentifier</key><string>com.naman.notchpad</string>
  <key>CFBundleExecutable</key><string>NotchPad</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.naman.notchpad</string>
    <key>CFBundleURLSchemes</key><array><string>notchpad</string></array>
  </dict></array>
  <key>NSAudioCaptureUsageDescription</key><string>NotchPad measures how loud the music is so the visualizer moves with it. Nothing is recorded or saved.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>NotchPad shows your events and lets you add new ones from the notch.</string>
  <key>NSCalendarsUsageDescription</key><string>NotchPad shows your events and lets you add new ones from the notch.</string>
</dict></plist>
PLIST

# Sign with the stable local identity (scripts/setup-signing.sh) so macOS keeps NotchPad's permissions
# (calendar, notifications, …) across rebuilds; fall back to ad-hoc if it hasn't been set up.
KC="$HOME/Library/Keychains/notchpad-signing.keychain-db"
PASSFILE="$HOME/Library/Application Support/NotchPad/signing-keychain-password"
if [[ -f "$KC" && -f "$PASSFILE" ]] && security unlock-keychain -p "$(cat "$PASSFILE")" "$KC" 2>/dev/null; then
  codesign --force --deep --sign "NotchPad Local Signing" --keychain "$KC" "$APP"
else
  echo "warning: no signing identity (run scripts/setup-signing.sh); using ad-hoc signature" >&2
  codesign --force --deep --sign - "$APP"
fi
mkdir -p ~/Applications
rm -rf ~/Applications/NotchPad.app
cp -R "$APP" ~/Applications/NotchPad.app
echo "Installed ~/Applications/NotchPad.app"
