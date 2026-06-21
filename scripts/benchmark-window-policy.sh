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
BENCH_DIR="$BUILD_DIR/bench-window-policy"
KLOTSKI="$BIN_DIR/klotski"
HARNESS="$BIN_DIR/klotski-harness"
LIST_WINDOWS="$BIN_DIR/klotski-list-windows"

BASE_WINDOWS="${KLOTSKI_WINDOW_POLICY_BASE_WINDOWS:-3}"
SETTLE_SEC="${KLOTSKI_WINDOW_POLICY_SETTLE_SEC:-0.25}"
RESCAN_INTERVAL_SEC="${KLOTSKI_WINDOW_POLICY_RESCAN_INTERVAL_SEC:-0.05}"

mkdir -p "$BENCH_DIR"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    make test "$KLOTSKI" "$HARNESS" "$LIST_WINDOWS"
fi

write_config() {
    local path="$1"
    cat > "$path" <<CONFIG
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
}

field_value() {
    local line="$1"
    local key="$2"
    local field
    local prefix="$key="

    for field in $line; do
        if [[ "$field" == "$prefix"* ]]; then
            printf '%s\n' "${field#*=}"
            return 0
        fi
    done

    return 1
}

ms_delta() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", (b - a) * 1000.0 }'
}

wait_for_harness_pid() {
    local harness_pid="$1"
    local windows_log="$2"

    for _ in $(seq 1 100); do
        local managed_pid
        managed_pid="$(awk -F= '/KLOTSKI_HARNESS_PID/ {print $2; exit}' "$windows_log")"
        if [[ -n "$managed_pid" ]]; then
            echo "$managed_pid"
            return 0
        fi
        if ! kill -0 "$harness_pid" 2>/dev/null; then
            echo "harness exited before publishing a pid" >&2
            cat "$windows_log" >&2
            return 1
        fi
        sleep 0.05
    done

    echo "timed out waiting for harness pid" >&2
    cat "$windows_log" >&2
    return 1
}

wait_for_klotski_ready() {
    local klotski_pid="$1"
    local klotski_log="$2"

    for _ in $(seq 1 120); do
        if grep -q "klotski running" "$klotski_log"; then
            return 0
        fi
        if ! kill -0 "$klotski_pid" 2>/dev/null; then
            echo "klotski exited before benchmark input" >&2
            cat "$klotski_log" >&2
            return 1
        fi
        sleep 0.05
    done

    echo "timed out waiting for klotski startup" >&2
    cat "$klotski_log" >&2
    return 1
}

wait_for_initial_layout() {
    local klotski_pid="$1"
    local klotski_log="$2"
    local expected="$3"

    for _ in $(seq 1 160); do
        if awk -v expected="$expected" '/bench layout_apply/ {
            columns = 0;
            matched = 0;
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^columns=/) {
                    value = $i;
                    sub(/^columns=/, "", value);
                    columns = value;
                } else if ($i ~ /^matched=/) {
                    value = $i;
                    sub(/^matched=/, "", value);
                    matched = value;
                }
            }
            if (columns >= expected && matched >= expected) {
                ready = 1;
            }
        } END { exit ready ? 0 : 1 }' "$klotski_log"; then
            return 0
        fi
        if ! kill -0 "$klotski_pid" 2>/dev/null; then
            echo "klotski exited before initial layout" >&2
            cat "$klotski_log" >&2
            return 1
        fi
        sleep 0.05
    done

    echo "timed out waiting for initial managed-window layout" >&2
    cat "$klotski_log" >&2
    return 1
}

wait_for_window_count() {
    local managed_pid="$1"
    local expected="$2"
    local out="$3"

    for _ in $(seq 1 120); do
        "$LIST_WINDOWS" --pid "$managed_pid" | sort -n > "$out"
        local count
        count="$(wc -l < "$out" | tr -d ' ')"
        if [[ "$count" -eq "$expected" ]]; then
            return 0
        fi
        sleep 0.05
    done

    echo "timed out waiting for $expected visible harness windows" >&2
    cat "$out" >&2
    return 1
}

wait_for_created_window() {
    local windows_log="$1"
    local expected_index="$2"
    local expected_kind="$3"

    for _ in $(seq 1 120); do
        local line
        line="$(awk -v expected="$expected_index" -v kind="$expected_kind" '/KLOTSKI_HARNESS_WINDOW_CREATED/ {
            created_index = "";
            created_kind = "";
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^index=/) {
                    value = $i;
                    sub(/^index=/, "", value);
                    created_index = value;
                } else if ($i ~ /^kind=/) {
                    value = $i;
                    sub(/^kind=/, "", value);
                    created_kind = value;
                }
            }
            if (created_index == expected && created_kind == kind) {
                print;
            }
        }' "$windows_log" | tail -n 1)"
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
        sleep 0.05
    done

    echo "timed out waiting for harness-created kind=$expected_kind index=$expected_index" >&2
    cat "$windows_log" >&2
    return 1
}

