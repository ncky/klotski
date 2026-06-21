#include "core/input.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static bool close_to(double a, double b)
{
    return fabs(a - b) < 0.0001;
}

static void test_scroll_tracker_matches_niri_ticks(void)
{
    kl_scroll_tracker_t tracker;
    kl_scroll_tracker_init(&tracker, KL_INPUT_WHEEL_SCROLL_TICK);

    assert(kl_scroll_tracker_accumulate(&tracker, 60.0) == 0);
    assert(kl_scroll_tracker_accumulate(&tracker, 70.0) == 1);
    assert(kl_scroll_tracker_accumulate(&tracker, -20.0) == 0);
    assert(kl_scroll_tracker_accumulate(&tracker, -100.0) == -1);
    assert(kl_scroll_tracker_accumulate(&tracker, 20000.0) == 127);

    kl_scroll_tracker_reset(&tracker);
    assert(kl_scroll_tracker_accumulate(&tracker, 119.0) == 0);

    kl_scroll_tracker_init(&tracker, KL_INPUT_FINGER_SCROLL_TICK);
    assert(kl_scroll_tracker_accumulate(&tracker, 9.0) == 0);
    assert(kl_scroll_tracker_accumulate(&tracker, 1.0) == 1);
}

static void test_scroll_swipe_gesture_tracks_axis_and_lifecycle(void)
{
    kl_scroll_swipe_gesture_t gesture;
    kl_scroll_swipe_gesture_init(&gesture);

    kl_scroll_swipe_action_t action = kl_scroll_swipe_gesture_update(&gesture, 4.0, 0.0);
    assert(action == KL_SCROLL_SWIPE_BEGIN_UPDATE);
    assert(kl_scroll_swipe_action_begins(action));
    assert(!kl_scroll_swipe_gesture_is_vertical(&gesture));

    action = kl_scroll_swipe_gesture_update(&gesture, 2.0, 1.0);
    assert(action == KL_SCROLL_SWIPE_UPDATE);

    action = kl_scroll_swipe_gesture_update(&gesture, 0.0, 0.0);
    assert(action == KL_SCROLL_SWIPE_END);
    assert(kl_scroll_swipe_action_ends(action));

    action = kl_scroll_swipe_gesture_update(&gesture, 0.0, 2.0);
    assert(action == KL_SCROLL_SWIPE_BEGIN_UPDATE);
    assert(kl_scroll_swipe_gesture_is_vertical(&gesture));
    assert(kl_scroll_swipe_gesture_reset(&gesture));
    assert(!kl_scroll_swipe_gesture_reset(&gesture));
}

static void test_swipe_tracker_velocity_projection_and_history(void)
{
    kl_swipe_tracker_t tracker;
    kl_swipe_tracker_init(&tracker);

    kl_swipe_tracker_push(&tracker, 10.0, 0.000);
    kl_swipe_tracker_push(&tracker, 10.0, 0.050);

    assert(close_to(kl_swipe_tracker_position(&tracker), 20.0));
    assert(close_to(kl_swipe_tracker_velocity(&tracker), 400.0));
    assert(kl_swipe_tracker_projected_end_position(&tracker) > 150.0);

    kl_swipe_tracker_push(&tracker, 10.0, 0.300);
    assert(close_to(kl_swipe_tracker_position(&tracker), 30.0));
    assert(close_to(kl_swipe_tracker_velocity(&tracker), 0.0));

    kl_swipe_tracker_push(&tracker, 10.0, 0.200);
    assert(close_to(kl_swipe_tracker_position(&tracker), 30.0));
}

