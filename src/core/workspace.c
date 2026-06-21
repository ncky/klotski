#include "core/workspace.h"

#include <string.h>

void kl_workspace_init(kl_workspace_t *workspace, kl_layout_options_t options)
{
    memset(workspace, 0, sizeof(*workspace));
    kl_strip_init(&workspace->strip, options);
}

kl_workspace_window_t *kl_workspace_find_window(kl_workspace_t *workspace, kl_window_id_t window_id)
{
    for (size_t i = 0; i < workspace->window_count; i++) {
        if (workspace->windows[i].window_id == window_id) {
            return &workspace->windows[i];
        }
    }

    return NULL;
}

const kl_workspace_window_t *kl_workspace_find_window_const(
    const kl_workspace_t *workspace,
    kl_window_id_t window_id)
{
    for (size_t i = 0; i < workspace->window_count; i++) {
        if (workspace->windows[i].window_id == window_id) {
            return &workspace->windows[i];
        }
    }

    return NULL;
}

kl_add_window_target_t kl_add_window_target_auto(void)
{
    return (kl_add_window_target_t) {
        .kind = KL_ADD_WINDOW_AUTO,
    };
}

kl_add_window_target_t kl_add_window_target_new_column_at(size_t column_index)
{
    return (kl_add_window_target_t) {
        .kind = KL_ADD_WINDOW_NEW_COLUMN_AT,
        .column_index = column_index,
    };
}

kl_add_window_target_t kl_add_window_target_next_to(kl_window_id_t window_id)
{
    return (kl_add_window_target_t) {
        .kind = KL_ADD_WINDOW_NEXT_TO_WINDOW,
        .window_id = window_id,
    };
}

static size_t kl_workspace_resolve_add_index(
    const kl_workspace_t *workspace,
    kl_add_window_target_t target)
{
    switch (target.kind) {
    case KL_ADD_WINDOW_AUTO:
        return workspace->strip.count == 0 ? 0 : workspace->strip.active + 1;
    case KL_ADD_WINDOW_NEW_COLUMN_AT:
        return target.column_index;
    case KL_ADD_WINDOW_NEXT_TO_WINDOW: {
        size_t index = kl_strip_find_window(&workspace->strip, target.window_id);
        if (index == workspace->strip.count) {
            return workspace->strip.count == 0 ? 0 : workspace->strip.active + 1;
        }
        return index + 1;
    }
    }

    return workspace->strip.count == 0 ? 0 : workspace->strip.active + 1;
}

static void kl_workspace_sync_column_width(kl_workspace_t *workspace, const kl_column_t *column)
{
    for (size_t row = 0; row < column->count; row++) {
        kl_workspace_window_t *window = kl_workspace_find_window(workspace, column->windows[row]);
        if (window) {
            window->tiled_width = column->width;
        }
    }
}

bool kl_workspace_add_window(kl_workspace_t *workspace, kl_window_id_t window_id, double viewport_width)
{
    return kl_workspace_add_window_with_mode(
        workspace,
        window_id,
        KL_WINDOW_TILED,
        viewport_width);
}

bool kl_workspace_add_window_with_mode(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    kl_window_mode_t mode,
    double viewport_width)
{
    return kl_workspace_add_window_with_mode_and_target(
        workspace,
        window_id,
        mode,
        kl_add_window_target_auto(),
        viewport_width);
}

bool kl_workspace_add_window_with_mode_and_target(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    kl_window_mode_t mode,
    kl_add_window_target_t target,
    double viewport_width)
{
    if (kl_workspace_find_window(workspace, window_id)) {
        return true;
    }

    if (workspace->window_count == KL_WORKSPACE_MAX_WINDOWS) {
        return false;
    }

    double width = kl_strip_default_column_width(&workspace->strip, viewport_width);

    workspace->windows[workspace->window_count++] = (kl_workspace_window_t) {
        .window_id = window_id,
        .mode = mode,
        .mode_origin = KL_WINDOW_MODE_POLICY,
        .tiled_width = width,
    };

    if (mode == KL_WINDOW_FLOATING) {
        return true;
    }

    size_t index = kl_workspace_resolve_add_index(workspace, target);
    return kl_strip_insert_at(&workspace->strip, index, window_id, width) &&
           kl_strip_focus_window(&workspace->strip, window_id, viewport_width);
}

