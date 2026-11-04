#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPTURE_DISPLAY_ID="${BISCUIT_SMOKE_CAPTURE_DISPLAY_ID:-}"
if [[ ! "$CAPTURE_DISPLAY_ID" =~ ^[1-9][0-9]{0,9}$ ]] || (( 10#$CAPTURE_DISPLAY_ID > 4294967295 )); then
  printf 'BISCUIT_SMOKE_CAPTURE_DISPLAY_ID must be a positive decimal UInt32 for an active built-in display.\n' >&2
  exit 2
fi
export BISCUIT_SMOKE_CAPTURE_DISPLAY_ID="$CAPTURE_DISPLAY_ID"
TMP_ROOT="${TMPDIR:-/tmp}"
RUN="$(mktemp -d "${TMP_ROOT%/}/biscuit-smoke.XXXXXX")"
export BISCUIT_BUILD_DIR="${BISCUIT_BUILD_DIR:-$ROOT/build-smoke}"
export BISCUIT_SMOKE_BUILD=1
export BISCUIT_DATA_DIR="$RUN/data"
export BISCUIT_SMOKE_OUTPUT="$RUN/evidence"
export BISCUIT_PREFERENCES_SUITE="org.biscuit.smoke.${RUN##*.}"
APP="$BISCUIT_BUILD_DIR/biscuit.app"
SMOKE_TIMEOUT="${BISCUIT_SMOKE_TIMEOUT:-90}"
SUBSCRIPTION_SMOKE="${BISCUIT_SUBSCRIPTION_SMOKE:-0}"
# Keep-open is for manual inspection only; the watchdog still fails and terminates it at SMOKE_TIMEOUT.
KEEP_OPEN="${BISCUIT_SMOKE_KEEP_OPEN:-0}"
mkdir -p "$BISCUIT_SMOKE_OUTPUT"
STDOUT="$RUN/stdout.txt"
STDERR="$RUN/stderr.txt"
OPEN_PID=""
APP_PID=""
TIMED_OUT=0
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then kill -TERM "$APP_PID" 2>/dev/null || true; fi
  if [[ -n "$OPEN_PID" ]] && kill -0 "$OPEN_PID" 2>/dev/null; then kill -TERM "$OPEN_PID" 2>/dev/null || true; fi
  defaults delete "$BISCUIT_PREFERENCES_SUITE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
"$ROOT/scripts/build.sh"
"$ROOT/scripts/smoke-chatgpt-web.sh" "$APP"
printf 'Isolated native smoke evidence: %s\n' "$BISCUIT_SMOKE_OUTPUT"
/usr/bin/open -n -W -a "$APP" \
  --env "BISCUIT_DATA_DIR=$BISCUIT_DATA_DIR" \
  --env "BISCUIT_SMOKE_OUTPUT=$BISCUIT_SMOKE_OUTPUT" \
  --env "BISCUIT_PREFERENCES_SUITE=$BISCUIT_PREFERENCES_SUITE" \
  --env "BISCUIT_SMOKE_CAPTURE_DISPLAY_ID=$BISCUIT_SMOKE_CAPTURE_DISPLAY_ID" \
  --env "BISCUIT_SMOKE_KEEP_OPEN=$KEEP_OPEN" \
  --stdout "$STDOUT" --stderr "$STDERR" --args --smoke &
OPEN_PID=$!
for ((elapsed = 0; elapsed < SMOKE_TIMEOUT; elapsed++)); do
  if [[ -z "$APP_PID" && -f "$BISCUIT_SMOKE_OUTPUT/pid" ]]; then APP_PID="$(<"$BISCUIT_SMOKE_OUTPUT/pid")"; fi
  if ! kill -0 "$OPEN_PID" 2>/dev/null; then break; fi
  if [[ -n "$APP_PID" ]] && ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
  sleep 1
done
if (( elapsed >= SMOKE_TIMEOUT )) && kill -0 "$OPEN_PID" 2>/dev/null; then
  TIMED_OUT=1
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    printf 'Native smoke app did not exit within %ss; terminating owned app process %s.\n' "$SMOKE_TIMEOUT" "$APP_PID" >&2
    kill -TERM "$APP_PID" 2>/dev/null || true
  fi
fi
for ((shutdown = 0; shutdown < 5; shutdown++)); do
  kill -0 "$OPEN_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$OPEN_PID" 2>/dev/null; then
  TIMED_OUT=1
  kill -TERM "$OPEN_PID" 2>/dev/null || true
fi
set +e
wait "$OPEN_PID" 2>/dev/null
OPEN_STATUS=$?
set -e
OPEN_PID=""
if [[ -f "$STDOUT" ]]; then printf '\n--- App stdout ---\n'; cat "$STDOUT"; fi
if [[ -f "$STDERR" ]]; then printf '\n--- App stderr ---\n' >&2; cat "$STDERR" >&2; fi
if [[ "$TIMED_OUT" -eq 0 && -f "$BISCUIT_SMOKE_OUTPUT/complete" && "$OPEN_STATUS" -eq 0 ]]; then
  printf 'Native smoke passed.\n'
else
  printf 'Native smoke failed: completion marker=%s, LaunchServices status=%s, timed out=%s.\n' \
    "$([[ -f "$BISCUIT_SMOKE_OUTPUT/complete" ]] && printf yes || printf no)" "$OPEN_STATUS" "$TIMED_OUT" >&2
  printf 'Partial results, if any: %s/results.json\nLogs: %s\n' "$BISCUIT_SMOKE_OUTPUT" "$RUN" >&2
  exit 1
fi
printf '\nResults: %s/results.json\nLogs: %s\n' "$BISCUIT_SMOKE_OUTPUT" "$RUN"
