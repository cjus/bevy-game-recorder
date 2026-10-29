#!/bin/bash
# Build a local bundle with an explicit privacy identity. Does not launch,
# install, request permissions, or change macOS settings.
set -euo pipefail
cd "$(dirname "$0")/.."
"${CARGO:-cargo}" build --features demo --example demo
bundle="$PWD/target/BevyRecorderDemo.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/assets"
cp target/debug/examples/demo "$bundle/Contents/MacOS/bevy-recorder-demo"
cp assets/tone.wav "$bundle/Contents/Resources/assets/tone.wav"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.cjus.bevy-game-recorder-demo</string>
<key>CFBundleName</key><string>Bevy Recorder Demo</string>
<key>CFBundleDisplayName</key><string>Bevy Recorder Demo</string>
<key>CFBundleExecutable</key><string>bevy-recorder-demo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier dev.cjus.bevy-game-recorder-demo "$bundle"
codesign --verify --strict "$bundle"
printf 'Built (not launched): %s\n' "$bundle"
