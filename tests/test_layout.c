#include "core/controller.h"
#include "core/config.h"
#include "core/workspace.h"
#include "layout/strip.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static bool close_to(double a, double b)
{
    return fabs(a - b) < 0.0001;
}

static kl_strip_t sample_strip(kl_center_mode_t center_mode)
{
    kl_layout_options_t options = kl_layout_default_options();
    options.gap = 10.0;
    options.default_width_fraction = 0.5;
    options.center_mode = center_mode;
    options.always_center_single_column = false;

    kl_strip_t strip;
    kl_strip_init(&strip, options);
    assert(kl_strip_append(&strip, 101, 400.0));
    assert(kl_strip_append(&strip, 102, 400.0));
    assert(kl_strip_append(&strip, 103, 400.0));

    return strip;
}

static void test_default_width_reserves_shared_inner_gap(void)
{
    kl_strip_t strip;
    kl_strip_init(&strip, kl_layout_default_options());

    assert(close_to(kl_strip_default_column_width(&strip, 1200.0), 599.0));
}

static void test_padding_and_gap_are_subtracted_from_default_width(void)
{
    kl_layout_options_t options = kl_layout_default_options();
    options.padding_left = 20.0;
    options.padding_right = 30.0;
    options.padding_top = 5.0;
    options.padding_bottom = 15.0;

    kl_strip_t strip;
    kl_strip_init(&strip, options);

    assert(close_to(kl_strip_default_column_width(&strip, 1000.0), 474.0));
    assert(kl_strip_append(&strip, 101, 400.0));

    kl_rect_t frame = kl_strip_column_frame(
        &strip,
        0,
        (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 1000.0, .height = 600.0});

    assert(close_to(frame.x, 20.0));
    assert(close_to(frame.y, 5.0));
    assert(close_to(frame.width, 400.0));
    assert(close_to(frame.height, 580.0));
}

static void test_two_half_width_columns_fit_with_one_inner_gap(void)
{
    kl_layout_options_t options = kl_layout_default_options();
    options.default_width_fraction = 0.5;
    options.gap = 2.0;
    options.padding_left = 24.0;
    options.padding_right = 24.0;

    kl_workspace_t workspace;
    kl_workspace_init(&workspace, options);
    assert(kl_workspace_add_window(&workspace, 101, 1200.0));
    assert(kl_workspace_add_window(&workspace, 102, 1200.0));

    kl_rect_t frames[2];
    assert(kl_strip_arrange(
               &workspace.strip,
               (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 1200.0, .height = 800.0},
               frames,
               2) == 2);

    assert(close_to(workspace.strip.viewport_x, 0.0));
    assert(close_to(frames[0].x, 24.0));
    assert(close_to(frames[0].width, 575.0));
    assert(close_to(frames[1].x, 601.0));
    assert(close_to(frames[1].width, 575.0));
    assert(close_to(frames[1].x + frames[1].width, 1176.0));
}

static void test_column_snap_points_are_clamped_to_useful_strip_width(void)
{
    kl_layout_options_t options = kl_layout_default_options();
    options.default_width_fraction = 0.5;
    options.gap = 2.0;
    options.padding_left = 24.0;
    options.padding_right = 24.0;

    kl_workspace_t workspace;
    kl_workspace_init(&workspace, options);
    assert(kl_workspace_add_window(&workspace, 101, 1200.0));
    assert(kl_workspace_add_window(&workspace, 102, 1200.0));
    assert(kl_workspace_add_window(&workspace, 103, 1200.0));

    assert(close_to(kl_strip_max_viewport_x(&workspace.strip, 1200.0), 577.0));
    assert(close_to(kl_strip_snap_viewport_x_for_column(&workspace.strip, 0, 1200.0), 0.0));
    assert(close_to(kl_strip_snap_viewport_x_for_column(&workspace.strip, 1, 1200.0), 577.0));
    assert(close_to(kl_strip_snap_viewport_x_for_column(&workspace.strip, 2, 1200.0), 577.0));
    assert(close_to(kl_strip_min_scroll_viewport_x(&workspace.strip, 1200.0), -26.0));
    assert(close_to(kl_strip_max_scroll_viewport_x(&workspace.strip, 1200.0), 555.0));
    assert(close_to(kl_strip_clamp_viewport_x(&workspace.strip, 1200.0, -500.0), -26.0));
    assert(close_to(kl_strip_clamp_viewport_x(&workspace.strip, 1200.0, 900.0), 555.0));
}

static void test_columns_keep_stable_positions(void)
{
    kl_strip_t strip = sample_strip(KL_CENTER_NEVER);

    assert(close_to(kl_strip_column_x(&strip, 0), 0.0));
    assert(close_to(kl_strip_column_x(&strip, 1), 410.0));
    assert(close_to(kl_strip_column_x(&strip, 2), 820.0));

    assert(kl_strip_insert_after_active(&strip, 104, 300.0));
    assert(close_to(strip.columns[0].width, 400.0));
    assert(close_to(strip.columns[1].width, 300.0));
    assert(close_to(strip.columns[2].width, 400.0));
    assert(close_to(kl_strip_column_x(&strip, 2), 720.0));
}

