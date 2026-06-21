#include "core/interaction.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>

static bool close_to(double a, double b)
{
    return fabs(a - b) < 0.0001;
}

static void test_rubber_band_matches_niri_shape(void)
{
    kl_rubber_band_t rubber = {.stiffness = 0.5, .limit = 0.05};

    assert(close_to(kl_rubber_band_clamp(rubber, 0.0, 1.0, 0.5), 0.5));
    assert(kl_rubber_band_clamp(rubber, 0.0, 1.0, -0.5) < 0.0);
    assert(kl_rubber_band_clamp(rubber, 0.0, 1.0, 1.5) > 1.0);
    assert(close_to(kl_rubber_band_clamp_derivative(rubber, 0.0, 1.0, 0.5), 1.0));
    assert(kl_rubber_band_clamp_derivative(rubber, 0.0, 1.0, 1.5) < 1.0);
}

static void test_pointer_move_recognizes_view_offset_for_horizontal_tiled_drag(void)
{
    kl_pointer_move_grab_t grab;
    kl_pointer_move_grab_begin(&grab, 100.0, 100.0, true, true);

    kl_pointer_move_result_t result =
        kl_pointer_move_grab_update(&grab, 104.0, 103.0, false, 0.0, 0.0);
    assert(result.phase == KL_POINTER_MOVE_RECOGNIZING_PHASE);
    assert(result.mode == KL_POINTER_MOVE_RECOGNIZING);

    result = kl_pointer_move_grab_update(&grab, 109.0, 103.0, false, 0.0, 0.0);
    assert(result.phase == KL_POINTER_MOVE_BEGIN);
    assert(result.mode == KL_POINTER_MOVE_VIEW_OFFSET);
    assert(close_to(result.delta_x, 9.0));
    assert(close_to(result.view_scroll_delta_x, -9.0));

    result = kl_pointer_move_grab_update(&grab, 112.0, 103.0, true, 2.0, 0.0);
    assert(result.phase == KL_POINTER_MOVE_UPDATE);
    assert(result.mode == KL_POINTER_MOVE_VIEW_OFFSET);
    assert(close_to(result.delta_x, 3.0));
    assert(close_to(result.relative_delta_x, 2.0));
    assert(close_to(result.view_scroll_delta_x, -2.0));
}

static void test_pointer_move_uses_window_move_for_vertical_or_floating_drag(void)
{
    kl_pointer_move_grab_t grab;
    kl_pointer_move_grab_begin(&grab, 0.0, 0.0, true, true);

    kl_pointer_move_result_t result =
        kl_pointer_move_grab_update(&grab, 2.0, 9.0, false, 0.0, 0.0);
    assert(result.phase == KL_POINTER_MOVE_BEGIN);
    assert(result.mode == KL_POINTER_MOVE_WINDOW);
    assert(close_to(result.delta_y, 9.0));

    kl_pointer_move_grab_begin(&grab, 0.0, 0.0, true, false);
    result = kl_pointer_move_grab_update(&grab, 9.0, 0.0, false, 0.0, 0.0);
    assert(result.phase == KL_POINTER_MOVE_BEGIN);
    assert(result.mode == KL_POINTER_MOVE_WINDOW);
}

static void test_pointer_move_force_move_applies_accumulated_delta(void)
{
    kl_pointer_move_grab_t grab;
    kl_pointer_move_grab_begin(&grab, 10.0, 20.0, true, true);

    kl_pointer_move_result_t result =
        kl_pointer_move_grab_update(&grab, 13.0, 21.0, false, 0.0, 0.0);
    assert(result.phase == KL_POINTER_MOVE_RECOGNIZING_PHASE);

    result = kl_pointer_move_grab_force_move(&grab);
    assert(result.phase == KL_POINTER_MOVE_BEGIN);
    assert(result.mode == KL_POINTER_MOVE_WINDOW);
    assert(close_to(result.delta_x, 3.0));
    assert(close_to(result.delta_y, 1.0));

    result = kl_pointer_move_grab_end(&grab);
    assert(result.phase == KL_POINTER_MOVE_END);
}

static void test_resize_uses_absolute_delta_from_start(void)
{
    kl_pointer_resize_grab_t grab;
    kl_pointer_resize_grab_begin(&grab, 100.0, 200.0);

    kl_pointer_resize_result_t result = kl_pointer_resize_grab_update(&grab, 130.0, 190.0);
    assert(result.active);
    assert(close_to(result.delta_x, 30.0));
    assert(close_to(result.delta_y, -10.0));

    result = kl_pointer_resize_grab_update(&grab, 110.0, 250.0);
    assert(close_to(result.delta_x, 10.0));
    assert(close_to(result.delta_y, 50.0));

    kl_pointer_resize_grab_end(&grab);
    result = kl_pointer_resize_grab_update(&grab, 110.0, 250.0);
    assert(!result.active);
}

static void test_overview_gesture_projects_to_open_or_closed(void)
{
    kl_overview_gesture_t gesture;
    kl_overview_gesture_begin(&gesture, 0.0);

    kl_overview_gesture_result_t result;
    assert(kl_overview_gesture_update(&gesture, 160.0, 0.000, &result));
    assert(result.changed);
    assert(result.value > 0.5);

    assert(kl_overview_gesture_end(&gesture, 0.050, &result));
    assert(result.open);
    assert(close_to(result.target_value, 1.0));

    kl_overview_gesture_begin(&gesture, 1.0);
    assert(kl_overview_gesture_update(&gesture, -160.0, 1.000, &result));
    assert(result.value < 0.5);
    assert(kl_overview_gesture_end(&gesture, 1.050, &result));
    assert(!result.open);
    assert(close_to(result.target_value, 0.0));
}

static void test_workspace_switch_gesture_clamps_to_adjacent_workspace_outside_overview(void)
{
    kl_workspace_switch_gesture_t gesture;
    kl_workspace_switch_gesture_begin(&gesture, 2, 2.0, 5, true, false);

    kl_workspace_switch_result_t result;
    assert(kl_workspace_switch_gesture_update(&gesture, 900.0, 0.000, true, 1.0, 800.0, &result));
    assert(result.current_index > 3.0);
    assert(result.current_index < 3.1);

    assert(kl_workspace_switch_gesture_end(&gesture, 0.050, true, true, 1.0, 800.0, &result));
    assert(result.active_index == 3);
}

static void test_workspace_switch_gesture_can_cross_multiple_workspaces_in_overview(void)
{
    kl_workspace_switch_gesture_t gesture;
    kl_workspace_switch_gesture_begin(&gesture, 1, 1.0, 5, true, true);

    kl_workspace_switch_result_t result;
    assert(kl_workspace_switch_gesture_update(&gesture, 900.0, 0.000, true, 1.0, 800.0, &result));
    assert(result.current_index > 3.9);

    assert(kl_workspace_switch_gesture_end(&gesture, 0.050, true, true, 1.0, 800.0, &result));
    assert(result.active_index == 4);
}

int main(void)
{
    test_rubber_band_matches_niri_shape();
    test_pointer_move_recognizes_view_offset_for_horizontal_tiled_drag();
    test_pointer_move_uses_window_move_for_vertical_or_floating_drag();
    test_pointer_move_force_move_applies_accumulated_delta();
    test_resize_uses_absolute_delta_from_start();
    test_overview_gesture_projects_to_open_or_closed();
    test_workspace_switch_gesture_clamps_to_adjacent_workspace_outside_overview();
    test_workspace_switch_gesture_can_cross_multiple_workspaces_in_overview();

    puts("interaction tests passed");
    return 0;
}
