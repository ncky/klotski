#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_BUILD=0
if [[ "${1:-}" == "--skip-build" ]]; then
    SKIP_BUILD=1
fi

BUILD_DIR="$ROOT/build"
BIN_DIR="$ROOT/bin"
BENCH_DIR="$BUILD_DIR/bench"
CORE_BENCH="$BUILD_DIR/bench_core"
KLOTSKI="$BIN_DIR/klotski"
HARNESS="$BIN_DIR/klotski-harness"
SEND_INPUT="$BIN_DIR/klotski-send-input"
LIST_WINDOWS="$BIN_DIR/klotski-list-windows"

WINDOWS="${KLOTSKI_BENCH_WINDOWS:-10}"
EVENTS="${KLOTSKI_BENCH_EVENTS:-160}"
DELTA="${KLOTSKI_BENCH_DELTA:-3}"
DELAY_MS="${KLOTSKI_BENCH_DELAY_MS:-4}"
SETTLE_SEC="${KLOTSKI_BENCH_SETTLE_SEC:-0.6}"
APPLY_HZ="${KLOTSKI_GESTURE_APPLY_HZ:-120}"
INTERVAL_GAP_MS="${KLOTSKI_BENCH_INTERVAL_GAP_MS:-40}"

mkdir -p "$BENCH_DIR"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    make test "$CORE_BENCH" "$KLOTSKI" "$HARNESS" "$SEND_INPUT" "$LIST_WINDOWS"
fi

CORE_LOG="$BENCH_DIR/core.log"
WINDOWS_LOG="$BENCH_DIR/windows.log"
KLOTSKI_LOG="$BENCH_DIR/klotski.log"
CONFIG="$BENCH_DIR/klotski.conf"
APPLY_MS="$BENCH_DIR/layout-apply-ms.txt"
APPLY_T="$BENCH_DIR/layout-apply-t.txt"
INTERVAL_MS="$BENCH_DIR/layout-apply-interval-ms.txt"
WINDOWS_BEFORE="$BENCH_DIR/windows-before.txt"
WINDOWS_MID="$BENCH_DIR/windows-mid.txt"
WINDOWS_AFTER="$BENCH_DIR/windows-after.txt"

"$CORE_BENCH" | tee "$CORE_LOG"

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
KLOTSKI_GESTURE_APPLY_HZ="$APPLY_HZ" \
"$KLOTSKI" > "$KLOTSKI_LOG" 2>&1 &
KLOTSKI_PID="$!"

for _ in $(seq 1 120); do
    if grep -q "klotski running" "$KLOTSKI_LOG"; then
        break
    fi
    if ! kill -0 "$KLOTSKI_PID" 2>/dev/null; then
        echo "klotski exited before benchmark input" >&2
        cat "$KLOTSKI_LOG" >&2
        exit 1
    fi
    sleep 0.05
done

if ! grep -q "klotski running" "$KLOTSKI_LOG"; then
    echo "timed out waiting for klotski startup" >&2
    cat "$KLOTSKI_LOG" >&2
    exit 1
fi

INITIAL_LAYOUT_READY=0
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
        INITIAL_LAYOUT_READY=1
        break
    fi
    if ! kill -0 "$KLOTSKI_PID" 2>/dev/null; then
        echo "klotski exited before initial layout" >&2
        cat "$KLOTSKI_LOG" >&2
        exit 1
    fi
    sleep 0.05
done

if [[ "$INITIAL_LAYOUT_READY" -ne 1 ]]; then
    echo "timed out waiting for initial managed-window layout" >&2
    cat "$KLOTSKI_LOG" >&2
    exit 1
fi

sleep 0.2
START_SEQ="$(awk '/bench layout_apply/ {
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^seq=/) {
            sub(/^seq=/, "", $i);
            seq = $i;
        }
    }
} END { print seq + 0 }' "$KLOTSKI_LOG")"

"$LIST_WINDOWS" --pid "$MANAGED_PID" | sort -n > "$WINDOWS_BEFORE"
"$SEND_INPUT" --scroll-events "$EVENTS" --delta "$DELTA" --delay-ms "$DELAY_MS" --axis horizontal
sleep 0.2
"$LIST_WINDOWS" --pid "$MANAGED_PID" | sort -n > "$WINDOWS_MID"
"$SEND_INPUT" --scroll-events "$EVENTS" --delta "-$DELTA" --delay-ms "$DELAY_MS" --axis horizontal
sleep "$SETTLE_SEC"
"$LIST_WINDOWS" --pid "$MANAGED_PID" | sort -n > "$WINDOWS_AFTER"