static void test_column_resize_moves_following_columns(void)
{
    kl_strip_t strip = sample_strip(KL_CENTER_NEVER);

    assert(kl_strip_set_column_width(&strip, 1, 520.0, 1000.0));
    assert(close_to(strip.columns[1].width, 520.0));
    assert(close_to(kl_strip_column_x(&strip, 0), 0.0));
    assert(close_to(kl_strip_column_x(&strip, 1), 410.0));
    assert(close_to(kl_strip_column_x(&strip, 2), 940.0));
}

static void test_column_maximize_width_toggles_back_to_previous_width(void)
{
    kl_layout_options_t options = kl_layout_default_options();
    options.padding_left = 24.0;
    options.padding_right = 24.0;

    kl_strip_t strip;
    kl_strip_init(&strip, options);
    assert(kl_strip_append(&strip, 101, 480.0));
    assert(kl_strip_append(&strip, 102, 480.0));

    assert(kl_strip_toggle_column_maximized_width(&strip, 0, 1200.0));
    assert(close_to(strip.columns[0].width, 1152.0));
    assert(strip.columns[0].has_restore_width);
    assert(close_to(kl_strip_column_x(&strip, 1), 1154.0));

    assert(kl_strip_toggle_column_maximized_width(&strip, 0, 1200.0));
    assert(close_to(strip.columns[0].width, 480.0));
    assert(!strip.columns[0].has_restore_width);
    assert(close_to(kl_strip_column_x(&strip, 1), 482.0));
}

static void test_focus_scrolls_minimally_to_edge(void)
{
    kl_strip_t strip = sample_strip(KL_CENTER_NEVER);

    assert(kl_strip_focus(&strip, 2, 800.0));
    assert(close_to(strip.viewport_x, 420.0));

    kl_rect_t viewport = {.x = 0.0, .y = 0.0, .width = 800.0, .height = 600.0};
    kl_rect_t frames[3];
    assert(kl_strip_arrange(&strip, viewport, frames, 3) == 3);
    assert(close_to(frames[2].x, 400.0));
}

static void test_focus_by_window_id_autoscrolls_to_whole_window(void)
{
    kl_strip_t strip = sample_strip(KL_CENTER_NEVER);

    assert(kl_strip_focus_window(&strip, 103, 800.0));
    assert(close_to(strip.viewport_x, 420.0));
    assert(strip.active == 2);
}

static void test_focus_can_center_column(void)
{
    kl_strip_t strip = sample_strip(KL_CENTER_ALWAYS);

    assert(kl_strip_focus(&strip, 1, 1000.0));
    assert(close_to(strip.viewport_x, 110.0));
}

static void test_single_column_centering(void)
{
    kl_layout_options_t options = kl_layout_default_options();
    options.gap = 10.0;
    options.center_mode = KL_CENTER_NEVER;
    options.always_center_single_column = true;

    kl_strip_t strip;
    kl_strip_init(&strip, options);
    assert(kl_strip_append(&strip, 101, 400.0));

    assert(kl_strip_focus(&strip, 0, 1000.0));
    assert(close_to(strip.viewport_x, -300.0));
}

static void test_on_overflow_centers_when_previous_and_next_do_not_fit(void)
{
    kl_strip_t strip = sample_strip(KL_CENTER_ON_OVERFLOW);

    assert(kl_strip_focus(&strip, 1, 700.0));
    assert(close_to(strip.viewport_x, 260.0));
}

static void test_move_active_reorders_columns(void)
{
    kl_strip_t strip = sample_strip(KL_CENTER_NEVER);

    assert(kl_strip_focus(&strip, 1, 800.0));
    assert(kl_strip_move_active(&strip, 2, 800.0));
    assert(strip.columns[0].window_id == 101);
    assert(strip.columns[1].window_id == 103);
    assert(strip.columns[2].window_id == 102);
    assert(strip.active == 2);
}

static void test_move_active_keeps_reordered_columns_adjacent(void)
{
    kl_layout_options_t options = kl_layout_default_options();
    options.default_width_fraction = 0.5;
    options.gap = 2.0;
    options.padding_left = 0.0;
    options.padding_right = 0.0;

    kl_strip_t strip;
    kl_strip_init(&strip, options);
    double width = kl_strip_default_column_width(&strip, 1440.0);
    assert(kl_strip_append(&strip, 101, width));
    assert(kl_strip_append(&strip, 102, width));
    assert(kl_strip_focus(&strip, 0, 1440.0));

    assert(kl_strip_move_active(&strip, 1, 1440.0));

    kl_arranged_window_t arranged[2];
    assert(kl_strip_arrange_windows(
               &strip,
               (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 1440.0, .height = 900.0},
               arranged,
               2) == 2);

    assert(arranged[0].window_id == 102);
    assert(arranged[1].window_id == 101);
    assert(close_to(arranged[1].frame.x - (arranged[0].frame.x + arranged[0].frame.width), 2.0));
}

