#ifndef KLOTSKI_CORE_WORKSPACE_H
#define KLOTSKI_CORE_WORKSPACE_H

#include <stdbool.h>
#include <stddef.h>

#include "layout/strip.h"

#define KL_WORKSPACE_MAX_WINDOWS 512

typedef enum kl_window_mode {
    KL_WINDOW_TILED,
    KL_WINDOW_FLOATING,
} kl_window_mode_t;

typedef enum kl_window_mode_origin {
    KL_WINDOW_MODE_POLICY,
    KL_WINDOW_MODE_USER,
} kl_window_mode_origin_t;

typedef enum kl_add_window_target_kind {
    KL_ADD_WINDOW_AUTO,
    KL_ADD_WINDOW_NEW_COLUMN_AT,
    KL_ADD_WINDOW_NEXT_TO_WINDOW,
} kl_add_window_target_kind_t;

typedef struct kl_add_window_target {
    kl_add_window_target_kind_t kind;
    size_t column_index;
    kl_window_id_t window_id;
} kl_add_window_target_t;

typedef struct kl_workspace_window {
    kl_window_id_t window_id;
    kl_window_mode_t mode;
    kl_window_mode_origin_t mode_origin;
    double tiled_width;
    bool minimized;
    bool fullscreen;
} kl_workspace_window_t;

typedef struct kl_workspace {
    kl_strip_t strip;
    kl_workspace_window_t windows[KL_WORKSPACE_MAX_WINDOWS];
    size_t window_count;
} kl_workspace_t;

void kl_workspace_init(kl_workspace_t *workspace, kl_layout_options_t options);

kl_add_window_target_t kl_add_window_target_auto(void);
kl_add_window_target_t kl_add_window_target_new_column_at(size_t column_index);
kl_add_window_target_t kl_add_window_target_next_to(kl_window_id_t window_id);

bool kl_workspace_add_window(kl_workspace_t *workspace, kl_window_id_t window_id, double viewport_width);
bool kl_workspace_add_window_with_mode(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    kl_window_mode_t mode,
    double viewport_width);
bool kl_workspace_add_window_with_mode_and_target(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    kl_window_mode_t mode,
    kl_add_window_target_t target,
    double viewport_width);
bool kl_workspace_remove_window(kl_workspace_t *workspace, kl_window_id_t window_id, double viewport_width);
bool kl_workspace_focus_window(kl_workspace_t *workspace, kl_window_id_t window_id, double viewport_width);
bool kl_workspace_toggle_floating(kl_workspace_t *workspace, kl_window_id_t window_id, double viewport_width);
bool kl_workspace_set_minimized(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    bool minimized,
    double viewport_width);
bool kl_workspace_set_fullscreen(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    bool fullscreen,
    double viewport_width);
bool kl_workspace_set_window_width(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    double width,
    double viewport_width);
bool kl_workspace_reconcile_window_width(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    double width,
    bool preserve_restore_width,
    double viewport_width);
bool kl_workspace_toggle_window_maximized_width(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    double viewport_width);
bool kl_workspace_set_mode(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    kl_window_mode_t mode,
    double viewport_width);
bool kl_workspace_set_mode_with_origin(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    kl_window_mode_t mode,
    kl_window_mode_origin_t origin,
    double viewport_width);

kl_workspace_window_t *kl_workspace_find_window(kl_workspace_t *workspace, kl_window_id_t window_id);
const kl_workspace_window_t *kl_workspace_find_window_const(
    const kl_workspace_t *workspace,
    kl_window_id_t window_id);

#endif
