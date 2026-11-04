#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${BISCUIT_BUILD_DIR:-$ROOT/build}"
MODULE_CACHE_DIR="${BISCUIT_MODULE_CACHE_DIR:-$OUT/module-cache}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
APP="$OUT/biscuit.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/objects" "$MODULE_CACHE_DIR"
"$ROOT/scripts/build-chatgpt-web.sh" "$OUT"
EXTRA_FLAGS=()
EXTRA_SOURCES=()
if [[ "${BISCUIT_SMOKE_BUILD:-0}" == 1 ]]; then
  EXTRA_FLAGS=(-D BISCUIT_SMOKE)
  EXTRA_SOURCES=("$ROOT"/Tests/*.swift)
  mkdir -p "$APP/Contents/Resources/Fixtures"
  cp -R "$ROOT/Tests/Fixtures/ImageEditor" "$APP/Contents/Resources/Fixtures/"
fi
for ARCH in arm64 x86_64; do
  mkdir -p "$MODULE_CACHE_DIR/$ARCH"
  xcrun swiftc -swift-version 5 -O -whole-module-optimization -sdk "$SDK" \
    -target "$ARCH-apple-macos14.0" -module-name Biscuit -file-prefix-map "$ROOT=." -debug-prefix-map "$ROOT=." \
    -module-cache-path "$MODULE_CACHE_DIR/$ARCH" \
    -framework AppKit -framework SwiftUI -framework Vision -framework Carbon -framework ScreenCaptureKit -framework ImageIO \
    -framework NaturalLanguage -framework ServiceManagement -framework Security -framework CryptoKit -framework Network -Xlinker -weak_framework -Xlinker Translation \
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} "$ROOT"/Sources/Biscuit/*.swift ${EXTRA_SOURCES[@]+"${EXTRA_SOURCES[@]}"} -o "$OUT/objects/biscuit-$ARCH"
done
lipo -create "$OUT/objects/biscuit-arm64" "$OUT/objects/biscuit-x86_64" -output "$APP/Contents/MacOS/biscuit"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp -R "$ROOT/Resources/Notices" "$APP/Contents/Resources/"
cp "$ROOT/Resources/biscuit.icns" "$APP/Contents/Resources/biscuit.icns"
cp -R "$ROOT"/Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - --identifier org.biscuit.app "$APP"
codesign --verify --strict "$APP"
printf '\nBuilt %s\n' "$APP"
lipo -info "$APP/Contents/MacOS/biscuit"
