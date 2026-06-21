#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
BIN_DIR="$ROOT/bin"
BENCH_DIR="$BUILD_DIR/bench-window-gap"
KLOTSKI="$BIN_DIR/klotski"
HARNESS="$BIN_DIR/klotski-harness"
SEND_INPUT="$BIN_DIR/klotski-send-input"
LIST_WINDOWS="$BIN_DIR/klotski-list-windows"

WINDOWS="${KLOTSKI_WINDOW_GAP_WINDOWS:-4}"
MIN_VISIBLE_WINDOWS="${KLOTSKI_WINDOW_GAP_MIN_VISIBLE_WINDOWS:-2}"
MAX_VISIBLE_GAP="${KLOTSKI_WINDOW_GAP_MAX_VISIBLE_GAP:-80}"
MAX_APPLY_MS="${KLOTSKI_WINDOW_GAP_MAX_APPLY_MS:-35}"
MAX_P95_MS="${KLOTSKI_WINDOW_GAP_MAX_P95_MS:-12}"

mkdir -p "$BENCH_DIR"
make test "$KLOTSKI" "$HARNESS" "$SEND_INPUT" "$LIST_WINDOWS"

CONFIG="$BENCH_DIR/klotski.conf"
WINDOWS_LOG="$BENCH_DIR/windows.log"
KLOTSKI_LOG="$BENCH_DIR/klotski.log"
WINDOWS_AFTER="$BENCH_DIR/windows-after.txt"
VISIBLE_WINDOWS="$BENCH_DIR/windows-visible.txt"
APPLY_MS="$BENCH_DIR/layout-apply-ms.txt"

cat > "$CONFIG" <<CONFIG
default-column-width-proportion = 0.5
gaps = 2
padding = 0
keyboard-scroll-fraction = 0.5
scroll-wheel-sensitivity = 3.0
gesture-scroll-sensitivity = 4.0
scroll-settle-delay = 0.08
horizontal-view-animation-speed = 18.0
focus-follows-mouse = false
CONFIG

KLOTSKI_PID=""
HARNESS_PID=""

cleanup() {
    if [[ -n "$KLOTSKI_PID" ]] && kill -0 "$KLOTSKI_PID" 2>/dev/null; then
        kill "$KLOTSKI_PID" 2>/dev/null || true
        wait "$KLOTSKI_PID" 2>/dev/null || true
    fi

    if [[ -n "$HARNESS_PID" ]] && kill -0 "$HARNESS_PID" 2>/dev/null; then
        kill "$HARNESS_PID" 2>/dev/null || true
        wait "$HARNESS_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

: > "$WINDOWS_LOG"
: > "$KLOTSKI_LOG"

KLOTSKI_HARNESS_WINDOWS="$WINDOWS" "$HARNESS" > "$WINDOWS_LOG" 2>&1 &
HARNESS_PID="$!"

MANAGED_PID=""
for _ in $(seq 1 100); do
    MANAGED_PID="$(awk -F= '/KLOTSKI_HARNESS_PID/ {print $2; exit}' "$WINDOWS_LOG")"
    if [[ -n "$MANAGED_PID" ]]; then
        break
    fi
    if ! kill -0 "$HARNESS_PID" 2>/dev/null; then
        echo "harness exited before publishing a pid" >&2
        cat "$WINDOWS_LOG" >&2
        exit 1
    fi
    sleep 0.05
done

if [[ -z "$MANAGED_PID" ]]; then
    echo "timed out waiting for harness pid" >&2
    cat "$WINDOWS_LOG" >&2
    exit 1
fi

KLOTSKI_CONFIG="$CONFIG" \
KLOTSKI_MANAGED_PID="$MANAGED_PID" \
KLOTSKI_BENCH=1 \
KLOTSKI_TRACE_GESTURES=1 \
"$KLOTSKI" > "$KLOTSKI_LOG" 2>&1 &
KLOTSKI_PID="$!"

for _ in $(seq 1 160); do
    if awk -v expected="$WINDOWS" '/bench layout_apply/ {
        columns = 0;
        matched = 0;
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^columns=/) {
                sub(/^columns=/, "", $i);
                columns = $i;
            } else if ($i ~ /^matched=/) {
                sub(/^matched=/, "", $i);
                matched = $i;
            }
        }
        if (columns >= expected && matched >= expected) {
            ready = 1;
        }
    } END { exit ready ? 0 : 1 }' "$KLOTSKI_LOG"; then
        break
    fi
    if ! kill -0 "$KLOTSKI_PID" 2>/dev/null; then
        echo "klotski exited before initial layout" >&2
        cat "$KLOTSKI_LOG" >&2
        exit 1
    fi
    sleep 0.05
