#include "platform/macos/runtime.h"

#include "core/config.h"
#include "core/controller.h"
#include "core/input.h"
#include "core/interaction.h"
#include "platform/macos/accessibility.h"
#include "platform/macos/window_server.h"
#include "platform/macos/window_observer.h"

#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>

#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <math.h>
#include <ctype.h>

enum {
    KL_KEY_A = 0,
    KL_KEY_S = 1,
    KL_KEY_D = 2,
    KL_KEY_F = 3,
    KL_KEY_H = 4,
    KL_KEY_G = 5,
    KL_KEY_Z = 6,
    KL_KEY_X = 7,
    KL_KEY_C = 8,
    KL_KEY_V = 9,
    KL_KEY_B = 11,
    KL_KEY_Q = 12,
    KL_KEY_W = 13,
    KL_KEY_E = 14,
    KL_KEY_R = 15,
    KL_KEY_Y = 16,
    KL_KEY_T = 17,
    KL_KEY_1 = 18,
    KL_KEY_2 = 19,
    KL_KEY_3 = 20,
    KL_KEY_4 = 21,
    KL_KEY_6 = 22,
    KL_KEY_5 = 23,
    KL_KEY_EQUAL = 24,
    KL_KEY_9 = 25,
    KL_KEY_7 = 26,
    KL_KEY_MINUS = 27,
    KL_KEY_8 = 28,
    KL_KEY_0 = 29,
    KL_KEY_BRACKET_RIGHT = 30,
    KL_KEY_O = 31,
    KL_KEY_U = 32,
    KL_KEY_BRACKET_LEFT = 33,
    KL_KEY_I = 34,
    KL_KEY_P = 35,
    KL_KEY_RETURN = 36,
    KL_KEY_L = 37,
    KL_KEY_J = 38,
    KL_KEY_K = 40,
    KL_KEY_COMMA = 43,
    KL_KEY_N = 45,
    KL_KEY_M = 46,
    KL_KEY_PERIOD = 47,
    KL_KEY_TAB = 48,
    KL_KEY_SPACE = 49,
    KL_KEY_ESCAPE = 53,
    KL_KEY_HOME = 115,
    KL_KEY_PAGE_UP = 116,
    KL_KEY_END = 119,
    KL_KEY_PAGE_DOWN = 121,
    KL_KEY_LEFT = 123,
    KL_KEY_RIGHT = 124,
    KL_KEY_DOWN = 125,
    KL_KEY_UP = 126,
};

#define KL_RUNTIME_DEFAULT_GESTURE_APPLY_HZ 120.0
#define KL_RUNTIME_MIN_GESTURE_APPLY_HZ 30.0
#define KL_RUNTIME_MAX_GESTURE_APPLY_HZ 240.0
#define KL_RUNTIME_DIRECT_SCROLL_ACTIVE_SPEED_MULTIPLIER 6.0
#define KL_RUNTIME_DEFAULT_RESCAN_INTERVAL 0.05
#define KL_RUNTIME_MIN_RESCAN_INTERVAL 0.02
#define KL_RUNTIME_MAX_RESCAN_INTERVAL 5.0
#define KL_RUNTIME_WINDOW_EVENT_RETRY_INTERVAL 0.008
#define KL_RUNTIME_WINDOW_EVENT_RETRY_ATTEMPTS 8
#define KL_RUNTIME_WINDOW_EVENT_BATCH_INTERVAL 0.016
#define KL_RUNTIME_PENDING_WINDOW_EVENTS_MAX 128
#define KL_RUNTIME_LAYOUT_FEEDBACK_SECONDS 0.25
#define KL_RUNTIME_DEFAULT_CONFIG_PATH "resources/default-config.kdl"
#define KL_RUNTIME_DRAG_COMMIT_THRESHOLD 48.0
#define KL_RUNTIME_DRAG_STACK_ZONE_FRACTION 0.30

typedef struct kl_macos_pending_window_event {
    pid_t pid;
    AXUIElementRef element;
    char reason[32];
} kl_macos_pending_window_event_t;

typedef enum kl_macos_window_policy {
    KL_MACOS_WINDOW_POLICY_IGNORED,
    KL_MACOS_WINDOW_POLICY_FLOATING,
    KL_MACOS_WINDOW_POLICY_TILED,
} kl_macos_window_policy_t;

typedef struct kl_macos_managed_window_source {
    uint32_t window_id;
    pid_t pid;
} kl_macos_managed_window_source_t;

typedef struct kl_macos_drag_state {
    kl_pointer_move_grab_t grab;
    kl_macos_window_t window;
    kl_rect_t start_frame;
    kl_point_t last_point;
    uint32_t window_id;
    bool active;
    bool started_window_move;
    bool started_tiled;
} kl_macos_drag_state_t;

typedef struct kl_macos_resize_state {
    kl_pointer_resize_grab_t grab;
    kl_macos_window_t window;
    uint32_t window_id;
    double start_width;
    double start_viewport_x;
    bool from_left_edge;
    bool active;
} kl_macos_resize_state_t;

typedef struct kl_macos_runtime {
    kl_controller_t controller;
    kl_config_t config;
    kl_three_finger_swipe_t three_finger_swipe;
    kl_view_scroll_gesture_t touch_scroll_gesture;
    kl_macos_drag_state_t drag;
    kl_macos_resize_state_t resize;
    kl_macos_window_list_t window_list;
    kl_macos_window_frame_cache_t window_frame_cache;
    kl_macos_managed_window_source_t managed_window_sources[KL_MACOS_MAX_WINDOWS];
    uint32_t focused_window_id;
    pid_t managed_pid_filter;
    CFMachPortRef event_tap;
    CFRunLoopSourceRef event_source;
    kl_macos_window_observer_t *window_observer;
    NSTimer *rescan_timer;
    NSTimer *animation_timer;
    NSTimer *scroll_flush_timer;
    NSTimer *scroll_settle_timer;
    NSTimer *gesture_apply_timer;
    NSTimer *window_event_retry_timer;
    NSTimer *window_event_batch_timer;
    kl_macos_pending_window_event_t pending_window_events[KL_RUNTIME_PENDING_WINDOW_EVENTS_MAX];
    bool scrolling_active;
    bool direct_scroll_active;
    bool touch_centroid_valid;
    bool visual_viewport_valid;
    bool gesture_apply_pending;
    bool window_list_valid;
    bool applied_viewport_valid;
    bool benchmark_active_focus_pending;
    double pending_scroll_pixels;
    double visual_viewport_x;
    double applied_viewport_x;
    double touch_centroid_x;
    double touch_centroid_y;
    double last_animation_time;
    double last_gesture_apply_time;
    double last_layout_apply_at;
    kl_point_t last_pointer;
    uint64_t layout_apply_count;
    size_t pending_window_event_count;
    size_t managed_window_source_count;
    size_t benchmark_active_focus_index;
    int window_event_retry_remaining;
} kl_macos_runtime_t;

static kl_workspace_t *runtime_workspace(kl_macos_runtime_t *runtime)
{
    return kl_controller_workspace(&runtime->controller);
}

static const kl_workspace_t *runtime_workspace_const(const kl_macos_runtime_t *runtime)
{
    return kl_controller_workspace_const(&runtime->controller);
}

static kl_strip_t *runtime_strip(kl_macos_runtime_t *runtime)
{
    return &runtime_workspace(runtime)->strip;
}

static bool runtime_remove_window_from_model(
    kl_macos_runtime_t *runtime,
    uint32_t window_id);
static void runtime_snap_layout(kl_macos_runtime_t *runtime);

static bool other_window_manager_is_running(void)
{
    if (getenv("KLOTSKI_ALLOW_WM_CONFLICT")) {
        return false;
    }

    int status = system("pgrep -x yabai >/dev/null 2>&1");
    return status == 0;
}

static kl_rect_t main_display_viewport(void)
{
    CGRect bounds = CGDisplayBounds(CGMainDisplayID());
    return (kl_rect_t) {
        .x = bounds.origin.x,
        .y = bounds.origin.y,
        .width = bounds.size.width,
        .height = bounds.size.height,
    };
}

static kl_rect_t runtime_ax_safe_frame(const kl_macos_runtime_t *runtime, kl_rect_t frame)
{
    const double sliver = 0.0;
    double min_x = runtime->controller.viewport.x - frame.width + sliver;
    double max_x = runtime->controller.viewport.x + runtime->controller.viewport.width - sliver;
    double min_y = runtime->controller.viewport.y;
    double max_y = runtime->controller.viewport.y + runtime->controller.viewport.height - sliver;

    frame.x = kl_clamp_double(frame.x, min_x, max_x);
    frame.y = kl_clamp_double(frame.y, min_y, max_y);
    return frame;
}

static bool runtime_frame_is_horizontally_offscreen(
    const kl_macos_runtime_t *runtime,
    kl_rect_t frame)
{
    double viewport_left = runtime->controller.viewport.x;
    double viewport_right = runtime->controller.viewport.x + runtime->controller.viewport.width;
    return frame.x + frame.width <= viewport_left || frame.x >= viewport_right;
}

static bool runtime_should_preserve_restore_width(
    kl_macos_runtime_t *runtime,
    uint32_t window_id,
    double requested_width,
    double actual_width)
{
    size_t column_index = 0;
    if (!kl_strip_find_window_location(runtime_strip(runtime), window_id, &column_index, NULL)) {
        return false;
    }

    kl_column_t *column = &runtime_strip(runtime)->columns[column_index];
    if (!column->has_restore_width) {
        return false;
    }

    double effective_width = kl_strip_effective_viewport_width(
        runtime_strip(runtime),
        runtime->controller.viewport.width);
    double changed_enough = kl_max_double(16.0, effective_width * 0.05);
    return requested_width >= effective_width * 0.85 &&
        actual_width > column->restore_width + changed_enough;
}

static bool runtime_is_stale_restore_width_feedback(
    kl_macos_runtime_t *runtime,
    uint32_t window_id,
    double actual_width)
{
    size_t column_index = 0;
    if (!kl_strip_find_window_location(runtime_strip(runtime), window_id, &column_index, NULL)) {
        return false;
    }

    kl_column_t *column = &runtime_strip(runtime)->columns[column_index];
    if (!column->has_restore_width) {
        return false;
    }

    double effective_width = kl_strip_effective_viewport_width(
        runtime_strip(runtime),
        runtime->controller.viewport.width);
    double changed_enough = kl_max_double(16.0, effective_width * 0.05);
    return column->width >= effective_width * 0.85 &&
        actual_width <= column->restore_width + changed_enough;
}

static bool runtime_is_stale_maximized_width_feedback(
    kl_macos_runtime_t *runtime,
    uint32_t window_id,
    double actual_width)
{
    size_t column_index = 0;
    if (!kl_strip_find_window_location(runtime_strip(runtime), window_id, &column_index, NULL)) {
        return false;
    }

    kl_column_t *column = &runtime_strip(runtime)->columns[column_index];
    if (column->has_restore_width) {
        return false;
    }

    double effective_width = kl_strip_effective_viewport_width(
        runtime_strip(runtime),
        runtime->controller.viewport.width);
    return column->width < effective_width * 0.85 &&
        actual_width >= effective_width * 0.85;
}

static bool runtime_managed_source_window(
    const kl_macos_runtime_t *runtime,
    uint32_t window_id,
    kl_macos_window_t *out)
{
    for (size_t i = 0; i < runtime->managed_window_source_count; i++) {
        const kl_macos_managed_window_source_t *source = &runtime->managed_window_sources[i];
        if (source->window_id != window_id) {
            continue;
        }

        if (out) {
            *out = (kl_macos_window_t) {
                .window_id = source->window_id,
                .pid = source->pid,
                .frame = {0},
            };
        }
        return true;
    }

    return false;
}

static double runtime_seconds(void)
{
    return CFAbsoluteTimeGetCurrent();
}

static bool runtime_trace_gestures(void)
{
    static int enabled = -1;
    if (enabled < 0) {
        const char *value = getenv("KLOTSKI_TRACE_GESTURES");
        enabled = value && *value != '\0' && strcmp(value, "0") != 0;
    }

    return enabled != 0;
}

static bool runtime_benchmark_enabled(void)
{
    static int enabled = -1;
    if (enabled < 0) {
        const char *value = getenv("KLOTSKI_BENCH");
        enabled = value && *value != '\0' && strcmp(value, "0") != 0;
    }

    return enabled != 0;
}

static bool runtime_load_benchmark_active_index(size_t *out)
{
    const char *value = getenv("KLOTSKI_BENCH_ACTIVE_INDEX");
    if (!value || *value == '\0') {
        return false;
    }

    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 10);
    if (end == value || *end != '\0') {
        fprintf(stderr, "ignoring invalid KLOTSKI_BENCH_ACTIVE_INDEX=%s\n", value);
        return false;
    }

    *out = (size_t) parsed;
    return true;
}

static double runtime_gesture_apply_interval(void)
{
    static double interval = -1.0;
    if (interval >= 0.0) {
        return interval;
    }

    double hz = KL_RUNTIME_DEFAULT_GESTURE_APPLY_HZ;
    const char *value = getenv("KLOTSKI_GESTURE_APPLY_HZ");
    if (value && *value != '\0') {
        char *end = NULL;
        double parsed = strtod(value, &end);
        if (end != value && *end == '\0') {
            hz = parsed;
        }
    }

    if (hz <= 0.0) {
        interval = 0.0;
    } else {
        hz = kl_clamp_double(
            hz,
            KL_RUNTIME_MIN_GESTURE_APPLY_HZ,
            KL_RUNTIME_MAX_GESTURE_APPLY_HZ);
        interval = 1.0 / hz;
    }

    return interval;
}

static double runtime_rescan_interval(void)
{
    static double interval = -1.0;
    if (interval >= 0.0) {
        return interval;
    }

    interval = KL_RUNTIME_DEFAULT_RESCAN_INTERVAL;
    const char *value = getenv("KLOTSKI_RESCAN_INTERVAL_SEC");
    if (value && *value != '\0') {
        char *end = NULL;
        double parsed = strtod(value, &end);
        if (end != value && *end == '\0') {
            interval = parsed;
        }
    }

    interval = kl_clamp_double(
        interval,
        KL_RUNTIME_MIN_RESCAN_INTERVAL,
        KL_RUNTIME_MAX_RESCAN_INTERVAL);
    return interval;
}

static NSTimer *runtime_schedule_timer(NSTimeInterval interval, BOOL repeats, void (^block)(NSTimer *timer))
{
    NSTimer *timer = [NSTimer timerWithTimeInterval:interval repeats:repeats block:block];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    return timer;
}

static void runtime_note_visual_viewport(kl_macos_runtime_t *runtime)
{
    if (!runtime->visual_viewport_valid) {
        runtime->visual_viewport_x = runtime_strip(runtime)->viewport_x;
        runtime->visual_viewport_valid = true;
    }
}

static bool runtime_refresh_window_list(kl_macos_runtime_t *runtime)
{
    kl_macos_window_list_t windows;
    if (!kl_macos_copy_window_list(&windows, runtime->managed_pid_filter)) {
        runtime->window_list_valid = false;
        return false;
    }

    runtime->window_list = windows;
    runtime->window_list_valid = true;
    return true;
}

static double runtime_visible_window_area(
    const kl_macos_runtime_t *runtime,
    kl_rect_t frame)
{
    double left = kl_max_double(frame.x, runtime->controller.viewport.x);
    double right = kl_min_double(
        frame.x + frame.width,
        runtime->controller.viewport.x + runtime->controller.viewport.width);
    double top = kl_max_double(frame.y, runtime->controller.viewport.y);
    double bottom = kl_min_double(
        frame.y + frame.height,
        runtime->controller.viewport.y + runtime->controller.viewport.height);
    return kl_max_double(0.0, right - left) * kl_max_double(0.0, bottom - top);
}

