#!/bin/sh
set -eu
cd "$(dirname "$0")"

app="build/DockNap.app"
mkdir -p build/ModuleCache "$app/Contents/MacOS" "$app/Contents/Resources"

xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path build/ModuleCache Sources/*.swift \
    -o "$app/Contents/MacOS/DockNap"

plutil -lint Resources/Info.plist
cp -X Resources/Info.plist "$app/Contents/Info.plist"
cp -X Resources/DockNap.icns "$app/Contents/Resources/DockNap.icns"
cp -X Resources/UnmountComplete.wav "$app/Contents/Resources/UnmountComplete.wav"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
echo "Built $app"
