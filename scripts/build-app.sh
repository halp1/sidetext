#!/bin/bash
# Builds SideText.app into ./build without Xcode project files or SwiftPM.
# Usage: scripts/build-app.sh [--install]   (--install copies the app to /Applications)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/SideText.app"
MIN_OS="13.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/obj"

SOURCES=("$ROOT"/Sources/SideText/*.swift)

for ARCH in arm64 x86_64; do
  xcrun swiftc -O -whole-module-optimization \
    -sdk "$SDK" -target "$ARCH-apple-macos$MIN_OS" \
    -module-name SideText -module-cache-path "$BUILD/ModuleCache" \
    -o "$BUILD/obj/SideText-$ARCH" \
    "${SOURCES[@]}"
done
lipo -create "$BUILD/obj/SideText-arm64" "$BUILD/obj/SideText-x86_64" -output "$APP/Contents/MacOS/SideText"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc sign with the sandbox entitlements (set SIGN_IDENTITY to use a real certificate).
codesign --force --options runtime --timestamp=none \
  --entitlements "$ROOT/Resources/SideText.entitlements" \
  --sign "${SIGN_IDENTITY:--}" "$APP"

echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/SideText.app
  cp -R "$APP" /Applications/SideText.app
  echo "Installed /Applications/SideText.app"
fi
