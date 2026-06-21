#include "core/config.h"
#include "core/controller.h"
#include "core/gesture.h"

#include <math.h>
#include <stdio.h>
#include <time.h>

#define BENCH_COLUMNS 128
#define ADD_BASE_COLUMNS 64
#define ARRANGE_ITERATIONS 200000
#define GESTURE_ITERATIONS 20000
#define GESTURE_STEPS 24
#define ADD_ITERATIONS 20000
#define BURST_ITERATIONS 10000

static double bench_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec + ((double) ts.tv_nsec / 1000000000.0);
}

static void setup_controller_with_count(kl_controller_t *controller, size_t columns)
{
    kl_config_t config = kl_config_default();
    kl_controller_init(
        controller,
        config.layout,
        (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 1440.0, .height = 900.0});

    for (size_t i = 0; i < columns; i++) {
        kl_controller_notice_window(controller, (kl_window_id_t) i + 1);
    }

    kl_strip_focus(&kl_controller_workspace(controller)->strip, 0, controller->viewport.width);
}

static void setup_controller(kl_controller_t *controller)
{
    setup_controller_with_count(controller, BENCH_COLUMNS);
}

static void bench_arrange(void)
{
    kl_controller_t controller;
    setup_controller(&controller);

    kl_rect_t frames[KL_STRIP_MAX_COLUMNS];
    volatile double checksum = 0.0;
    double max_viewport = kl_strip_max_scroll_viewport_x(
        &kl_controller_workspace(&controller)->strip,
        controller.viewport.width);

    double started_at = bench_seconds();
    for (size_t i = 0; i < ARRANGE_ITERATIONS; i++) {
        kl_controller_workspace(&controller)->strip.viewport_x = fmod((double) i * 17.0, max_viewport);
        size_t count = kl_controller_arrange(&controller, frames, KL_STRIP_MAX_COLUMNS);
        checksum += frames[i % count].x;
    }
    double elapsed = bench_seconds() - started_at;

    printf(
        "bench_core arrange columns=%d iterations=%d total_ms=%.3f ns_per_iter=%.3f checksum=%.3f\n",
        BENCH_COLUMNS,
        ARRANGE_ITERATIONS,
        elapsed * 1000.0,
        (elapsed * 1000000000.0) / (double) ARRANGE_ITERATIONS,
        checksum);
}

static void bench_gesture(void)
{
    kl_controller_t controller;
    setup_controller(&controller);

    volatile double checksum = 0.0;
    double started_at = bench_seconds();
    for (size_t i = 0; i < GESTURE_ITERATIONS; i++) {
        kl_horizontal_gesture_t gesture = {0};
        kl_horizontal_gesture_begin(&gesture, &controller);

        for (size_t step = 0; step < GESTURE_STEPS; step++) {
            double direction = (i % 2) == 0 ? 1.0 : -1.0;
            double visual = kl_horizontal_gesture_update(
                &gesture,
                &controller,
                direction * 12.0,
                ((double) i * 0.5) + ((double) step * 0.008));
            checksum += visual;
        }

        kl_horizontal_gesture_result_t result = kl_horizontal_gesture_finish(
            &gesture,
            &controller,
            ((double) i * 0.5) + ((double) GESTURE_STEPS * 0.008));
        checksum += result.target_viewport_x;
    }
    double elapsed = bench_seconds() - started_at;

    printf(
        "bench_core gesture columns=%d gestures=%d steps=%d total_ms=%.3f us_per_gesture=%.3f checksum=%.3f\n",
        BENCH_COLUMNS,
        GESTURE_ITERATIONS,
        GESTURE_STEPS,
        elapsed * 1000.0,
        (elapsed * 1000000.0) / (double) GESTURE_ITERATIONS,
        checksum);
}

static void bench_window_add_scenario(const char *scenario, size_t active_index)
{
    volatile double checksum = 0.0;

    kl_controller_t moved_controller;
    setup_controller_with_count(&moved_controller, ADD_BASE_COLUMNS);
    kl_strip_focus(&kl_controller_workspace(&moved_controller)->strip, active_index, moved_controller.viewport.width);

    kl_rect_t before_frames[KL_STRIP_MAX_COLUMNS];
    kl_window_id_t before_ids[KL_STRIP_MAX_COLUMNS];
    size_t before_count =
        kl_controller_arrange(&moved_controller, before_frames, KL_STRIP_MAX_COLUMNS);
    for (size_t i = 0; i < before_count; i++) {
        before_ids[i] = kl_controller_workspace(&moved_controller)->strip.columns[i].window_id;
    }

    kl_controller_notice_window(&moved_controller, (kl_window_id_t) 999999);
    kl_rect_t after_frames[KL_STRIP_MAX_COLUMNS];
    size_t after_count =
        kl_controller_arrange(&moved_controller, after_frames, KL_STRIP_MAX_COLUMNS);
    size_t moved_existing = 0;
    for (size_t before = 0; before < before_count; before++) {
        for (size_t after = 0; after < after_count; after++) {
            if (kl_controller_workspace(&moved_controller)->strip.columns[after].window_id != before_ids[before]) {
                continue;
            }

            double dx = after_frames[after].x - before_frames[before].x;
            double dy = after_frames[after].y - before_frames[before].y;
            double dw = after_frames[after].width - before_frames[before].width;
            double dh = after_frames[after].height - before_frames[before].height;
            if ((dx * dx) > 1.0 || (dy * dy) > 1.0 || (dw * dw) > 1.0 || (dh * dh) > 1.0) {
                moved_existing++;
            }
            break;
        }
    }

    double started_at = bench_seconds();

    for (size_t i = 0; i < ADD_ITERATIONS; i++) {
        kl_controller_t controller;
        setup_controller_with_count(&controller, ADD_BASE_COLUMNS);
        kl_strip_focus(&kl_controller_workspace(&controller)->strip, active_index, controller.viewport.width);

        kl_controller_notice_window(
            &controller,
            (kl_window_id_t) 1000000 + (kl_window_id_t) i);

        kl_rect_t frames[KL_STRIP_MAX_COLUMNS];
        size_t count = kl_controller_arrange(&controller, frames, KL_STRIP_MAX_COLUMNS);
        checksum += (double) kl_controller_workspace(&controller)->strip.active;
        checksum += frames[kl_controller_workspace(&controller)->strip.active % count].x;
    }

    double elapsed = bench_seconds() - started_at;
    printf(
        "bench_core window_add scenario=%s base_columns=%d moved_existing=%zu iterations=%d total_ms=%.3f us_per_add_layout=%.3f checksum=%.3f\n",
        scenario,
        ADD_BASE_COLUMNS,
        moved_existing,
        ADD_ITERATIONS,
        elapsed * 1000.0,
        (elapsed * 1000000.0) / (double) ADD_ITERATIONS,
        checksum);
}

