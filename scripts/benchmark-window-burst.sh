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
BENCH_DIR="$BUILD_DIR/bench-window-burst"
CORE_BENCH="$BUILD_DIR/bench_core"
KLOTSKI="$BIN_DIR/klotski"
HARNESS="$BIN_DIR/klotski-harness"
LIST_WINDOWS="$BIN_DIR/klotski-list-windows"

BASE_WINDOWS="${KLOTSKI_WINDOW_BURST_BASE_WINDOWS:-8}"
BURST_COUNTS="${KLOTSKI_WINDOW_BURST_COUNTS:-2 3 5}"
ACTIVE_INDEX="${KLOTSKI_WINDOW_BURST_ACTIVE_INDEX:-$((BASE_WINDOWS / 2))}"
SETTLE_SEC="${KLOTSKI_WINDOW_BURST_SETTLE_SEC:-0.25}"
RESCAN_INTERVAL_SEC="${KLOTSKI_WINDOW_BURST_RESCAN_INTERVAL_SEC:-0.05}"
MAX_LAYOUTS_TO_FINAL="${KLOTSKI_WINDOW_BURST_MAX_LAYOUTS_TO_FINAL:-2}"

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

    for _ in $(seq 1 160); do
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

    echo "timed out waiting for final burst layout after notice_t=$notice_t" >&2
    cat "$klotski_log" >&2
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

display_right_for() {
    local windows_file="$1"

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
    }' "$windows_file"
}

count_visible_overlaps() {
    local windows_file="$1"
    local display_right="$2"

    awk -v display_right="$display_right" '
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
    ' "$windows_file"
}

layout_stats_between() {
    local klotski_log="$1"
    local start_t="$2"
    local end_t="$3"

    awk -v start_t="$start_t" -v end_t="$end_t" '/bench layout_apply/ {
        t = "";
        writes = 0;
        skipped = 0;
        failed = 0;
        ms = 0.0;
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^t=/) {
                value = $i;
                sub(/^t=/, "", value);
                t = value;
            } else if ($i ~ /^writes=/) {
                value = $i;
                sub(/^writes=/, "", value);
                writes = value;
            } else if ($i ~ /^skipped=/) {
                value = $i;
                sub(/^skipped=/, "", value);
                skipped = value;
            } else if ($i ~ /^failed=/) {
                value = $i;
                sub(/^failed=/, "", value);
                failed = value;
            } else if ($i ~ /^ms=/) {
                value = $i;
                sub(/^ms=/, "", value);
                ms = value;
            }
        }
        if (t >= start_t && t <= end_t) {
            count++;
            total_writes += writes;
            total_skipped += skipped;
            total_failed += failed;
            if (ms > max_ms) {
                max_ms = ms;
            }
        }
    } END {
        printf "%d %d %d %d %.3f\n", count + 0, total_writes + 0, total_skipped + 0, total_failed + 0, max_ms + 0.0;
    }' "$klotski_log"
}