done

START_SEQ="$(awk '/bench layout_apply/ {
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^seq=/) {
            sub(/^seq=/, "", $i);
            seq = $i;
        }
    }
} END { print seq + 0 }' "$KLOTSKI_LOG")"

kill -s VTALRM "$HARNESS_PID"
sleep 0.35

"$SEND_INPUT" --alt-shift-key left
sleep 0.15
"$SEND_INPUT" --alt-shift-key right
sleep 0.15
"$SEND_INPUT" --scroll-events 120 --delta 4 --delay-ms 2 --axis horizontal
sleep 0.25
"$SEND_INPUT" --scroll-events 120 --delta -4 --delay-ms 2 --axis horizontal
sleep 0.5

if ! kill -0 "$KLOTSKI_PID" 2>/dev/null; then
    echo "klotski exited during window-gap benchmark input" >&2
    cat "$KLOTSKI_LOG" >&2
    exit 1
fi

"$LIST_WINDOWS" --pid "$MANAGED_PID" | sort -n > "$WINDOWS_AFTER"

display_width="$(
    swift -e 'import CoreGraphics; print(CGDisplayBounds(CGMainDisplayID()).size.width)'
)"

awk -v display_width="$display_width" '
    {
        left = $2;
        right = $2 + $4;
        if (right <= 0 || left >= display_width) {
            next;
        }
        if (left < 0) {
            left = 0;
        }
        if (right > display_width) {
            right = display_width;
        }
        if (right - left >= 80) {
            printf "%.3f %.3f %s\n", left, right, $1;
        }
    }
' "$WINDOWS_AFTER" | sort -n > "$VISIBLE_WINDOWS"

read -r visible_count max_gap visible_overlaps < <(
    awk '
        NR > 1 {
            gap = $1 - previous_right;
            if (gap > max_gap) {
                max_gap = gap;
            }
            overlap = previous_right - $1;
            if (overlap > 80) {
                overlaps++;
            }
        }
        {
            previous_right = $2;
        }
        END {
            printf "%d %.3f %d\n", NR, max_gap + 0, overlaps + 0;
        }
    ' "$VISIBLE_WINDOWS"
)

if [[ "$WINDOWS" -ge "$MIN_VISIBLE_WINDOWS" && "$visible_count" -lt "$MIN_VISIBLE_WINDOWS" ]]; then
    echo "too few visible harness windows: visible=$visible_count expected_at_least=$MIN_VISIBLE_WINDOWS" >&2
    echo "visible windows:" >&2
    cat "$VISIBLE_WINDOWS" >&2
    echo "all windows:" >&2
    cat "$WINDOWS_AFTER" >&2
    exit 1
fi

if [[ "$visible_overlaps" -gt 0 ]]; then
    echo "visible harness windows overlap: overlaps=$visible_overlaps" >&2
    echo "visible windows:" >&2
    cat "$VISIBLE_WINDOWS" >&2
    echo "all windows:" >&2
    cat "$WINDOWS_AFTER" >&2
    exit 1
fi

if [[ "$visible_count" -gt 1 ]] && awk -v gap="$max_gap" -v max="$MAX_VISIBLE_GAP" 'BEGIN { exit gap > max ? 0 : 1 }'; then
    echo "visible harness windows have a large horizontal gap: ${max_gap}px" >&2
    echo "visible windows:" >&2
    cat "$VISIBLE_WINDOWS" >&2
    echo "all windows:" >&2
    cat "$WINDOWS_AFTER" >&2
    exit 1