static void bench_window_add(void)
{
    bench_window_add_scenario("left", 0);
    bench_window_add_scenario("middle", ADD_BASE_COLUMNS / 2);
    bench_window_add_scenario("right", ADD_BASE_COLUMNS - 1);
}

static size_t moved_existing_after_burst(size_t active_index, size_t burst_count)
{
    kl_controller_t controller;
    setup_controller_with_count(&controller, ADD_BASE_COLUMNS);
    kl_strip_focus(&kl_controller_workspace(&controller)->strip, active_index, controller.viewport.width);

    kl_rect_t before_frames[KL_STRIP_MAX_COLUMNS];
    kl_window_id_t before_ids[KL_STRIP_MAX_COLUMNS];
    size_t before_count = kl_controller_arrange(&controller, before_frames, KL_STRIP_MAX_COLUMNS);
    for (size_t i = 0; i < before_count; i++) {
        before_ids[i] = kl_controller_workspace(&controller)->strip.columns[i].window_id;
    }

    for (size_t i = 0; i < burst_count; i++) {
        kl_controller_notice_window(&controller, (kl_window_id_t) 900000 + (kl_window_id_t) i);
    }

    kl_rect_t after_frames[KL_STRIP_MAX_COLUMNS];
    size_t after_count = kl_controller_arrange(&controller, after_frames, KL_STRIP_MAX_COLUMNS);
    size_t moved_existing = 0;
    for (size_t before = 0; before < before_count; before++) {
        for (size_t after = 0; after < after_count; after++) {
            if (kl_controller_workspace(&controller)->strip.columns[after].window_id != before_ids[before]) {
                continue;
            }

            double dx = after_frames[after].x - before_frames[before].x;
            double dy = after_frames[after].y - before_frames[before].y;
            double dw = after_frames[after].width - before_frames[before].width;
            double dh = after_frames[after].height - before_frames[before].height;
            if ((dx * dx) > 1.0 || (dy * dy) > 1.0 || (dw * dw) > 1.0 || (dh * dh) > 1.0) {
                moved_existing++;
            }
            break;
        }
    }

    return moved_existing;
}

static void bench_window_burst_count(size_t burst_count)
{
    size_t active_index = ADD_BASE_COLUMNS / 2;
    size_t moved_existing = moved_existing_after_burst(active_index, burst_count);
    volatile double checksum = 0.0;
    double started_at = bench_seconds();

    for (size_t i = 0; i < BURST_ITERATIONS; i++) {
        kl_controller_t controller;
        setup_controller_with_count(&controller, ADD_BASE_COLUMNS);
        kl_strip_focus(&kl_controller_workspace(&controller)->strip, active_index, controller.viewport.width);

        for (size_t burst = 0; burst < burst_count; burst++) {
            kl_controller_notice_window(
                &controller,
                (kl_window_id_t) 2000000 +
                    (kl_window_id_t) (i * burst_count) +
                    (kl_window_id_t) burst);
        }

        kl_rect_t frames[KL_STRIP_MAX_COLUMNS];
        size_t count = kl_controller_arrange(&controller, frames, KL_STRIP_MAX_COLUMNS);
        checksum += (double) kl_controller_workspace(&controller)->strip.active;
        checksum += frames[kl_controller_workspace(&controller)->strip.active % count].x;
    }

    double elapsed = bench_seconds() - started_at;
    printf(
        "bench_core window_burst count=%zu base_columns=%d moved_existing=%zu iterations=%d total_ms=%.3f us_per_burst_layout=%.3f checksum=%.3f\n",
        burst_count,
        ADD_BASE_COLUMNS,
        moved_existing,
        BURST_ITERATIONS,
        elapsed * 1000.0,
        (elapsed * 1000000.0) / (double) BURST_ITERATIONS,
        checksum);
}

static void bench_window_burst(void)
{
    bench_window_burst_count(2);
    bench_window_burst_count(3);
    bench_window_burst_count(5);
}

int main(void)
{
    bench_arrange();
    bench_gesture();
    bench_window_add();
    bench_window_burst();
    return 0;
}