static uint32_t runtime_largest_visible_window_id(const kl_macos_runtime_t *runtime)
{
    uint32_t window_id = 0;
    double best_area = 0.0;

    for (size_t i = 0; i < runtime->window_list.count; i++) {
        const kl_macos_window_t *window = &runtime->window_list.windows[i];
        double area = runtime_visible_window_area(runtime, window->frame);
        if (area > best_area) {
            best_area = area;
            window_id = window->window_id;
        }
    }

    return window_id;
}

static void runtime_apply_layout_at_viewport_x(kl_macos_runtime_t *runtime, double viewport_x)
{
    bool benchmark = runtime_benchmark_enabled();
    double started_at = benchmark ? runtime_seconds() : 0.0;
    size_t arranged = 0;
    size_t matched = 0;
    size_t writes = 0;
    size_t skipped = 0;
    size_t deferred = 0;
    size_t failed = 0;
    size_t restored_hidden = 0;
    size_t hidden_restore_failed = 0;
    size_t width_reconciled = 0;
    double write_ms = 0.0;
    double max_write_ms = 0.0;
    bool removed_stale_window = false;
    bool reconciled_layout_width = false;

    double target_viewport_x = runtime_strip(runtime)->viewport_x;
    runtime_strip(runtime)->viewport_x = viewport_x;

    if (!runtime->window_list_valid && !runtime_refresh_window_list(runtime)) {
        runtime_strip(runtime)->viewport_x = target_viewport_x;
        if (benchmark) {
            double finished_at = runtime_seconds();
            fprintf(
                stderr,
                "bench layout_apply seq=%llu t=%.6f viewport=%.3f columns=0 matched=0 writes=0 skipped=0 deferred=0 failed=1 write_ms=0.000 max_write_ms=0.000 ms=%.3f\n",
                (unsigned long long) ++runtime->layout_apply_count,
                finished_at,
                viewport_x,
                (finished_at - started_at) * 1000.0);
        }
        return;
    }

    kl_arranged_window_t frames[KL_MACOS_MAX_WINDOWS];
    size_t count = kl_controller_arrange_windows(&runtime->controller, frames, KL_MACOS_MAX_WINDOWS);
    uint32_t arranged_window_ids[KL_MACOS_MAX_WINDOWS];
    size_t arranged_window_id_count = 0;
    for (size_t i = 0; i < count && arranged_window_id_count < KL_MACOS_MAX_WINDOWS; i++) {
        arranged_window_ids[arranged_window_id_count++] = (uint32_t) frames[i].window_id;
    }
    arranged = count;

    kl_macos_window_t visible_windows[KL_MACOS_MAX_WINDOWS];
    kl_rect_t visible_requested_frames[KL_MACOS_MAX_WINDOWS];
    bool visible_wrote_frames[KL_MACOS_MAX_WINDOWS];
    size_t visible_window_count = 0;

    bool frame_updates_paused = kl_macos_begin_frame_updates();

    for (size_t i = 0; i < count; i++) {
        uint32_t window_id = (uint32_t) frames[i].window_id;
        kl_macos_window_t window;
        bool found_cg_window = kl_macos_find_window(&runtime->window_list, window_id, &window);
        bool found_virtual_window = false;

        if (!found_cg_window) {
            found_virtual_window = runtime_managed_source_window(runtime, window_id, &window);
        }

        if (found_cg_window || found_virtual_window) {
            bool wrote_frame = false;
            kl_rect_t safe_frame = runtime_ax_safe_frame(runtime, frames[i].frame);
            bool should_hide = runtime_frame_is_horizontally_offscreen(runtime, frames[i].frame);
            size_t visible_index = KL_MACOS_MAX_WINDOWS;
            matched++;

            if (!should_hide && visible_window_count < KL_MACOS_MAX_WINDOWS) {
                visible_index = visible_window_count;
                visible_windows[visible_window_count] = window;
                visible_requested_frames[visible_window_count] = safe_frame;
                visible_wrote_frames[visible_window_count] = false;
                visible_window_count++;
            }

            if (should_hide &&
                !kl_macos_window_frame_cache_set_hidden(&runtime->window_frame_cache, &window, true)) {
                failed++;
            }

            bool needs_frame =
                kl_macos_window_frame_cache_needs_frame(&runtime->window_frame_cache, &window, safe_frame);

            if (!needs_frame) {
                if (!kl_macos_window_frame_cache_set_hidden(
                        &runtime->window_frame_cache,
                        &window,
                        should_hide)) {
                    failed++;
                }
                skipped++;
                continue;
            }

            double write_started_at = benchmark ? runtime_seconds() : 0.0;
            if (kl_macos_set_window_frame_cached(
                    &runtime->window_frame_cache,
                    &window,
                    safe_frame,
                    &wrote_frame)) {
                if (benchmark) {
                    double elapsed_ms = (runtime_seconds() - write_started_at) * 1000.0;
                    write_ms += elapsed_ms;
                    if (elapsed_ms > max_write_ms) {
                        max_write_ms = elapsed_ms;
                    }
                }
                if (wrote_frame) {
                    writes++;
                    if (visible_index < visible_window_count) {
                        visible_wrote_frames[visible_index] = true;
                    }
                } else {
                    skipped++;
                }
                if (!kl_macos_window_frame_cache_set_hidden(
                        &runtime->window_frame_cache,
                        &window,
                        should_hide)) {
                    failed++;
                }
            } else {
                if (benchmark) {
                    double elapsed_ms = (runtime_seconds() - write_started_at) * 1000.0;
                    write_ms += elapsed_ms;
                    if (elapsed_ms > max_write_ms) {
                        max_write_ms = elapsed_ms;
                    }
                }
                failed++;
                if (found_virtual_window && !found_cg_window) {
                    removed_stale_window |= runtime_remove_window_from_model(
                        runtime,
                        window_id);
                }
            }
        } else {
            deferred++;
            removed_stale_window |= runtime_remove_window_from_model(
                runtime,
                window_id);
        }
    }

    restored_hidden = kl_macos_window_frame_cache_restore_hidden_except(
        &runtime->window_frame_cache,
        arranged_window_ids,
        arranged_window_id_count,
        &hidden_restore_failed);
    failed += hidden_restore_failed;

    kl_macos_end_frame_updates(frame_updates_paused);

    for (size_t i = 0; i < visible_window_count; i++) {
        kl_rect_t actual_frame;
        if (!kl_macos_copy_window_frame(&visible_windows[i], &actual_frame)) {
            continue;
        }

        kl_macos_window_frame_cache_note_frame(
            &runtime->window_frame_cache,
            &visible_windows[i],
            actual_frame);

        if (actual_frame.width <= 1.0 ||
            fabs(actual_frame.width - visible_requested_frames[i].width) <= 1.0) {
            continue;
        }

        if (visible_wrote_frames[i]) {
            if (runtime_trace_gestures()) {
                fprintf(
                    stderr,
                    "width reconcile deferred pending_write window=%u requested=%.1f actual=%.1f\n",
                    visible_windows[i].window_id,
                    visible_requested_frames[i].width,
                    actual_frame.width);
            }
            continue;
        }

        if (runtime_is_stale_restore_width_feedback(
                runtime,
                visible_windows[i].window_id,
                actual_frame.width)) {
            if (runtime_trace_gestures()) {
                fprintf(
                    stderr,
                    "width reconcile deferred stale_restore window=%u requested=%.1f actual=%.1f\n",
                    visible_windows[i].window_id,
                    visible_requested_frames[i].width,
                    actual_frame.width);
            }
            continue;
        }

        if (runtime_is_stale_maximized_width_feedback(
                runtime,
                visible_windows[i].window_id,
                actual_frame.width)) {
            if (runtime_trace_gestures()) {
                fprintf(
                    stderr,
                    "width reconcile deferred stale_maximized window=%u requested=%.1f actual=%.1f\n",
                    visible_windows[i].window_id,
                    visible_requested_frames[i].width,
                    actual_frame.width);
            }
            continue;
        }

        bool preserve_restore_width = runtime_should_preserve_restore_width(
            runtime,
            visible_windows[i].window_id,
            visible_requested_frames[i].width,
            actual_frame.width);
        bool changed = kl_controller_reconcile_window_width(
            &runtime->controller,
            visible_windows[i].window_id,
            actual_frame.width,
            preserve_restore_width);
        if (changed) {
            width_reconciled++;
            reconciled_layout_width = true;
        }

        if (runtime_trace_gestures()) {
            fprintf(
                stderr,
                "width reconcile window=%u requested=%.1f actual=%.1f preserve_restore=%d changed=%d\n",
                visible_windows[i].window_id,
                visible_requested_frames[i].width,
                actual_frame.width,
                preserve_restore_width,
                changed);
        }
    }

    if (reconciled_layout_width) {
        target_viewport_x = kl_strip_clamp_viewport_x(
            runtime_strip(runtime),
            runtime->controller.viewport.width,
            target_viewport_x);
    }
    runtime_strip(runtime)->viewport_x = target_viewport_x;
    runtime->applied_viewport_x = viewport_x;
    runtime->applied_viewport_valid = true;
    runtime->last_layout_apply_at = runtime_seconds();

    if (benchmark) {
        double finished_at = runtime->last_layout_apply_at;
        fprintf(
            stderr,
            "bench layout_apply seq=%llu t=%.6f viewport=%.3f columns=%zu matched=%zu writes=%zu skipped=%zu deferred=%zu failed=%zu hidden_restored=%zu hidden_restore_failed=%zu width_reconciled=%zu write_ms=%.3f max_write_ms=%.3f ms=%.3f\n",
            (unsigned long long) ++runtime->layout_apply_count,
            finished_at,
            viewport_x,
            arranged,
            matched,
            writes,
            skipped,
            deferred,
            failed,
            restored_hidden,
            hidden_restore_failed,
            width_reconciled,
            write_ms,
            max_write_ms,
            (finished_at - started_at) * 1000.0);
    }

    if (removed_stale_window || reconciled_layout_width) {
        runtime_strip(runtime)->viewport_x = kl_strip_clamp_viewport_x(
            runtime_strip(runtime),
            runtime->controller.viewport.width,
            runtime_strip(runtime)->viewport_x);
        runtime_schedule_timer(0.0, NO, ^(__unused NSTimer *timer) {
            runtime_snap_layout(runtime);
        });
    }
}

static void runtime_cancel_gesture_apply(kl_macos_runtime_t *runtime)
{
    if (runtime->gesture_apply_timer) {
        [runtime->gesture_apply_timer invalidate];
        runtime->gesture_apply_timer = nil;
    }
    runtime->gesture_apply_pending = false;
}

static void runtime_flush_pending_gesture_apply(kl_macos_runtime_t *runtime)
{
    if (runtime->gesture_apply_timer) {
        [runtime->gesture_apply_timer invalidate];
        runtime->gesture_apply_timer = nil;
    }

    if (!runtime->gesture_apply_pending) {
        return;
    }

    runtime->gesture_apply_pending = false;
    if (runtime->applied_viewport_valid &&
        fabs(runtime->visual_viewport_x - runtime->applied_viewport_x) <= 0.01) {
        runtime->last_gesture_apply_time = runtime_seconds();
        return;
    }

    runtime_apply_layout_at_viewport_x(runtime, runtime->visual_viewport_x);
    runtime->last_gesture_apply_time = runtime_seconds();
}

static void runtime_schedule_gesture_apply(kl_macos_runtime_t *runtime, double timestamp)
{
    double interval = runtime_gesture_apply_interval();
    if (interval <= 0.0) {
        runtime_cancel_gesture_apply(runtime);
        runtime_apply_layout_at_viewport_x(runtime, runtime->visual_viewport_x);
        runtime->last_gesture_apply_time = runtime_seconds();
        return;
    }

    runtime->gesture_apply_pending = true;

    double elapsed = runtime->last_gesture_apply_time > 0.0
        ? timestamp - runtime->last_gesture_apply_time
        : interval;

    if (elapsed >= interval) {
        runtime_flush_pending_gesture_apply(runtime);
        return;
    }

    if (runtime->gesture_apply_timer) {
        return;
    }

    NSTimeInterval delay = kl_clamp_double(interval - elapsed, 0.0, interval);
    runtime->gesture_apply_timer = runtime_schedule_timer(delay, NO, ^(NSTimer *timer) {
        if (runtime->gesture_apply_timer == timer) {
            runtime->gesture_apply_timer = nil;
        }
        runtime_flush_pending_gesture_apply(runtime);
    });
}

static void runtime_cancel_layout_animation(kl_macos_runtime_t *runtime)
{
    if (runtime->animation_timer) {
        [runtime->animation_timer invalidate];
        runtime->animation_timer = nil;
    }
    runtime->last_animation_time = 0.0;
}

static void runtime_snap_layout(kl_macos_runtime_t *runtime)
{
    runtime_cancel_layout_animation(runtime);
    runtime_cancel_gesture_apply(runtime);
    runtime->visual_viewport_x = runtime_strip(runtime)->viewport_x;
    runtime->visual_viewport_valid = true;
    runtime_apply_layout_at_viewport_x(runtime, runtime->visual_viewport_x);
}

static void runtime_tick_layout_animation(kl_macos_runtime_t *runtime, NSTimer *timer)
{
    runtime_note_visual_viewport(runtime);

    double now = runtime_seconds();
    double dt = runtime->last_animation_time > 0.0 ? now - runtime->last_animation_time : (1.0 / 60.0);
    runtime->last_animation_time = now;

    double target = runtime_strip(runtime)->viewport_x;
    double delta = target - runtime->visual_viewport_x;
    double rate = runtime->config.horizontal_view_animation_speed;
    double amount = kl_clamp_double(1.0 - exp(-rate * dt), 0.0, 1.0);
    double next = runtime->visual_viewport_x + (delta * amount);
    bool finished = fabs(target - next) <= 0.5;

    if (finished) {
        next = target;
        if (timer) {
            [timer invalidate];
            if (runtime->animation_timer == timer) {
                runtime->animation_timer = nil;
            }
        }
        runtime->last_animation_time = 0.0;
    }

    runtime->visual_viewport_x = next;
    runtime_apply_layout_at_viewport_x(runtime, runtime->visual_viewport_x);
}

static void runtime_apply_layout(kl_macos_runtime_t *runtime)
{
    runtime_note_visual_viewport(runtime);

    if (fabs(runtime_strip(runtime)->viewport_x - runtime->visual_viewport_x) <= 0.5) {
        runtime_snap_layout(runtime);
        return;
    }

    if (!runtime->animation_timer) {
        runtime_apply_layout_at_viewport_x(runtime, runtime->visual_viewport_x);
        runtime->last_animation_time = runtime_seconds();
        runtime->animation_timer = runtime_schedule_timer(1.0 / 60.0, YES, ^(NSTimer *timer) {
            runtime_tick_layout_animation(runtime, timer);
        });
    }
}

static void runtime_apply_pending_benchmark_active_focus(kl_macos_runtime_t *runtime)
{
    if (!runtime->benchmark_active_focus_pending) {
        return;
    }

    kl_strip_t *strip = runtime_strip(runtime);
    if (runtime->benchmark_active_focus_index >= strip->count) {
        return;
    }

    size_t previous_active = strip->active;
    if (kl_strip_focus(strip, runtime->benchmark_active_focus_index, runtime->controller.viewport.width)) {
        runtime->benchmark_active_focus_pending = false;
        runtime->focused_window_id = (uint32_t) kl_strip_active_window(strip);

        if (runtime_benchmark_enabled()) {
            fprintf(
                stderr,
                "bench active_focus index=%zu previous_active=%zu active=%zu window=%u viewport=%.3f columns=%zu\n",
                runtime->benchmark_active_focus_index,
                previous_active,
                strip->active,
                runtime->focused_window_id,
                strip->viewport_x,
                strip->count);
        }
    }
}

