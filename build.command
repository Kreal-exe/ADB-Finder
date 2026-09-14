#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/AndroidDrop/main.m"
APP="$ROOT/Android Drop.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
OUT="$ROOT/.build"
ICONSET="$OUT/AndroidDrop.iconset"

echo "Building Android Drop 16.0 (native Cocoa)..."
rm -rf "$OUT" "$APP" "$ROOT/AndroidDrop.icns"
mkdir -p "$OUT/$APP/Contents/MacOS" "$OUT/$APP/Contents/Resources" "$ICONSET"

if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [ -f "$ROOT/AndroidDropIcon.png" ]; then
  for spec in \
    "16 icon_16x16.png" "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
    size="${spec%% *}"
    name="${spec#* }"
    sips -z "$size" "$size" "$ROOT/AndroidDropIcon.png" --out "$ICONSET/$name" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ROOT/AndroidDrop.icns"
fi

"$CLANG" -fobjc-arc -Wall -Wextra -O2 -mmacosx-version-min=12.0 -isysroot "$SDK" -framework Cocoa "$SRC" -o "$OUT/$APP/Contents/MacOS/AndroidDrop"
cat > "$OUT/$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Android Drop</string>
<key>CFBundleDisplayName</key><string>Android Drop</string>
<key>CFBundleIdentifier</key><string>local.androiddrop.native</string>
<key>CFBundleExecutable</key><string>AndroidDrop</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>17.0</string>
<key>CFBundleShortVersionString</key><string>17.0</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AndroidDrop.icns</string>
</dict></plist>
PLIST
[ -f "$ROOT/AndroidDrop.icns" ] && cp "$ROOT/AndroidDrop.icns" "$OUT/$APP/Contents/Resources/AndroidDrop.icns"
cp -R "$OUT/$APP" "$APP"
rm -rf "$OUT"
echo "Build successful:"
echo "$APP"
