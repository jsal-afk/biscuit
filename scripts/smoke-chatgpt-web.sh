#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-${BISCUIT_BUILD_DIR:-$ROOT/build}/biscuit.app}"
case "$APP" in
  /*) ;;
  *) APP="$PWD/$APP" ;;
esac
RESOURCE="$APP/Contents/Resources/ChatGPTWeb"
BUN="${BUN_EXECUTABLE:-$(command -v bun || true)}"
if [[ -z "$BUN" ]]; then
  printf 'ChatGPT Web offline smoke requires externally supplied Bun 1.4.0; set BUN_EXECUTABLE.\n' >&2
  exit 1
fi
case "$BUN" in
  /*) ;;
  *) BUN="$PWD/$BUN" ;;
esac
if [[ ! -x "$BUN" || "$("$BUN" --version)" != 1.4.0 ]]; then
  printf 'ChatGPT Web offline smoke requires exactly Bun 1.4.0.\n' >&2
  exit 1
fi
for FILE in "$RESOURCE/electron-main.cjs" "$RESOURCE/electron-driver.cjs" \
  "$RESOURCE/node_modules/zod/package.json" "$RESOURCE/node_modules/playwright-core/package.json"; do
  if [[ ! -f "$FILE" ]]; then
    printf 'Current packaged Electron bridge resource is missing: %s\n' "$FILE" >&2
    exit 1
  fi
done
TMP_ROOT="${TMPDIR:-/tmp}"
if [[ "$TMP_ROOT" == "/" ]]; then TMP_ROOT="/tmp"; fi
STAGE="$(mktemp -d "${TMP_ROOT%/}/biscuit-chatgpt-web-test.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
STAGE_ROOT="$STAGE/upstream"
STAGE_WEB="$STAGE_ROOT/web-provider"
STAGE_UPSTREAM="$STAGE_ROOT/codex-chatgpt-web"
REPORT="$STAGE_ROOT/electron-driver-smoke.xml"
mkdir -p "$STAGE_WEB/tests" "$STAGE_UPSTREAM/launcher/electron" "$STAGE/home" "$STAGE/tmp"
cp "$ROOT/upstream/package.json" "$ROOT/upstream/bun.lock" "$STAGE_ROOT/"
cp "$ROOT/upstream/web-provider/error-categories.ts" \
  "$ROOT/upstream/web-provider/request-lifecycle.ts" "$ROOT/upstream/web-provider/run-turn.ts" "$STAGE_WEB/"
cp "$ROOT/upstream/web-provider/electron-driver.ts" "$STAGE_WEB/"
cp "$ROOT/upstream/web-provider/tests/protocol.test.ts" \
  "$ROOT/upstream/web-provider/tests/electron-driver-contract.test.ts" "$STAGE_WEB/tests/"
cp -R "$ROOT/upstream/codex-chatgpt-web/src" "$STAGE_UPSTREAM/src"
cp "$ROOT/upstream/codex-chatgpt-web/launcher/electron/chatgpt-auth-session.cjs" \
  "$STAGE_UPSTREAM/launcher/electron/"
ln -s "$RESOURCE/node_modules" "$STAGE_ROOT/node_modules"
(
  cd "$STAGE_ROOT"
  export HOME="$STAGE/home"
  export TMPDIR="$STAGE/tmp"
  export NODE_PATH="$RESOURCE/node_modules"
  export BISCUIT_ELECTRON_CONTRACT_DRIVER="$RESOURCE/electron-driver.cjs"
  "$BUN" test --reporter=junit --reporter-outfile="$REPORT" ./web-provider/tests/protocol.test.ts ./web-provider/tests/electron-driver-contract.test.ts
)
if ! grep -Fq 'current Electron driver offline consumer contract in an isolated child' "$REPORT"; then
  printf 'Packaged Electron driver consumer contract did not run.\n' >&2
  exit 1
fi
printf 'PASS: current Electron driver offline consumer contract in an isolated child (packaged driver: %s)\n' "$RESOURCE/electron-driver.cjs"