static void test_column_drop_target_uses_column_midpoints(void)
{
    kl_strip_t strip = sample_strip(KL_CENTER_NEVER);

    assert(kl_strip_target_index_for_x(&strip, -100.0) == 0);
    assert(kl_strip_target_index_for_x(&strip, 199.0) == 0);
    assert(kl_strip_target_index_for_x(&strip, 200.0) == 1);
    assert(kl_strip_target_index_for_x(&strip, 609.0) == 1);
    assert(kl_strip_target_index_for_x(&strip, 610.0) == 2);
    assert(kl_strip_target_index_for_x(&strip, 2000.0) == 2);
}

static void test_stacked_column_arranges_windows_vertically(void)
{
    kl_layout_options_t options = kl_layout_default_options();
    options.gap = 10.0;

    kl_strip_t strip;
    kl_strip_init(&strip, options);
    assert(kl_strip_append(&strip, 101, 400.0));
    assert(kl_strip_insert_into_column(&strip, 0, 1, 102, 800.0));

    assert(strip.count == 1);
    assert(strip.columns[0].count == 2);
    assert(strip.columns[0].active == 1);
    assert(kl_strip_active_window(&strip) == 102);

    kl_arranged_window_t arranged[2];
    assert(kl_strip_arrange_windows(
               &strip,
               (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 800.0, .height = 600.0},
               arranged,
               2) == 2);

    assert(arranged[0].window_id == 101);
    assert(close_to(arranged[0].frame.y, 0.0));
    assert(close_to(arranged[0].frame.height, 295.0));
    assert(arranged[1].window_id == 102);
    assert(close_to(arranged[1].frame.y, 305.0));
    assert(close_to(arranged[1].frame.height, 295.0));

    assert(kl_strip_target_row_for_y(
               &strip,
               0,
               (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 800.0, .height = 600.0},
               100.0) == 0);
    assert(kl_strip_target_row_for_y(
               &strip,
               0,
               (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 800.0, .height = 600.0},
               450.0) == 1);
    assert(kl_strip_target_row_for_y(
               &strip,
               0,
               (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 800.0, .height = 600.0},
               590.0) == 2);
}

static void test_window_can_move_into_existing_column(void)
{
    kl_strip_t strip = sample_strip(KL_CENTER_NEVER);

    assert(kl_strip_move_window_to_column(&strip, 102, 0, 1, 800.0));
    assert(strip.count == 2);
    assert(strip.active == 0);
    assert(strip.columns[0].count == 2);
    assert(strip.columns[0].windows[0] == 101);
    assert(strip.columns[0].windows[1] == 102);
    assert(strip.columns[0].active == 1);
    assert(strip.columns[0].window_id == 102);
    assert(strip.columns[1].count == 1);
    assert(strip.columns[1].window_id == 103);
    assert(kl_strip_active_window(&strip) == 102);

    assert(kl_strip_focus_window(&strip, 101, 800.0));
    assert(strip.active == 0);
    assert(strip.columns[0].active == 0);
    assert(kl_strip_active_window(&strip) == 101);

    kl_column_t removed;
    assert(kl_strip_remove_window(&strip, 101, 800.0, &removed));
    assert(removed.window_id == 101);
    assert(removed.width == 400.0);
    assert(strip.count == 2);
    assert(strip.columns[0].count == 1);
    assert(strip.columns[0].window_id == 102);
}

static void test_window_can_extract_from_stacked_column(void)
{
    kl_strip_t strip = sample_strip(KL_CENTER_NEVER);

    assert(kl_strip_move_window_to_column(&strip, 102, 0, 1, 800.0));
    assert(strip.count == 2);
    assert(strip.columns[0].count == 2);

    assert(kl_strip_extract_window_to_column(&strip, 102, 1, 800.0));
    assert(strip.count == 3);
    assert(strip.active == 1);
    assert(strip.columns[0].count == 1);
    assert(strip.columns[0].window_id == 101);
    assert(strip.columns[1].count == 1);
    assert(strip.columns[1].window_id == 102);
    assert(strip.columns[1].width == 400.0);
    assert(strip.columns[2].window_id == 103);
    assert(kl_strip_active_window(&strip) == 102);
}

static void test_single_window_column_does_not_extract(void)
{
    kl_strip_t strip = sample_strip(KL_CENTER_NEVER);

    assert(!kl_strip_extract_window_to_column(&strip, 102, 0, 800.0));
    assert(strip.count == 3);
    assert(strip.columns[1].window_id == 102);
}

static void test_manual_scroll_moves_canvas_without_changing_focus(void)
{
    kl_strip_t strip = sample_strip(KL_CENTER_NEVER);

    kl_strip_scroll_by(&strip, 120.0);
    assert(close_to(strip.viewport_x, 120.0));
    assert(strip.active == 0);

    kl_rect_t frame = kl_strip_column_frame(
        &strip,
        0,
        (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 800.0, .height = 600.0});

    assert(close_to(frame.x, -120.0));
}