bool kl_workspace_remove_window(kl_workspace_t *workspace, kl_window_id_t window_id, double viewport_width)
{
    size_t index = workspace->window_count;
    for (size_t i = 0; i < workspace->window_count; i++) {
        if (workspace->windows[i].window_id == window_id) {
            index = i;
            break;
        }
    }

    if (index == workspace->window_count) {
        return false;
    }

    if (workspace->windows[index].mode == KL_WINDOW_TILED && !workspace->windows[index].fullscreen) {
        kl_strip_remove_window(&workspace->strip, window_id, viewport_width, NULL);
    }

    if (index + 1 < workspace->window_count) {
        memmove(
            &workspace->windows[index],
            &workspace->windows[index + 1],
            (workspace->window_count - index - 1) * sizeof(workspace->windows[0]));
    }
    workspace->window_count--;
    return true;
}

bool kl_workspace_focus_window(kl_workspace_t *workspace, kl_window_id_t window_id, double viewport_width)
{
    const kl_workspace_window_t *window = kl_workspace_find_window_const(workspace, window_id);
    if (!window || window->mode != KL_WINDOW_TILED || window->minimized || window->fullscreen) {
        return false;
    }

    return kl_strip_focus_window(&workspace->strip, window_id, viewport_width);
}

bool kl_workspace_toggle_floating(kl_workspace_t *workspace, kl_window_id_t window_id, double viewport_width)
{
    kl_workspace_window_t *window = kl_workspace_find_window(workspace, window_id);
    if (!window) {
        return false;
    }

    kl_window_mode_t next = window->mode == KL_WINDOW_TILED ? KL_WINDOW_FLOATING : KL_WINDOW_TILED;
    return kl_workspace_set_mode_with_origin(
        workspace,
        window_id,
        next,
        KL_WINDOW_MODE_USER,
        viewport_width);
}

bool kl_workspace_set_mode(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    kl_window_mode_t mode,
    double viewport_width)
{
    return kl_workspace_set_mode_with_origin(
        workspace,
        window_id,
        mode,
        KL_WINDOW_MODE_USER,
        viewport_width);
}

bool kl_workspace_set_mode_with_origin(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    kl_window_mode_t mode,
    kl_window_mode_origin_t origin,
    double viewport_width)
{
    kl_workspace_window_t *window = kl_workspace_find_window(workspace, window_id);
    if (!window) {
        return false;
    }

    if (window->mode_origin == KL_WINDOW_MODE_USER &&
        origin == KL_WINDOW_MODE_POLICY) {
        return true;
    }

    if (window->mode == mode) {
        window->mode_origin = origin;
        return window != NULL;
    }

    if (mode == KL_WINDOW_FLOATING) {
        kl_column_t removed;
        if (!window->minimized && !window->fullscreen) {
            if (!kl_strip_remove_window(&workspace->strip, window_id, viewport_width, &removed)) {
                return false;
            }

            window->tiled_width = removed.width;
        }
        window->mode = KL_WINDOW_FLOATING;
        window->mode_origin = origin;
        return true;
    }

    if (!window->minimized && !window->fullscreen) {
        bool inserted = workspace->strip.count == 0
            ? kl_strip_append(&workspace->strip, window_id, window->tiled_width)
            : kl_strip_insert_after_active(&workspace->strip, window_id, window->tiled_width);

        if (!inserted) {
            return false;
        }
    }

    window->mode = KL_WINDOW_TILED;
    window->mode_origin = origin;
    return window->minimized ||
        window->fullscreen ||
        kl_strip_focus_window(&workspace->strip, window_id, viewport_width);
}

