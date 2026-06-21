#include "core/gesture.h"
#include "core/controller.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static bool close_to(double a, double b)
{
    return fabs(a - b) < 0.0001;
}

static kl_controller_t sample_controller(void)
{
    kl_layout_options_t options = kl_layout_default_options();
    options.default_width_fraction = 0.5;
    options.gap = 2.0;
    options.padding_left = 24.0;
    options.padding_right = 24.0;

    kl_controller_t controller;
    kl_controller_init(
        &controller,
        options,
        (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 1200.0, .height = 800.0});

    assert(kl_controller_notice_window(&controller, 101));
    assert(kl_controller_notice_window(&controller, 102));
    assert(kl_controller_notice_window(&controller, 103));
    assert(kl_controller_focus_window(&controller, 101));
    kl_controller_workspace(&controller)->strip.viewport_x =
        kl_strip_snap_viewport_x_for_column(&kl_controller_workspace(&controller)->strip, 0, controller.viewport.width);

    return controller;
}

static void test_fast_snap_tracker_projects_to_next_snap(void)
{
    kl_controller_t controller = sample_controller();
    kl_horizontal_gesture_t gesture = {0};

    kl_horizontal_gesture_begin(&gesture, &controller);
    double visual = kl_horizontal_gesture_update(&gesture, &controller, 80.0, 0.016);
    assert(close_to(visual, 80.0));
    assert(close_to(kl_controller_workspace(&controller)->strip.viewport_x, 0.0));
    assert(kl_controller_workspace(&controller)->strip.active == 0);

    kl_horizontal_gesture_result_t result =
        kl_horizontal_gesture_finish(&gesture, &controller, 0.032);

    assert(result.committed);
    assert(result.changed_focus);
    assert(kl_controller_workspace(&controller)->strip.active == 1);
    assert(close_to(kl_controller_workspace(&controller)->strip.viewport_x, 551.0));
    assert(close_to(result.target_viewport_x, 551.0));
}

static void test_fast_snap_tracker_projects_to_previous_snap(void)
{
    kl_controller_t controller = sample_controller();
    assert(kl_controller_focus_window(&controller, 102));
    kl_controller_workspace(&controller)->strip.viewport_x =
        kl_strip_snap_viewport_x_for_column(&kl_controller_workspace(&controller)->strip, 1, controller.viewport.width);

    kl_horizontal_gesture_t gesture = {0};
    kl_horizontal_gesture_begin(&gesture, &controller);
    gesture.visual_viewport_x = kl_controller_workspace(&controller)->strip.viewport_x;

    double visual = kl_horizontal_gesture_update(&gesture, &controller, -80.0, 0.016);
    assert(close_to(visual, 497.0));
    assert(close_to(kl_controller_workspace(&controller)->strip.viewport_x, 577.0));
    assert(kl_controller_workspace(&controller)->strip.active == 1);

    kl_horizontal_gesture_result_t result =
        kl_horizontal_gesture_finish(&gesture, &controller, 0.032);

    assert(result.committed);
    assert(result.changed_focus);
    assert(kl_controller_workspace(&controller)->strip.active == 0);
    assert(close_to(kl_controller_workspace(&controller)->strip.viewport_x, -26.0));
    assert(close_to(result.target_viewport_x, -26.0));
}

static void test_slow_snap_tracker_snaps_to_adjacent_visible_edge(void)
{
    kl_controller_t controller = sample_controller();
    kl_horizontal_gesture_t gesture = {0};

    kl_horizontal_gesture_begin(&gesture, &controller);
    double visual = kl_horizontal_gesture_update(&gesture, &controller, 8.0, 0.016);
    assert(close_to(visual, 8.0));

    kl_horizontal_gesture_result_t result =
        kl_horizontal_gesture_finish(&gesture, &controller, 0.200);

    assert(result.committed);
    assert(result.changed_focus);
    assert(kl_controller_workspace(&controller)->strip.active == 1);
    assert(close_to(kl_controller_workspace(&controller)->strip.viewport_x, -22.0));
    assert(close_to(result.target_viewport_x, -22.0));
}

static void test_gesture_visual_viewport_is_clamped_at_strip_edges(void)
{
    kl_controller_t controller = sample_controller();
    kl_horizontal_gesture_t gesture = {0};

    kl_horizontal_gesture_begin(&gesture, &controller);
    double visual = kl_horizontal_gesture_update(&gesture, &controller, -500.0, 0.016);
    assert(close_to(visual, -26.0));

    kl_horizontal_gesture_result_t result =
        kl_horizontal_gesture_finish(&gesture, &controller, 0.080);

    assert(result.committed);
    assert(!result.changed_focus);
    assert(kl_controller_workspace(&controller)->strip.active == 0);
    assert(close_to(kl_controller_workspace(&controller)->strip.viewport_x, -26.0));

    assert(kl_controller_focus_window(&controller, 103));
    kl_controller_workspace(&controller)->strip.viewport_x = kl_strip_max_scroll_viewport_x(
        &kl_controller_workspace(&controller)->strip,
        controller.viewport.width);

    kl_horizontal_gesture_begin(&gesture, &controller);
    visual = kl_horizontal_gesture_update(&gesture, &controller, 500.0, 1.016);
    assert(close_to(visual, 555.0));

    result = kl_horizontal_gesture_finish(&gesture, &controller, 1.080);

    assert(result.committed);
    assert(!result.changed_focus);
    assert(kl_controller_workspace(&controller)->strip.active == 2);
    assert(close_to(kl_controller_workspace(&controller)->strip.viewport_x, 555.0));
}

static void test_large_gesture_commits_only_to_adjacent_column(void)
{
    kl_controller_t controller = sample_controller();
    kl_horizontal_gesture_t gesture = {0};

    kl_controller_workspace(&controller)->strip.viewport_x = kl_strip_min_scroll_viewport_x(
        &kl_controller_workspace(&controller)->strip,
        controller.viewport.width);

    kl_horizontal_gesture_begin(&gesture, &controller);
    double visual = kl_horizontal_gesture_update(&gesture, &controller, 500.0, 0.016);
    assert(close_to(visual, 474.0));

    kl_horizontal_gesture_result_t result =
        kl_horizontal_gesture_finish(&gesture, &controller, 0.080);

    assert(result.committed);
    assert(result.changed_focus);
    assert(kl_controller_workspace(&controller)->strip.active == 1);
    assert(close_to(kl_controller_workspace(&controller)->strip.viewport_x, 551.0));

    assert(kl_controller_focus_window(&controller, 103));
    kl_controller_workspace(&controller)->strip.viewport_x = kl_strip_max_scroll_viewport_x(
        &kl_controller_workspace(&controller)->strip,
        controller.viewport.width);

    kl_horizontal_gesture_begin(&gesture, &controller);
    visual = kl_horizontal_gesture_update(&gesture, &controller, -500.0, 1.016);
    assert(close_to(visual, 55.0));

    result = kl_horizontal_gesture_finish(&gesture, &controller, 1.080);

    assert(result.committed);
    assert(result.changed_focus);
    assert(kl_controller_workspace(&controller)->strip.active == 1);
    assert(close_to(kl_controller_workspace(&controller)->strip.viewport_x, -22.0));
}

int main(void)
{
    test_fast_snap_tracker_projects_to_next_snap();
    test_fast_snap_tracker_projects_to_previous_snap();
    test_slow_snap_tracker_snaps_to_adjacent_visible_edge();
    test_gesture_visual_viewport_is_clamped_at_strip_edges();
    test_large_gesture_commits_only_to_adjacent_column();

    puts("gesture tests passed");
    return 0;
}