static bool string_equals(const char *a, const char *b)
{
    return a && b && strcmp(a, b) == 0;
}

static const char *runtime_window_policy_name(
    kl_macos_window_policy_t policy)
{
    switch (policy) {
    case KL_MACOS_WINDOW_POLICY_IGNORED:
        return "ignored";
    case KL_MACOS_WINDOW_POLICY_FLOATING:
        return "floating";
    case KL_MACOS_WINDOW_POLICY_TILED:
        return "tiled";
    }

    return "tiled";
}

static kl_macos_window_policy_t runtime_window_policy(
    const kl_macos_runtime_t *runtime,
    __unused const kl_macos_window_t *window,
    const kl_macos_window_hints_t *hints)
{
    if (!hints) {
        return KL_MACOS_WINDOW_POLICY_FLOATING;
    }

    if (hints->role[0] && !string_equals(hints->role, "AXWindow")) {
        return KL_MACOS_WINDOW_POLICY_IGNORED;
    }

    if (hints->fullscreen_known && hints->fullscreen) {
        return KL_MACOS_WINDOW_POLICY_FLOATING;
    }

    for (size_t i = runtime->config.window_rule_count; i > 0; i--) {
        const kl_window_rule_t *rule = &runtime->config.window_rules[i - 1];
        if (rule->role[0] && !string_equals(rule->role, hints->role)) {
            continue;
        }
        if (rule->subrole[0] && !string_equals(rule->subrole, hints->subrole)) {
            continue;
        }
        if (rule->app_id[0] && !string_equals(rule->app_id, hints->app_id)) {
            continue;
        }
        if (rule->app_name[0] && !string_equals(rule->app_name, hints->app_name)) {
            continue;
        }

        switch (rule->action) {
        case KL_WINDOW_RULE_ACTION_IGNORED:
            return KL_MACOS_WINDOW_POLICY_IGNORED;
        case KL_WINDOW_RULE_ACTION_FLOATING:
            return KL_MACOS_WINDOW_POLICY_FLOATING;
        case KL_WINDOW_RULE_ACTION_TILED:
            return KL_MACOS_WINDOW_POLICY_TILED;
        case KL_WINDOW_RULE_ACTION_NONE:
            break;
        }
    }

    return KL_MACOS_WINDOW_POLICY_TILED;
}

static void runtime_remember_window(kl_macos_runtime_t *runtime, const kl_macos_window_t *window)
{
    if (!runtime->window_list_valid) {
        runtime_refresh_window_list(runtime);
    }

    for (size_t i = 0; i < runtime->window_list.count; i++) {
        if (runtime->window_list.windows[i].window_id == window->window_id) {
            runtime->window_list.windows[i] = *window;
            return;
        }
    }

    if (runtime->window_list.count < KL_MACOS_MAX_WINDOWS) {
        runtime->window_list.windows[runtime->window_list.count++] = *window;
        runtime->window_list_valid = true;
    }
}

static void runtime_forget_window_from_list(kl_macos_runtime_t *runtime, uint32_t window_id)
{
    for (size_t i = 0; i < runtime->window_list.count; i++) {
        if (runtime->window_list.windows[i].window_id != window_id) {
            continue;
        }

        if (i + 1 < runtime->window_list.count) {
            memmove(
                &runtime->window_list.windows[i],
                &runtime->window_list.windows[i + 1],
                (runtime->window_list.count - i - 1) * sizeof(runtime->window_list.windows[0]));
        }
        runtime->window_list.count--;
        runtime->window_list_valid = true;
        return;
    }
}

static void runtime_remember_managed_window_source(
    kl_macos_runtime_t *runtime,
    const kl_macos_window_t *window)
{
    if (!window || window->window_id == 0 || window->pid <= 0) {
        return;
    }

    for (size_t i = 0; i < runtime->managed_window_source_count; i++) {
        if (runtime->managed_window_sources[i].window_id == window->window_id) {
            runtime->managed_window_sources[i].pid = window->pid;
            return;
        }
    }

    if (runtime->managed_window_source_count == KL_MACOS_MAX_WINDOWS) {
        fprintf(stderr, "too many managed window sources to track\n");
        return;
    }

    runtime->managed_window_sources[runtime->managed_window_source_count++] =
        (kl_macos_managed_window_source_t) {
            .window_id = window->window_id,
            .pid = window->pid,
        };
}

static void runtime_forget_managed_window_source(kl_macos_runtime_t *runtime, uint32_t window_id)
{
    for (size_t i = 0; i < runtime->managed_window_source_count; i++) {
        if (runtime->managed_window_sources[i].window_id != window_id) {
            continue;
        }

        if (i + 1 < runtime->managed_window_source_count) {
            memmove(
                &runtime->managed_window_sources[i],
                &runtime->managed_window_sources[i + 1],
                (runtime->managed_window_source_count - i - 1) *
                    sizeof(runtime->managed_window_sources[0]));
        }
        runtime->managed_window_source_count--;
        return;
    }
}

static bool runtime_window_id_collected(const uint32_t *window_ids, size_t count, uint32_t window_id)
{
    for (size_t i = 0; i < count; i++) {
        if (window_ids[i] == window_id) {
            return true;
        }
    }

    return false;
}

static void runtime_collect_window_id(uint32_t *window_ids, size_t *count, uint32_t window_id)
{
    if (window_id == 0 ||
        *count == KL_MACOS_MAX_WINDOWS ||
        runtime_window_id_collected(window_ids, *count, window_id)) {
        return;
    }

    window_ids[(*count)++] = window_id;
}

static size_t runtime_collect_managed_window_ids_for_pid(
    const kl_macos_runtime_t *runtime,
    pid_t pid,
    uint32_t *window_ids,
    size_t capacity)
{
    size_t count = 0;
    if (pid <= 0 || capacity == 0) {
        return 0;
    }

    for (size_t i = 0; i < runtime->managed_window_source_count && count < capacity; i++) {
        if (runtime->managed_window_sources[i].pid == pid) {
            runtime_collect_window_id(
                window_ids,
                &count,
                runtime->managed_window_sources[i].window_id);
        }
    }

    for (size_t i = 0; i < runtime->window_list.count && count < capacity; i++) {
        if (runtime->window_list.windows[i].pid == pid) {
            runtime_collect_window_id(
                window_ids,
                &count,
                runtime->window_list.windows[i].window_id);
        }
    }

    if (count == 0 && runtime->managed_pid_filter == pid) {
        const kl_workspace_t *workspace = runtime_workspace_const(runtime);
        for (size_t i = 0; i < workspace->window_count && count < capacity; i++) {
            runtime_collect_window_id(
                window_ids,
                &count,
                (uint32_t) workspace->windows[i].window_id);
        }
    }

    return count;
}

static void runtime_sync_focused_window(kl_macos_runtime_t *runtime)
{
    runtime->focused_window_id = (uint32_t) kl_strip_active_window(runtime_strip(runtime));
}

static bool runtime_remove_window_from_model(
    kl_macos_runtime_t *runtime,
    uint32_t window_id)
{
    bool changed = kl_controller_forget_window(&runtime->controller, window_id);
    runtime_forget_window_from_list(runtime, window_id);
    runtime_forget_managed_window_source(runtime, window_id);
    kl_macos_window_frame_cache_forget(&runtime->window_frame_cache, window_id);

    if (runtime->focused_window_id == window_id || changed) {
        runtime_sync_focused_window(runtime);
    }

    return changed;
}

static bool runtime_notice_window(
    kl_macos_runtime_t *runtime,
    const kl_macos_window_t *window,
    const kl_macos_window_hints_t *known_hints,
    const char *source,
    bool defer_hints)
{
    if (kl_workspace_find_window(runtime_workspace(runtime), window->window_id)) {
        return false;
    }

    kl_macos_window_hints_t hints;
    bool has_hints = known_hints != NULL;
    if (has_hints) {
        hints = *known_hints;
    } else if (!defer_hints) {
        has_hints = kl_macos_copy_window_hints(window, &hints);
    }

    kl_macos_window_policy_t policy = runtime_window_policy(
        runtime,
        window,
        has_hints ? &hints : NULL);
    if (policy == KL_MACOS_WINDOW_POLICY_IGNORED) {
        return false;
    }

    bool benchmark = runtime_benchmark_enabled();
    size_t before_columns = runtime_strip(runtime)->count;
    size_t before_active = runtime_strip(runtime)->active;
    double notice_started_at = benchmark ? runtime_seconds() : 0.0;
    kl_window_mode_t mode = policy == KL_MACOS_WINDOW_POLICY_FLOATING
        ? KL_WINDOW_FLOATING
        : KL_WINDOW_TILED;
    bool noticed = kl_controller_notice_window_with_mode(
        &runtime->controller,
        window->window_id,
        mode);

    if (noticed) {
        runtime_remember_window(runtime, window);
        runtime_remember_managed_window_source(runtime, window);
        if (has_hints && hints.fullscreen_known && hints.fullscreen) {
            kl_controller_set_fullscreen(&runtime->controller, window->window_id, true);
        }
    }

    if (benchmark && noticed) {
        double noticed_at = runtime_seconds();
        fprintf(
            stderr,
            "bench window_notice t=%.6f source=%s window=%u policy=%s fullscreen_known=%d fullscreen=%d role=%s subrole=%s app_id=%s app_name=%s before_columns=%zu after_columns=%zu before_active=%zu after_active=%zu viewport=%.3f notice_ms=%.3f\n",
            noticed_at,
            source ? source : "unknown",
            window->window_id,
            runtime_window_policy_name(policy),
            has_hints && hints.fullscreen_known,
            has_hints && hints.fullscreen,
            has_hints && hints.role[0] ? hints.role : "-",
            has_hints && hints.subrole[0] ? hints.subrole : "-",
            has_hints && hints.app_id[0] ? hints.app_id : "-",
            has_hints && hints.app_name[0] ? hints.app_name : "-",
            before_columns,
            runtime_strip(runtime)->count,
            before_active,
            runtime_strip(runtime)->active,
            runtime_strip(runtime)->viewport_x,
            (noticed_at - notice_started_at) * 1000.0);
    }

    return noticed;
}

static void runtime_log_lifecycle(
    kl_macos_runtime_t *runtime,
    const char *reason,
    uint32_t window_id,
    bool changed)
{
    if (!runtime_benchmark_enabled()) {
        return;
    }

    fprintf(
        stderr,
        "bench window_lifecycle t=%.6f reason=%s window=%u changed=%d columns=%zu active=%zu viewport=%.3f\n",
        runtime_seconds(),
        reason ? reason : "unknown",
        window_id,
        changed,
        runtime_strip(runtime)->count,
        runtime_strip(runtime)->active,
        runtime_strip(runtime)->viewport_x);
}

static void runtime_log_fullscreen_lifecycle(
    kl_macos_runtime_t *runtime,
    const char *reason,
    uint32_t window_id,
    bool fullscreen,
    bool changed)
{
    if (!runtime_benchmark_enabled()) {
        return;
    }

    fprintf(
        stderr,
        "bench window_lifecycle t=%.6f reason=%s window=%u fullscreen=%d changed=%d columns=%zu active=%zu viewport=%.3f\n",
        runtime_seconds(),
        reason ? reason : "unknown",
        window_id,
        fullscreen,
        changed,
        runtime_strip(runtime)->count,
        runtime_strip(runtime)->active,
        runtime_strip(runtime)->viewport_x);
}

static void runtime_log_pid_lifecycle(
    kl_macos_runtime_t *runtime,
    const char *reason,
    pid_t pid,
    size_t removed,
    bool changed)
{
    if (!runtime_benchmark_enabled()) {
        return;
    }

    fprintf(
        stderr,
        "bench window_lifecycle t=%.6f reason=%s pid=%d removed=%zu changed=%d columns=%zu active=%zu viewport=%.3f\n",
        runtime_seconds(),
        reason ? reason : "unknown",
        pid,
        removed,
        changed,
        runtime_strip(runtime)->count,
        runtime_strip(runtime)->active,
        runtime_strip(runtime)->viewport_x);
}

static void runtime_forget_window(kl_macos_runtime_t *runtime, uint32_t window_id, const char *reason)
{
    bool changed = runtime_remove_window_from_model(runtime, window_id);

    if (changed) {
        runtime_apply_layout(runtime);
    }

    runtime_log_lifecycle(runtime, reason, window_id, changed);
}

static size_t runtime_forget_windows_for_pid(
    kl_macos_runtime_t *runtime,
    pid_t pid,
    const char *reason)
{
    uint32_t window_ids[KL_MACOS_MAX_WINDOWS];
    size_t window_count =
        runtime_collect_managed_window_ids_for_pid(runtime, pid, window_ids, KL_MACOS_MAX_WINDOWS);
    size_t removed = 0;
    bool changed = false;
    bool focus_removed = false;

    for (size_t i = 0; i < window_count; i++) {
        uint32_t window_id = window_ids[i];
        if (runtime->focused_window_id == window_id) {
            focus_removed = true;
        }

        if (runtime_remove_window_from_model(runtime, window_id)) {
            changed = true;
            removed++;
        }
    }

    if (focus_removed || changed) {
        runtime_sync_focused_window(runtime);
    }

    if (changed) {
        runtime_apply_layout(runtime);
    }

    runtime_log_pid_lifecycle(runtime, reason, pid, removed, changed);
    return removed;
}

static void runtime_set_window_minimized(
    kl_macos_runtime_t *runtime,
    const kl_macos_window_t *window,
    bool minimized,
    const char *reason)
{
    kl_workspace_window_t *record =
        kl_workspace_find_window(runtime_workspace(runtime), window->window_id);

    if (!record && !minimized) {
        runtime_remember_window(runtime, window);
        if (runtime_notice_window(runtime, window, NULL, reason, true)) {
            runtime_apply_layout(runtime);
            runtime_log_lifecycle(runtime, reason, window->window_id, true);
            return;
        }
    }

    bool state_changed = record && record->minimized != minimized;
    bool should_layout =
        record &&
        record->mode == KL_WINDOW_TILED &&
        state_changed;
    bool known = kl_controller_set_minimized(
        &runtime->controller,
        window->window_id,
        minimized);

    if (known && should_layout) {
        runtime_sync_focused_window(runtime);
        runtime_apply_layout(runtime);
    }

    runtime_log_lifecycle(runtime, reason, window->window_id, known && state_changed);
}

static void runtime_set_window_fullscreen(
    kl_macos_runtime_t *runtime,
    const kl_macos_window_t *window,
    const kl_macos_window_hints_t *hints,
    bool fullscreen,
    const char *reason)
{
    kl_workspace_window_t *record =
        kl_workspace_find_window(runtime_workspace(runtime), window->window_id);

    if (!record && fullscreen) {
        runtime_remember_window(runtime, window);
        if (runtime_notice_window(runtime, window, hints, reason, false)) {
            kl_controller_set_fullscreen(&runtime->controller, window->window_id, true);
            runtime_log_fullscreen_lifecycle(runtime, reason, window->window_id, true, true);
        }
        return;
    }

    bool state_changed = record && record->fullscreen != fullscreen;
    bool should_layout =
        record &&
        record->mode == KL_WINDOW_TILED &&
        state_changed;
    bool known = kl_controller_set_fullscreen(
        &runtime->controller,
        window->window_id,
        fullscreen);

    if (known && should_layout) {
        runtime_sync_focused_window(runtime);
        runtime_apply_layout(runtime);
    }

    if (known && state_changed) {
        runtime_log_fullscreen_lifecycle(runtime, reason, window->window_id, fullscreen, true);
    }
}

