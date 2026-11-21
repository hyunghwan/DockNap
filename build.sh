#!/bin/sh
set -eu
cd "$(dirname "$0")"

mkdir -p build/ModuleCache
stage=$(mktemp -d build/.bundle.XXXXXX)
trap 'rm -rf "$stage"' EXIT
app="$stage/DockNap.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path build/ModuleCache Sources/*.swift \
    -o "$app/Contents/MacOS/DockNap"

plutil -lint Resources/Info.plist
cp -X Resources/Info.plist "$app/Contents/Info.plist"
cp -X Resources/DockNap.icns "$app/Contents/Resources/DockNap.icns"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
if [ -e build/DockNap.app ]; then mv build/DockNap.app "$stage/previous.app"; fi
mv "$app" build/DockNap.app
echo "Built build/DockNap.app"
