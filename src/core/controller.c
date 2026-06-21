#include "core/controller.h"

void kl_controller_init(kl_controller_t *controller, kl_layout_options_t options, kl_rect_t viewport)
{
    kl_workspace_stack_init(&controller->workspaces, options);
    controller->viewport = viewport;
    controller->keyboard_scroll_fraction = 0.5;
}

kl_workspace_t *kl_controller_workspace(kl_controller_t *controller)
{
    return kl_workspace_stack_active(&controller->workspaces);
}

const kl_workspace_t *kl_controller_workspace_const(const kl_controller_t *controller)
{
    return kl_workspace_stack_active_const(&controller->workspaces);
}

void kl_controller_set_viewport(kl_controller_t *controller, kl_rect_t viewport)
{
    controller->viewport = viewport;

    kl_workspace_t *workspace = kl_controller_workspace(controller);
    if (workspace->strip.count != 0) {
        kl_strip_focus(
            &workspace->strip,
            workspace->strip.active,
            controller->viewport.width);
    }
}

bool kl_controller_notice_window(kl_controller_t *controller, kl_window_id_t window_id)
{
    return kl_controller_notice_window_with_mode(controller, window_id, KL_WINDOW_TILED);
}

bool kl_controller_notice_window_with_mode(
    kl_controller_t *controller,
    kl_window_id_t window_id,
    kl_window_mode_t mode)
{
    return kl_controller_notice_window_with_mode_and_target(
        controller,
        window_id,
        mode,
        kl_add_window_target_auto());
}

bool kl_controller_notice_window_with_mode_and_target(
    kl_controller_t *controller,
    kl_window_id_t window_id,
    kl_window_mode_t mode,
    kl_add_window_target_t target)
{
    return kl_workspace_add_window_with_mode_and_target(
        kl_controller_workspace(controller),
        window_id,
        mode,
        target,
        controller->viewport.width);
}

bool kl_controller_forget_window(kl_controller_t *controller, kl_window_id_t window_id)
{
    return kl_workspace_remove_window(kl_controller_workspace(controller), window_id, controller->viewport.width);
}

bool kl_controller_focus_window(kl_controller_t *controller, kl_window_id_t window_id)
{
    return kl_workspace_focus_window(kl_controller_workspace(controller), window_id, controller->viewport.width);
}

bool kl_controller_focus_next(kl_controller_t *controller)
{
    return kl_strip_focus_next(&kl_controller_workspace(controller)->strip, controller->viewport.width);
}

bool kl_controller_focus_previous(kl_controller_t *controller)
{
    return kl_strip_focus_previous(&kl_controller_workspace(controller)->strip, controller->viewport.width);
}

bool kl_controller_focus_window_in_column(kl_controller_t *controller, int direction)
{
    return kl_strip_focus_active_column_window(
        &kl_controller_workspace(controller)->strip,
        direction,
        controller->viewport.width);
}

bool kl_controller_move_active_column(kl_controller_t *controller, int direction)
{
    kl_strip_t *strip = &kl_controller_workspace(controller)->strip;
    if (strip->count == 0 || direction == 0) {
        return false;
    }

    if (direction < 0) {
        if (strip->active == 0) {
            return false;
        }

        return kl_strip_move_active(strip, strip->active - 1, controller->viewport.width);
    }

    if (strip->active + 1 >= strip->count) {
        return false;
    }

    return kl_strip_move_active(strip, strip->active + 1, controller->viewport.width);
}

bool kl_controller_move_active_window_in_column(kl_controller_t *controller, int direction)
{
    return kl_strip_move_active_column_window(
        &kl_controller_workspace(controller)->strip,
        direction,
        controller->viewport.width);
}

bool kl_controller_toggle_floating(kl_controller_t *controller, kl_window_id_t window_id)
{
    return kl_workspace_toggle_floating(kl_controller_workspace(controller), window_id, controller->viewport.width);
}

bool kl_controller_set_mode_with_origin(
    kl_controller_t *controller,
    kl_window_id_t window_id,
    kl_window_mode_t mode,
    kl_window_mode_origin_t origin)
{
    return kl_workspace_set_mode_with_origin(
        kl_controller_workspace(controller),
        window_id,
        mode,
        origin,
        controller->viewport.width);
}

bool kl_controller_set_minimized(kl_controller_t *controller, kl_window_id_t window_id, bool minimized)
{
    return kl_workspace_set_minimized(
        kl_controller_workspace(controller),
        window_id,
        minimized,
        controller->viewport.width);
}

bool kl_controller_set_fullscreen(kl_controller_t *controller, kl_window_id_t window_id, bool fullscreen)
{
    return kl_workspace_set_fullscreen(
        kl_controller_workspace(controller),
        window_id,
        fullscreen,
        controller->viewport.width);
}

bool kl_controller_set_window_width(kl_controller_t *controller, kl_window_id_t window_id, double width)
{
    return kl_workspace_set_window_width(
        kl_controller_workspace(controller),
        window_id,
        width,
        controller->viewport.width);
}

bool kl_controller_reconcile_window_width(
    kl_controller_t *controller,
    kl_window_id_t window_id,
    double width,
    bool preserve_restore_width)
{
    return kl_workspace_reconcile_window_width(
        kl_controller_workspace(controller),
        window_id,
        width,
        preserve_restore_width,
        controller->viewport.width);
}

bool kl_controller_toggle_window_maximized_width(kl_controller_t *controller, kl_window_id_t window_id)
{
    return kl_workspace_toggle_window_maximized_width(
        kl_controller_workspace(controller),
        window_id,
        controller->viewport.width);
}

bool kl_controller_switch_workspace(kl_controller_t *controller, int direction)
{
    if (!kl_workspace_stack_switch(&controller->workspaces, direction)) {
        return false;
    }

    kl_workspace_t *workspace = kl_controller_workspace(controller);
    if (workspace->strip.count != 0) {
        kl_strip_focus(&workspace->strip, workspace->strip.active, controller->viewport.width);
    }
    return true;
}

void kl_controller_scroll(kl_controller_t *controller, kl_scroll_direction_t direction)
{
    double distance = controller->viewport.width * controller->keyboard_scroll_fraction;
    kl_controller_scroll_delta(controller, (double) direction * distance);
}

void kl_controller_scroll_delta(kl_controller_t *controller, double delta)
{
    kl_workspace_t *workspace = kl_controller_workspace(controller);
    kl_strip_scroll_by(&workspace->strip, delta);
    workspace->strip.viewport_x = kl_strip_clamp_viewport_x(
        &workspace->strip,
        controller->viewport.width,
        workspace->strip.viewport_x);
}

size_t kl_controller_arrange(const kl_controller_t *controller, kl_rect_t *out, size_t capacity)
{
    return kl_strip_arrange(&kl_controller_workspace_const(controller)->strip, controller->viewport, out, capacity);
}

size_t kl_controller_arrange_windows(
    const kl_controller_t *controller,
    kl_arranged_window_t *out,
    size_t capacity)
{
    return kl_strip_arrange_windows(
        &kl_controller_workspace_const(controller)->strip,
        controller->viewport,
        out,
        capacity);
}