static void test_workspace_floating_toggle_removes_and_restores_tiled_windows(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_add_window(&workspace, 102, 1000.0));
    assert(workspace.strip.count == 2);

    assert(kl_workspace_toggle_floating(&workspace, 101, 1000.0));
    assert(workspace.strip.count == 1);
    assert(kl_strip_find_window(&workspace.strip, 101) == workspace.strip.count);
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_FLOATING);
    assert(kl_workspace_find_window(&workspace, 101)->mode_origin == KL_WINDOW_MODE_USER);

    assert(!kl_workspace_focus_window(&workspace, 101, 1000.0));

    assert(kl_workspace_toggle_floating(&workspace, 101, 1000.0));
    assert(workspace.strip.count == 2);
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_TILED);
    assert(kl_workspace_find_window(&workspace, 101)->mode_origin == KL_WINDOW_MODE_USER);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 101);
}

static void test_workspace_window_width_updates_restore_width(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_add_window(&workspace, 102, 1000.0));
    assert(kl_workspace_set_window_width(&workspace, 101, 640.0, 1000.0));
    assert(close_to(workspace.strip.columns[0].width, 640.0));
    assert(close_to(kl_workspace_find_window(&workspace, 101)->tiled_width, 640.0));
    assert(close_to(kl_strip_column_x(&workspace.strip, 1), 642.0));

    assert(kl_workspace_toggle_floating(&workspace, 101, 1000.0));
    assert(kl_workspace_toggle_floating(&workspace, 101, 1000.0));
    assert(close_to(workspace.strip.columns[workspace.strip.active].width, 640.0));
}

static void test_workspace_reconcile_width_clears_false_maximize_state(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_add_window(&workspace, 102, 1000.0));
    assert(kl_workspace_toggle_window_maximized_width(&workspace, 101, 1000.0));
    assert(workspace.strip.columns[0].has_restore_width);
    assert(close_to(workspace.strip.columns[0].width, 1000.0));

    assert(kl_workspace_reconcile_window_width(&workspace, 101, 499.0, false, 1000.0));
    assert(close_to(workspace.strip.columns[0].width, 499.0));
    assert(!workspace.strip.columns[0].has_restore_width);
    assert(close_to(kl_workspace_find_window(&workspace, 101)->tiled_width, 499.0));
    assert(workspace.strip.active == 0);
}

static void test_workspace_reconcile_width_can_preserve_maximize_restore_state(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_add_window(&workspace, 102, 1000.0));
    assert(kl_workspace_toggle_window_maximized_width(&workspace, 101, 1000.0));
    assert(workspace.strip.columns[0].has_restore_width);
    assert(close_to(workspace.strip.columns[0].restore_width, 499.0));

    assert(kl_workspace_reconcile_window_width(&workspace, 101, 940.0, true, 1000.0));
    assert(close_to(workspace.strip.columns[0].width, 940.0));
    assert(workspace.strip.columns[0].has_restore_width);
    assert(close_to(workspace.strip.columns[0].restore_width, 499.0));

    assert(kl_workspace_toggle_window_maximized_width(&workspace, 101, 1000.0));
    assert(close_to(workspace.strip.columns[0].width, 499.0));
    assert(!workspace.strip.columns[0].has_restore_width);
}

static void test_existing_floating_window_is_not_retiled_by_rescan(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_toggle_floating(&workspace, 101, 1000.0));
    assert(workspace.strip.count == 0);

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(workspace.strip.count == 0);
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_FLOATING);
}

static void test_workspace_can_add_window_as_floating(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window_with_mode(&workspace, 101, KL_WINDOW_FLOATING, 1000.0));
    assert(workspace.window_count == 1);
    assert(workspace.strip.count == 0);
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_FLOATING);
    assert(kl_workspace_find_window(&workspace, 101)->mode_origin == KL_WINDOW_MODE_POLICY);

    assert(kl_workspace_set_mode(&workspace, 101, KL_WINDOW_TILED, 1000.0));
    assert(workspace.strip.count == 1);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 101);
    assert(kl_workspace_find_window(&workspace, 101)->mode_origin == KL_WINDOW_MODE_USER);
}

static void test_policy_mode_cannot_override_user_mode(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_TILED);
    assert(kl_workspace_find_window(&workspace, 101)->mode_origin == KL_WINDOW_MODE_POLICY);

    assert(kl_workspace_toggle_floating(&workspace, 101, 1000.0));
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_FLOATING);
    assert(kl_workspace_find_window(&workspace, 101)->mode_origin == KL_WINDOW_MODE_USER);
    assert(workspace.strip.count == 0);

    assert(kl_workspace_set_mode_with_origin(
        &workspace,
        101,
        KL_WINDOW_TILED,
        KL_WINDOW_MODE_POLICY,
        1000.0));
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_FLOATING);
    assert(kl_workspace_find_window(&workspace, 101)->mode_origin == KL_WINDOW_MODE_USER);
    assert(workspace.strip.count == 0);
}

static void test_policy_mode_can_update_policy_owned_window(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window_with_mode(&workspace, 101, KL_WINDOW_FLOATING, 1000.0));
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_FLOATING);
    assert(kl_workspace_find_window(&workspace, 101)->mode_origin == KL_WINDOW_MODE_POLICY);
    assert(workspace.strip.count == 0);

    assert(kl_workspace_set_mode_with_origin(
        &workspace,
        101,
        KL_WINDOW_TILED,
        KL_WINDOW_MODE_POLICY,
        1000.0));
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_TILED);
    assert(kl_workspace_find_window(&workspace, 101)->mode_origin == KL_WINDOW_MODE_POLICY);
    assert(workspace.strip.count == 1);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 101);
}