static void test_three_finger_swipe_uses_niri_axis_threshold(void)
{
    kl_three_finger_swipe_t gesture;
    kl_three_finger_swipe_begin(&gesture, 2);
    kl_three_finger_swipe_result_t result =
        kl_three_finger_swipe_update(&gesture, 20.0, 0.0);
    assert(result.phase == KL_THREE_FINGER_SWIPE_IGNORED);

    kl_three_finger_swipe_begin(&gesture, 3);
    result = kl_three_finger_swipe_update(&gesture, 4.0, 4.0);
    assert(result.phase == KL_THREE_FINGER_SWIPE_RECOGNIZING);
    assert(close_to(result.delta_x, 4.0));
    assert(close_to(result.delta_y, 4.0));

    result = kl_three_finger_swipe_update(&gesture, 13.0, 0.0);
    assert(result.phase == KL_THREE_FINGER_SWIPE_BEGIN);
    assert(result.axis == KL_INPUT_AXIS_HORIZONTAL);
    assert(close_to(result.delta_x, 17.0));
    assert(close_to(result.delta_y, 4.0));

    result = kl_three_finger_swipe_update(&gesture, 2.0, 1.0);
    assert(result.phase == KL_THREE_FINGER_SWIPE_UPDATE);
    assert(result.axis == KL_INPUT_AXIS_HORIZONTAL);
    assert(close_to(result.delta_x, 2.0));
    assert(close_to(result.delta_y, 1.0));

    result = kl_three_finger_swipe_end(&gesture);
    assert(result.phase == KL_THREE_FINGER_SWIPE_END);
    assert(result.axis == KL_INPUT_AXIS_HORIZONTAL);

    kl_three_finger_swipe_begin(&gesture, 3);
    result = kl_three_finger_swipe_update(&gesture, 0.0, 17.0);
    assert(result.phase == KL_THREE_FINGER_SWIPE_BEGIN);
    assert(result.axis == KL_INPUT_AXIS_VERTICAL);
}

static void test_view_scroll_gesture_scales_touchpad_units_to_viewport_width(void)
{
    kl_view_scroll_gesture_t gesture;
    kl_view_scroll_gesture_begin(&gesture, 100.0, true);

    double viewport_x = 0.0;
    assert(kl_view_scroll_gesture_update(&gesture, 120.0, 0.000, 2400.0, true, &viewport_x));
    assert(close_to(viewport_x, 340.0));

    kl_view_scroll_gesture_adjust_after_clamp(&gesture, viewport_x, 300.0);
    assert(kl_view_scroll_gesture_update(&gesture, 60.0, 0.016, 2400.0, true, &viewport_x));
    assert(close_to(viewport_x, 420.0));

    kl_view_scroll_gesture_result_t result;
    assert(kl_view_scroll_gesture_end(&gesture, 0.032, 2400.0, true, true, &result));
    assert(result.ended);
    assert(close_to(result.current_viewport_x, 420.0));
    assert(result.projected_viewport_x > result.current_viewport_x);

    kl_view_scroll_gesture_begin(&gesture, 100.0, false);
    assert(kl_view_scroll_gesture_update(&gesture, 120.0, 0.000, 2400.0, false, &viewport_x));
    assert(close_to(viewport_x, 220.0));
}

static void test_input_delta_conversions(void)
{
    double units = kl_input_touchpad_normalized_delta_to_units(0.01, 8.0);
    assert(close_to(units, 96.0));
    assert(close_to(kl_input_touchpad_scroll_delta_to_units(0.01, 8.0, false), 96.0));
    assert(close_to(kl_input_touchpad_scroll_delta_to_units(0.01, 8.0, true), -96.0));
    assert(close_to(kl_input_touchpad_units_to_viewport_pixels(units, 1200.0), 96.0));
    assert(close_to(kl_input_wheel_delta_to_viewport_pixels(10.0, 1200.0, 3.0), -180.0));
}

int main(void)
{
    test_scroll_tracker_matches_niri_ticks();
    test_scroll_swipe_gesture_tracks_axis_and_lifecycle();
    test_swipe_tracker_velocity_projection_and_history();
    test_three_finger_swipe_uses_niri_axis_threshold();
    test_view_scroll_gesture_scales_touchpad_units_to_viewport_width();
    test_input_delta_conversions();

    puts("input tests passed");
    return 0;
}
