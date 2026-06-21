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
BENCH_DIR="$BUILD_DIR/bench-window-add"
CORE_BENCH="$BUILD_DIR/bench_core"
KLOTSKI="$BIN_DIR/klotski"
HARNESS="$BIN_DIR/klotski-harness"
LIST_WINDOWS="$BIN_DIR/klotski-list-windows"

BASE_WINDOWS="${KLOTSKI_WINDOW_ADD_BASE_WINDOWS:-8}"
SETTLE_SEC="${KLOTSKI_WINDOW_ADD_SETTLE_SEC:-0.25}"
RESCAN_INTERVAL_SEC="${KLOTSKI_WINDOW_ADD_RESCAN_INTERVAL_SEC:-0.05}"
SCENARIOS="${KLOTSKI_WINDOW_ADD_SCENARIOS:-left middle right}"

mkdir -p "$BENCH_DIR"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    make test "$CORE_BENCH" "$KLOTSKI" "$HARNESS" "$LIST_WINDOWS"
fi

CORE_LOG="$BENCH_DIR/core.log"
"$CORE_BENCH" | tee "$CORE_LOG"

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

active_index_for_scenario() {
    local scenario="$1"

    case "$scenario" in
        left)
            echo 0
            ;;
        middle)
            echo $((BASE_WINDOWS / 2))
            ;;
        right)
            echo $((BASE_WINDOWS - 1))
            ;;
    esac
}

wait_for_active_focus() {
    local klotski_pid="$1"
    local klotski_log="$2"
    local expected="$3"

    for _ in $(seq 1 120); do
        local line
        line="$(awk -v expected="$expected" '/bench active_focus/ {
            active = "";
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^active=/) {
                    value = $i;
                    sub(/^active=/, "", value);
                    active = value;
                }
            }
            if (active == expected) {
                print;
            }
        }' "$klotski_log" | tail -n 1)"
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
        if ! kill -0 "$klotski_pid" 2>/dev/null; then
            echo "klotski exited before benchmark active focus" >&2
            cat "$klotski_log" >&2
            return 1
        fi
        sleep 0.05
    done

    echo "timed out waiting for benchmark active index=$expected" >&2
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
        if [[ "$count" -ge "$expected" ]]; then
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

    for _ in $(seq 1 120); do
        local line
        line="$(awk -v expected="$expected_index" '/KLOTSKI_HARNESS_WINDOW_CREATED/ {
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
        }' "$windows_log" | tail -n 1)"
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
        sleep 0.05
    done

    echo "timed out waiting for harness-created window index=$expected_index" >&2
    cat "$windows_log" >&2
    return 1
}

wait_for_notice_line() {
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

wait_for_layout_after_notice() {
    local klotski_log="$1"
    local notice_t="$2"
    local expected="$3"

    for _ in $(seq 1 120); do
        local line
        line="$(awk -v notice_t="$notice_t" -v expected="$expected" '/bench layout_apply/ {
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
            if (t >= notice_t && columns >= expected && matched >= expected) {
                print;
                exit;
            }
        }' "$klotski_log")"
        if [[ -n "$line" ]]; then
            echo "$line"
            return 0
        fi
        sleep 0.05
    done

    echo "timed out waiting for layout after notice_t=$notice_t" >&2
    cat "$klotski_log" >&2
    return 1
}

wait_for_hints_line() {
    local klotski_log="$1"
    local window_id="$2"

    for _ in $(seq 1 40); do
        local line
        line="$(awk -v id="$window_id" '/bench window_hints/ {
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
        sleep 0.01
    done

    return 1
}

moved_existing_count() {
    local before="$1"
    local after="$2"

    awk '
        FNR == NR {
            before[$1] = $2 " " $3 " " $4 " " $5;
            next;
        }
        {
            if (!($1 in before)) {
                next;
            }
            split(before[$1], origin, " ");
            dx = $2 - origin[1];
            dy = $3 - origin[2];
            dw = $4 - origin[3];
            dh = $5 - origin[4];
            if ((dx * dx) > 1.0 || (dy * dy) > 1.0 || (dw * dw) > 1.0 || (dh * dh) > 1.0) {
                moved++;
            }
        }
        END { print moved + 0; }
    ' "$before" "$after"
}

