#!/bin/bash
# Builds Teleprompter.app and installs it into /Applications. Requires only the Xcode
# command-line tools (swiftc). Run ./test.sh for the pacing-engine tests.
set -euo pipefail
cd "$(dirname "$0")"
APP=Teleprompter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"  # regenerate with: swift Tools/make-icon.swift
swiftc -swift-version 5 -target arm64-apple-macos26.0 -O Sources/*.swift -o "$APP/Contents/MacOS/Teleprompter"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Teleprompter</string>
    <key>CFBundleIdentifier</key><string>local.teleprompter</string>
    <key>CFBundleExecutable</key><string>Teleprompter</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSMicrophoneUsageDescription</key><string>Teleprompter listens to your voice so the script can follow along as you read. Audio stays on your Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Teleprompter uses on-device speech recognition to keep its place in your script.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Ad-hoc signing normally identifies the app by a hash of this exact build,
# so macOS forgets Microphone/Speech permission after every rebuild. A
# designated requirement based on the bundle identifier keeps the identity
# stable across rebuilds, so permission is granted once.
codesign --force --sign - --requirements '=designated => identifier "local.teleprompter"' "$APP" >/dev/null

# Install into /Applications, replacing the old copy (quit it first if running).
osascript -e 'quit app "Teleprompter"' 2>/dev/null || true
rm -rf "/Applications/$APP"
mv "$APP" /Applications/
echo "Installed /Applications/$APP"
