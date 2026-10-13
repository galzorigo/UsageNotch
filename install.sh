#!/bin/sh
# Builds UsageNotch and installs it in /Applications, replacing any older copy.
# Run it again whenever you've changed the code and want the installed app updated.
set -e
cd "$(dirname "$0")"
BUILD_DIR="$(mktemp -d)"

echo "Building…"
xcodebuild -project UsageNotch.xcodeproj -target UsageNotch -configuration Release \
  SYMROOT="$BUILD_DIR" build -quiet

echo "Installing to /Applications…"
pkill -x UsageNotch 2>/dev/null || true
sleep 1
rm -rf /Applications/UsageNotch.app
cp -R "$BUILD_DIR/Release/UsageNotch.app" /Applications/
rm -rf "$BUILD_DIR"

open /Applications/UsageNotch.app
echo "Done. UsageNotch is running from /Applications."