run_scenario() {
    local scenario="$1"
    local scenario_dir="$BENCH_DIR/$scenario"
    mkdir -p "$scenario_dir"

    local windows_log="$scenario_dir/windows.log"
    local klotski_log="$scenario_dir/klotski.log"
    local config="$scenario_dir/klotski.conf"
    local windows_before="$scenario_dir/windows-before.txt"
    local windows_after="$scenario_dir/windows-after.txt"
    local active_index
    active_index="$(active_index_for_scenario "$scenario")"

    : > "$windows_log"
    : > "$klotski_log"
    write_config "$config"

    local harness_pid=""
    local klotski_pid=""

    cleanup_scenario() {
        if [[ -n "$klotski_pid" ]] && kill -0 "$klotski_pid" 2>/dev/null; then
            kill "$klotski_pid" 2>/dev/null || true
            wait "$klotski_pid" 2>/dev/null || true
        fi

        if [[ -n "$harness_pid" ]] && kill -0 "$harness_pid" 2>/dev/null; then
            kill "$harness_pid" 2>/dev/null || true
            wait "$harness_pid" 2>/dev/null || true
        fi
    }
    trap cleanup_scenario RETURN

    KLOTSKI_HARNESS_WINDOWS="$BASE_WINDOWS" "$HARNESS" > "$windows_log" 2>&1 &
    harness_pid="$!"

    local managed_pid
    managed_pid="$(wait_for_harness_pid "$harness_pid" "$windows_log")"

    KLOTSKI_CONFIG="$config" \
    KLOTSKI_MANAGED_PID="$managed_pid" \
    KLOTSKI_BENCH=1 \
    KLOTSKI_BENCH_ACTIVE_INDEX="$active_index" \
    KLOTSKI_RESCAN_INTERVAL_SEC="$RESCAN_INTERVAL_SEC" \
    "$KLOTSKI" > "$klotski_log" 2>&1 &
    klotski_pid="$!"

    wait_for_klotski_ready "$klotski_pid" "$klotski_log"
    wait_for_active_focus "$klotski_pid" "$klotski_log" "$active_index" >/dev/null
    wait_for_initial_layout "$klotski_pid" "$klotski_log" "$BASE_WINDOWS"
    sleep "$SETTLE_SEC"
    wait_for_window_count "$managed_pid" "$BASE_WINDOWS" "$windows_before"

    kill -USR1 "$harness_pid"
    local created_line
    created_line="$(wait_for_created_window "$windows_log" "$((BASE_WINDOWS + 1))")"
    local created_id created_t shown_t
    created_id="$(field_value "$created_line" "id")"
    created_t="$(field_value "$created_line" "t")"
    shown_t="$(field_value "$created_line" "shown_t" || true)"
    if [[ -z "$shown_t" ]]; then
        shown_t="$created_t"
    fi

    local notice_line
    notice_line="$(wait_for_notice_line "$klotski_log" "$created_id")"
    local notice_t notice_ms before_columns after_columns before_active after_active policy fullscreen_known fullscreen role subrole
    notice_t="$(field_value "$notice_line" "t")"
    notice_ms="$(field_value "$notice_line" "notice_ms")"
    policy="$(field_value "$notice_line" "policy")"
    fullscreen_known="$(field_value "$notice_line" "fullscreen_known")"
    fullscreen="$(field_value "$notice_line" "fullscreen")"
    role="$(field_value "$notice_line" "role")"
    subrole="$(field_value "$notice_line" "subrole")"
    before_columns="$(field_value "$notice_line" "before_columns")"
    after_columns="$(field_value "$notice_line" "after_columns")"
    before_active="$(field_value "$notice_line" "before_active")"
    after_active="$(field_value "$notice_line" "after_active")"

    local layout_line
    layout_line="$(wait_for_layout_after_notice "$klotski_log" "$notice_t" "$((BASE_WINDOWS + 1))")"
    local layout_t layout_ms writes skipped failed columns matched
    layout_t="$(field_value "$layout_line" "t")"
    layout_ms="$(field_value "$layout_line" "ms")"
    writes="$(field_value "$layout_line" "writes")"
    skipped="$(field_value "$layout_line" "skipped")"
    failed="$(field_value "$layout_line" "failed")"
    columns="$(field_value "$layout_line" "columns")"
    matched="$(field_value "$layout_line" "matched")"

    local hints_line
    if hints_line="$(wait_for_hints_line "$klotski_log" "$created_id")"; then
        fullscreen_known="$(field_value "$hints_line" "fullscreen_known")"
        fullscreen="$(field_value "$hints_line" "fullscreen")"
        role="$(field_value "$hints_line" "role")"
        subrole="$(field_value "$hints_line" "subrole")"
    fi

    sleep "$SETTLE_SEC"
    wait_for_window_count "$managed_pid" "$((BASE_WINDOWS + 1))" "$windows_after"

    local moved_existing
    moved_existing="$(moved_existing_count "$windows_before" "$windows_after")"

    local create_to_notice_ms shown_to_notice_ms notice_to_layout_ms create_to_layout_ms shown_to_layout_ms
    create_to_notice_ms="$(awk -v a="$created_t" -v b="$notice_t" 'BEGIN { printf "%.3f", (b - a) * 1000.0 }')"
    shown_to_notice_ms="$(awk -v a="$shown_t" -v b="$notice_t" 'BEGIN { printf "%.3f", (b - a) * 1000.0 }')"
    notice_to_layout_ms="$(awk -v a="$notice_t" -v b="$layout_t" 'BEGIN { printf "%.3f", (b - a) * 1000.0 }')"
    create_to_layout_ms="$(awk -v a="$created_t" -v b="$layout_t" 'BEGIN { printf "%.3f", (b - a) * 1000.0 }')"
    shown_to_layout_ms="$(awk -v a="$shown_t" -v b="$layout_t" 'BEGIN { printf "%.3f", (b - a) * 1000.0 }')"

    echo "macos_window_add scenario=$scenario active_index=$active_index base_windows=$BASE_WINDOWS new_window=$created_id create_to_notice_ms=$create_to_notice_ms shown_to_notice_ms=$shown_to_notice_ms notice_ms=$notice_ms notice_to_layout_ms=$notice_to_layout_ms create_to_layout_ms=$create_to_layout_ms shown_to_layout_ms=$shown_to_layout_ms layout_ms=$layout_ms writes=$writes skipped=$skipped failed=$failed moved_existing=$moved_existing policy=$policy fullscreen_known=$fullscreen_known fullscreen=$fullscreen role=$role subrole=$subrole before_columns=$before_columns after_columns=$after_columns before_active=$before_active after_active=$after_active columns=$columns matched=$matched"

    cleanup_scenario
    trap - RETURN
}

for scenario in $SCENARIOS; do
    case "$scenario" in
        left|middle|right)
            run_scenario "$scenario"
            ;;
        *)
            echo "unknown scenario: $scenario" >&2
            exit 2
            ;;
    esac
done

echo "window_add_logs dir=$BENCH_DIR"