run_burst() {
    local burst_count="$1"
    local scenario_dir="$BENCH_DIR/burst-$burst_count"
    mkdir -p "$scenario_dir"

    local windows_log="$scenario_dir/windows.log"
    local klotski_log="$scenario_dir/klotski.log"
    local config="$scenario_dir/klotski.conf"
    local windows_before="$scenario_dir/windows-before.txt"
    local windows_after="$scenario_dir/windows-after.txt"
    local timing_pairs="$scenario_dir/shown-notice-times.txt"
    local created_times="$scenario_dir/created-times.txt"
    local shown_times="$scenario_dir/shown-times.txt"
    local notice_times="$scenario_dir/notice-times.txt"

    : > "$windows_log"
    : > "$klotski_log"
    : > "$timing_pairs"
    : > "$created_times"
    : > "$shown_times"
    : > "$notice_times"
    write_config "$config"

    local harness_pid=""
    local klotski_pid=""

    cleanup_burst() {
        if [[ -n "$klotski_pid" ]] && kill -0 "$klotski_pid" 2>/dev/null; then
            kill "$klotski_pid" 2>/dev/null || true
            wait "$klotski_pid" 2>/dev/null || true
        fi

        if [[ -n "$harness_pid" ]] && kill -0 "$harness_pid" 2>/dev/null; then
            kill "$harness_pid" 2>/dev/null || true
            wait "$harness_pid" 2>/dev/null || true
        fi
    }
    trap cleanup_burst RETURN

    KLOTSKI_HARNESS_WINDOWS="$BASE_WINDOWS" \
    KLOTSKI_HARNESS_BURST_WINDOWS="$burst_count" \
    "$HARNESS" > "$windows_log" 2>&1 &
    harness_pid="$!"

    local managed_pid
    managed_pid="$(wait_for_harness_pid "$harness_pid" "$windows_log")"

    KLOTSKI_CONFIG="$config" \
    KLOTSKI_MANAGED_PID="$managed_pid" \
    KLOTSKI_BENCH=1 \
    KLOTSKI_BENCH_ACTIVE_INDEX="$ACTIVE_INDEX" \
    KLOTSKI_RESCAN_INTERVAL_SEC="$RESCAN_INTERVAL_SEC" \
    "$KLOTSKI" > "$klotski_log" 2>&1 &
    klotski_pid="$!"

    wait_for_klotski_ready "$klotski_pid" "$klotski_log"
    wait_for_active_focus "$klotski_pid" "$klotski_log" "$ACTIVE_INDEX" >/dev/null
    wait_for_initial_layout "$klotski_pid" "$klotski_log" "$BASE_WINDOWS"
    sleep "$SETTLE_SEC"
    wait_for_window_count "$managed_pid" "$BASE_WINDOWS" "$windows_before"

    kill -USR2 "$harness_pid"

    local direct_notices=0
    local scan_notices=0
    local expected_total=$((BASE_WINDOWS + burst_count))
    local first_window="-"
    local last_window="-"

    for offset in $(seq 1 "$burst_count"); do
        local expected_index=$((BASE_WINDOWS + offset))
        local created_line
        created_line="$(wait_for_created_window "$windows_log" "$expected_index")"

        local created_id created_t shown_t
        created_id="$(field_value "$created_line" "id")"
        created_t="$(field_value "$created_line" "t")"
        shown_t="$(field_value "$created_line" "shown_t" || true)"
        if [[ -z "$shown_t" ]]; then
            shown_t="$created_t"
        fi

        if [[ "$first_window" == "-" ]]; then
            first_window="$created_id"
        fi
        last_window="$created_id"

        printf '%s\n' "$created_t" >> "$created_times"
        printf '%s\n' "$shown_t" >> "$shown_times"

        local notice_line
        notice_line="$(wait_for_notice_line "$klotski_log" "$created_id")"
        local notice_t source
        notice_t="$(field_value "$notice_line" "t")"
        source="$(field_value "$notice_line" "source" || true)"
        if [[ "$source" == "ax-created" ]]; then
            direct_notices=$((direct_notices + 1))
        else
            scan_notices=$((scan_notices + 1))
        fi

        printf '%s\n' "$notice_t" >> "$notice_times"
        printf '%s %s\n' "$shown_t" "$notice_t" >> "$timing_pairs"
    done

    local first_created_t last_created_t first_shown_t last_shown_t first_notice_t last_notice_t
    read -r first_created_t last_created_t < <(awk 'NR == 1 { first = $1 } { last = $1 } END { print first, last }' "$created_times")
    read -r first_shown_t last_shown_t < <(awk 'NR == 1 { first = $1 } { last = $1 } END { print first, last }' "$shown_times")
    read -r first_notice_t last_notice_t < <(awk 'NR == 1 { first = $1 } { last = $1 } END { print first, last }' "$notice_times")

    local layout_line
    layout_line="$(wait_for_layout_after_notice "$klotski_log" "$last_notice_t" "$expected_total")"
    local layout_t layout_ms writes skipped failed columns matched
    layout_t="$(field_value "$layout_line" "t")"
    layout_ms="$(field_value "$layout_line" "ms")"
    writes="$(field_value "$layout_line" "writes")"
    skipped="$(field_value "$layout_line" "skipped")"
    failed="$(field_value "$layout_line" "failed")"
    columns="$(field_value "$layout_line" "columns")"
    matched="$(field_value "$layout_line" "matched")"

    sleep "$SETTLE_SEC"
    wait_for_window_count "$managed_pid" "$expected_total" "$windows_after"

    local moved_existing
    moved_existing="$(moved_existing_count "$windows_before" "$windows_after")"

    local display_right overlaps
    display_right="$(display_right_for "$windows_before")"
    overlaps="$(count_visible_overlaps "$windows_after" "$display_right")"

    local created_span_ms shown_span_ms notice_span_ms first_shown_to_first_notice_ms
    local avg_shown_to_notice_ms max_shown_to_notice_ms last_notice_to_layout_ms
    local first_shown_to_layout_ms last_shown_to_layout_ms
    created_span_ms="$(ms_delta "$first_created_t" "$last_created_t")"
    shown_span_ms="$(ms_delta "$first_shown_t" "$last_shown_t")"
    notice_span_ms="$(ms_delta "$first_notice_t" "$last_notice_t")"
    first_shown_to_first_notice_ms="$(ms_delta "$first_shown_t" "$first_notice_t")"
    read -r avg_shown_to_notice_ms max_shown_to_notice_ms < <(
        awk '{
            delta = ($2 - $1) * 1000.0;
            total += delta;
            if (delta > max) {
                max = delta;
            }
        } END {
            printf "%.3f %.3f\n", total / NR, max;
        }' "$timing_pairs"
    )
    last_notice_to_layout_ms="$(ms_delta "$last_notice_t" "$layout_t")"
    first_shown_to_layout_ms="$(ms_delta "$first_shown_t" "$layout_t")"
    last_shown_to_layout_ms="$(ms_delta "$last_shown_t" "$layout_t")"

    local layouts_to_final total_writes total_skipped total_failed max_layout_ms
    read -r layouts_to_final total_writes total_skipped total_failed max_layout_ms < <(
        layout_stats_between "$klotski_log" "$first_notice_t" "$layout_t"
    )

    echo "macos_window_burst count=$burst_count active_index=$ACTIVE_INDEX base_windows=$BASE_WINDOWS first_window=$first_window last_window=$last_window created_span_ms=$created_span_ms shown_span_ms=$shown_span_ms notice_span_ms=$notice_span_ms first_shown_to_notice_ms=$first_shown_to_first_notice_ms avg_shown_to_notice_ms=$avg_shown_to_notice_ms max_shown_to_notice_ms=$max_shown_to_notice_ms last_notice_to_layout_ms=$last_notice_to_layout_ms first_shown_to_layout_ms=$first_shown_to_layout_ms last_shown_to_layout_ms=$last_shown_to_layout_ms layout_ms=$layout_ms layouts_to_final=$layouts_to_final max_layouts_to_final=$MAX_LAYOUTS_TO_FINAL max_layout_ms=$max_layout_ms writes=$writes skipped=$skipped failed=$failed total_writes=$total_writes total_failed=$total_failed direct_notices=$direct_notices scan_notices=$scan_notices moved_existing=$moved_existing overlaps=$overlaps columns=$columns matched=$matched"

    if [[ "$failed" -ne 0 || "$total_failed" -ne 0 ]]; then
        echo "burst benchmark saw failed frame writes" >&2
        cat "$klotski_log" >&2
        return 1
    fi

    if [[ "$overlaps" -ne 0 ]]; then
        echo "burst benchmark detected visible harness window overlap" >&2
        echo "after:" >&2
        cat "$windows_after" >&2
        return 1
    fi

    if [[ "$layouts_to_final" -gt "$MAX_LAYOUTS_TO_FINAL" ]]; then
        echo "burst benchmark used too many layout applications before final layout" >&2
        cat "$klotski_log" >&2
        return 1
    fi

    cleanup_burst
    trap - RETURN
}

for burst_count in $BURST_COUNTS; do
    if [[ "$burst_count" -lt 1 ]]; then
        echo "invalid burst count: $burst_count" >&2
        exit 2
    fi

    run_burst "$burst_count"
done

echo "window_burst_logs dir=$BENCH_DIR"
