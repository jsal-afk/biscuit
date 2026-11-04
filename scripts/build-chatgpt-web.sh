#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${BISCUIT_BUILD_DIR:-$ROOT/build}}"
case "$OUT" in
  /*) ;;
  *) OUT="$PWD/$OUT" ;;
esac
APP="$OUT/biscuit.app"
WEB_SOURCE="$ROOT/upstream/web-provider"
UPSTREAM_SOURCE="$ROOT/upstream/codex-chatgpt-web"
DEPENDENCY_ROOT="$ROOT/upstream"
RESOURCE="$APP/Contents/Resources/ChatGPTWeb"

# The emitted Node/Electron driver reaches these six runtime packages. Keep
# executable JS, both module formats, locales and deferred Playwright assets
# byte-for-byte; only remove unused packages and development/alternate inputs.
finalize_runtime() {
  rm -rf "$RESOURCE/node_modules/ajv" "$RESOURCE/node_modules/ajv-formats" \
    "$RESOURCE/node_modules/fast-deep-equal" "$RESOURCE/node_modules/fast-uri" \
    "$RESOURCE/node_modules/json-schema-traverse" "$RESOURCE/node_modules/require-from-string"
  # get_encoding uses the original full WASM, not the separate encoder/lite copies.
  rm -rf "$RESOURCE/node_modules/tiktoken/encoders" "$RESOURCE/node_modules/tiktoken/lite" \
    "$RESOURCE/node_modules/@mixmark-io/domino/test" "$RESOURCE/node_modules/@mixmark-io/domino/.yarn" \
    "$RESOURCE/node_modules/zod/src" "$RESOURCE/node_modules/playwright-core/types"
  find "$RESOURCE/node_modules" -type f \
    \( -name '*.d.ts' -o -name '*.d.cts' -o -name '*.d.mts' \) -delete
  rm -rf "$RESOURCE/Notices"
  cp -R "$ROOT/Resources/ChatGPTWeb/Notices" "$RESOURCE/Notices"
}

PREBUILT_RESOURCE="${BISCUIT_PREBUILT_CHATGPT_WEB:-}"
if [[ -n "$PREBUILT_RESOURCE" ]]; then
  for FILE in "$PREBUILT_RESOURCE/electron-main.cjs" \
    "$PREBUILT_RESOURCE/electron-driver.cjs" \
    "$PREBUILT_RESOURCE/Notices/THIRD-PARTY-NOTICES.txt"; do
    if [[ ! -f "$FILE" ]]; then
      printf 'Caller-selected prebuilt ChatGPT Web resource is incomplete.\n' >&2
      exit 1
    fi
  done
  if [[ -e "$RESOURCE" || -L "$RESOURCE" ]]; then
    printf 'Refusing to replace an existing ChatGPT Web resource: %s\n' "$RESOURCE" >&2
    exit 1
  fi
  mkdir -p "$APP/Contents/Resources"
  cp -R "$PREBUILT_RESOURCE" "$RESOURCE"
  finalize_runtime
  printf 'Reused the caller-selected complete ChatGPT Web resource in %s\n' "$RESOURCE"
  exit 0
fi
BUN="${BUN_EXECUTABLE:-$(command -v bun || true)}"
if [[ -z "$BUN" || ! -x "$BUN" ]]; then
  printf 'Bun 1.4.0 is required only to build the ChatGPT Web Electron bridge; set BUN_EXECUTABLE to a verified Bun 1.4.0 binary.\n' >&2
  exit 1
fi
if [[ "$("$BUN" --version)" != 1.4.0 ]]; then
  printf 'ChatGPT Web bridge builds require exactly Bun 1.4.0.\n' >&2
  exit 1
fi
for FILE in "$DEPENDENCY_ROOT/package.json" "$DEPENDENCY_ROOT/bun.lock" "$WEB_SOURCE/electron-main.cjs" "$WEB_SOURCE/electron-driver.ts" "$WEB_SOURCE/error-categories.ts" "$WEB_SOURCE/request-lifecycle.ts" "$UPSTREAM_SOURCE/LICENSE" "$UPSTREAM_SOURCE/launcher/electron/chatgpt-auth-session.cjs" "$ROOT/Resources/ChatGPTWeb/Notices/THIRD-PARTY-NOTICES.txt"; do
  if [[ ! -f "$FILE" ]]; then
    printf 'Required ChatGPT Web source or notice is missing: %s\n' "$FILE" >&2
    exit 1
  fi
done
if [[ ! -d "$UPSTREAM_SOURCE/src" ]]; then
  printf 'The selected pinned browser-only upstream source closure is missing.\n' >&2
  exit 1
fi
mkdir -p "$APP/Contents/Resources"
STAGE="$(mktemp -d "${TMPDIR:-/tmp/}biscuit-chatgpt-web-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
STAGE_ROOT="$STAGE/upstream"
STAGE_WEB="$STAGE_ROOT/web-provider"
STAGE_UPSTREAM="$STAGE_ROOT/codex-chatgpt-web"
mkdir -p "$STAGE_WEB" "$STAGE_UPSTREAM"
cp "$DEPENDENCY_ROOT/package.json" "$DEPENDENCY_ROOT/bun.lock" "$STAGE_ROOT/"
cp "$WEB_SOURCE/electron-main.cjs" "$WEB_SOURCE/electron-driver.ts" "$WEB_SOURCE/error-categories.ts" "$WEB_SOURCE/request-lifecycle.ts" "$STAGE_WEB/"
cp -R "$UPSTREAM_SOURCE/src" "$STAGE_UPSTREAM/src"
cp "$UPSTREAM_SOURCE/LICENSE" "$STAGE_UPSTREAM/LICENSE"
mkdir -p "$STAGE_UPSTREAM/launcher/electron"
cp "$UPSTREAM_SOURCE/launcher/electron/chatgpt-auth-session.cjs" "$STAGE_UPSTREAM/launcher/electron/"
(
  cd "$STAGE_ROOT"
  "$BUN" install --frozen-lockfile --ignore-scripts --production --no-progress
)
rm -rf "$RESOURCE"
mkdir -p "$RESOURCE/node_modules/@mixmark-io"
(
  cd "$STAGE_ROOT"
  "$BUN" build web-provider/electron-driver.ts --target=node --format=cjs --packages=external --reject-unresolved --outfile "$RESOURCE/electron-driver.cjs"
)
cp "$WEB_SOURCE/electron-main.cjs" "$RESOURCE/electron-main.cjs"
for PACKAGE in \
  '@mixmark-io/domino' \
  playwright-core \
  tiktoken \
  turndown \
  turndown-plugin-gfm \
  zod; do
  SOURCE_PACKAGE="$(cd "$STAGE_ROOT/node_modules/$PACKAGE" && pwd -P)"
  mkdir -p "$RESOURCE/node_modules/$(dirname "$PACKAGE")"
  cp -R "$SOURCE_PACKAGE" "$RESOURCE/node_modules/$PACKAGE"
done
finalize_runtime
printf 'Built the pinned ChatGPT Web Electron bridge and its locked six-package runtime closure in %s\n' "$RESOURCE"