static bool runtime_focus_external_window(
    kl_macos_runtime_t *runtime,
    pid_t pid,
    AXUIElementRef element,
    uint32_t window_id,
    const char *reason)
{
    kl_macos_window_t window = {
        .window_id = window_id,
        .pid = pid,
        .frame = {0},
    };
    kl_macos_window_hints_t hints;
    bool has_hints = false;
    bool has_window = window_id != 0;

    if (element) {
        has_hints = kl_macos_copy_window_from_ax_element(pid, element, &window, &hints);
        has_window = has_hints ||
            kl_macos_copy_window_identity_from_ax_element(pid, element, &window);
    }

    if (!has_window || window.window_id == 0) {
        return false;
    }

    kl_workspace_window_t *record =
        kl_workspace_find_window(runtime_workspace(runtime), window.window_id);
    if (!record && !has_hints) {
        return false;
    }

    if (!record &&
        !runtime_notice_window(runtime, &window, &hints, reason, false)) {
        return false;
    }

    runtime->focused_window_id = window.window_id;
    record = kl_workspace_find_window(runtime_workspace(runtime), window.window_id);
    if (record &&
        record->mode == KL_WINDOW_TILED &&
        !record->minimized &&
        !record->fullscreen &&
        kl_controller_focus_window(&runtime->controller, window.window_id)) {
        runtime_apply_layout(runtime);
        runtime_log_lifecycle(runtime, reason, window.window_id, true);
    }

    return true;
}

static bool runtime_update_tiled_window_width_from_frame(
    kl_macos_runtime_t *runtime,
    const kl_macos_window_t *window,
    const char *reason)
{
    if (!window || window->frame.width <= 0.0) {
        return false;
    }

    if (runtime->resize.active && runtime->resize.window_id == window->window_id) {
        return false;
    }

    if (runtime->scrolling_active ||
        runtime->direct_scroll_active ||
        runtime->animation_timer ||
        runtime->gesture_apply_pending) {
        return false;
    }

    double visible_left = kl_max_double(window->frame.x, runtime->controller.viewport.x);
    double visible_right = kl_min_double(
        window->frame.x + window->frame.width,
        runtime->controller.viewport.x + runtime->controller.viewport.width);
    double visible_width = kl_max_double(0.0, visible_right - visible_left);
    if (visible_width < window->frame.width * 0.75) {
        return false;
    }

    bool cache_matches_width = kl_macos_window_frame_cache_matches_width(
            &runtime->window_frame_cache,
            window,
            window->frame);
    if (cache_matches_width) {
        return false;
    }

    kl_workspace_window_t *record =
        kl_workspace_find_window(runtime_workspace(runtime), window->window_id);
    if (!record ||
        record->mode != KL_WINDOW_TILED ||
        record->fullscreen ||
        record->minimized) {
        return false;
    }

    double now = runtime_seconds();
    bool layout_feedback = runtime->last_layout_apply_at > 0.0 &&
        now - runtime->last_layout_apply_at <= KL_RUNTIME_LAYOUT_FEEDBACK_SECONDS;
    if (layout_feedback &&
        runtime_is_stale_restore_width_feedback(runtime, window->window_id, window->frame.width)) {
        if (runtime_trace_gestures()) {
            size_t column_index = kl_strip_find_window(runtime_strip(runtime), window->window_id);
            fprintf(
                stderr,
                "native resize ignored stale_restore window=%u reason=%s width=%.1f column=%zu viewport=%.3f\n",
                window->window_id,
                reason ? reason : "unknown",
                window->frame.width,
                column_index,
                runtime_strip(runtime)->viewport_x);
        }
        return false;
    }

    if (layout_feedback &&
        runtime_is_stale_maximized_width_feedback(runtime, window->window_id, window->frame.width)) {
        if (runtime_trace_gestures()) {
            size_t column_index = kl_strip_find_window(runtime_strip(runtime), window->window_id);
            fprintf(
                stderr,
                "native resize ignored stale_maximized window=%u reason=%s width=%.1f column=%zu viewport=%.3f\n",
                window->window_id,
                reason ? reason : "unknown",
                window->frame.width,
                column_index,
                runtime_strip(runtime)->viewport_x);
        }
        return false;
    }

    bool preserve_restore_width = layout_feedback &&
        runtime_should_preserve_restore_width(
            runtime,
            window->window_id,
            window->frame.width,
            window->frame.width);

    bool changed = layout_feedback
        ? kl_controller_reconcile_window_width(
            &runtime->controller,
            window->window_id,
            window->frame.width,
            preserve_restore_width)
        : kl_controller_set_window_width(
            &runtime->controller,
            window->window_id,
            window->frame.width);
    kl_macos_window_frame_cache_note_frame(
        &runtime->window_frame_cache,
        window,
        window->frame);

    if (runtime_trace_gestures()) {
        size_t column_index = kl_strip_find_window(runtime_strip(runtime), window->window_id);
        fprintf(
            stderr,
            "native resize window=%u reason=%s width=%.1f layout_feedback=%d preserve_restore=%d changed=%d column=%zu viewport=%.3f\n",
            window->window_id,
            reason ? reason : "unknown",
            window->frame.width,
            layout_feedback,
            preserve_restore_width,
            changed,
            column_index,
            runtime_strip(runtime)->viewport_x);
    }

    if (changed) {
        if (!layout_feedback) {
            runtime->focused_window_id = window->window_id;
            runtime_sync_focused_window(runtime);
        }
        runtime_snap_layout(runtime);
    }
    return changed;
}

static void runtime_log_window_hints(
    kl_macos_runtime_t *runtime,
    const kl_macos_window_t *window,
    AXUIElementRef element)
{
    (void) runtime;

    if (!runtime_benchmark_enabled()) {
        return;
    }

    kl_macos_window_t resolved_window = *window;
    kl_macos_window_hints_t hints;
    bool has_hints = false;
    if (element) {
        has_hints = kl_macos_copy_window_from_ax_element(
            window->pid,
            element,
            &resolved_window,
            &hints);
    }
    if (!has_hints) {
        has_hints = kl_macos_copy_window_hints(window, &hints);
    }

    fprintf(
        stderr,
        "bench window_hints t=%.6f window=%u fullscreen_known=%d fullscreen=%d role=%s subrole=%s app_id=%s app_name=%s\n",
        runtime_seconds(),
        window->window_id,
        has_hints && hints.fullscreen_known,
        has_hints && hints.fullscreen,
        has_hints && hints.role[0] ? hints.role : "-",
        has_hints && hints.subrole[0] ? hints.subrole : "-",
        has_hints && hints.app_id[0] ? hints.app_id : "-",
        has_hints && hints.app_name[0] ? hints.app_name : "-");
}

static bool runtime_rescan_windows(kl_macos_runtime_t *runtime, uint32_t *largest_visible_window_id)
{
    bool benchmark = runtime_benchmark_enabled();
    double rescan_started_at = benchmark ? runtime_seconds() : 0.0;

    if (!runtime_refresh_window_list(runtime)) {
        return false;
    }

    if (largest_visible_window_id) {
        *largest_visible_window_id = runtime_largest_visible_window_id(runtime);
    }

    bool changed = false;
    for (size_t i = 0; i < runtime->window_list.count; i++) {
        const kl_macos_window_t *window = &runtime->window_list.windows[i];
        changed |= runtime_notice_window(runtime, window, NULL, "scan", false);
    }

    if (benchmark) {
        double rescanned_at = runtime_seconds();
        fprintf(
            stderr,
            "bench rescan t=%.6f windows=%zu changed=%d ms=%.3f\n",
            rescanned_at,
            runtime->window_list.count,
            changed,
            (rescanned_at - rescan_started_at) * 1000.0);
    }

    return changed;
}

static bool runtime_rescan_and_apply(kl_macos_runtime_t *runtime, const char *reason)
{
    bool benchmark = runtime_benchmark_enabled();
    double started_at = benchmark ? runtime_seconds() : 0.0;
    bool startup = reason && strcmp(reason, "startup") == 0;
    uint32_t startup_focus_window_id = 0;
    bool changed = runtime_rescan_windows(
        runtime,
        startup ? &startup_focus_window_id : NULL);

    if (changed) {
        if (startup_focus_window_id != 0 &&
            !runtime->benchmark_active_focus_pending &&
            kl_controller_focus_window(&runtime->controller, startup_focus_window_id)) {
            runtime->focused_window_id = startup_focus_window_id;
        }
        runtime_apply_pending_benchmark_active_focus(runtime);
        runtime_apply_layout(runtime);
    }

    if (benchmark && reason) {
        double finished_at = runtime_seconds();
        fprintf(
            stderr,
            "bench rescan_apply t=%.6f reason=%s changed=%d retry_remaining=%d ms=%.3f\n",
            finished_at,
            reason,
            changed,
            runtime->window_event_retry_remaining,
            (finished_at - started_at) * 1000.0);
    }

    return changed;
}

static void runtime_cancel_window_event_retry(kl_macos_runtime_t *runtime)
{
    if (runtime->window_event_retry_timer) {
        [runtime->window_event_retry_timer invalidate];
        runtime->window_event_retry_timer = nil;
    }
    runtime->window_event_retry_remaining = 0;
}

static void runtime_schedule_window_event_retry(kl_macos_runtime_t *runtime)
{
    runtime->window_event_retry_remaining = KL_RUNTIME_WINDOW_EVENT_RETRY_ATTEMPTS;
    if (runtime->window_event_retry_timer) {
        return;
    }

    runtime->window_event_retry_timer =
        runtime_schedule_timer(KL_RUNTIME_WINDOW_EVENT_RETRY_INTERVAL, YES, ^(NSTimer *timer) {
        if (runtime->window_event_retry_remaining <= 0) {
            [timer invalidate];
            if (runtime->window_event_retry_timer == timer) {
                runtime->window_event_retry_timer = nil;
            }
            return;
        }

        runtime->window_event_retry_remaining--;
        if (runtime_rescan_and_apply(runtime, "window-event-retry")) {
            runtime_cancel_window_event_retry(runtime);
        } else if (runtime->window_event_retry_remaining <= 0) {
            [timer invalidate];
            if (runtime->window_event_retry_timer == timer) {
                runtime->window_event_retry_timer = nil;
            }
        }
    });
}

static void runtime_clear_pending_window_events(kl_macos_runtime_t *runtime)
{
    for (size_t i = 0; i < runtime->pending_window_event_count; i++) {
        if (runtime->pending_window_events[i].element) {
            CFRelease(runtime->pending_window_events[i].element);
        }
    }
    runtime->pending_window_event_count = 0;
}

static void runtime_cancel_window_event_batch(kl_macos_runtime_t *runtime)
{
    if (runtime->window_event_batch_timer) {
        [runtime->window_event_batch_timer invalidate];
        runtime->window_event_batch_timer = nil;
    }
    runtime_clear_pending_window_events(runtime);
}

static bool runtime_window_event_batch_pending(const kl_macos_runtime_t *runtime)
{
    return runtime->window_event_batch_timer || runtime->pending_window_event_count > 0;
}

static void runtime_flush_pending_window_events(kl_macos_runtime_t *runtime, const char *reason)
{
    if (runtime->window_event_batch_timer) {
        [runtime->window_event_batch_timer invalidate];
        runtime->window_event_batch_timer = nil;
    }

    size_t pending_count = runtime->pending_window_event_count;
    if (pending_count == 0) {
        return;
    }

    bool benchmark = runtime_benchmark_enabled();
    double started_at = benchmark ? runtime_seconds() : 0.0;
    bool changed = false;
    size_t resolved = 0;
    size_t noticed = 0;
    size_t unresolved = 0;
    kl_macos_window_t noticed_windows[KL_RUNTIME_PENDING_WINDOW_EVENTS_MAX];
    AXUIElementRef noticed_elements[KL_RUNTIME_PENDING_WINDOW_EVENTS_MAX];

    for (size_t i = 0; i < pending_count; i++) {
        kl_macos_pending_window_event_t *event = &runtime->pending_window_events[i];
        kl_macos_window_t window;
        kl_macos_window_hints_t hints;
        bool has_hints = kl_macos_copy_window_from_ax_element(
            event->pid,
            event->element,
            &window,
            &hints);

        if (!has_hints) {
            unresolved++;
            continue;
        }

        resolved++;
        runtime_remember_window(runtime, &window);
        kl_macos_window_frame_cache_remember_ax_window(
            &runtime->window_frame_cache,
            &window,
            event->element);

        if (runtime_notice_window(
                runtime,
                &window,
                has_hints ? &hints : NULL,
                event->reason,
                true)) {
            changed = true;
            noticed_windows[noticed] = window;
            noticed_elements[noticed] = event->element;
            noticed++;
        }
    }

    if (changed) {
        runtime_cancel_window_event_retry(runtime);
        runtime_apply_layout(runtime);

        for (size_t i = 0; i < noticed; i++) {
            runtime_log_window_hints(runtime, &noticed_windows[i], noticed_elements[i]);
        }
    }

    runtime_clear_pending_window_events(runtime);

    if (unresolved > 0) {
        if (runtime_rescan_and_apply(runtime, "window-batch-unresolved")) {
            runtime_cancel_window_event_retry(runtime);
        } else {
            runtime_schedule_window_event_retry(runtime);
        }
    }

    if (benchmark) {
        double finished_at = runtime_seconds();
        fprintf(
            stderr,
            "bench window_batch t=%.6f reason=%s events=%zu resolved=%zu noticed=%zu unresolved=%zu changed=%d ms=%.3f\n",
            finished_at,
            reason ? reason : "unknown",
            pending_count,
            resolved,
            noticed,
            unresolved,
            changed,
            (finished_at - started_at) * 1000.0);
    }
}

static bool runtime_queue_window_event(
    kl_macos_runtime_t *runtime,
    pid_t pid,
    AXUIElementRef element,
    const char *reason)
{
    if (!element || runtime->pending_window_event_count == KL_RUNTIME_PENDING_WINDOW_EVENTS_MAX) {
        return false;
    }

    kl_macos_pending_window_event_t *pending =
        &runtime->pending_window_events[runtime->pending_window_event_count++];
    pending->pid = pid;
    pending->element = (AXUIElementRef) CFRetain(element);
    snprintf(pending->reason, sizeof(pending->reason), "%s", reason ? reason : "ax-event");

    if (runtime->window_event_batch_timer) {
        [runtime->window_event_batch_timer invalidate];
        runtime->window_event_batch_timer = nil;
    }

    runtime->window_event_batch_timer =
        runtime_schedule_timer(KL_RUNTIME_WINDOW_EVENT_BATCH_INTERVAL, NO, ^(NSTimer *timer) {
        if (runtime->window_event_batch_timer == timer) {
            runtime->window_event_batch_timer = nil;
        }
        runtime_flush_pending_window_events(runtime, "timer");
    });

    return true;
}