fi

max_columns="$(awk -v start_seq="$START_SEQ" '/bench layout_apply/ {
    seq = 0;
    columns = 0;
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^seq=/) {
            sub(/^seq=/, "", $i);
            seq = $i;
        } else if ($i ~ /^columns=/) {
            sub(/^columns=/, "", $i);
            columns = $i;
        }
    }
    if (seq > start_seq && columns > max) {
        max = columns;
    }
} END { print max + 0 }' "$KLOTSKI_LOG")"

if [[ "$max_columns" -gt "$WINDOWS" ]]; then
    echo "ghost/helper window entered tiled layout: columns=$max_columns expected=$WINDOWS" >&2
    cat "$KLOTSKI_LOG" >&2
    exit 1
fi

awk -v start_seq="$START_SEQ" '/bench layout_apply/ {
    seq = 0;
    ms = "";
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^seq=/) {
            sub(/^seq=/, "", $i);
            seq = $i;
        } else if ($i ~ /^ms=/) {
            sub(/^ms=/, "", $i);
            ms = $i;
        }
    }
    if (seq > start_seq && ms != "") {
        print ms;
    }
}' "$KLOTSKI_LOG" | sort -n > "$APPLY_MS"

sample_count="$(wc -l < "$APPLY_MS" | tr -d ' ')"
if [[ "$sample_count" -eq 0 ]]; then
    echo "no layout samples recorded" >&2
    cat "$KLOTSKI_LOG" >&2
    exit 1
fi

percentile() {
    local file="$1"
    local count="$2"
    local pct="$3"
    local index
    index=$(( (count * pct + 99) / 100 ))
    if [[ "$index" -lt 1 ]]; then
        index=1
    elif [[ "$index" -gt "$count" ]]; then
        index="$count"
    fi
    sed -n "${index}p" "$file"
}

apply_p95="$(percentile "$APPLY_MS" "$sample_count" 95)"
apply_max="$(tail -n 1 "$APPLY_MS")"

if awk -v value="$apply_p95" -v limit="$MAX_P95_MS" 'BEGIN { exit value > limit ? 0 : 1 }'; then
    echo "layout apply p95 too slow: ${apply_p95}ms > ${MAX_P95_MS}ms" >&2
    cat "$KLOTSKI_LOG" >&2
    exit 1
fi

if awk -v value="$apply_max" -v limit="$MAX_APPLY_MS" 'BEGIN { exit value > limit ? 0 : 1 }'; then
    echo "layout apply max too slow: ${apply_max}ms > ${MAX_APPLY_MS}ms" >&2
    cat "$KLOTSKI_LOG" >&2
    exit 1
fi

read -r total_deferred total_failed < <(
    awk -v start_seq="$START_SEQ" '/bench layout_apply/ {
        seq = 0;
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^seq=/) {
                sub(/^seq=/, "", $i);
                seq = $i;
            }
        }
        if (seq <= start_seq) {
            next;
        }
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^deferred=/) {
                sub(/^deferred=/, "", $i);
                deferred += $i;
            } else if ($i ~ /^failed=/) {
                sub(/^failed=/, "", $i);
                failed += $i;
            }
        }
    } END { printf "%d %d\n", deferred, failed }' "$KLOTSKI_LOG"
)

if [[ "$total_deferred" -ne 0 || "$total_failed" -ne 0 ]]; then
    echo "layout had deferred or failed frame writes: deferred=$total_deferred failed=$total_failed" >&2
    cat "$KLOTSKI_LOG" >&2
    exit 1
fi

echo "window_gap windows=$WINDOWS visible=$visible_count max_visible_gap=$max_gap visible_overlaps=$visible_overlaps max_columns=$max_columns"
echo "window_gap_apply samples=$sample_count p95=$apply_p95 max=$apply_max"
echo "window_gap_writes deferred=$total_deferred failed=$total_failed"
echo "benchmark_logs dir=$BENCH_DIR"
