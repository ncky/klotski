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
BENCH_DIR="$BUILD_DIR/bench-window-lifecycle"
KLOTSKI="$BIN_DIR/klotski"
HARNESS="$BIN_DIR/klotski-harness"
LIST_WINDOWS="$BIN_DIR/klotski-list-windows"

BASE_WINDOWS="${KLOTSKI_WINDOW_LIFECYCLE_BASE_WINDOWS:-5}"
SETTLE_SEC="${KLOTSKI_WINDOW_LIFECYCLE_SETTLE_SEC:-0.25}"
RESCAN_INTERVAL_SEC="${KLOTSKI_WINDOW_LIFECYCLE_RESCAN_INTERVAL_SEC:-0.05}"

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
    local marker="$2"
    local window_id="$3"

    for _ in $(seq 1 120); do
        local line
        line="$(awk -v marker="$marker" -v id="$window_id" '$0 ~ marker {
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

    echo "timed out waiting for harness marker=$marker window=$window_id" >&2
    cat "$windows_log" >&2
    return 1
}

wait_for_marker_line() {
    local windows_log="$1"
    local marker="$2"

    for _ in $(seq 1 120); do
        local line
        line="$(awk -v marker="$marker" '$0 ~ marker { print }' "$windows_log" | tail -n 1)"
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
        sleep 0.05
    done

    echo "timed out waiting for harness marker=$marker" >&2
    cat "$windows_log" >&2
    return 1
}

wait_for_lifecycle_line() {
    local klotski_log="$1"
    local reason="$2"
    local window_id="$3"

    for _ in $(seq 1 160); do
        local line
        line="$(awk -v reason="$reason" -v id="$window_id" '/bench window_lifecycle/ {
            event_reason = "";
            window = "";
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^reason=/) {
                    value = $i;
                    sub(/^reason=/, "", value);
                    event_reason = value;
                } else if ($i ~ /^window=/) {
                    value = $i;
                    sub(/^window=/, "", value);
                    window = value;
                }
            }
            if (event_reason == reason && window == id) {
                print;
            }
        }' "$klotski_log" | tail -n 1)"
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
        sleep 0.05
    done

    echo "timed out waiting for lifecycle reason=$reason window=$window_id" >&2
    cat "$klotski_log" >&2
    return 1
}

wait_for_pid_lifecycle_line() {
    local klotski_log="$1"
    local reason="$2"
    local pid="$3"

    for _ in $(seq 1 160); do
        local line
        line="$(awk -v reason="$reason" -v pid="$pid" '/bench window_lifecycle/ {
            event_reason = "";
            event_pid = "";
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^reason=/) {
                    value = $i;
                    sub(/^reason=/, "", value);
                    event_reason = value;
                } else if ($i ~ /^pid=/) {
                    value = $i;
                    sub(/^pid=/, "", value);
                    event_pid = value;
                }
            }
            if (event_reason == reason && event_pid == pid) {
                print;
            }
        }' "$klotski_log" | tail -n 1)"
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
        sleep 0.05
    done

    echo "timed out waiting for lifecycle reason=$reason pid=$pid" >&2
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
            matched = 0;
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^t=/) {
                    value = $i;
                    sub(/^t=/, "", value);
                    t = value;
                } else if ($i ~ /^columns=/) {
                    value = $i;
                    sub(/^columns=/, "", value);
                    columns = value;
                } else if ($i ~ /^matched=/) {
                    value = $i;
                    sub(/^matched=/, "", value);
                    matched = value;
                }
            }
            if (t >= after_t && columns == expected && matched == expected && first == "") {
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

    echo "timed out waiting for lifecycle layout after $after_t expected=$expected" >&2
    cat "$klotski_log" >&2
    return 1
}