static void runtime_window_observer_callback(
    pid_t pid,
    AXUIElementRef element,
    uint32_t window_id,
    const char *reason,
    void *context)
{
    kl_macos_runtime_t *runtime = context;
    if (!runtime || (runtime->managed_pid_filter > 0 && runtime->managed_pid_filter != pid)) {
        return;
    }

    if (runtime_benchmark_enabled()) {
        fprintf(
            stderr,
            "bench window_event t=%.6f reason=%s pid=%d\n",
            runtime_seconds(),
            reason ? reason : "unknown",
            pid);
    }

    bool destroyed = reason && strcmp(reason, "ax-destroyed") == 0;
    bool minimized = reason && strcmp(reason, "ax-minimized") == 0;
    bool deminimized = reason && strcmp(reason, "ax-deminimized") == 0;
    bool app_terminated = reason && strcmp(reason, "app-terminated") == 0;
    bool resized = reason && strcmp(reason, "ax-resized") == 0;
    bool focused = reason && strcmp(reason, "ax-focused") == 0;
    if (app_terminated) {
        runtime_flush_pending_window_events(runtime, "before-app-terminated");
        runtime_forget_windows_for_pid(runtime, pid, reason);
        runtime_cancel_window_event_retry(runtime);
        return;
    }

    if (focused) {
        if (!runtime_focus_external_window(runtime, pid, element, window_id, reason) &&
            runtime_rescan_and_apply(runtime, reason)) {
            runtime_cancel_window_event_retry(runtime);
        }
        return;
    }

    if (resized) {
        kl_macos_window_t window = {
            .window_id = window_id,
            .pid = pid,
            .frame = {0},
        };
        kl_macos_window_hints_t hints;
        bool has_hints = false;
        if (element) {
            has_hints = kl_macos_copy_window_from_ax_element(pid, element, &window, &hints);
        }
        if (!has_hints && window.window_id != 0) {
            has_hints = kl_macos_copy_window_hints(&window, &hints);
        }

        if (has_hints && hints.fullscreen_known) {
            runtime_set_window_fullscreen(
                runtime,
                &window,
                &hints,
                hints.fullscreen,
                reason);
        }
        runtime_update_tiled_window_width_from_frame(runtime, &window, reason);
        return;
    }

    if (destroyed || minimized || deminimized) {
        runtime_flush_pending_window_events(runtime, "before-lifecycle");

        kl_macos_window_t window = {
            .window_id = window_id,
            .pid = pid,
            .frame = {0},
        };
        bool has_window =
            (element && kl_macos_copy_window_identity_from_ax_element(pid, element, &window)) ||
            window.window_id != 0;

        if (has_window) {
            if (destroyed) {
                runtime_forget_window(runtime, window.window_id, reason);
            } else {
                runtime_set_window_minimized(runtime, &window, minimized, reason);
            }
            return;
        }

        if (runtime_rescan_and_apply(runtime, reason ? reason : "window-lifecycle")) {
            runtime_cancel_window_event_retry(runtime);
        } else {
            runtime_schedule_window_event_retry(runtime);
        }
        return;
    }

    if (element) {
        if (runtime_queue_window_event(runtime, pid, element, reason ? reason : "ax-event")) {
            return;
        }
    }

    runtime_flush_pending_window_events(runtime, "before-rescan");
    if (runtime_rescan_and_apply(runtime, reason ? reason : "window-event")) {
        runtime_cancel_window_event_retry(runtime);
    } else {
        runtime_schedule_window_event_retry(runtime);
    }
}

static bool runtime_load_config_file(const char *path, kl_config_t *config, const char *label)
{
    if (!path || access(path, R_OK) != 0) {
        return false;
    }

    char error[256];
    if (!kl_config_load_file(path, config, error, sizeof(error))) {
        fprintf(stderr, "failed to load %s %s: %s\n", label, path, error);
        return false;
    }

    return true;
}

static bool runtime_load_default_config(kl_config_t *config)
{
    const char *env_path = getenv("KLOTSKI_DEFAULT_CONFIG");
    if (env_path && *env_path) {
        if (access(env_path, R_OK) != 0) {
            fprintf(stderr, "default config %s is not readable; no default binds loaded\n", env_path);
        } else {
            runtime_load_config_file(env_path, config, "default config");
        }
        return true;
    }

    if (runtime_load_config_file(KL_RUNTIME_DEFAULT_CONFIG_PATH, config, "default config")) {
        return true;
    }

    char executable_path[PATH_MAX];
    uint32_t executable_path_size = sizeof(executable_path);
    if (_NSGetExecutablePath(executable_path, &executable_path_size) == 0) {
        char *slash = strrchr(executable_path, '/');
        if (slash) {
            *slash = '\0';

            char candidate[PATH_MAX];
            snprintf(candidate, sizeof(candidate), "%s/../%s", executable_path, KL_RUNTIME_DEFAULT_CONFIG_PATH);
            if (runtime_load_config_file(candidate, config, "default config")) {
                return true;
            }
        }
    }

    fprintf(
        stderr,
        "default config not found at %s; no default binds loaded\n",
        KL_RUNTIME_DEFAULT_CONFIG_PATH);
    return false;
}

static kl_config_t runtime_load_config(void)
{
    kl_config_t config = kl_config_default();
    runtime_load_default_config(&config);

    const char *env_path = getenv("KLOTSKI_CONFIG");
    const char *path = NULL;
    bool explicit_path = env_path && *env_path;
    char default_path[4096];

    if (explicit_path) {
        path = env_path;
    } else {
        const char *home = getenv("HOME");
        if (home) {
            snprintf(default_path, sizeof(default_path), "%s/.config/klotski/klotski.conf", home);
            path = default_path;
        }
    }

    if (path) {
        if (access(path, R_OK) != 0) {
            if (explicit_path) {
                fprintf(stderr, "config %s is not readable; using default config only\n", path);
            }
        } else {
            runtime_load_config_file(path, &config, "config");
        }
    }

    return config;
}

static pid_t runtime_load_managed_pid_filter(void)
{
    const char *value = getenv("KLOTSKI_MANAGED_PID");
    if (!value || *value == '\0') {
        return 0;
    }

    char *end = NULL;
    long pid = strtol(value, &end, 10);
    if (end == value || *end != '\0' || pid <= 0) {
        fprintf(stderr, "ignoring invalid KLOTSKI_MANAGED_PID=%s\n", value);
        return 0;
    }

    return (pid_t) pid;
}

static void runtime_focus_hovered_window(kl_macos_runtime_t *runtime, kl_point_t point)
{
    if (!runtime->config.focus_follows_mouse) {
        return;
    }

    kl_macos_window_t window;
    if (!kl_macos_window_at_point(point, runtime->managed_pid_filter, &window)) {
        return;
    }

    if (runtime->focused_window_id == window.window_id) {
        return;
    }

    if (!kl_workspace_find_window(runtime_workspace(runtime), window.window_id) &&
        !runtime_notice_window(runtime, &window, NULL, "hover", false)) {
        return;
    }

    runtime->focused_window_id = window.window_id;
    kl_macos_focus_window(&window);

    kl_workspace_window_t *record =
        kl_workspace_find_window(runtime_workspace(runtime), window.window_id);
    if (record && record->mode == KL_WINDOW_TILED) {
        kl_controller_focus_window(&runtime->controller, window.window_id);
        runtime_apply_layout(runtime);
    }
}

static void runtime_flush_scroll(kl_macos_runtime_t *runtime)
{
    double pixels = runtime->pending_scroll_pixels;
    runtime->pending_scroll_pixels = 0.0;

    if (fabs(pixels) <= 0.01) {
        return;
    }

    kl_controller_scroll_delta(&runtime->controller, pixels);
    runtime_apply_layout(runtime);
}

static void runtime_finish_scroll(kl_macos_runtime_t *runtime)
{
    bool had_direct_scroll = runtime->direct_scroll_active;

    runtime_flush_pending_gesture_apply(runtime);
    runtime->scrolling_active = false;
    runtime->direct_scroll_active = false;
    runtime->touch_centroid_valid = false;

    runtime_flush_scroll(runtime);
    if (had_direct_scroll) {
        runtime_apply_layout(runtime);
        return;
    }

    if (!had_direct_scroll) {
        runtime_focus_hovered_window(runtime, runtime->last_pointer);
    }
}

static void runtime_schedule_scroll_flush(kl_macos_runtime_t *runtime)
{
    if (runtime->scroll_flush_timer) {
        return;
    }

    runtime->scroll_flush_timer = runtime_schedule_timer(1.0 / 120.0, YES, ^(NSTimer *timer) {
        runtime_flush_scroll(runtime);

        if (fabs(runtime->pending_scroll_pixels) <= 0.01) {
            [timer invalidate];
            if (runtime->scroll_flush_timer == timer) {
                runtime->scroll_flush_timer = nil;
            }
        }
    });
}

static void runtime_mark_scroll_active(kl_macos_runtime_t *runtime, kl_point_t point)
{
    runtime->scrolling_active = true;
    runtime->last_pointer = point;

    if (runtime->scroll_settle_timer) {
        [runtime->scroll_settle_timer invalidate];
        runtime->scroll_settle_timer = nil;
    }

    runtime->scroll_settle_timer =
        runtime_schedule_timer(runtime->config.scroll_settle_delay, NO, ^(NSTimer *timer) {
        if (runtime->scroll_settle_timer == timer) {
            runtime->scroll_settle_timer = nil;
        }
        runtime_finish_scroll(runtime);
    });
}

static void runtime_toggle_floating(kl_macos_runtime_t *runtime, kl_point_t fallback_point)
{
    uint32_t window_id = runtime->focused_window_id;

    if (window_id == 0) {
        kl_macos_window_t window;
        if (!kl_macos_window_at_point(fallback_point, runtime->managed_pid_filter, &window)) {
            return;
        }

        if (!kl_workspace_find_window(runtime_workspace(runtime), window.window_id) &&
            !runtime_notice_window(runtime, &window, NULL, "toggle-floating", false)) {
            return;
        }

        window_id = window.window_id;
        runtime->focused_window_id = window_id;
    }

    if (kl_controller_toggle_floating(&runtime->controller, window_id)) {
        runtime_apply_layout(runtime);
    }
}

static bool runtime_notice_hovered_window(
    kl_macos_runtime_t *runtime,
    kl_point_t point,
    const char *reason,
    kl_macos_window_t *window,
    kl_workspace_window_t **record)
{
    if (!kl_macos_window_at_point(point, runtime->managed_pid_filter, window)) {
        return false;
    }

    *record = kl_workspace_find_window(runtime_workspace(runtime), window->window_id);
    if (!*record && !runtime_notice_window(runtime, window, NULL, reason, false)) {
        return false;
    }

    *record = kl_workspace_find_window(runtime_workspace(runtime), window->window_id);
    return *record != NULL;
}

static void runtime_toggle_hovered_window_maximized_width(
    kl_macos_runtime_t *runtime,
    kl_point_t point)
{
    kl_macos_window_t window = {0};
    kl_workspace_window_t *record = NULL;
    uint32_t window_id = 0;
    bool has_window = runtime_notice_hovered_window(
        runtime,
        point,
        "toggle-maximize-width",
        &window,
        &record);

    if (has_window) {
        window_id = window.window_id;
    } else {
        window_id = (uint32_t) kl_strip_active_window(runtime_strip(runtime));
        if (window_id == 0) {
            return;
        }

        record = kl_workspace_find_window(runtime_workspace(runtime), window_id);
        if (!record) {
            return;
        }
    }

    if (record->mode != KL_WINDOW_TILED || record->fullscreen || record->minimized) {
        return;
    }

    size_t before_active = runtime_strip(runtime)->active;
    double before_viewport_x = runtime_strip(runtime)->viewport_x;
    bool changed = kl_controller_toggle_window_maximized_width(
        &runtime->controller,
        window_id);
    bool focused = before_active != runtime_strip(runtime)->active ||
        fabs(before_viewport_x - runtime_strip(runtime)->viewport_x) > 0.5;

    runtime->focused_window_id = window_id;
    if (has_window) {
        kl_macos_focus_window(&window);
    }

    if (runtime_trace_gestures()) {
        size_t column_index = kl_strip_find_window(runtime_strip(runtime), window_id);
        fprintf(
            stderr,
            "key toggle-maximize-width window=%u hovered=%d changed=%d focused=%d column=%zu width=%.1f viewport=%.3f\n",
            window_id,
            has_window,
            changed,
            focused,
            column_index,
            column_index < runtime_strip(runtime)->count
                ? runtime_strip(runtime)->columns[column_index].width
                : 0.0,
            runtime_strip(runtime)->viewport_x);
    }

    if (changed || focused) {
        runtime_apply_layout(runtime);
    }
}

static void runtime_scroll(kl_macos_runtime_t *runtime, kl_scroll_direction_t direction)
{
    double distance = runtime->controller.viewport.width * runtime->controller.keyboard_scroll_fraction;
    runtime->pending_scroll_pixels += (double) direction * distance;
    runtime_mark_scroll_active(runtime, runtime->last_pointer);
    runtime_schedule_scroll_flush(runtime);
}

static bool runtime_focus_active_column(kl_macos_runtime_t *runtime, int direction)
{
    bool changed = direction < 0
        ? kl_controller_focus_previous(&runtime->controller)
        : kl_controller_focus_next(&runtime->controller);
    if (changed) {
        runtime_sync_focused_window(runtime);
        runtime_apply_layout(runtime);
    }
    return changed;
}

static void runtime_move_active_column(kl_macos_runtime_t *runtime, int direction)
{
    kl_strip_t *strip = runtime_strip(runtime);
    size_t before_active = strip->active;
    uint32_t before_window = (uint32_t) kl_strip_active_window(strip);
    bool moved = kl_controller_move_active_column(&runtime->controller, direction);

    if (runtime_trace_gestures()) {
        strip = runtime_strip(runtime);
        uint32_t after_window = (uint32_t) kl_strip_active_window(strip);
        fprintf(
            stderr,
            "key reorder direction=%d moved=%d before_active=%zu after_active=%zu before_window=%u after_window=%u columns=%zu\n",
            direction,
            moved,
            before_active,
            strip->active,
            before_window,
            after_window,
            strip->count);
    }

    if (moved) {
        runtime_sync_focused_window(runtime);
        runtime_apply_layout(runtime);
    }
}

static void runtime_queue_direct_scroll_pixels(
    kl_macos_runtime_t *runtime,
    double pixels,
    kl_point_t point,
    const char *source)
{
    runtime_note_visual_viewport(runtime);

    if (!runtime->direct_scroll_active) {
        runtime_cancel_layout_animation(runtime);
        runtime->last_gesture_apply_time = 0.0;
    }

    double previous_visual = runtime->visual_viewport_x;
    double timestamp = runtime_seconds();
    kl_controller_scroll_delta(&runtime->controller, pixels);

    double dt = runtime->last_animation_time > 0.0
        ? timestamp - runtime->last_animation_time
        : (1.0 / KL_RUNTIME_DEFAULT_GESTURE_APPLY_HZ);
    runtime->last_animation_time = timestamp;

    double target = runtime_strip(runtime)->viewport_x;
    double rate =
        runtime->config.horizontal_view_animation_speed * KL_RUNTIME_DIRECT_SCROLL_ACTIVE_SPEED_MULTIPLIER;
    double amount = kl_clamp_double(1.0 - exp(-rate * dt), 0.0, 1.0);
    runtime->visual_viewport_x += (target - runtime->visual_viewport_x) * amount;
    if (fabs(target - runtime->visual_viewport_x) <= 0.25) {
        runtime->visual_viewport_x = target;
    }

    runtime->visual_viewport_valid = true;
    runtime->direct_scroll_active = true;

    if (runtime_trace_gestures()) {
        fprintf(
            stderr,
            "direct scroll update source=%s t=%.6f delta=%.3f visual %.3f->%.3f logical=%.3f active=%zu point=(%.1f,%.1f)\n",
            source,
            timestamp,
            pixels,
            previous_visual,
            runtime->visual_viewport_x,
            runtime_strip(runtime)->viewport_x,
            runtime_strip(runtime)->active,
            point.x,
            point.y);
    }

    runtime_mark_scroll_active(runtime, point);
    runtime_schedule_gesture_apply(runtime, timestamp);
}

static unsigned runtime_modifiers_from_flags(CGEventFlags flags);
static bool runtime_binding_ready(kl_binding_t *binding, bool repeat, double now);
static bool runtime_execute_binding_action(
    kl_macos_runtime_t *runtime,
    const kl_binding_t *binding,
    kl_point_t point);
static bool runtime_handle_binding(
    kl_macos_runtime_t *runtime,
    kl_binding_trigger_t trigger,
    unsigned modifiers,
    bool repeat,
    kl_point_t point);
static kl_binding_trigger_t runtime_wheel_trigger(double horizontal_delta, double vertical_delta);

