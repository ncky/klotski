#ifndef KLOTSKI_CORE_CONTROLLER_H
#define KLOTSKI_CORE_CONTROLLER_H

#include <stdbool.h>
#include <stddef.h>

#include "core/workspace_stack.h"
#include "layout/geometry.h"

typedef enum kl_scroll_direction {
    KL_SCROLL_LEFT = -1,
    KL_SCROLL_RIGHT = 1,
} kl_scroll_direction_t;

typedef struct kl_controller {
    kl_workspace_stack_t workspaces;
    kl_rect_t viewport;
    double keyboard_scroll_fraction;
} kl_controller_t;

void kl_controller_init(kl_controller_t *controller, kl_layout_options_t options, kl_rect_t viewport);
void kl_controller_set_viewport(kl_controller_t *controller, kl_rect_t viewport);
kl_workspace_t *kl_controller_workspace(kl_controller_t *controller);
const kl_workspace_t *kl_controller_workspace_const(const kl_controller_t *controller);

bool kl_controller_notice_window(kl_controller_t *controller, kl_window_id_t window_id);
bool kl_controller_notice_window_with_mode(
    kl_controller_t *controller,
    kl_window_id_t window_id,
    kl_window_mode_t mode);
bool kl_controller_notice_window_with_mode_and_target(
    kl_controller_t *controller,
    kl_window_id_t window_id,
    kl_window_mode_t mode,
    kl_add_window_target_t target);
bool kl_controller_forget_window(kl_controller_t *controller, kl_window_id_t window_id);
bool kl_controller_focus_window(kl_controller_t *controller, kl_window_id_t window_id);
bool kl_controller_focus_next(kl_controller_t *controller);
bool kl_controller_focus_previous(kl_controller_t *controller);
bool kl_controller_focus_window_in_column(kl_controller_t *controller, int direction);
bool kl_controller_move_active_column(kl_controller_t *controller, int direction);
bool kl_controller_move_active_window_in_column(kl_controller_t *controller, int direction);
bool kl_controller_toggle_floating(kl_controller_t *controller, kl_window_id_t window_id);
bool kl_controller_set_mode_with_origin(
    kl_controller_t *controller,
    kl_window_id_t window_id,
    kl_window_mode_t mode,
    kl_window_mode_origin_t origin);
bool kl_controller_set_minimized(kl_controller_t *controller, kl_window_id_t window_id, bool minimized);
bool kl_controller_set_fullscreen(kl_controller_t *controller, kl_window_id_t window_id, bool fullscreen);
bool kl_controller_set_window_width(kl_controller_t *controller, kl_window_id_t window_id, double width);
bool kl_controller_reconcile_window_width(
    kl_controller_t *controller,
    kl_window_id_t window_id,
    double width,
    bool preserve_restore_width);
bool kl_controller_toggle_window_maximized_width(kl_controller_t *controller, kl_window_id_t window_id);
bool kl_controller_switch_workspace(kl_controller_t *controller, int direction);
void kl_controller_scroll(kl_controller_t *controller, kl_scroll_direction_t direction);
void kl_controller_scroll_delta(kl_controller_t *controller, double delta);

size_t kl_controller_arrange(const kl_controller_t *controller, kl_rect_t *out, size_t capacity);
size_t kl_controller_arrange_windows(
    const kl_controller_t *controller,
    kl_arranged_window_t *out,
    size_t capacity);

#endif