run_pair() {
    local scenario="$1"
    local scenario_dir="$BENCH_DIR/$scenario"
    mkdir -p "$scenario_dir"

    local windows_log="$scenario_dir/windows.log"
    local klotski_log="$scenario_dir/klotski.log"
    local config="$scenario_dir/klotski.conf"
    local windows_after="$scenario_dir/windows-after.txt"

    : > "$windows_log"
    : > "$klotski_log"
    write_config "$config"

    local harness_pid=""
    local klotski_pid=""

    cleanup_pair() {
        if [[ -n "$klotski_pid" ]] && kill -0 "$klotski_pid" 2>/dev/null; then
            kill "$klotski_pid" 2>/dev/null || true
            wait "$klotski_pid" 2>/dev/null || true
        fi

        if [[ -n "$harness_pid" ]] && kill -0 "$harness_pid" 2>/dev/null; then
            kill "$harness_pid" 2>/dev/null || true
            wait "$harness_pid" 2>/dev/null || true
        fi
    }
    trap cleanup_pair RETURN

    KLOTSKI_HARNESS_WINDOWS="$BASE_WINDOWS" "$HARNESS" > "$windows_log" 2>&1 &
    harness_pid="$!"

    local managed_pid
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

    local last_created
    last_created="$(created_window_line "$windows_log" "$BASE_WINDOWS")"
    local window_id
    window_id="$(field_value "$last_created" "id")"

    if [[ "$scenario" == "close" ]]; then
        kill -s HUP "$harness_pid"
        local request_line lifecycle_line lifecycle_t layout_line layout_t layout_ms columns matched visible_count
        request_line="$(wait_for_request_line "$windows_log" "KLOTSKI_HARNESS_WINDOW_CLOSE_REQUESTED" "$window_id")"
        lifecycle_line="$(wait_for_lifecycle_line "$klotski_log" "ax-destroyed" "$window_id")"
        lifecycle_t="$(field_value "$lifecycle_line" "t")"
        layout_line="$(wait_for_layout_after "$klotski_log" "$(field_value "$request_line" "t")" "$((BASE_WINDOWS - 1))")"
        layout_t="$(field_value "$layout_line" "t")"
        layout_ms="$(field_value "$layout_line" "ms")"
        columns="$(field_value "$layout_line" "columns")"
        matched="$(field_value "$layout_line" "matched")"
        wait_for_window_count "$managed_pid" "$((BASE_WINDOWS - 1))" "$windows_after"
        visible_count="$(wc -l < "$windows_after" | tr -d ' ')"
        echo "macos_window_lifecycle scenario=close window=$window_id request_to_event_ms=$(ms_delta "$(field_value "$request_line" "t")" "$lifecycle_t") request_to_layout_ms=$(ms_delta "$(field_value "$request_line" "t")" "$layout_t") layout_to_event_ms=$(ms_delta "$layout_t" "$lifecycle_t") layout_ms=$layout_ms visible=$visible_count columns=$columns matched=$matched"
    elif [[ "$scenario" == "terminate" ]]; then
        kill -s TERM "$harness_pid"
        local request_line lifecycle_line lifecycle_t layout_line layout_t layout_ms columns matched visible_count removed
        request_line="$(wait_for_marker_line "$windows_log" "KLOTSKI_HARNESS_APP_TERMINATE_REQUESTED")"
        lifecycle_line="$(wait_for_pid_lifecycle_line "$klotski_log" "app-terminated" "$managed_pid")"
        lifecycle_t="$(field_value "$lifecycle_line" "t")"
        layout_line="$(wait_for_layout_after "$klotski_log" "$(field_value "$request_line" "t")" 0)"
        layout_t="$(field_value "$layout_line" "t")"
        layout_ms="$(field_value "$layout_line" "ms")"
        columns="$(field_value "$layout_line" "columns")"
        matched="$(field_value "$layout_line" "matched")"
        removed="$(field_value "$lifecycle_line" "removed")"
        wait_for_window_count "$managed_pid" 0 "$windows_after"
        visible_count="$(wc -l < "$windows_after" | tr -d ' ')"
        wait "$harness_pid" 2>/dev/null || true
        harness_pid=""
        echo "macos_window_lifecycle scenario=terminate pid=$managed_pid removed=$removed request_to_event_ms=$(ms_delta "$(field_value "$request_line" "t")" "$lifecycle_t") request_to_layout_ms=$(ms_delta "$(field_value "$request_line" "t")" "$layout_t") layout_to_event_ms=$(ms_delta "$layout_t" "$lifecycle_t") layout_ms=$layout_ms visible=$visible_count columns=$columns matched=$matched"
    else
        kill -s WINCH "$harness_pid"
        local min_request min_line min_t min_layout min_layout_t min_layout_ms min_columns min_matched min_visible
        min_request="$(wait_for_request_line "$windows_log" "KLOTSKI_HARNESS_WINDOW_MINIMIZE_REQUESTED" "$window_id")"
        min_line="$(wait_for_lifecycle_line "$klotski_log" "ax-minimized" "$window_id")"
        min_t="$(field_value "$min_line" "t")"
        min_layout="$(wait_for_layout_after "$klotski_log" "$(field_value "$min_request" "t")" "$((BASE_WINDOWS - 1))")"
        min_layout_t="$(field_value "$min_layout" "t")"
        min_layout_ms="$(field_value "$min_layout" "ms")"
        min_columns="$(field_value "$min_layout" "columns")"
        min_matched="$(field_value "$min_layout" "matched")"
        wait_for_window_count "$managed_pid" "$((BASE_WINDOWS - 1))" "$windows_after"
        min_visible="$(wc -l < "$windows_after" | tr -d ' ')"
        echo "macos_window_lifecycle scenario=minimize window=$window_id request_to_event_ms=$(ms_delta "$(field_value "$min_request" "t")" "$min_t") request_to_layout_ms=$(ms_delta "$(field_value "$min_request" "t")" "$min_layout_t") layout_to_event_ms=$(ms_delta "$min_layout_t" "$min_t") layout_ms=$min_layout_ms visible=$min_visible columns=$min_columns matched=$min_matched"

        kill -s URG "$harness_pid"
        local demin_request demin_line demin_t demin_layout demin_layout_t demin_layout_ms demin_columns demin_matched demin_visible
        demin_request="$(wait_for_request_line "$windows_log" "KLOTSKI_HARNESS_WINDOW_DEMINIMIZE_REQUESTED" "$window_id")"
        demin_line="$(wait_for_lifecycle_line "$klotski_log" "ax-deminimized" "$window_id")"
        demin_t="$(field_value "$demin_line" "t")"
        demin_layout="$(wait_for_layout_after "$klotski_log" "$(field_value "$demin_request" "t")" "$BASE_WINDOWS")"
        demin_layout_t="$(field_value "$demin_layout" "t")"
        demin_layout_ms="$(field_value "$demin_layout" "ms")"
        demin_columns="$(field_value "$demin_layout" "columns")"
        demin_matched="$(field_value "$demin_layout" "matched")"
        wait_for_window_count "$managed_pid" "$BASE_WINDOWS" "$windows_after"
        demin_visible="$(wc -l < "$windows_after" | tr -d ' ')"
        echo "macos_window_lifecycle scenario=deminimize window=$window_id request_to_event_ms=$(ms_delta "$(field_value "$demin_request" "t")" "$demin_t") request_to_layout_ms=$(ms_delta "$(field_value "$demin_request" "t")" "$demin_layout_t") layout_to_event_ms=$(ms_delta "$demin_layout_t" "$demin_t") layout_ms=$demin_layout_ms visible=$demin_visible columns=$demin_columns matched=$demin_matched"
    fi

    cleanup_pair
    trap - RETURN
}

run_pair close
run_pair minimize
run_pair terminate

echo "window_lifecycle_logs dir=$BENCH_DIR"