static bool runtime_handle_scroll_wheel(kl_macos_runtime_t *runtime, CGEventRef event)
{
    CGEventFlags flags = CGEventGetFlags(event);
    unsigned modifiers = runtime_modifiers_from_flags(flags);
    double horizontal_delta = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2);
    double vertical_delta = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1);
    double delta = fabs(horizontal_delta) > 0.001 ? horizontal_delta : vertical_delta;

    if (fabs(delta) <= 0.001) {
        return false;
    }

    CGPoint point = CGEventGetLocation(event);
    kl_point_t kl_point = {.x = point.x, .y = point.y};
    kl_binding_trigger_t trigger = runtime_wheel_trigger(horizontal_delta, vertical_delta);
    kl_binding_t *binding = kl_config_find_binding(&runtime->config, trigger, modifiers);
    if (!binding) {
        return false;
    }

    if (!runtime_binding_ready(binding, false, runtime_seconds())) {
        return true;
    }

    if (binding->action != KL_ACTION_SCROLL_LEFT && binding->action != KL_ACTION_SCROLL_RIGHT) {
        runtime_execute_binding_action(runtime, binding, kl_point);
        return true;
    }

    double action_delta = binding->action == KL_ACTION_SCROLL_RIGHT
        ? -fabs(delta)
        : fabs(delta);

    if (runtime_trace_gestures()) {
        fprintf(
            stderr,
            "scroll wheel horizontal=%.3f vertical=%.3f chosen=%.3f action=%s\n",
            horizontal_delta,
            vertical_delta,
            delta,
            kl_action_name(binding->action));
    }

    runtime_queue_direct_scroll_pixels(
        runtime,
        kl_input_wheel_delta_to_viewport_pixels(
            action_delta,
            runtime->controller.viewport.width,
            runtime->config.scroll_wheel_sensitivity),
        kl_point,
        "wheel");
    return true;
}

static bool runtime_end_touch_gesture(kl_macos_runtime_t *runtime, const char *reason)
{
    bool had_touch_tracking =
        runtime->touch_centroid_valid ||
        runtime->three_finger_swipe.recognizing ||
        runtime->three_finger_swipe.active ||
        runtime->touch_scroll_gesture.active;
    bool had_scroll = runtime->touch_scroll_gesture.active || runtime->direct_scroll_active;

    kl_three_finger_swipe_result_t swipe_result = kl_three_finger_swipe_end(&runtime->three_finger_swipe);
    if (runtime->touch_scroll_gesture.active) {
        kl_view_scroll_gesture_result_t view_result;
        if (kl_view_scroll_gesture_end(
                &runtime->touch_scroll_gesture,
                runtime_seconds(),
                runtime->controller.viewport.width,
                true,
                true,
                &view_result) &&
            runtime_trace_gestures()) {
            fprintf(
                stderr,
                "touch view gesture end reason=%s current=%.3f projected=%.3f velocity=%.3f\n",
                reason,
                view_result.current_viewport_x,
                view_result.projected_viewport_x,
                view_result.velocity_pixels);
        }
    }

    runtime->touch_centroid_valid = false;

    if (runtime_trace_gestures()) {
        fprintf(
            stderr,
            "gesture phase ended reason=%s had_tracking=%d had_scroll=%d swipe_phase=%d\n",
            reason,
            had_touch_tracking,
            had_scroll,
            swipe_result.phase);
    }

    if (had_scroll) {
        if (runtime->scroll_settle_timer) {
            [runtime->scroll_settle_timer invalidate];
            runtime->scroll_settle_timer = nil;
        }
        runtime_finish_scroll(runtime);
    }

    return had_touch_tracking || had_scroll;
}

static bool runtime_handle_gesture(kl_macos_runtime_t *runtime, CGEventRef event)
{
    NSEvent *ns_event = [NSEvent eventWithCGEvent:event];
    if (!ns_event || [ns_event type] != NSEventTypeGesture) {
        return false;
    }

    NSUInteger phase = [ns_event phase];
    NSSet<NSTouch *> *touches = [ns_event allTouches];
    NSUInteger active_touch_count = 0;
    double current_x = 0.0;
    double current_y = 0.0;

    for (NSTouch *touch in touches) {
        NSTouchPhase touch_phase = [touch phase];
        if ((touch_phase & (NSTouchPhaseEnded | NSTouchPhaseCancelled)) != 0) {
            continue;
        }

        NSPoint current_position = [touch normalizedPosition];
        current_x += current_position.x;
        current_y += current_position.y;
        active_touch_count++;
    }

    if (runtime_trace_gestures() &&
        ([touches count] >= 3 || active_touch_count >= 3 ||
         (phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) != 0)) {
        fprintf(
            stderr,
            "gesture raw phase=%lu touches=%lu active_touches=%lu\n",
            (unsigned long) phase,
            (unsigned long) [touches count],
            (unsigned long) active_touch_count);
    }

    if ((phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) != 0) {
        return runtime_end_touch_gesture(runtime, "phase");
    }

    if (active_touch_count != 3) {
        bool tracking =
            runtime->touch_centroid_valid ||
            runtime->three_finger_swipe.recognizing ||
            runtime->three_finger_swipe.active ||
            runtime->touch_scroll_gesture.active;
        if (tracking) {
            if (runtime_trace_gestures()) {
                fprintf(
                    stderr,
                    "gesture touch-count dropout ignored touches=%lu active_touches=%lu\n",
                    (unsigned long) [touches count],
                    (unsigned long) active_touch_count);
            }
            return true;
        }
        return runtime_end_touch_gesture(runtime, "touch-count");
    }

    current_x /= (double) active_touch_count;
    current_y /= (double) active_touch_count;

    if (!runtime->touch_centroid_valid) {
        runtime->touch_centroid_x = current_x;
        runtime->touch_centroid_y = current_y;
        runtime->touch_centroid_valid = true;
        kl_three_finger_swipe_begin(&runtime->three_finger_swipe, active_touch_count);
        if (runtime_trace_gestures()) {
            fprintf(
                stderr,
                "touch scroll primed centroid=(%.6f,%.6f)\n",
                current_x,
                current_y);
        }
        return true;
    }

    double x_delta = runtime->touch_centroid_x - current_x;
    double y_delta = runtime->touch_centroid_y - current_y;
    runtime->touch_centroid_x = current_x;
    runtime->touch_centroid_y = current_y;

    double axis_delta_x_units = kl_input_touchpad_scroll_delta_to_units(
        x_delta,
        1.0,
        runtime->config.gesture_scroll_inverted);
    double axis_delta_y_units = kl_input_touchpad_scroll_delta_to_units(
        y_delta,
        1.0,
        runtime->config.gesture_scroll_inverted);

    if (fabs(axis_delta_x_units) <= 0.00001 && fabs(axis_delta_y_units) <= 0.00001) {
        if (runtime_trace_gestures()) {
            fprintf(
                stderr,
                "touch scroll ignored x_delta=%.6f y_delta=%.6f\n",
                x_delta,
                y_delta);
        }
        return true;
    }

    kl_three_finger_swipe_result_t swipe =
        kl_three_finger_swipe_update(
            &runtime->three_finger_swipe,
            axis_delta_x_units,
            axis_delta_y_units);
    if (swipe.phase == KL_THREE_FINGER_SWIPE_RECOGNIZING) {
        if (runtime_trace_gestures()) {
            fprintf(
                stderr,
                "touch scroll recognizing axis_dx_units=%.3f axis_dy_units=%.3f dx_units=%.3f dy_units=%.3f\n",
                axis_delta_x_units,
                axis_delta_y_units,
                swipe.delta_x * runtime->config.gesture_scroll_sensitivity,
                swipe.delta_y * runtime->config.gesture_scroll_sensitivity);
        }
        return true;
    }

    if (swipe.phase == KL_THREE_FINGER_SWIPE_BEGIN) {
        if (runtime_trace_gestures()) {
            fprintf(
                stderr,
                "touch scroll axis locked axis=%d axis_dx_units=%.3f axis_dy_units=%.3f dx_units=%.3f dy_units=%.3f\n",
                swipe.axis,
                axis_delta_x_units,
                axis_delta_y_units,
                swipe.delta_x * runtime->config.gesture_scroll_sensitivity,
                swipe.delta_y * runtime->config.gesture_scroll_sensitivity);
        }

        if (swipe.axis == KL_INPUT_AXIS_HORIZONTAL) {
            runtime_note_visual_viewport(runtime);
            kl_view_scroll_gesture_begin(
                &runtime->touch_scroll_gesture,
                runtime_strip(runtime)->viewport_x,
                true);
        }
    }

    if (swipe.axis != KL_INPUT_AXIS_HORIZONTAL) {
        return true;
    }

    if (!runtime->touch_scroll_gesture.active) {
        runtime_note_visual_viewport(runtime);
        kl_view_scroll_gesture_begin(
            &runtime->touch_scroll_gesture,
            runtime_strip(runtime)->viewport_x,
            true);
    }

    double delta_x_units = swipe.delta_x * runtime->config.gesture_scroll_sensitivity;
    double delta_y_units = swipe.delta_y * runtime->config.gesture_scroll_sensitivity;
    double requested_viewport_x = runtime_strip(runtime)->viewport_x;
    if (!kl_view_scroll_gesture_update(
            &runtime->touch_scroll_gesture,
            delta_x_units,
            runtime_seconds(),
            runtime->controller.viewport.width,
            true,
            &requested_viewport_x)) {
        return true;
    }

    CGPoint point = CGEventGetLocation(event);
    double before_viewport_x = runtime_strip(runtime)->viewport_x;
    double requested_delta = requested_viewport_x - before_viewport_x;
    runtime_queue_direct_scroll_pixels(
        runtime,
        requested_delta,
        (kl_point_t) {.x = point.x, .y = point.y},
        "touch");
    double applied_viewport_x = runtime_strip(runtime)->viewport_x;
    kl_view_scroll_gesture_adjust_after_clamp(
        &runtime->touch_scroll_gesture,
        requested_viewport_x,
        applied_viewport_x);

    if (runtime_trace_gestures()) {
        fprintf(
            stderr,
            "touch scroll accepted x_delta=%.6f y_delta=%.6f axis_dx_units=%.3f axis_dy_units=%.3f dx_units=%.3f dy_units=%.3f requested=%.3f applied=%.3f\n",
            x_delta,
            y_delta,
            axis_delta_x_units,
            axis_delta_y_units,
            delta_x_units,
            delta_y_units,
            requested_viewport_x,
            applied_viewport_x);
    }
    return true;
}

static void runtime_reset_drag(kl_macos_runtime_t *runtime)
{
    memset(&runtime->drag, 0, sizeof(runtime->drag));
}

static bool runtime_begin_drag(kl_macos_runtime_t *runtime, CGEventRef event)
{
    if (runtime->drag.active) {
        return false;
    }

    CGPoint point = CGEventGetLocation(event);
    kl_point_t kl_point = {.x = point.x, .y = point.y};
    kl_macos_window_t window;
    if (!kl_macos_window_at_point(kl_point, runtime->managed_pid_filter, &window)) {
        return false;
    }

    kl_workspace_window_t *record = kl_workspace_find_window(runtime_workspace(runtime), window.window_id);
    if (!record && !runtime_notice_window(runtime, &window, NULL, "drag", false)) {
        return false;
    }

    record = kl_workspace_find_window(runtime_workspace(runtime), window.window_id);
    if (!record || record->fullscreen || record->minimized) {
        return false;
    }

    bool is_tiled = record->mode == KL_WINDOW_TILED;
    runtime->drag = (kl_macos_drag_state_t) {
        .window = window,
        .start_frame = window.frame,
        .last_point = kl_point,
        .window_id = window.window_id,
        .active = true,
        .started_tiled = is_tiled,
    };
    kl_pointer_move_grab_begin(
        &runtime->drag.grab,
        kl_point.x,
        kl_point.y,
        false,
        is_tiled);

    runtime->focused_window_id = window.window_id;
    kl_macos_focus_window(&window);
    if (is_tiled && kl_controller_focus_window(&runtime->controller, window.window_id)) {
        runtime_apply_layout(runtime);
    }

    if (runtime_trace_gestures()) {
        fprintf(
            stderr,
            "drag begin window=%u tiled=%d point=(%.1f,%.1f) frame=(%.1f,%.1f %.1fx%.1f)\n",
            window.window_id,
            is_tiled,
            kl_point.x,
            kl_point.y,
            window.frame.x,
            window.frame.y,
            window.frame.width,
            window.frame.height);
    }
    return true;
}

static size_t runtime_drag_target_column_index(const kl_macos_runtime_t *runtime, kl_point_t point)
{
    const kl_strip_t *strip = &runtime_workspace_const(runtime)->strip;
    double content_x =
        point.x -
        runtime->controller.viewport.x -
        strip->options.padding_left +
        strip->viewport_x;
    return kl_strip_target_index_for_x(strip, content_x);
}

static size_t runtime_drag_target_insert_index(const kl_macos_runtime_t *runtime, kl_point_t point)
{
    const kl_strip_t *strip = &runtime_workspace_const(runtime)->strip;
    double content_x =
        point.x -
        runtime->controller.viewport.x -
        strip->options.padding_left +
        strip->viewport_x;

    for (size_t i = 0; i < strip->count; i++) {
        double midpoint = kl_strip_column_x(strip, i) + (strip->columns[i].width / 2.0);
        if (content_x < midpoint) {
            return i;
        }
    }

    return strip->count;
}

static double runtime_drag_content_x(const kl_macos_runtime_t *runtime, const kl_strip_t *strip, kl_point_t point)
{
    return point.x -
        runtime->controller.viewport.x -
        strip->options.padding_left +
        strip->viewport_x;
}

static bool runtime_drag_stack_target(
    const kl_macos_runtime_t *runtime,
    size_t source_column,
    size_t *column_index,
    size_t *row_index)
{
    const kl_strip_t *strip = &runtime_workspace_const(runtime)->strip;
    if (strip->count == 0) {
        return false;
    }

    size_t target_column = runtime_drag_target_column_index(runtime, runtime->drag.last_point);
    if (target_column >= strip->count) {
        return false;
    }

    if (target_column != source_column &&
        strip->columns[target_column].count == KL_COLUMN_MAX_WINDOWS) {
        return false;
    }

    double content_x = runtime_drag_content_x(runtime, strip, runtime->drag.last_point);
    double column_x = kl_strip_column_x(strip, target_column);
    double column_width = strip->columns[target_column].width;
    double side_fraction = (1.0 - KL_RUNTIME_DRAG_STACK_ZONE_FRACTION) / 2.0;
    double left_stack_edge = column_x + (column_width * side_fraction);
    double right_stack_edge = column_x + (column_width * (1.0 - side_fraction));
    bool in_stack_zone = left_stack_edge <= content_x && content_x <= right_stack_edge;
    if (!in_stack_zone || (target_column == source_column && strip->columns[target_column].count == 1)) {
        return false;
    }

    *column_index = target_column;
    *row_index = kl_strip_target_row_for_y(
        strip,
        target_column,
        runtime->controller.viewport,
        runtime->drag.last_point.y);
    return true;
}