cleanup
trap - EXIT

if ! grep -q "direct scroll update source=wheel" "$KLOTSKI_LOG"; then
    echo "synthetic Alt-scroll did not enter the direct wheel scroll path" >&2
    cat "$KLOTSKI_LOG" >&2
    exit 1
fi

if grep -q "gesture finish begin" "$KLOTSKI_LOG"; then
    echo "synthetic Alt-scroll entered the old snap/projection gesture path" >&2
    cat "$KLOTSKI_LOG" >&2
    exit 1
fi

if ! awk '/direct scroll update source=wheel/ {
    visual = "";
    logical = "";
    for (i = 1; i <= NF; i++) {
        if ($i == "visual" && i + 1 <= NF) {
            split($(i + 1), parts, "->");
            visual = parts[2];
        } else if ($i ~ /^logical=/) {
            sub(/^logical=/, "", $i);
            logical = $i;
        }
    }
    if (visual != "" && logical != "" && sqrt((visual - logical) * (visual - logical)) > 0.5) {
        eased = 1;
    }
} END { exit eased ? 0 : 1 }' "$KLOTSKI_LOG"; then
    echo "synthetic Alt-scroll did not ease the visual viewport toward the direct target" >&2
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
        }
        if ($i ~ /^ms=/) {
            sub(/^ms=/, "", $i);
            ms = $i;
        }
    }
    if (seq > start_seq && ms != "") {
        print ms;
    }
}' "$KLOTSKI_LOG" | sort -n > "$APPLY_MS"

awk -v start_seq="$START_SEQ" '/bench layout_apply/ {
    seq = 0;
    timestamp = "";
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^seq=/) {
            sub(/^seq=/, "", $i);
            seq = $i;
        }
        if ($i ~ /^t=/) {
            sub(/^t=/, "", $i);
            timestamp = $i;
        }
    }
    if (seq > start_seq && timestamp != "") {
        print timestamp;
    }
}' "$KLOTSKI_LOG" > "$APPLY_T"

awk -v gap_ms="$INTERVAL_GAP_MS" 'NR > 1 {
    delta = ($1 - previous) * 1000.0;
    if (delta <= gap_ms) {
        printf "%.6f\n", delta;
    }
} { previous = $1 }' "$APPLY_T" \
    | sort -n > "$INTERVAL_MS"

sample_count="$(wc -l < "$APPLY_MS" | tr -d ' ')"
if [[ "$sample_count" -eq 0 ]]; then
    echo "no layout_apply samples were recorded" >&2
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

apply_avg="$(awk '{ sum += $1 } END { printf "%.3f", sum / NR }' "$APPLY_MS")"
apply_p50="$(percentile "$APPLY_MS" "$sample_count" 50)"
apply_p95="$(percentile "$APPLY_MS" "$sample_count" 95)"
apply_max="$(tail -n 1 "$APPLY_MS")"
over_8="$(awk '$1 > 8.333 { count++ } END { print count + 0 }' "$APPLY_MS")"
over_16="$(awk '$1 > 16.667 { count++ } END { print count + 0 }' "$APPLY_MS")"

interval_count="$(wc -l < "$INTERVAL_MS" | tr -d ' ')"
if [[ "$interval_count" -gt 0 ]]; then
    interval_avg="$(awk '{ sum += $1 } END { printf "%.3f", sum / NR }' "$INTERVAL_MS")"
    interval_p95="$(percentile "$INTERVAL_MS" "$interval_count" 95)"
    interval_max="$(tail -n 1 "$INTERVAL_MS")"
else
    interval_avg="0.000"
    interval_p95="0.000"
    interval_max="0.000"
fi

read -r total_writes total_skipped total_deferred total_failed < <(
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
            if ($i ~ /^writes=/) {
                sub(/^writes=/, "", $i);
                writes += $i;
            } else if ($i ~ /^skipped=/) {
                sub(/^skipped=/, "", $i);
                skipped += $i;
            } else if ($i ~ /^deferred=/) {
                sub(/^deferred=/, "", $i);
                deferred += $i;
            } else if ($i ~ /^failed=/) {
                sub(/^failed=/, "", $i);
                failed += $i;
            }
        }
    } END { printf "%d %d %d %d\n", writes, skipped, deferred, failed }' "$KLOTSKI_LOG"
)