static void test_fullscreen_does_not_change_mode_origin(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_toggle_floating(&workspace, 101, 1000.0));
    assert(kl_workspace_find_window(&workspace, 101)->mode_origin == KL_WINDOW_MODE_USER);

    assert(kl_workspace_set_fullscreen(&workspace, 101, true, 1000.0));
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_FLOATING);
    assert(kl_workspace_find_window(&workspace, 101)->mode_origin == KL_WINDOW_MODE_USER);

    assert(kl_workspace_set_fullscreen(&workspace, 101, false, 1000.0));
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_FLOATING);
    assert(kl_workspace_find_window(&workspace, 101)->mode_origin == KL_WINDOW_MODE_USER);
}

static void test_workspace_add_window_at_explicit_column_index(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_add_window(&workspace, 102, 1000.0));
    assert(kl_workspace_add_window(&workspace, 103, 1000.0));

    assert(kl_workspace_add_window_with_mode_and_target(
        &workspace,
        201,
        KL_WINDOW_TILED,
        kl_add_window_target_new_column_at(0),
        1000.0));
    assert(workspace.strip.columns[0].window_id == 201);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 201);

    assert(kl_workspace_add_window_with_mode_and_target(
        &workspace,
        202,
        KL_WINDOW_TILED,
        kl_add_window_target_new_column_at(2),
        1000.0));
    assert(workspace.strip.columns[2].window_id == 202);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 202);

    assert(kl_workspace_add_window_with_mode_and_target(
        &workspace,
        203,
        KL_WINDOW_TILED,
        kl_add_window_target_new_column_at(100),
        1000.0));
    assert(workspace.strip.columns[workspace.strip.count - 1].window_id == 203);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 203);
}

static void test_workspace_add_window_next_to_existing_window(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_add_window(&workspace, 102, 1000.0));
    assert(kl_workspace_add_window(&workspace, 103, 1000.0));
    assert(kl_workspace_focus_window(&workspace, 103, 1000.0));

    assert(kl_workspace_add_window_with_mode_and_target(
        &workspace,
        201,
        KL_WINDOW_TILED,
        kl_add_window_target_next_to(101),
        1000.0));

    assert(workspace.strip.columns[0].window_id == 101);
    assert(workspace.strip.columns[1].window_id == 201);
    assert(workspace.strip.columns[2].window_id == 102);
    assert(workspace.strip.columns[3].window_id == 103);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 201);
}

static void test_workspace_add_window_next_to_missing_window_falls_back_to_auto(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_add_window(&workspace, 102, 1000.0));
    assert(kl_workspace_focus_window(&workspace, 101, 1000.0));

    assert(kl_workspace_add_window_with_mode_and_target(
        &workspace,
        201,
        KL_WINDOW_TILED,
        kl_add_window_target_next_to(999),
        1000.0));

    assert(workspace.strip.columns[0].window_id == 101);
    assert(workspace.strip.columns[1].window_id == 201);
    assert(workspace.strip.columns[2].window_id == 102);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 201);
}

static void test_workspace_remove_forgets_tiled_window(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_add_window(&workspace, 102, 1000.0));
    assert(kl_workspace_add_window(&workspace, 103, 1000.0));
    assert(workspace.window_count == 3);
    assert(workspace.strip.count == 3);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 103);

    assert(kl_workspace_remove_window(&workspace, 102, 1000.0));
    assert(workspace.window_count == 2);
    assert(workspace.strip.count == 2);
    assert(!kl_workspace_find_window(&workspace, 102));
    assert(kl_strip_find_window(&workspace.strip, 102) == workspace.strip.count);
    assert(workspace.strip.columns[0].window_id == 101);
    assert(workspace.strip.columns[1].window_id == 103);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 103);
}

static void test_workspace_remove_forgets_floating_window(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_toggle_floating(&workspace, 101, 1000.0));
    assert(workspace.window_count == 1);
    assert(workspace.strip.count == 0);

    assert(kl_workspace_remove_window(&workspace, 101, 1000.0));
    assert(workspace.window_count == 0);
    assert(workspace.strip.count == 0);
    assert(!kl_workspace_find_window(&workspace, 101));
}

static void test_workspace_minimize_removes_and_deminiaturize_restores_tiled_window(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_add_window(&workspace, 102, 1000.0));
    assert(workspace.strip.count == 2);

    assert(kl_workspace_set_minimized(&workspace, 102, true, 1000.0));
    assert(workspace.window_count == 2);
    assert(workspace.strip.count == 1);
    assert(kl_workspace_find_window(&workspace, 102)->minimized);
    assert(kl_strip_find_window(&workspace.strip, 102) == workspace.strip.count);
    assert(!kl_workspace_focus_window(&workspace, 102, 1000.0));

    assert(kl_workspace_set_minimized(&workspace, 102, false, 1000.0));
    assert(workspace.strip.count == 2);
    assert(!kl_workspace_find_window(&workspace, 102)->minimized);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 102);
}