static bool runtime_commit_tiled_drag(
    kl_macos_runtime_t *runtime,
    double accumulated_x,
    double accumulated_y)
{
    kl_workspace_window_t *record =
        kl_workspace_find_window(runtime_workspace(runtime), runtime->drag.window_id);
    if (!record || record->mode != KL_WINDOW_TILED || record->fullscreen || record->minimized) {
        return false;
    }

    double distance = hypot(accumulated_x, accumulated_y);
    if (distance < KL_RUNTIME_DRAG_COMMIT_THRESHOLD) {
        if (runtime_trace_gestures()) {
            fprintf(
                stderr,
                "drag drop ignored window=%u distance=%.1f threshold=%.1f\n",
                runtime->drag.window_id,
                distance,
                KL_RUNTIME_DRAG_COMMIT_THRESHOLD);
        }
        return false;
    }

    kl_strip_t *strip = runtime_strip(runtime);
    if (strip->count == 0 || kl_strip_active_window(strip) != runtime->drag.window_id) {
        if (!kl_controller_focus_window(&runtime->controller, runtime->drag.window_id)) {
            return false;
        }
    }

    size_t source_column = 0;
    size_t source_row = 0;
    if (!kl_strip_find_window_location(strip, runtime->drag.window_id, &source_column, &source_row)) {
        return false;
    }

    size_t target_column = 0;
    size_t target_row = 0;
    bool moved = false;
    bool stacked = runtime_drag_stack_target(runtime, source_column, &target_column, &target_row);
    bool extracted = false;
    if (stacked) {
        size_t effective_row = target_row;
        if (target_column == source_column && effective_row > source_row) {
            effective_row--;
        }
        if (target_column != source_column || effective_row != source_row) {
            moved = kl_strip_move_window_to_column(
                strip,
                runtime->drag.window_id,
                target_column,
                target_row,
                runtime->controller.viewport.width);
        }
    } else if (strip->columns[source_column].count > 1) {
        target_column = runtime_drag_target_insert_index(runtime, runtime->drag.last_point);
        extracted = true;
        moved = kl_strip_extract_window_to_column(
            strip,
            runtime->drag.window_id,
            target_column,
            runtime->controller.viewport.width);
    } else {
        size_t previous = strip->active;
        target_column = runtime_drag_target_column_index(runtime, runtime->drag.last_point);
        moved = kl_strip_move_active(strip, target_column, runtime->controller.viewport.width) &&
            target_column != previous;
    }

    if (runtime_trace_gestures()) {
        fprintf(
            stderr,
            "drag drop window=%u stacked=%d extracted=%d source_column=%zu source_row=%zu target_column=%zu target_row=%zu moved=%d distance=%.1f\n",
            runtime->drag.window_id,
            stacked,
            extracted,
            source_column,
            source_row,
            target_column,
            target_row,
            moved,
            distance);
    }

    if (moved) {
        runtime_sync_focused_window(runtime);
        runtime_apply_layout(runtime);
    }
    return moved;
}

static bool runtime_update_drag(kl_macos_runtime_t *runtime, CGEventRef event)
{
    if (!runtime->drag.active) {
        return false;
    }

    CGPoint point = CGEventGetLocation(event);
    kl_point_t kl_point = {.x = point.x, .y = point.y};
    runtime->last_pointer = kl_point;
    runtime->drag.last_point = kl_point;

    kl_pointer_move_result_t result = kl_pointer_move_grab_update(
        &runtime->drag.grab,
        kl_point.x,
        kl_point.y,
        false,
        0.0,
        0.0);

    if (result.phase == KL_POINTER_MOVE_RECOGNIZING_PHASE) {
        return true;
    }

    if (result.phase == KL_POINTER_MOVE_BEGIN || result.phase == KL_POINTER_MOVE_UPDATE) {
        if (result.mode == KL_POINTER_MOVE_WINDOW) {
            runtime->drag.started_window_move = true;

            kl_rect_t frame = runtime->drag.start_frame;
            frame.x += result.accumulated_x;
            frame.y += result.accumulated_y;
            bool wrote_frame = false;
            kl_macos_set_window_frame_cached(
                &runtime->window_frame_cache,
                &runtime->drag.window,
                frame,
                &wrote_frame);
            runtime->drag.window.frame = frame;
            runtime->window_list_valid = false;
            return true;
        }
    }

    return true;
}

static bool runtime_end_drag(kl_macos_runtime_t *runtime, const char *reason)
{
    if (!runtime->drag.active) {
        return false;
    }

    kl_pointer_move_result_t result = kl_pointer_move_grab_end(&runtime->drag.grab);
    bool moved_floating_window = runtime->drag.started_window_move && !runtime->drag.started_tiled;
    bool should_commit_tiled = runtime->drag.started_tiled && runtime->drag.started_window_move;

    if (runtime_trace_gestures()) {
        fprintf(
            stderr,
            "drag end reason=%s window=%u mode=%d moved_floating=%d tiled_commit=%d\n",
            reason ? reason : "unknown",
            runtime->drag.window_id,
            result.mode,
            moved_floating_window,
            should_commit_tiled);
    }

    if (should_commit_tiled) {
        bool committed = runtime_commit_tiled_drag(
            runtime,
            result.accumulated_x,
            result.accumulated_y);
        if (!committed) {
            runtime_apply_layout(runtime);
        }
    } else if (moved_floating_window) {
        runtime_refresh_window_list(runtime);
    }

    runtime_reset_drag(runtime);
    return true;
}

static void runtime_reset_resize(kl_macos_runtime_t *runtime)
{
    memset(&runtime->resize, 0, sizeof(runtime->resize));
}

static bool runtime_begin_resize(kl_macos_runtime_t *runtime, CGEventRef event)
{
    if (runtime->resize.active || runtime->drag.active) {
        return false;
    }

    CGPoint point = CGEventGetLocation(event);
    kl_point_t kl_point = {.x = point.x, .y = point.y};
    kl_macos_window_t window;
    kl_workspace_window_t *record = NULL;
    if (!runtime_notice_hovered_window(runtime, kl_point, "resize", &window, &record)) {
        return false;
    }

    if (record->mode != KL_WINDOW_TILED || record->fullscreen || record->minimized) {
        return false;
    }

    size_t column_index = 0;
    size_t row_index = 0;
    if (!kl_strip_find_window_location(runtime_strip(runtime), window.window_id, &column_index, &row_index)) {
        return false;
    }

    kl_rect_t start_frame =
        kl_strip_window_frame(runtime_strip(runtime), column_index, row_index, runtime->controller.viewport);
    bool from_left_edge = kl_point.x < start_frame.x + (start_frame.width / 2.0);

    runtime->resize = (kl_macos_resize_state_t) {
        .window = window,
        .window_id = window.window_id,
        .start_width = runtime_strip(runtime)->columns[column_index].width,
        .start_viewport_x = runtime_strip(runtime)->viewport_x,
        .from_left_edge = from_left_edge,
        .active = true,
    };
    kl_pointer_resize_grab_begin(&runtime->resize.grab, kl_point.x, kl_point.y);

    runtime->focused_window_id = window.window_id;
    kl_macos_focus_window(&window);
    if (kl_controller_focus_window(&runtime->controller, window.window_id)) {
        runtime_apply_layout(runtime);
    }
    runtime->resize.start_viewport_x = runtime_strip(runtime)->viewport_x;

    if (runtime_trace_gestures()) {
        fprintf(
            stderr,
            "resize begin window=%u point=(%.1f,%.1f) edge=%s column=%zu width=%.1f viewport=%.3f\n",
            window.window_id,
            kl_point.x,
            kl_point.y,
            from_left_edge ? "left" : "right",
            column_index,
            runtime->resize.start_width,
            runtime->resize.start_viewport_x);
    }
    return true;
}

static bool runtime_update_resize(kl_macos_runtime_t *runtime, CGEventRef event)
{
    if (!runtime->resize.active) {
        return false;
    }

    CGPoint point = CGEventGetLocation(event);
    kl_point_t kl_point = {.x = point.x, .y = point.y};
    runtime->last_pointer = kl_point;

    kl_pointer_resize_result_t result = kl_pointer_resize_grab_update(
        &runtime->resize.grab,
        kl_point.x,
        kl_point.y);
    if (!result.active) {
        return true;
    }

    double width = runtime->resize.from_left_edge
        ? runtime->resize.start_width - result.delta_x
        : runtime->resize.start_width + result.delta_x;
    bool changed = kl_controller_set_window_width(
        &runtime->controller,
        runtime->resize.window_id,
        width);
    if (changed) {
        size_t column_index = 0;
        if (kl_strip_find_window_location(
                runtime_strip(runtime),
                runtime->resize.window_id,
                &column_index,
                NULL)) {
            double actual_delta =
                runtime_strip(runtime)->columns[column_index].width - runtime->resize.start_width;
            double anchored_viewport_x = runtime->resize.from_left_edge
                ? runtime->resize.start_viewport_x + actual_delta
                : runtime->resize.start_viewport_x;
            runtime_strip(runtime)->viewport_x = kl_strip_clamp_viewport_x(
                runtime_strip(runtime),
                runtime->controller.viewport.width,
                anchored_viewport_x);
        }
    }

    if (runtime_trace_gestures()) {
        size_t column_index = kl_strip_find_window(runtime_strip(runtime), runtime->resize.window_id);
        fprintf(
            stderr,
            "resize update window=%u edge=%s delta=(%.1f,%.1f) width=%.1f changed=%d column=%zu viewport=%.3f\n",
            runtime->resize.window_id,
            runtime->resize.from_left_edge ? "left" : "right",
            result.delta_x,
            result.delta_y,
            width,
            changed,
            column_index,
            runtime_strip(runtime)->viewport_x);
    }

    if (changed) {
        runtime_sync_focused_window(runtime);
        runtime_snap_layout(runtime);
    }
    return true;
}

static bool runtime_end_resize(kl_macos_runtime_t *runtime, const char *reason)
{
    if (!runtime->resize.active) {
        return false;
    }

    kl_pointer_resize_grab_end(&runtime->resize.grab);
    if (runtime_trace_gestures()) {
        size_t column_index = kl_strip_find_window(runtime_strip(runtime), runtime->resize.window_id);
        fprintf(
            stderr,
            "resize end reason=%s window=%u column=%zu\n",
            reason ? reason : "unknown",
            runtime->resize.window_id,
            column_index);
    }
    runtime_reset_resize(runtime);
    return true;
}

static unsigned runtime_modifiers_from_flags(CGEventFlags flags)
{
    unsigned modifiers = 0;
    if ((flags & kCGEventFlagMaskControl) != 0) {
        modifiers |= KL_MODIFIER_CTRL;
    }
    if ((flags & kCGEventFlagMaskShift) != 0) {
        modifiers |= KL_MODIFIER_SHIFT;
    }
    if ((flags & kCGEventFlagMaskAlternate) != 0) {
        modifiers |= KL_MODIFIER_ALT;
    }
    if ((flags & kCGEventFlagMaskCommand) != 0) {
        modifiers |= KL_MODIFIER_SUPER;
    }
    return modifiers;
}

static kl_key_symbol_t runtime_key_symbol_from_keycode(int64_t keycode)
{
    switch (keycode) {
    case KL_KEY_A:
        return KL_KEY_SYMBOL_A;
    case KL_KEY_B:
        return KL_KEY_SYMBOL_B;
    case KL_KEY_C:
        return KL_KEY_SYMBOL_C;
    case KL_KEY_D:
        return KL_KEY_SYMBOL_D;
    case KL_KEY_E:
        return KL_KEY_SYMBOL_E;
    case KL_KEY_F:
        return KL_KEY_SYMBOL_F;
    case KL_KEY_G:
        return KL_KEY_SYMBOL_G;
    case KL_KEY_H:
        return KL_KEY_SYMBOL_H;
    case KL_KEY_I:
        return KL_KEY_SYMBOL_I;
    case KL_KEY_J:
        return KL_KEY_SYMBOL_J;
    case KL_KEY_K:
        return KL_KEY_SYMBOL_K;
    case KL_KEY_L:
        return KL_KEY_SYMBOL_L;
    case KL_KEY_M:
        return KL_KEY_SYMBOL_M;
    case KL_KEY_N:
        return KL_KEY_SYMBOL_N;
    case KL_KEY_O:
        return KL_KEY_SYMBOL_O;
    case KL_KEY_P:
        return KL_KEY_SYMBOL_P;
    case KL_KEY_Q:
        return KL_KEY_SYMBOL_Q;
    case KL_KEY_R:
        return KL_KEY_SYMBOL_R;
    case KL_KEY_S:
        return KL_KEY_SYMBOL_S;
    case KL_KEY_T:
        return KL_KEY_SYMBOL_T;
    case KL_KEY_U:
        return KL_KEY_SYMBOL_U;
    case KL_KEY_V:
        return KL_KEY_SYMBOL_V;
    case KL_KEY_W:
        return KL_KEY_SYMBOL_W;
    case KL_KEY_X:
        return KL_KEY_SYMBOL_X;
    case KL_KEY_Y:
        return KL_KEY_SYMBOL_Y;
    case KL_KEY_Z:
        return KL_KEY_SYMBOL_Z;
    case KL_KEY_1:
        return KL_KEY_SYMBOL_1;
    case KL_KEY_2:
        return KL_KEY_SYMBOL_2;
    case KL_KEY_3:
        return KL_KEY_SYMBOL_3;
    case KL_KEY_4:
        return KL_KEY_SYMBOL_4;
    case KL_KEY_5:
        return KL_KEY_SYMBOL_5;
    case KL_KEY_6:
        return KL_KEY_SYMBOL_6;
    case KL_KEY_7:
        return KL_KEY_SYMBOL_7;
    case KL_KEY_8:
        return KL_KEY_SYMBOL_8;
    case KL_KEY_9:
        return KL_KEY_SYMBOL_9;
    case KL_KEY_0:
        return KL_KEY_SYMBOL_0;
    case KL_KEY_LEFT:
        return KL_KEY_SYMBOL_LEFT;
    case KL_KEY_RIGHT:
        return KL_KEY_SYMBOL_RIGHT;
    case KL_KEY_UP:
        return KL_KEY_SYMBOL_UP;
    case KL_KEY_DOWN:
        return KL_KEY_SYMBOL_DOWN;
    case KL_KEY_HOME:
        return KL_KEY_SYMBOL_HOME;
    case KL_KEY_END:
        return KL_KEY_SYMBOL_END;
    case KL_KEY_PAGE_UP:
        return KL_KEY_SYMBOL_PAGE_UP;
    case KL_KEY_PAGE_DOWN:
        return KL_KEY_SYMBOL_PAGE_DOWN;
    case KL_KEY_MINUS:
        return KL_KEY_SYMBOL_MINUS;
    case KL_KEY_EQUAL:
        return KL_KEY_SYMBOL_EQUAL;
    case KL_KEY_BRACKET_LEFT:
        return KL_KEY_SYMBOL_BRACKET_LEFT;
    case KL_KEY_BRACKET_RIGHT:
        return KL_KEY_SYMBOL_BRACKET_RIGHT;
    case KL_KEY_COMMA:
        return KL_KEY_SYMBOL_COMMA;
    case KL_KEY_PERIOD:
        return KL_KEY_SYMBOL_PERIOD;
    case KL_KEY_TAB:
        return KL_KEY_SYMBOL_TAB;
    case KL_KEY_SPACE:
        return KL_KEY_SYMBOL_SPACE;
    case KL_KEY_RETURN:
        return KL_KEY_SYMBOL_RETURN;
    case KL_KEY_ESCAPE:
        return KL_KEY_SYMBOL_ESCAPE;
    default:
        return KL_KEY_SYMBOL_NONE;
    }
}

static bool runtime_binding_ready(kl_binding_t *binding, bool repeat, double now)
{
    if (!binding->repeat && repeat) {
        return false;
    }

    if (binding->cooldown_ms > 0.0 &&
        binding->last_triggered_at > 0.0 &&
        (now - binding->last_triggered_at) * 1000.0 < binding->cooldown_ms) {
        return false;
    }

    binding->last_triggered_at = now;
    return true;
}

static uint32_t runtime_target_window_id(kl_macos_runtime_t *runtime, kl_point_t point)
{
    if (runtime->focused_window_id != 0) {
        return runtime->focused_window_id;
    }

    kl_macos_window_t window;
    if (!kl_macos_window_at_point(point, runtime->managed_pid_filter, &window)) {
        return 0;
    }

    if (!kl_workspace_find_window(runtime_workspace(runtime), window.window_id) &&
        !runtime_notice_window(runtime, &window, NULL, "binding", false)) {
        return 0;
    }

    runtime->focused_window_id = window.window_id;
    return window.window_id;
}