read -r moved_mid moved_after < <(
    awk '
        FNR == NR {
            before[$1] = $2 " " $3;
            next;
        }
        FILENAME == ARGV[2] {
            split(before[$1], origin, " ");
            if ($1 in before && (sqrt(($2 - origin[1])^2) > 1.0 || sqrt(($3 - origin[2])^2) > 1.0)) {
                mid++;
            }
            next;
        }
        FILENAME == ARGV[3] {
            split(before[$1], origin, " ");
            if ($1 in before && (sqrt(($2 - origin[1])^2) > 1.0 || sqrt(($3 - origin[2])^2) > 1.0)) {
                after++;
            }
        }
        END { printf "%d %d\n", mid + 0, after + 0 }
    ' "$WINDOWS_BEFORE" "$WINDOWS_MID" "$WINDOWS_AFTER"
)

if [[ "$moved_mid" -eq 0 && "$moved_after" -eq 0 ]]; then
    echo "benchmark input did not visibly move any harness windows" >&2
    echo "before:" >&2
    cat "$WINDOWS_BEFORE" >&2
    echo "mid:" >&2
    cat "$WINDOWS_MID" >&2
    echo "after:" >&2
    cat "$WINDOWS_AFTER" >&2
    exit 1
fi

count_visible_overlaps() {
    awk -v display_right="$2" '
        function min(a, b) { return a < b ? a : b }
        function max(a, b) { return a > b ? a : b }
        {
            id[NR] = $1;
            x[NR] = $2;
            y[NR] = $3;
            w[NR] = $4;
            h[NR] = $5;
        }
        END {
            for (i = 1; i <= NR; i++) {
                left_i = max(x[i], 0);
                right_i = min(x[i] + w[i], display_right);
                visible_i = right_i - left_i;
                if (visible_i < 80) {
                    continue;
                }

                for (j = i + 1; j <= NR; j++) {
                    left_j = max(x[j], 0);
                    right_j = min(x[j] + w[j], display_right);
                    visible_j = right_j - left_j;
                    if (visible_j < 80) {
                        continue;
                    }

                    overlap_w = min(right_i, right_j) - max(left_i, left_j);
                    overlap_h = min(y[i] + h[i], y[j] + h[j]) - max(y[i], y[j]);
                    if (overlap_w > 80 && overlap_h > 80) {
                        overlaps++;
                    }
                }
            }
            print overlaps + 0;
        }
    ' "$1"
}

display_right="$(
    awk '$2 >= 0 && $2 <= $4 + 10 {
        right = $2 + $4;
        if (right > max) {
            max = right;
        }
    } END {
        if (max <= 0) {
            max = 100000;
        }
        printf "%.3f\n", max;
    }' "$WINDOWS_BEFORE"
)"

overlaps_before="$(count_visible_overlaps "$WINDOWS_BEFORE" "$display_right")"
overlaps_mid="$(count_visible_overlaps "$WINDOWS_MID" "$display_right")"
overlaps_after="$(count_visible_overlaps "$WINDOWS_AFTER" "$display_right")"

if [[ "$overlaps_mid" -gt 0 || "$overlaps_after" -gt 0 ]]; then
    echo "benchmark detected visible harness window overlap" >&2
    echo "overlaps before=$overlaps_before mid=$overlaps_mid after=$overlaps_after" >&2
    echo "mid:" >&2
    cat "$WINDOWS_MID" >&2
    echo "after:" >&2
    cat "$WINDOWS_AFTER" >&2
    exit 1
fi

echo "macos_apply windows=$WINDOWS events=$(( EVENTS * 2 )) apply_hz=$APPLY_HZ samples=$sample_count"
echo "macos_apply_ms avg=$apply_avg p50=$apply_p50 p95=$apply_p95 max=$apply_max over_8_33=$over_8 over_16_67=$over_16"
echo "macos_apply_interval_ms avg=$interval_avg p95=$interval_p95 max=$interval_max"
echo "macos_apply_writes writes=$total_writes skipped=$total_skipped deferred=$total_deferred failed=$total_failed"
echo "macos_visible_moved mid=$moved_mid after=$moved_after"
echo "macos_visible_overlaps before=$overlaps_before mid=$overlaps_mid after=$overlaps_after"
echo "benchmark_logs dir=$BENCH_DIR"
