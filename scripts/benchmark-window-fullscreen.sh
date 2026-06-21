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
BENCH_DIR="$BUILD_DIR/bench-window-fullscreen"
KLOTSKI="$BIN_DIR/klotski"
HARNESS="$BIN_DIR/klotski-harness"

BASE_WINDOWS="${KLOTSKI_WINDOW_FULLSCREEN_BASE_WINDOWS:-3}"
SETTLE_SEC="${KLOTSKI_WINDOW_FULLSCREEN_SETTLE_SEC:-0.5}"
RESCAN_INTERVAL_SEC="${KLOTSKI_WINDOW_FULLSCREEN_RESCAN_INTERVAL_SEC:-0.05}"

mkdir -p "$BENCH_DIR"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    make test "$KLOTSKI" "$HARNESS"
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

created_window_line() {
    local windows_log="$1"
    local expected_index="$2"

    awk -v expected="$expected_index" '/KLOTSKI_HARNESS_WINDOW_CREATED/ {
        created_index = "";
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^index=/) {
                value = $i;
                sub(/^index=/, "", value);
                created_index = value;
            }
        }
        if (created_index == expected) {
            print;
        }
    }' "$windows_log" | tail -n 1
}

wait_for_request_line() {
    local windows_log="$1"
    local window_id="$2"

    for _ in $(seq 1 180); do
        local line
        line="$(awk -v id="$window_id" '/KLOTSKI_HARNESS_WINDOW_FULLSCREEN_TOGGLE_REQUESTED/ {
            window = "";
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^id=/) {
                    value = $i;
                    sub(/^id=/, "", value);
                    window = value;
                }
            }
            if (window == id) {
                print;
            }
        }' "$windows_log" | tail -n 1)"
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
        sleep 0.05
    done

    echo "timed out waiting for fullscreen toggle request window=$window_id" >&2
    cat "$windows_log" >&2
    return 1
}

wait_for_fullscreen_lifecycle_line() {
    local klotski_log="$1"
    local window_id="$2"
    local fullscreen="$3"
    local after_t="$4"

    for _ in $(seq 1 300); do
        local line
        line="$(awk -v id="$window_id" -v fullscreen="$fullscreen" -v after_t="$after_t" '/bench window_lifecycle/ {
            event_reason = "";
            window = "";
            state = "";
            t = "";
            changed = "";
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^t=/) {
                    value = $i;
                    sub(/^t=/, "", value);
                    t = value;
                } else if ($i ~ /^reason=/) {
                    value = $i;
                    sub(/^reason=/, "", value);
                    event_reason = value;
                } else if ($i ~ /^window=/) {
                    value = $i;
                    sub(/^window=/, "", value);
                    window = value;
                } else if ($i ~ /^fullscreen=/) {
                    value = $i;
                    sub(/^fullscreen=/, "", value);
                    state = value;
                } else if ($i ~ /^changed=/) {
                    value = $i;
                    sub(/^changed=/, "", value);
                    changed = value;
                }
            }
            if (t >= after_t && event_reason == "ax-resized" && window == id && state == fullscreen && changed == "1") {
                latest = $0;
            }
        } END {
            if (latest != "") {
                print latest;
            }
        }' "$klotski_log")"
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
        sleep 0.05
    done

    echo "timed out waiting for fullscreen=$fullscreen lifecycle window=$window_id after_t=$after_t" >&2
    cat "$klotski_log" >&2
    return 1
}

wait_for_layout_after() {
    local klotski_log="$1"
    local after_t="$2"
    local expected="$3"

    for _ in $(seq 1 160); do
        local line
        line="$(awk -v after_t="$after_t" -v expected="$expected" '/bench layout_apply/ {
            t = "";
            columns = 0;
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^t=/) {
                    value = $i;
                    sub(/^t=/, "", value);
                    t = value;
                } else if ($i ~ /^columns=/) {
                    value = $i;
                    sub(/^columns=/, "", value);
                    columns = value;
                }
            }
            if (t >= after_t && columns == expected && first == "") {
                first = $0;
            }
        } END {
            if (first != "") {
                print first;
            }
        }' "$klotski_log")"
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
        sleep 0.05
    done

    echo "timed out waiting for layout columns=$expected after $after_t" >&2
    cat "$klotski_log" >&2
    return 1
}

windows_log="$BENCH_DIR/windows.log"
klotski_log="$BENCH_DIR/klotski.log"
config="$BENCH_DIR/klotski.conf"

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

last_created="$(created_window_line "$windows_log" "$BASE_WINDOWS")"
window_id="$(field_value "$last_created" "id")"

kill -s XCPU "$harness_pid"
enter_request="$(wait_for_request_line "$windows_log" "$window_id")"
enter_request_t="$(field_value "$enter_request" "t")"
enter_line="$(wait_for_fullscreen_lifecycle_line "$klotski_log" "$window_id" 1 "$enter_request_t")"
enter_t="$(field_value "$enter_line" "t")"
enter_layout="$(wait_for_layout_after "$klotski_log" "$enter_request_t" "$((BASE_WINDOWS - 1))")"
enter_layout_t="$(field_value "$enter_layout" "t")"
enter_layout_ms="$(field_value "$enter_layout" "ms")"
enter_columns="$(field_value "$enter_layout" "columns")"
enter_matched="$(field_value "$enter_layout" "matched")"

sleep "$SETTLE_SEC"

kill -s XCPU "$harness_pid"
exit_request="$(wait_for_request_line "$windows_log" "$window_id")"
exit_request_t="$(field_value "$exit_request" "t")"
exit_line="$(wait_for_fullscreen_lifecycle_line "$klotski_log" "$window_id" 0 "$exit_request_t")"
exit_t="$(field_value "$exit_line" "t")"
exit_layout="$(wait_for_layout_after "$klotski_log" "$exit_request_t" "$BASE_WINDOWS")"
exit_layout_t="$(field_value "$exit_layout" "t")"
exit_layout_ms="$(field_value "$exit_layout" "ms")"
exit_columns="$(field_value "$exit_layout" "columns")"
exit_matched="$(field_value "$exit_layout" "matched")"

echo "macos_window_fullscreen phase=enter window=$window_id request_to_event_ms=$(ms_delta "$enter_request_t" "$enter_t") request_to_layout_ms=$(ms_delta "$enter_request_t" "$enter_layout_t") layout_to_event_ms=$(ms_delta "$enter_layout_t" "$enter_t") layout_ms=$enter_layout_ms columns=$enter_columns matched=$enter_matched"
echo "macos_window_fullscreen phase=exit window=$window_id request_to_event_ms=$(ms_delta "$exit_request_t" "$exit_t") request_to_layout_ms=$(ms_delta "$exit_request_t" "$exit_layout_t") layout_to_event_ms=$(ms_delta "$exit_layout_t" "$exit_t") layout_ms=$exit_layout_ms columns=$exit_columns matched=$exit_matched"
echo "window_fullscreen_logs dir=$BENCH_DIR"