bool kl_workspace_set_minimized(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    bool minimized,
    double viewport_width)
{
    kl_workspace_window_t *window = kl_workspace_find_window(workspace, window_id);
    if (!window || window->minimized == minimized) {
        return window != NULL;
    }

    if (minimized) {
        if (window->mode == KL_WINDOW_TILED && !window->fullscreen) {
            kl_column_t removed;
            if (kl_strip_remove_window(&workspace->strip, window_id, viewport_width, &removed)) {
                window->tiled_width = removed.width;
            }
        }

        window->minimized = true;
        return true;
    }

    window->minimized = false;
    if (window->mode == KL_WINDOW_FLOATING || window->fullscreen) {
        return true;
    }

    bool inserted = workspace->strip.count == 0
        ? kl_strip_append(&workspace->strip, window_id, window->tiled_width)
        : kl_strip_insert_after_active(&workspace->strip, window_id, window->tiled_width);

    if (!inserted) {
        window->minimized = true;
        return false;
    }

    return kl_strip_focus_window(&workspace->strip, window_id, viewport_width);
}

bool kl_workspace_set_fullscreen(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    bool fullscreen,
    double viewport_width)
{
    kl_workspace_window_t *window = kl_workspace_find_window(workspace, window_id);
    if (!window || window->fullscreen == fullscreen) {
        return window != NULL;
    }

    if (fullscreen) {
        if (window->mode == KL_WINDOW_TILED && !window->minimized) {
            kl_column_t removed;
            if (kl_strip_remove_window(&workspace->strip, window_id, viewport_width, &removed)) {
                window->tiled_width = removed.width;
            }
        }

        window->fullscreen = true;
        return true;
    }

    window->fullscreen = false;
    if (window->mode == KL_WINDOW_FLOATING || window->minimized) {
        return true;
    }

    bool inserted = workspace->strip.count == 0
        ? kl_strip_append(&workspace->strip, window_id, window->tiled_width)
        : kl_strip_insert_after_active(&workspace->strip, window_id, window->tiled_width);

    if (!inserted) {
        window->fullscreen = true;
        return false;
    }

    return kl_strip_focus_window(&workspace->strip, window_id, viewport_width);
}

bool kl_workspace_set_window_width(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    double width,
    double viewport_width)
{
    kl_workspace_window_t *window = kl_workspace_find_window(workspace, window_id);
    if (!window ||
        window->mode != KL_WINDOW_TILED ||
        window->minimized ||
        window->fullscreen) {
        return false;
    }

    size_t column_index = 0;
    if (!kl_strip_find_window_location(&workspace->strip, window_id, &column_index, NULL)) {
        return false;
    }

    if (!kl_strip_set_column_width(&workspace->strip, column_index, width, viewport_width)) {
        return false;
    }

    kl_workspace_sync_column_width(workspace, &workspace->strip.columns[column_index]);
    return kl_strip_focus_window(&workspace->strip, window_id, viewport_width);
}

bool kl_workspace_reconcile_window_width(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    double width,
    bool preserve_restore_width,
    double viewport_width)
{
    kl_workspace_window_t *window = kl_workspace_find_window(workspace, window_id);
    if (!window ||
        window->mode != KL_WINDOW_TILED ||
        window->minimized ||
        window->fullscreen) {
        return false;
    }

    size_t column_index = 0;
    if (!kl_strip_find_window_location(&workspace->strip, window_id, &column_index, NULL)) {
        return false;
    }

    if (!kl_strip_reconcile_column_width(
            &workspace->strip,
            column_index,
            width,
            viewport_width,
            preserve_restore_width)) {
        return false;
    }

    kl_workspace_sync_column_width(workspace, &workspace->strip.columns[column_index]);
    return true;
}

bool kl_workspace_toggle_window_maximized_width(
    kl_workspace_t *workspace,
    kl_window_id_t window_id,
    double viewport_width)
{
    kl_workspace_window_t *window = kl_workspace_find_window(workspace, window_id);
    if (!window ||
        window->mode != KL_WINDOW_TILED ||
        window->minimized ||
        window->fullscreen) {
        return false;
    }

    size_t column_index = 0;
    if (!kl_strip_find_window_location(&workspace->strip, window_id, &column_index, NULL)) {
        return false;
    }

    bool changed = kl_strip_toggle_column_maximized_width(
        &workspace->strip,
        column_index,
        viewport_width);
    kl_workspace_sync_column_width(workspace, &workspace->strip.columns[column_index]);
    kl_strip_focus_window(&workspace->strip, window_id, viewport_width);
    return changed;
}
