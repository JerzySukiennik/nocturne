#!/bin/bash
# Nocturne: builds, bundles and signs Nocturne.app. Usage: ./build.sh [install|dev]. dev makes a separate test copy that never touches /Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
SCRATCH="Niepotrzebne/build"
nice -n 10 swift build -c release --scratch-path "$SCRATCH" -j 4
BIN="$SCRATCH/release"
ICONS="Niepotrzebne/icon"
if [ ! -f "$ICONS/AppIcon.icns" ]; then
  mkdir -p "$ICONS"
  swift Niepotrzebne/tools/make-icon.swift "$ICONS/AppIcon.iconset"
  iconutil -c icns "$ICONS/AppIcon.iconset" -o "$ICONS/AppIcon.icns"
fi
NAME="Nocturne"
BUNDLE="fun.gzowo.nocturne"
if [ "${1:-}" = "dev" ]; then
  NAME="Nocturne Dev"
  BUNDLE="fun.gzowo.nocturne.dev"
fi
OUT="Niepotrzebne/$NAME.app"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN/Nocturne" "$OUT/Contents/MacOS/Nocturne.new"
mv -f "$OUT/Contents/MacOS/Nocturne.new" "$OUT/Contents/MacOS/Nocturne"
cp "$ICONS/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE</string>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleExecutable</key><string>Nocturne</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Gzowo Labs</string>
</dict></plist>
PLIST
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
codesign --force --sign "${IDENTITY:--}" "$OUT" 2>/dev/null
MODELS="$HOME/Library/Application Support/Nocturne/Models"
for MODEL in DepthAnythingV2SmallF16 LaMa; do
  if [ ! -d "$MODELS/$MODEL.mlmodelc" ] && [ -d "Niepotrzebne/models/$MODEL.mlmodelc" ]; then
    mkdir -p "$MODELS"
    cp -R "Niepotrzebne/models/$MODEL.mlmodelc" "$MODELS/"
  fi
done
if [ "${1:-}" = "install" ]; then
  rm -rf "/Applications/Nocturne.app"
  cp -R "$OUT" "/Applications/Nocturne.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Nocturne.app" >/dev/null 2>&1 || true
  echo "/Applications/Nocturne.app"
else
  echo "$OUT"
fi