static bool runtime_focus_column_edge(kl_macos_runtime_t *runtime, bool last)
{
    kl_strip_t *strip = runtime_strip(runtime);
    if (strip->count == 0) {
        return false;
    }

    bool changed = kl_strip_focus(
        strip,
        last ? strip->count - 1 : 0,
        runtime->controller.viewport.width);
    if (changed) {
        runtime_sync_focused_window(runtime);
        runtime_apply_layout(runtime);
    }
    return changed;
}

static bool runtime_move_column_edge(kl_macos_runtime_t *runtime, bool last)
{
    kl_strip_t *strip = runtime_strip(runtime);
    if (strip->count == 0) {
        return false;
    }

    bool changed = kl_strip_move_active(
        strip,
        last ? strip->count - 1 : 0,
        runtime->controller.viewport.width);
    if (changed) {
        runtime_sync_focused_window(runtime);
        runtime_apply_layout(runtime);
    }
    return changed;
}

static bool runtime_parse_width_change(
    kl_macos_runtime_t *runtime,
    const char *argument,
    double current_width,
    double *out)
{
    if (!argument || *argument == '\0') {
        return false;
    }

    bool relative = argument[0] == '+' || argument[0] == '-';
    char *end = NULL;
    double value = strtod(argument, &end);
    if (end == argument) {
        return false;
    }

    double width = value;
    if (*end == '%') {
        width = kl_strip_effective_viewport_width(
            runtime_strip(runtime),
            runtime->controller.viewport.width) * (value / 100.0);
        end++;
    }

    while (*end && isspace((unsigned char) *end)) {
        end++;
    }
    if (*end != '\0') {
        return false;
    }

    *out = relative ? current_width + width : width;
    return true;
}

static bool runtime_set_active_column_width(kl_macos_runtime_t *runtime, const char *argument)
{
    kl_window_id_t window_id = kl_strip_active_window(runtime_strip(runtime));
    if (window_id == 0) {
        return false;
    }

    size_t column_index = 0;
    if (!kl_strip_find_window_location(runtime_strip(runtime), window_id, &column_index, NULL)) {
        return false;
    }

    double width = 0.0;
    if (!runtime_parse_width_change(
            runtime,
            argument,
            runtime_strip(runtime)->columns[column_index].width,
            &width)) {
        return false;
    }

    if (!kl_controller_set_window_width(&runtime->controller, window_id, width)) {
        return false;
    }

    runtime_sync_focused_window(runtime);
    runtime_apply_layout(runtime);
    return true;
}

static bool runtime_set_target_window_mode(
    kl_macos_runtime_t *runtime,
    kl_point_t point,
    kl_window_mode_t mode)
{
    uint32_t window_id = runtime_target_window_id(runtime, point);
    if (window_id == 0) {
        return false;
    }

    bool changed = kl_controller_set_mode_with_origin(
        &runtime->controller,
        window_id,
        mode,
        KL_WINDOW_MODE_USER);
    if (changed) {
        runtime_sync_focused_window(runtime);
        runtime_apply_layout(runtime);
    }
    return changed;
}

static bool runtime_execute_binding_action(
    kl_macos_runtime_t *runtime,
    const kl_binding_t *binding,
    kl_point_t point)
{
    switch (binding->action) {
    case KL_ACTION_SCROLL_LEFT:
        runtime_scroll(runtime, KL_SCROLL_LEFT);
        return true;
    case KL_ACTION_SCROLL_RIGHT:
        runtime_scroll(runtime, KL_SCROLL_RIGHT);
        return true;
    case KL_ACTION_FOCUS_COLUMN_LEFT:
        return runtime_focus_active_column(runtime, -1);
    case KL_ACTION_FOCUS_COLUMN_RIGHT:
        return runtime_focus_active_column(runtime, 1);
    case KL_ACTION_FOCUS_COLUMN_FIRST:
        return runtime_focus_column_edge(runtime, false);
    case KL_ACTION_FOCUS_COLUMN_LAST:
        return runtime_focus_column_edge(runtime, true);
    case KL_ACTION_FOCUS_WINDOW_UP:
        if (kl_controller_focus_window_in_column(&runtime->controller, -1)) {
            runtime_sync_focused_window(runtime);
            runtime_apply_layout(runtime);
            return true;
        }
        return false;
    case KL_ACTION_FOCUS_WINDOW_DOWN:
        if (kl_controller_focus_window_in_column(&runtime->controller, 1)) {
            runtime_sync_focused_window(runtime);
            runtime_apply_layout(runtime);
            return true;
        }
        return false;
    case KL_ACTION_MOVE_COLUMN_LEFT:
        runtime_move_active_column(runtime, -1);
        return true;
    case KL_ACTION_MOVE_COLUMN_RIGHT:
        runtime_move_active_column(runtime, 1);
        return true;
    case KL_ACTION_MOVE_COLUMN_FIRST:
        return runtime_move_column_edge(runtime, false);
    case KL_ACTION_MOVE_COLUMN_LAST:
        return runtime_move_column_edge(runtime, true);
    case KL_ACTION_MOVE_WINDOW_UP:
        if (kl_controller_move_active_window_in_column(&runtime->controller, -1)) {
            runtime_sync_focused_window(runtime);
            runtime_apply_layout(runtime);
            return true;
        }
        return false;
    case KL_ACTION_MOVE_WINDOW_DOWN:
        if (kl_controller_move_active_window_in_column(&runtime->controller, 1)) {
            runtime_sync_focused_window(runtime);
            runtime_apply_layout(runtime);
            return true;
        }
        return false;
    case KL_ACTION_TOGGLE_WINDOW_FLOATING:
        runtime_toggle_floating(runtime, point);
        return true;
    case KL_ACTION_MOVE_WINDOW_TO_FLOATING:
        return runtime_set_target_window_mode(runtime, point, KL_WINDOW_FLOATING);
    case KL_ACTION_MOVE_WINDOW_TO_TILING:
        return runtime_set_target_window_mode(runtime, point, KL_WINDOW_TILED);
    case KL_ACTION_MAXIMIZE_COLUMN:
        runtime_toggle_hovered_window_maximized_width(runtime, point);
        return true;
    case KL_ACTION_SET_COLUMN_WIDTH:
        return runtime_set_active_column_width(runtime, binding->argument);
    case KL_ACTION_START_MOVE:
    case KL_ACTION_START_RESIZE:
        return false;
    }

    return false;
}

static bool runtime_handle_binding(
    kl_macos_runtime_t *runtime,
    kl_binding_trigger_t trigger,
    unsigned modifiers,
    bool repeat,
    kl_point_t point)
{
    kl_binding_t *binding = kl_config_find_binding(&runtime->config, trigger, modifiers);
    if (!binding) {
        return false;
    }

    double now = runtime_seconds();
    if (!runtime_binding_ready(binding, repeat, now)) {
        return true;
    }

    runtime_execute_binding_action(runtime, binding, point);
    return true;
}

static bool runtime_handle_mouse_binding(
    kl_macos_runtime_t *runtime,
    CGEventRef event,
    kl_binding_trigger_kind_t kind)
{
    CGPoint point = CGEventGetLocation(event);
    kl_point_t kl_point = {.x = point.x, .y = point.y};
    kl_binding_trigger_t trigger = {
        .kind = kind,
        .key = KL_KEY_SYMBOL_NONE,
    };
    unsigned modifiers = runtime_modifiers_from_flags(CGEventGetFlags(event));
    kl_binding_t *binding = kl_config_find_binding(&runtime->config, trigger, modifiers);
    if (!binding) {
        return false;
    }

    if (!runtime_binding_ready(binding, false, runtime_seconds())) {
        return true;
    }

    if (binding->action == KL_ACTION_START_MOVE) {
        return runtime_begin_drag(runtime, event);
    }
    if (binding->action == KL_ACTION_START_RESIZE) {
        return runtime_begin_resize(runtime, event);
    }

    runtime_execute_binding_action(runtime, binding, kl_point);
    return true;
}

static kl_binding_trigger_t runtime_wheel_trigger(double horizontal_delta, double vertical_delta)
{
    kl_binding_trigger_t trigger = {
        .kind = KL_BINDING_TRIGGER_WHEEL_UP,
        .key = KL_KEY_SYMBOL_NONE,
    };

    if (fabs(horizontal_delta) > fabs(vertical_delta)) {
        trigger.kind = horizontal_delta >= 0.0
            ? KL_BINDING_TRIGGER_WHEEL_RIGHT
            : KL_BINDING_TRIGGER_WHEEL_LEFT;
        return trigger;
    }

    trigger.kind = vertical_delta >= 0.0
        ? KL_BINDING_TRIGGER_WHEEL_UP
        : KL_BINDING_TRIGGER_WHEEL_DOWN;
    return trigger;
}

static CGEventRef event_tap_callback(
    CGEventTapProxy proxy,
    CGEventType type,
    CGEventRef event,
    void *refcon)
{
    (void) proxy;
    kl_macos_runtime_t *runtime = refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        runtime_end_drag(runtime, "tap-disabled");
        runtime_end_resize(runtime, "tap-disabled");
        CGEventTapEnable(runtime->event_tap, true);
        return event;
    }

    if (type == kCGEventLeftMouseDown) {
        return runtime_handle_mouse_binding(
            runtime,
            event,
            KL_BINDING_TRIGGER_MOUSE_LEFT) ? NULL : event;
    }

    if (type == kCGEventLeftMouseDragged && runtime->drag.active) {
        return runtime_update_drag(runtime, event) ? NULL : event;
    }

    if (type == kCGEventLeftMouseUp) {
        return runtime_end_drag(runtime, "mouse-up") ? NULL : event;
    }

    if (type == kCGEventRightMouseDown) {
        return runtime_handle_mouse_binding(
            runtime,
            event,
            KL_BINDING_TRIGGER_MOUSE_RIGHT) ? NULL : event;
    }

    if (type == kCGEventRightMouseDragged && runtime->resize.active) {
        return runtime_update_resize(runtime, event) ? NULL : event;
    }

    if (type == kCGEventRightMouseUp) {
        return runtime_end_resize(runtime, "mouse-up") ? NULL : event;
    }

    if (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged) {
        CGPoint point = CGEventGetLocation(event);
        runtime->last_pointer = (kl_point_t) {.x = point.x, .y = point.y};
        if (!runtime->scrolling_active && !runtime->drag.active && !runtime->resize.active) {
            runtime_focus_hovered_window(runtime, runtime->last_pointer);
        }
        return event;
    }

    if (type == kCGEventScrollWheel) {
        return runtime_handle_scroll_wheel(runtime, event) ? NULL : event;
    }

    if (type != kCGEventKeyDown) {
        if (type == (CGEventType) NSEventTypeGesture) {
            return runtime_handle_gesture(runtime, event) ? NULL : event;
        }

        return event;
    }

    CGEventFlags flags = CGEventGetFlags(event);
    int64_t keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    kl_key_symbol_t key = runtime_key_symbol_from_keycode(keycode);
    if (key == KL_KEY_SYMBOL_NONE) {
        return event;
    }

    CGPoint point = CGEventGetLocation(event);
    runtime->last_pointer = (kl_point_t) {.x = point.x, .y = point.y};

    kl_binding_trigger_t trigger = {
        .kind = KL_BINDING_TRIGGER_KEY,
        .key = key,
    };
    bool repeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
    return runtime_handle_binding(
        runtime,
        trigger,
        runtime_modifiers_from_flags(flags),
        repeat,
        runtime->last_pointer) ? NULL : event;
}

static bool runtime_install_event_tap(kl_macos_runtime_t *runtime)
{
    CGEventMask mask =
        CGEventMaskBit(kCGEventKeyDown) |
        CGEventMaskBit(kCGEventMouseMoved) |
        CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseDragged) |
        CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventScrollWheel) |
        ((CGEventMask) 1 << NSEventTypeGesture);

    runtime->event_tap = CGEventTapCreate(
        kCGHIDEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        event_tap_callback,
        runtime);

    if (!runtime->event_tap) {
        runtime->event_tap = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionDefault,
            mask,
            event_tap_callback,
            runtime);
    }

    if (!runtime->event_tap) {
        return false;
    }

    runtime->event_source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, runtime->event_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), runtime->event_source, kCFRunLoopCommonModes);
    CGEventTapEnable(runtime->event_tap, true);
    return true;
}

static void runtime_install_rescan_timer(kl_macos_runtime_t *runtime)
{
    runtime->rescan_timer = runtime_schedule_timer(runtime_rescan_interval(), YES, ^(__unused NSTimer *timer) {
        if (runtime_window_event_batch_pending(runtime)) {
            return;
        }
        runtime_rescan_and_apply(runtime, "poll");
    });
}

int kl_macos_runtime_run(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        if (other_window_manager_is_running()) {
            fprintf(stderr, "refusing to start while yabai is running; stop yabai or set KLOTSKI_ALLOW_WM_CONFLICT=1.\n");
            return 1;
        }

        if (!kl_macos_accessibility_is_trusted(true)) {
            fprintf(stderr, "klotski needs Accessibility permission before it can manage windows.\n");
            return 1;
        }

        kl_macos_runtime_t *runtime = calloc(1, sizeof(*runtime));
        if (!runtime) {
            return 1;
        }
        kl_macos_window_frame_cache_init(&runtime->window_frame_cache);

        kl_config_t config = runtime_load_config();
        runtime->config = config;
        for (size_t i = 0; i < runtime->config.unsupported_bind_count; i++) {
            fprintf(
                stderr,
                "unsupported bind action ignored: %s\n",
                runtime->config.unsupported_binds[i]);
        }
        kl_controller_init(&runtime->controller, config.layout, main_display_viewport());
        runtime->controller.keyboard_scroll_fraction = config.keyboard_scroll_fraction;
        runtime->managed_pid_filter = runtime_load_managed_pid_filter();
        runtime->benchmark_active_focus_pending =
            runtime_benchmark_enabled() &&
            runtime_load_benchmark_active_index(&runtime->benchmark_active_focus_index);
        runtime->window_observer = kl_macos_window_observer_create();
        if (runtime->window_observer &&
            !kl_macos_window_observer_start(
                runtime->window_observer,
                runtime->managed_pid_filter,
                runtime_window_observer_callback,
                runtime)) {
            fprintf(stderr, "window creation observer unavailable; using polling fallback.\n");
            kl_macos_window_observer_destroy(runtime->window_observer);
            runtime->window_observer = NULL;
        }

        runtime_rescan_and_apply(runtime, "startup");

        if (!runtime_install_event_tap(runtime)) {
            fprintf(stderr, "failed to install event tap; check Accessibility/Input Monitoring permissions.\n");
            kl_macos_window_observer_destroy(runtime->window_observer);
            kl_macos_window_frame_cache_destroy(&runtime->window_frame_cache);
            free(runtime);
            return 1;
        }

        runtime_install_rescan_timer(runtime);
        if (runtime->managed_pid_filter > 0) {
            fprintf(stderr, "klotski managing only pid %d.\n", runtime->managed_pid_filter);
        }
        if (runtime_benchmark_enabled()) {
            double apply_interval = runtime_gesture_apply_interval();
            fprintf(
                stderr,
                "bench config gesture_apply_hz=%.3f rescan_interval_ms=%.3f coalescing=%d\n",
                apply_interval > 0.0 ? 1.0 / apply_interval : 0.0,
                runtime_rescan_interval() * 1000.0,
                apply_interval > 0.0);
        }
        fprintf(
            stderr,
            "klotski running: %zu binds active, %zu window rules active, %zu unsupported bind actions ignored, hover focuses.\n",
            runtime->config.binding_count,
            runtime->config.window_rule_count,
            runtime->config.unsupported_bind_count);

        CFRunLoopRun();
        runtime_cancel_window_event_batch(runtime);
        runtime_cancel_window_event_retry(runtime);
        kl_macos_window_observer_destroy(runtime->window_observer);
        kl_macos_window_frame_cache_destroy(&runtime->window_frame_cache);
        free(runtime);
        return 0;
    }
}
