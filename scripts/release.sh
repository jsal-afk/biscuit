#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=1.0.1
BUILD_DIR="${BISCUIT_BUILD_DIR:-$ROOT/build}"
RELEASE_DIR="${BISCUIT_RELEASE_DIR:-$ROOT/dist}"
PUBLIC_CONTENT_DIR="${BISCUIT_PUBLIC_CONTENT_DIR:-$ROOT}"
case "$BUILD_DIR" in
  /*) ;;
  *) BUILD_DIR="$PWD/$BUILD_DIR" ;;
esac
case "$RELEASE_DIR" in
  /*) ;;
  *) RELEASE_DIR="$PWD/$RELEASE_DIR" ;;
esac
APP="$BUILD_DIR/biscuit.app"
APP_ZIP="$RELEASE_DIR/biscuit-$VERSION-macos-universal.zip"
APP_DMG="$RELEASE_DIR/biscuit-$VERSION-macos-universal.dmg"
SOURCE_ZIP="$RELEASE_DIR/biscuit-$VERSION-source.zip"
if [[ -e "$APP" || -L "$APP" ]]; then
  printf 'Refusing to replace existing build output: %s\n' "$APP" >&2
  exit 1
fi
if [[ -e "$APP_ZIP" || -L "$APP_ZIP" || -e "$APP_DMG" || -L "$APP_DMG" || -e "$SOURCE_ZIP" || -L "$SOURCE_ZIP" ]]; then
  printf 'Refusing to replace existing release archive(s) under %s\n' "$RELEASE_DIR" >&2
  exit 1
fi
mkdir -p "$BUILD_DIR" "$RELEASE_DIR"
BISCUIT_SMOKE_BUILD=0 BISCUIT_BUILD_DIR="$BUILD_DIR" "$ROOT/scripts/build.sh"
ARCHIVE_FLAGS=(--norsrc --noextattr --noqtn --noacl --nopersistRootless)
ditto -c -k "${ARCHIVE_FLAGS[@]}" --keepParent "$APP" "$APP_ZIP"
STAGE="$(mktemp -d "${TMPDIR:-/tmp/}biscuit-release-source.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
INSTALLER="$STAGE/installer"
mkdir -p "$INSTALLER"
ditto "$APP" "$INSTALLER/biscuit.app"
ln -s /Applications "$INSTALLER/Applications"
hdiutil create -volname biscuit -srcfolder "$INSTALLER" -format UDZO "$APP_DMG"
SRC="$STAGE/biscuit-$VERSION"
mkdir -p "$SRC/scripts" "$SRC/upstream/codex-chatgpt-web/launcher/electron" \
  "$SRC/upstream/web-provider/tests"
# Deliberate allowlist: never ship downloaded apps, runtimes, private analysis or sessions.
cp -R "$ROOT/Sources" "$ROOT/Resources" "$ROOT/Tests" "$SRC/"
rm -f "$SRC/Sources/Biscuit/NativeAccountQABrowserOpener.swift"
cp -R "$ROOT/upstream/codex-chatgpt-web/src" "$SRC/upstream/codex-chatgpt-web/"
cp "$ROOT/upstream/codex-chatgpt-web/LICENSE" "$ROOT/upstream/codex-chatgpt-web/SOURCE-PIN.txt" "$SRC/upstream/codex-chatgpt-web/"
cp "$ROOT/upstream/codex-chatgpt-web/launcher/electron/chatgpt-auth-session.cjs" "$SRC/upstream/codex-chatgpt-web/launcher/electron/"
cp "$ROOT/upstream/package.json" "$ROOT/upstream/bun.lock" "$SRC/upstream/"
cp "$ROOT/upstream/web-provider/electron-main.cjs" "$ROOT/upstream/web-provider/electron-driver.ts" \
  "$ROOT/upstream/web-provider/error-categories.ts" "$ROOT/upstream/web-provider/request-lifecycle.ts" \
  "$ROOT/upstream/web-provider/run-turn.ts" "$SRC/upstream/web-provider/"
cp "$ROOT/upstream/web-provider/tests/protocol.test.ts" \
  "$ROOT/upstream/web-provider/tests/electron-driver-contract.test.ts" \
  "$ROOT/upstream/web-provider/tests/packaged-dependencies.test.ts" "$SRC/upstream/web-provider/tests/"
cp "$ROOT/LICENSE" "$SRC/"
cp "$PUBLIC_CONTENT_DIR/README.md" "$PUBLIC_CONTENT_DIR/README.ko.md" \
  "$PUBLIC_CONTENT_DIR/PRIVACY.md" "$PUBLIC_CONTENT_DIR/CHANGELOG.md" \
  "$PUBLIC_CONTENT_DIR/.gitignore" "$SRC/"
mkdir -p "$SRC/docs/images"
cp "$PUBLIC_CONTENT_DIR/docs/images/translation.png" "$PUBLIC_CONTENT_DIR/docs/images/language-learning.png" \
  "$PUBLIC_CONTENT_DIR/docs/images/image-editor.png" "$SRC/docs/images/"
cp "$ROOT/scripts/build-chatgpt-web.sh" "$ROOT/scripts/build.sh" "$ROOT/scripts/smoke-chatgpt-web.sh" \
  "$ROOT/scripts/smoke.sh" "$ROOT/scripts/measure.sh" "$ROOT/scripts/make-icon.swift" "$ROOT/scripts/release.sh" "$SRC/scripts/"
ditto -c -k "${ARCHIVE_FLAGS[@]}" --keepParent "$SRC" "$SOURCE_ZIP"
shasum -a 256 "$APP_ZIP" "$APP_DMG" "$SOURCE_ZIP"
du -sk "$APP" "$APP_ZIP" "$APP_DMG" "$SOURCE_ZIP"