wait_for_window_notice() {
    local klotski_log="$1"
    local window_id="$2"

    for _ in $(seq 1 160); do
        local line
        line="$(awk -v id="$window_id" '/bench window_notice/ {
            window = "";
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^window=/) {
                    value = $i;
                    sub(/^window=/, "", value);
                    window = value;
                }
            }
            if (window == id) {
                print;
            }
        }' "$klotski_log" | tail -n 1)"
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
        sleep 0.05
    done

    echo "timed out waiting for Klotski to notice window=$window_id" >&2
    cat "$klotski_log" >&2
    return 1
}

windows_log="$BENCH_DIR/windows.log"
klotski_log="$BENCH_DIR/klotski.log"
config="$BENCH_DIR/klotski.conf"
windows_after="$BENCH_DIR/windows-after.txt"

: > "$windows_log"
: > "$klotski_log"
write_config "$config"

harness_pid=""
klotski_pid=""

cleanup() {
    if [[ -n "$klotski_pid" ]] && kill -0 "$klotski_pid" 2>/dev/null; then
        kill "$klotski_pid" 2>/dev/null || true
        wait "$klotski_pid" 2>/dev/null || true
    fi

    if [[ -n "$harness_pid" ]] && kill -0 "$harness_pid" 2>/dev/null; then
        kill "$harness_pid" 2>/dev/null || true
        wait "$harness_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

KLOTSKI_HARNESS_WINDOWS="$BASE_WINDOWS" "$HARNESS" > "$windows_log" 2>&1 &
harness_pid="$!"

managed_pid="$(wait_for_harness_pid "$harness_pid" "$windows_log")"

KLOTSKI_CONFIG="$config" \
KLOTSKI_MANAGED_PID="$managed_pid" \
KLOTSKI_BENCH=1 \
KLOTSKI_RESCAN_INTERVAL_SEC="$RESCAN_INTERVAL_SEC" \
"$KLOTSKI" > "$klotski_log" 2>&1 &
klotski_pid="$!"

wait_for_klotski_ready "$klotski_pid" "$klotski_log"
wait_for_initial_layout "$klotski_pid" "$klotski_log" "$BASE_WINDOWS"
sleep "$SETTLE_SEC"

kill -s ALRM "$harness_pid"
created_line="$(wait_for_created_window "$windows_log" "$((BASE_WINDOWS + 1))" panel)"
window_id="$(field_value "$created_line" "id")"
notice_line="$(wait_for_window_notice "$klotski_log" "$window_id")"
notice_t="$(field_value "$notice_line" "t")"

policy="$(field_value "$notice_line" "policy")"
before_columns="$(field_value "$notice_line" "before_columns")"
after_columns="$(field_value "$notice_line" "after_columns")"
role="$(field_value "$notice_line" "role")"
subrole="$(field_value "$notice_line" "subrole")"
fullscreen_known="$(field_value "$notice_line" "fullscreen_known")"
fullscreen="$(field_value "$notice_line" "fullscreen")"

wait_for_window_count "$managed_pid" "$BASE_WINDOWS" "$windows_after"
visible_count="$(wc -l < "$windows_after" | tr -d ' ')"

if [[ "$policy" != "floating" || "$before_columns" != "$BASE_WINDOWS" || "$after_columns" != "$BASE_WINDOWS" ]]; then
    echo "window policy benchmark expected floating panel to keep tiled columns unchanged" >&2
    echo "notice: $notice_line" >&2
    exit 1
fi

echo "macos_window_policy scenario=floating-panel window=$window_id create_to_notice_ms=$(ms_delta "$(field_value "$created_line" "t")" "$notice_t") shown_to_notice_ms=$(ms_delta "$(field_value "$created_line" "shown_t")" "$notice_t") layout_after_notice=0 visible_layer0=$visible_count policy=$policy fullscreen_known=$fullscreen_known fullscreen=$fullscreen role=$role subrole=$subrole before_columns=$before_columns after_columns=$after_columns columns=$after_columns matched=$BASE_WINDOWS"
echo "window_policy_logs dir=$BENCH_DIR"