static void test_workspace_minimized_floating_window_stays_floating_on_restore(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_toggle_floating(&workspace, 101, 1000.0));
    assert(workspace.strip.count == 0);

    assert(kl_workspace_set_minimized(&workspace, 101, true, 1000.0));
    assert(workspace.window_count == 1);
    assert(workspace.strip.count == 0);
    assert(kl_workspace_find_window(&workspace, 101)->minimized);
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_FLOATING);

    assert(kl_workspace_set_minimized(&workspace, 101, false, 1000.0));
    assert(workspace.window_count == 1);
    assert(workspace.strip.count == 0);
    assert(!kl_workspace_find_window(&workspace, 101)->minimized);
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_FLOATING);
}

static void test_workspace_minimized_window_can_change_mode_without_reappearing(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_add_window(&workspace, 102, 1000.0));
    assert(kl_workspace_set_minimized(&workspace, 102, true, 1000.0));
    assert(workspace.strip.count == 1);

    assert(kl_workspace_set_mode(&workspace, 102, KL_WINDOW_FLOATING, 1000.0));
    assert(workspace.strip.count == 1);
    assert(kl_workspace_find_window(&workspace, 102)->mode == KL_WINDOW_FLOATING);
    assert(kl_workspace_find_window(&workspace, 102)->minimized);

    assert(kl_workspace_set_mode(&workspace, 102, KL_WINDOW_TILED, 1000.0));
    assert(workspace.strip.count == 1);
    assert(kl_workspace_find_window(&workspace, 102)->mode == KL_WINDOW_TILED);
    assert(kl_workspace_find_window(&workspace, 102)->minimized);

    assert(kl_workspace_set_minimized(&workspace, 102, false, 1000.0));
    assert(workspace.strip.count == 2);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 102);
}

static void test_workspace_fullscreen_removes_and_restores_tiled_window(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_add_window(&workspace, 102, 1000.0));
    assert(workspace.strip.count == 2);

    assert(kl_workspace_set_fullscreen(&workspace, 102, true, 1000.0));
    assert(workspace.window_count == 2);
    assert(workspace.strip.count == 1);
    assert(kl_workspace_find_window(&workspace, 102)->fullscreen);
    assert(kl_workspace_find_window(&workspace, 102)->mode == KL_WINDOW_TILED);
    assert(kl_strip_find_window(&workspace.strip, 102) == workspace.strip.count);
    assert(!kl_workspace_focus_window(&workspace, 102, 1000.0));

    assert(kl_workspace_set_fullscreen(&workspace, 102, false, 1000.0));
    assert(workspace.strip.count == 2);
    assert(!kl_workspace_find_window(&workspace, 102)->fullscreen);
    assert(kl_workspace_find_window(&workspace, 102)->mode == KL_WINDOW_TILED);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 102);
}

static void test_workspace_fullscreen_preserves_floating_mode_on_exit(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_toggle_floating(&workspace, 101, 1000.0));
    assert(workspace.strip.count == 0);

    assert(kl_workspace_set_fullscreen(&workspace, 101, true, 1000.0));
    assert(workspace.window_count == 1);
    assert(workspace.strip.count == 0);
    assert(kl_workspace_find_window(&workspace, 101)->fullscreen);
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_FLOATING);

    assert(kl_workspace_set_fullscreen(&workspace, 101, false, 1000.0));
    assert(workspace.window_count == 1);
    assert(workspace.strip.count == 0);
    assert(!kl_workspace_find_window(&workspace, 101)->fullscreen);
    assert(kl_workspace_find_window(&workspace, 101)->mode == KL_WINDOW_FLOATING);
}

static void test_workspace_fullscreen_window_can_change_mode_without_reappearing(void)
{
    kl_workspace_t workspace;
    kl_workspace_init(&workspace, kl_layout_default_options());

    assert(kl_workspace_add_window(&workspace, 101, 1000.0));
    assert(kl_workspace_add_window(&workspace, 102, 1000.0));
    assert(kl_workspace_set_fullscreen(&workspace, 102, true, 1000.0));
    assert(workspace.strip.count == 1);

    assert(kl_workspace_set_mode(&workspace, 102, KL_WINDOW_FLOATING, 1000.0));
    assert(workspace.strip.count == 1);
    assert(kl_workspace_find_window(&workspace, 102)->mode == KL_WINDOW_FLOATING);
    assert(kl_workspace_find_window(&workspace, 102)->fullscreen);

    assert(kl_workspace_set_mode(&workspace, 102, KL_WINDOW_TILED, 1000.0));
    assert(workspace.strip.count == 1);
    assert(kl_workspace_find_window(&workspace, 102)->mode == KL_WINDOW_TILED);
    assert(kl_workspace_find_window(&workspace, 102)->fullscreen);

    assert(kl_workspace_set_fullscreen(&workspace, 102, false, 1000.0));
    assert(workspace.strip.count == 2);
    assert(workspace.strip.columns[workspace.strip.active].window_id == 102);
}

