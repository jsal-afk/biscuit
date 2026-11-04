#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/biscuit.app}"
DATA="$(mktemp -d "${TMPDIR:-/tmp/}biscuit-idle.XXXXXX")"
PREFERENCES_SUITE="org.biscuit.measure.$(basename "$DATA")"
PATH="/usr/bin:/bin:/usr/sbin:/sbin" BISCUIT_DATA_DIR="$DATA" BISCUIT_PREFERENCES_SUITE="$PREFERENCES_SUITE" "$APP/Contents/MacOS/biscuit" &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; /usr/bin/defaults delete "$PREFERENCES_SUITE" >/dev/null 2>&1 || true; rm -rf "$DATA"; }
trap cleanup EXIT
# Fixed measurement intervals, not a readiness/polling loop.
sleep 3
printf 'Native host: '; uname -m
printf 'Isolated empty store; menu bar idle; edge monitor enabled; PID %s\n' "$PID"
printf 'Snapshot after 3 seconds (PID / RSS KiB / CPU percent / CPU time / elapsed):\n'
ps -p "$PID" -o pid=,rss=,%cpu=,time=,etime=
sleep 15
printf 'Snapshot after 18 seconds:\n'
ps -p "$PID" -o pid=,rss=,%cpu=,time=,etime=
printf 'Bundle disk KiB:\n'; du -sk "$APP"
printf 'Executable bytes:\n'; stat -f %z "$APP/Contents/MacOS/biscuit"
