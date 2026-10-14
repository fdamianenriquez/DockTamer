#!/bin/bash
# Builds DockTamer.app (universal: arm64 + x86_64) and packages it into DockTamer.dmg
# using only the Xcode Command Line Tools (no full Xcode required).
# The app is ad-hoc signed; it is not signed with a Developer ID nor notarized.
#
# Usage: scripts/build-dmg.sh [output_dmg]   (default: ./DockTamer.dmg)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DMG="${1:-$ROOT/DockTamer.dmg}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Read version and settings from project.yml so there is a single source of truth.
yml_value() { grep -E "^\s*$1:" "$ROOT/project.yml" | head -1 | sed -E 's/^[^:]+:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'; }
VERSION="$(yml_value INFOPLIST_KEY_CFBundleShortVersionString)"
BUILD="$(yml_value INFOPLIST_KEY_CFBundleVersion)"
MIN_OS="$(yml_value deploymentTarget)"
USAGE="$(yml_value INFOPLIST_KEY_NSAccessibilityUsageDescription)"

APP="$WORK/stage/DockTamer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling DockTamer $VERSION ($BUILD), macOS $MIN_OS+"
# The x86_64 link prints "ignoring file ... libswiftCompatibilityPacks.a: fat file missing arch 'x86_64'".
# That library only back-deploys Swift parameter packs, which DockTamer doesn't use, so it's harmless.
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN_OS" \
    -framework Cocoa -framework ApplicationServices \
    -o "$WORK/DockTamer-$arch" "$ROOT"/DockTamer/Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/DockTamer" "$WORK"/DockTamer-arm64 "$WORK"/DockTamer-x86_64

echo "==> Building resources"
ICONSET="$WORK/AppIcon.iconset"
ICONS="$ROOT/DockTamer/Assets.xcassets/AppIcon.appiconset"
mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  cp "$ICONS/icon_$s.png" "$ICONSET/icon_${s}x${s}.png"
  if [ -f "$ICONS/icon_$((s * 2)).png" ]; then
    cp "$ICONS/icon_$((s * 2)).png" "$ICONSET/icon_${s}x${s}@2x.png"
  fi
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT"/DockTamer/Resources/*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>DockTamer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.docktamer.DockTamer</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>DockTamer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><true/>
  <key>NSAccessibilityUsageDescription</key><string>$USAGE</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Ad-hoc signing"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "==> Creating DMG"
ln -s /Applications "$WORK/stage/Applications"
rm -f "$OUT_DMG"
hdiutil create -quiet -volname DockTamer -srcfolder "$WORK/stage" -fs APFS -format UDZO "$OUT_DMG"

echo "==> Done: $OUT_DMG"