static void test_controller_scroll_uses_half_viewport_default(void)
{
    kl_controller_t controller;
    kl_controller_init(
        &controller,
        kl_layout_default_options(),
        (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 1200.0, .height = 800.0});

    assert(kl_controller_notice_window(&controller, 101));
    assert(kl_controller_notice_window(&controller, 102));
    assert(kl_controller_notice_window(&controller, 103));

    kl_controller_scroll(&controller, KL_SCROLL_RIGHT);
    assert(close_to(kl_controller_workspace(&controller)->strip.viewport_x, 603.0));

    kl_controller_scroll(&controller, KL_SCROLL_LEFT);
    kl_controller_scroll(&controller, KL_SCROLL_LEFT);
    assert(close_to(kl_controller_workspace(&controller)->strip.viewport_x, -2.0));
}

static void test_controller_scroll_delta_is_continuous_without_focus_change(void)
{
    kl_controller_t controller;
    kl_controller_init(
        &controller,
        kl_layout_default_options(),
        (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 1200.0, .height = 800.0});

    assert(kl_controller_notice_window(&controller, 101));
    assert(kl_controller_notice_window(&controller, 102));
    assert(kl_controller_notice_window(&controller, 103));
    assert(kl_controller_focus_window(&controller, 101));

    kl_controller_scroll_delta(&controller, 37.0);
    assert(close_to(kl_controller_workspace(&controller)->strip.viewport_x, 37.0));
    assert(kl_controller_workspace(&controller)->strip.active == 0);

    kl_controller_scroll_delta(&controller, 10000.0);
    assert(close_to(
        kl_controller_workspace(&controller)->strip.viewport_x,
        kl_strip_max_scroll_viewport_x(&kl_controller_workspace(&controller)->strip, controller.viewport.width)));
    assert(kl_controller_workspace(&controller)->strip.active == 0);
}

static void test_controller_focuses_adjacent_columns(void)
{
    kl_controller_t controller;
    kl_controller_init(
        &controller,
        kl_layout_default_options(),
        (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 1200.0, .height = 800.0});

    assert(kl_controller_notice_window(&controller, 101));
    assert(kl_controller_notice_window(&controller, 102));

    assert(kl_controller_workspace(&controller)->strip.active == 1);
    assert(kl_controller_focus_previous(&controller));
    assert(kl_controller_workspace(&controller)->strip.active == 0);
    assert(!kl_controller_focus_previous(&controller));
    assert(kl_controller_focus_next(&controller));
    assert(kl_controller_workspace(&controller)->strip.active == 1);
}

static void test_controller_moves_active_column_within_workspace(void)
{
    kl_controller_t controller;
    kl_controller_init(
        &controller,
        kl_layout_default_options(),
        (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 1200.0, .height = 800.0});

    assert(kl_controller_notice_window(&controller, 101));
    assert(kl_controller_notice_window(&controller, 102));
    assert(kl_controller_notice_window(&controller, 103));
    assert(kl_controller_focus_window(&controller, 102));

    assert(kl_controller_move_active_column(&controller, -1));
    assert(kl_controller_workspace(&controller)->strip.active == 0);
    assert(kl_controller_workspace(&controller)->strip.columns[0].window_id == 102);
    assert(kl_controller_workspace(&controller)->strip.columns[1].window_id == 101);
    assert(kl_controller_workspace(&controller)->strip.columns[2].window_id == 103);

    assert(!kl_controller_move_active_column(&controller, -1));

    assert(kl_controller_move_active_column(&controller, 1));
    assert(kl_controller_workspace(&controller)->strip.active == 1);
    assert(kl_controller_workspace(&controller)->strip.columns[0].window_id == 101);
    assert(kl_controller_workspace(&controller)->strip.columns[1].window_id == 102);
    assert(kl_controller_workspace(&controller)->strip.columns[2].window_id == 103);
}

static void test_controller_switches_between_isolated_workspaces(void)
{
    kl_controller_t controller;
    kl_controller_init(
        &controller,
        kl_layout_default_options(),
        (kl_rect_t) {.x = 0.0, .y = 0.0, .width = 1200.0, .height = 800.0});

    assert(controller.workspaces.count == 1);
    assert(controller.workspaces.active == 0);
    assert(!kl_controller_switch_workspace(&controller, -1));
    assert(controller.workspaces.active == 0);

    assert(kl_controller_notice_window(&controller, 101));
    assert(kl_controller_notice_window(&controller, 102));
    assert(kl_controller_workspace(&controller)->strip.count == 2);
    assert(kl_workspace_find_window(kl_controller_workspace(&controller), 101));

    assert(kl_controller_switch_workspace(&controller, 1));
    assert(controller.workspaces.count == 2);
    assert(controller.workspaces.active == 1);
    assert(kl_controller_workspace(&controller)->strip.count == 0);
    assert(!kl_workspace_find_window(kl_controller_workspace(&controller), 101));

    assert(kl_controller_notice_window(&controller, 201));
    assert(kl_controller_workspace(&controller)->strip.count == 1);
    assert(kl_workspace_find_window(kl_controller_workspace(&controller), 201));

    assert(kl_controller_switch_workspace(&controller, -1));
    assert(controller.workspaces.active == 0);
    assert(kl_controller_workspace(&controller)->strip.count == 2);
    assert(kl_workspace_find_window(kl_controller_workspace(&controller), 101));
    assert(!kl_workspace_find_window(kl_controller_workspace(&controller), 201));

    assert(kl_controller_switch_workspace(&controller, 1));
    assert(controller.workspaces.active == 1);
    assert(kl_controller_workspace(&controller)->strip.count == 1);
    assert(!kl_workspace_find_window(kl_controller_workspace(&controller), 101));
    assert(kl_workspace_find_window(kl_controller_workspace(&controller), 201));
}

