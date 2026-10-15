#!/bin/bash
# Builds ADB Finder and installs it into /Applications.
#
#   ./build.command          build and install (relaunches the app if it was running)
#   ./build.command --zip    also write dist/ADB-Finder-v<version>.zip for a release
#
# INSTALL_DIR=~/Applications ./build.command installs somewhere else.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/ADBFinder/main.m"
NAME="ADB Finder"
BUNDLE_ID="io.github.kreal-exe.adbfinder"
VERSION="1.0.0"
DEST="${INSTALL_DIR:-/Applications}"
ZIP=0
[ "${1:-}" = "--zip" ] && ZIP=1

SDK="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"

# Build outside the project: synced folders (iCloud Documents) attach extended
# attributes to everything, and codesign refuses bundles that carry them.
OUT="$(mktemp -d -t adbfinder)"
trap 'rm -rf "$OUT"' EXIT
APP="$OUT/$NAME.app"
ICONSET="$OUT/AppIcon.iconset"
ICNS="$OUT/AppIcon.icns"

echo "Building $NAME $VERSION (native Cocoa)..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"

if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [ -f "$ROOT/AppIcon.png" ]; then
  for spec in \
    "16 icon_16x16.png" "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
    size="${spec%% *}"
    name="${spec#* }"
    sips -z "$size" "$size" "$ROOT/AppIcon.png" --out "$ICONSET/$name" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
  cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
fi

"$CLANG" -fobjc-arc -Wall -Wextra -O2 -mmacosx-version-min=12.0 -arch arm64 -arch x86_64 -isysroot "$SDK" \
  -framework Cocoa -framework Quartz -framework UniformTypeIdentifiers -framework AVFoundation -framework CoreMedia \
  "$SRC" -o "$APP/Contents/MacOS/ADBFinder"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>ADBFinder</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHumanReadableCopyright</key><string>MIT License</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>ADB Finder connects to Android phones over Wi-Fi (wireless debugging) on your local network.</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleDocumentTypes</key><array><dict>
  <key>CFBundleTypeName</key><string>Any file or folder</string>
  <key>CFBundleTypeRole</key><string>Viewer</string>
  <key>LSHandlerRank</key><string>None</string>
  <key>LSItemContentTypes</key><array><string>public.item</string><string>public.folder</string></array>
</dict></array>
</dict></plist>
PLIST

# Ad-hoc signature: required on Apple Silicon, and keeps the bundle intact in a zip.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
codesign --verify --strict "$APP"

if [ "$ZIP" = 1 ]; then
  mkdir -p "$ROOT/dist"
  ZIPFILE="$ROOT/dist/ADB-Finder-v$VERSION.zip"
  rm -f "$ZIPFILE"
  ditto -c -k --norsrc --keepParent "$APP" "$ZIPFILE"
  echo "Release zip: $ZIPFILE"
fi

# Quit a running copy first; the app asks before stopping a transfer, and if the
# user keeps it running we leave the installed version alone.
WAS_RUNNING=0
if pgrep -f "$DEST/$NAME.app/Contents/MacOS/" >/dev/null 2>&1; then
  WAS_RUNNING=1
  echo "Quitting the running $NAME..."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    pgrep -f "$DEST/$NAME.app/Contents/MacOS/" >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -f "$DEST/$NAME.app/Contents/MacOS/" >/dev/null 2>&1; then
    echo "$NAME is still running (a transfer may be in progress). Quit it and run the build again." >&2
    exit 1
  fi
fi

mkdir -p "$DEST"
rm -rf "$DEST/$NAME.app"
ditto "$APP" "$DEST/$NAME.app"
echo "Installed: $DEST/$NAME.app"

[ "$WAS_RUNNING" = 1 ] && open "$DEST/$NAME.app"
exit 0
