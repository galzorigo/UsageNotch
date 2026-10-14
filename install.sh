#!/bin/sh
# Builds Brow and installs it in /Applications, replacing any older copy.
# Run it again whenever you've changed the code and want the installed app updated.
set -e
cd "$(dirname "$0")"
BUILD_DIR="$(mktemp -d)"

echo "Building…"
# Make Xcode's build system re-list the source folder, so newly added files are always included
touch Brow.xcodeproj/project.pbxproj
xcodebuild -project Brow.xcodeproj -target Brow -configuration Release \
  SYMROOT="$BUILD_DIR" build -quiet

echo "Installing to /Applications…"
pkill -x Brow 2>/dev/null || true
# The app used to be called UsageNotch: remove that copy so you don't end up with two
pkill -x UsageNotch 2>/dev/null || true
rm -rf /Applications/UsageNotch.app
sleep 1
rm -rf /Applications/Brow.app
cp -R "$BUILD_DIR/Release/Brow.app" /Applications/

# Sign with your own local certificate if you've made one (see README). A stable signature means
# macOS remembers permissions like Accessibility between updates. Without it, the app stays
# signed to run locally and those permissions need switching on again after each update.
if security find-identity -p codesigning 2>/dev/null | grep -q "Brow Local Signing"; then
  codesign --force --deep --options runtime --sign "Brow Local Signing" /Applications/Brow.app
  echo "Signed with Brow Local Signing."
fi
rm -rf "$BUILD_DIR"

open /Applications/Brow.app
echo "Done. Brow is running from /Applications."