static void test_config_file_overrides_layout_defaults(void)
{
    char path[] = "/tmp/klotski-config-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);

    FILE *file = fdopen(fd, "w");
    assert(file);
    fputs("default-column-width-proportion = 0.333\n", file);
    fputs("gaps = 8\n", file);
    fputs("padding = 12\n", file);
    fputs("padding-left = 2\n", file);
    fputs("keyboard-scroll-fraction = 0.25\n", file);
    fputs("scroll-wheel-sensitivity = 2.5\n", file);
    fputs("gesture-scroll-sensitivity = 3.0\n", file);
    fputs("gesture-scroll-inverted = false\n", file);
    fputs("scroll-settle-delay = 0.2\n", file);
    fputs("horizontal-view-animation-speed = 12.0\n", file);
    fputs("center-focused-column = always\n", file);
    fputs("always-center-single-column = true\n", file);
    fputs("focus-follows-mouse = false\n", file);
    fclose(file);

    kl_config_t config = kl_config_default();
    assert(config.gesture_scroll_inverted);

    char error[256];
    assert(kl_config_load_file(path, &config, error, sizeof(error)));
    unlink(path);

    assert(close_to(config.layout.default_width_fraction, 0.333));
    assert(close_to(config.layout.gap, 8.0));
    assert(close_to(config.layout.padding_left, 2.0));
    assert(close_to(config.layout.padding_right, 12.0));
    assert(close_to(config.keyboard_scroll_fraction, 0.25));
    assert(close_to(config.scroll_wheel_sensitivity, 2.5));
    assert(close_to(config.gesture_scroll_sensitivity, 3.0));
    assert(!config.gesture_scroll_inverted);
    assert(close_to(config.scroll_settle_delay, 0.2));
    assert(close_to(config.horizontal_view_animation_speed, 12.0));
    assert(config.layout.center_mode == KL_CENTER_ALWAYS);
    assert(config.layout.always_center_single_column);
    assert(!config.focus_follows_mouse);
}

int main(void)
{
    test_default_width_reserves_shared_inner_gap();
    test_padding_and_gap_are_subtracted_from_default_width();
    test_two_half_width_columns_fit_with_one_inner_gap();
    test_column_snap_points_are_clamped_to_useful_strip_width();
    test_columns_keep_stable_positions();
    test_column_resize_moves_following_columns();
    test_column_maximize_width_toggles_back_to_previous_width();
    test_focus_scrolls_minimally_to_edge();
    test_focus_by_window_id_autoscrolls_to_whole_window();
    test_focus_can_center_column();
    test_single_column_centering();
    test_on_overflow_centers_when_previous_and_next_do_not_fit();
    test_move_active_reorders_columns();
    test_move_active_keeps_reordered_columns_adjacent();
    test_column_drop_target_uses_column_midpoints();
    test_stacked_column_arranges_windows_vertically();
    test_window_can_move_into_existing_column();
    test_window_can_extract_from_stacked_column();
    test_single_window_column_does_not_extract();
    test_manual_scroll_moves_canvas_without_changing_focus();
    test_workspace_floating_toggle_removes_and_restores_tiled_windows();
    test_workspace_window_width_updates_restore_width();
    test_workspace_reconcile_width_clears_false_maximize_state();
    test_workspace_reconcile_width_can_preserve_maximize_restore_state();
    test_existing_floating_window_is_not_retiled_by_rescan();
    test_workspace_can_add_window_as_floating();
    test_policy_mode_cannot_override_user_mode();
    test_policy_mode_can_update_policy_owned_window();
    test_fullscreen_does_not_change_mode_origin();
    test_workspace_add_window_at_explicit_column_index();
    test_workspace_add_window_next_to_existing_window();
    test_workspace_add_window_next_to_missing_window_falls_back_to_auto();
    test_workspace_remove_forgets_tiled_window();
    test_workspace_remove_forgets_floating_window();
    test_workspace_minimize_removes_and_deminiaturize_restores_tiled_window();
    test_workspace_minimized_floating_window_stays_floating_on_restore();
    test_workspace_minimized_window_can_change_mode_without_reappearing();
    test_workspace_fullscreen_removes_and_restores_tiled_window();
    test_workspace_fullscreen_preserves_floating_mode_on_exit();
    test_workspace_fullscreen_window_can_change_mode_without_reappearing();
    test_controller_scroll_uses_half_viewport_default();
    test_controller_scroll_delta_is_continuous_without_focus_change();
    test_controller_focuses_adjacent_columns();
    test_controller_moves_active_column_within_workspace();
    test_controller_switches_between_isolated_workspaces();
    test_config_file_overrides_layout_defaults();

    puts("layout tests passed");
    return 0;
}
