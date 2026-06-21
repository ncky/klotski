#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOG_DIR="$ROOT/build/harness"
HARNESS_LOG="$LOG_DIR/windows.log"
KLOTSKI_LOG="$LOG_DIR/klotski.log"
CONFIG="$LOG_DIR/klotski.conf"

mkdir -p "$LOG_DIR"
rm -f "$HARNESS_LOG" "$KLOTSKI_LOG" "$CONFIG"
KLOTSKI_PID=

cat > "$CONFIG" <<'CONFIG'
# On a 1200px display, this gives 24 + 575 + 2 + 575 + 24.
default-column-width-proportion = 0.5
gaps = 2
padding = 24
keyboard-scroll-fraction = 0.5
scroll-wheel-sensitivity = 3.0
gesture-scroll-sensitivity = 4.0
scroll-settle-delay = 0.08
horizontal-view-animation-speed = 18.0
center-focused-column = never
always-center-single-column = false
focus-follows-mouse = true
CONFIG

make -C "$ROOT" all bin/klotski-harness

"$ROOT/bin/klotski-harness" > "$HARNESS_LOG" 2>&1 &
HARNESS_PID=$!

cleanup() {
    if [ -n "$KLOTSKI_PID" ] && kill -0 "$KLOTSKI_PID" 2>/dev/null; then
        kill "$KLOTSKI_PID" 2>/dev/null || true
    fi

    if kill -0 "$HARNESS_PID" 2>/dev/null; then
        kill "$HARNESS_PID" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

sleep 1

KLOTSKI_TRACE_GESTURES=1 KLOTSKI_CONFIG="$CONFIG" KLOTSKI_MANAGED_PID="$HARNESS_PID" "$ROOT/bin/klotski" > "$KLOTSKI_LOG" 2>&1 &
KLOTSKI_PID=$!

echo "Harness PID: $HARNESS_PID"
echo "Klotski PID: $KLOTSKI_PID"
echo "Logs:"
echo "  $HARNESS_LOG"
echo "  $KLOTSKI_LOG"
echo
echo "Try the default Mod binds: Alt+Left/Right, Alt+W, and hover over the harness windows."
echo "Press Ctrl+C here to stop both processes."

wait "$KLOTSKI_PID"
