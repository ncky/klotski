#include "layout/strip.h"

#include <math.h>
#include <string.h>

#define KL_STRIP_MIN_COLUMN_WIDTH 1.0
#define KL_STRIP_WIDTH_EPSILON 0.5

kl_layout_options_t kl_layout_default_options(void)
{
    return (kl_layout_options_t) {
        .gap = 2.0,
        .padding_left = 0.0,
        .padding_right = 0.0,
        .padding_top = 0.0,
        .padding_bottom = 0.0,
        .default_width_fraction = 0.5,
        .center_mode = KL_CENTER_NEVER,
        .always_center_single_column = false,
    };
}

void kl_strip_init(kl_strip_t *strip, kl_layout_options_t options)
{
    memset(strip, 0, sizeof(*strip));
    strip->options = options;
}

double kl_strip_default_column_width(const kl_strip_t *strip, double viewport_width)
{
    double fraction = strip->options.default_width_fraction;
    if (fraction <= 0.0) {
        fraction = 0.5;
    }

    double gap_share = strip->options.gap * kl_clamp_double(1.0 - fraction, 0.0, 1.0);
    return kl_max_double(
        1.0,
        (kl_strip_effective_viewport_width(strip, viewport_width) * fraction) - gap_share);
}

double kl_strip_effective_viewport_width(const kl_strip_t *strip, double viewport_width)
{
    return kl_max_double(
        1.0,
        viewport_width - strip->options.padding_left - strip->options.padding_right);
}

static double kl_strip_column_edge_padding(
    const kl_strip_t *strip,
    double viewport_width,
    double column_width)
{
    double effective_width = kl_strip_effective_viewport_width(strip, viewport_width);
    return kl_clamp_double((effective_width - column_width) / 2.0, 0.0, strip->options.gap);
}

double kl_strip_max_viewport_x(const kl_strip_t *strip, double viewport_width)
{
    if (strip->count == 0) {
        return 0.0;
    }

    size_t last = strip->count - 1;
    double strip_width = kl_strip_column_x(strip, last) + strip->columns[last].width;
    return kl_max_double(0.0, strip_width - kl_strip_effective_viewport_width(strip, viewport_width));
}

static bool kl_strip_should_use_center_scroll_bounds(const kl_strip_t *strip)
{
    return strip->options.center_mode == KL_CENTER_ALWAYS ||
           (strip->options.always_center_single_column && strip->count == 1);
}

static double kl_strip_centered_viewport_x(const kl_strip_t *strip, size_t index, double viewport_width)
{
    double effective_width = kl_strip_effective_viewport_width(strip, viewport_width);
    double column_x = kl_strip_column_x(strip, index);
    double column_width = strip->columns[index].width;

    return effective_width <= column_width
        ? column_x - strip->options.padding_left
        : column_x - ((effective_width - column_width) / 2.0) - strip->options.padding_left;
}

double kl_strip_min_scroll_viewport_x(const kl_strip_t *strip, double viewport_width)
{
    if (strip->count == 0) {
        return 0.0;
    }

    if (kl_strip_should_use_center_scroll_bounds(strip)) {
        return kl_strip_centered_viewport_x(strip, 0, viewport_width);
    }

    double padding = kl_strip_column_edge_padding(strip, viewport_width, strip->columns[0].width);
    return kl_strip_column_x(strip, 0) - padding - strip->options.padding_left;
}

double kl_strip_max_scroll_viewport_x(const kl_strip_t *strip, double viewport_width)
{
    if (strip->count == 0) {
        return 0.0;
    }

    size_t last = strip->count - 1;
    if (kl_strip_should_use_center_scroll_bounds(strip)) {
        return kl_strip_centered_viewport_x(strip, last, viewport_width);
    }

    double padding = kl_strip_column_edge_padding(strip, viewport_width, strip->columns[last].width);
    return kl_strip_column_x(strip, last) +
           strip->columns[last].width +
           padding +
           strip->options.padding_right -
           viewport_width;
}

double kl_strip_clamp_viewport_x(const kl_strip_t *strip, double viewport_width, double viewport_x)
{
    double min_x = kl_strip_min_scroll_viewport_x(strip, viewport_width);
    double max_x = kl_strip_max_scroll_viewport_x(strip, viewport_width);

    if (min_x > max_x) {
        return 0.0;
    }

    return kl_clamp_double(viewport_x, min_x, max_x);
}

double kl_strip_snap_viewport_x_for_column(const kl_strip_t *strip, size_t index, double viewport_width)
{
    if (index >= strip->count) {
        return strip->viewport_x;
    }

    return kl_clamp_double(
        kl_strip_column_x(strip, index),
        0.0,
        kl_strip_max_viewport_x(strip, viewport_width));
}

bool kl_strip_append(kl_strip_t *strip, kl_window_id_t window_id, double width)
{
    if (strip->count == KL_STRIP_MAX_COLUMNS || width <= 0.0) {
        return false;
    }

    strip->columns[strip->count++] = (kl_column_t) {
        .window_id = window_id,
        .windows = {window_id},
        .count = 1,
        .active = 0,
        .width = width,
    };
    return true;
}

bool kl_strip_insert_at(kl_strip_t *strip, size_t index, kl_window_id_t window_id, double width)
{
    if (strip->count == KL_STRIP_MAX_COLUMNS || width <= 0.0) {
        return false;
    }

    if (index > strip->count) {
        index = strip->count;
    }

    if (index < strip->count) {
        memmove(
            &strip->columns[index + 1],
            &strip->columns[index],
            (strip->count - index) * sizeof(strip->columns[0]));
    }

    strip->columns[index] = (kl_column_t) {
        .window_id = window_id,
        .windows = {window_id},
        .count = 1,
        .active = 0,
        .width = width,
    };
    strip->count++;
    return true;
}

bool kl_strip_insert_after_active(kl_strip_t *strip, kl_window_id_t window_id, double width)
{
    if (strip->count == 0) {
        return kl_strip_insert_at(strip, 0, window_id, width);
    }

    return kl_strip_insert_at(strip, strip->active + 1, window_id, width);
}

bool kl_strip_insert_into_column(
    kl_strip_t *strip,
    size_t column_index,
    size_t row_index,
    kl_window_id_t window_id,
    double viewport_width)
{
    if (column_index >= strip->count) {
        return false;
    }

    kl_column_t *column = &strip->columns[column_index];
    if (column->count == KL_COLUMN_MAX_WINDOWS) {
        return false;
    }

    if (row_index > column->count) {
        row_index = column->count;
    }

    if (row_index < column->count) {
        memmove(
            &column->windows[row_index + 1],
            &column->windows[row_index],
            (column->count - row_index) * sizeof(column->windows[0]));
    }

    column->windows[row_index] = window_id;
    column->count++;
    column->active = row_index;
    column->window_id = window_id;
    strip->active = column_index;
    return kl_strip_focus(strip, column_index, viewport_width);
}

double kl_strip_column_x(const kl_strip_t *strip, size_t index)
{
    double x = 0.0;

    for (size_t i = 0; i < index && i < strip->count; i++) {
        x += strip->columns[i].width + strip->options.gap;
    }

    return x;
}

size_t kl_strip_target_index_for_x(const kl_strip_t *strip, double x)
{
    if (strip->count == 0) {
        return 0;
    }

    for (size_t i = 0; i < strip->count; i++) {
        double column_x = kl_strip_column_x(strip, i);
        double midpoint = column_x + (strip->columns[i].width / 2.0);
        if (x < midpoint) {
            return i;
        }
    }

    return strip->count - 1;
}

static bool kl_strip_should_center_focus(const kl_strip_t *strip, size_t previous, size_t next, double viewport_width)
{
    if (strip->count == 0) {
        return false;
    }

    if (strip->options.always_center_single_column && strip->count == 1) {
        return true;
    }

    switch (strip->options.center_mode) {
    case KL_CENTER_ALWAYS:
        return true;
    case KL_CENTER_NEVER:
        return false;
    case KL_CENTER_ON_OVERFLOW: {
        double prev_x = kl_strip_column_x(strip, previous);
        double next_x = kl_strip_column_x(strip, next);
        double left = kl_min_double(prev_x, next_x);
        double right = kl_max_double(
            prev_x + strip->columns[previous].width,
            next_x + strip->columns[next].width);
        return (right - left) > viewport_width;
    }
    }

    return false;
}

double kl_strip_compute_focused_viewport_x(
    double current_viewport_x,
    double viewport_width,
    double column_x,
    double column_width,
    double gap,
    bool center)
{
    if (center && viewport_width > column_width) {
        return column_x - ((viewport_width - column_width) / 2.0);
    }

    if (viewport_width <= column_width) {
        return column_x;
    }

    double padding = kl_clamp_double((viewport_width - column_width) / 2.0, 0.0, gap);
    double desired_left = column_x - padding;
    double desired_right = column_x + column_width + padding;

    if (current_viewport_x <= desired_left &&
        desired_right <= current_viewport_x + viewport_width) {
        return current_viewport_x;
    }

    double distance_to_left = fabs(current_viewport_x - desired_left);
    double distance_to_right = fabs((current_viewport_x + viewport_width) - desired_right);

    if (distance_to_left <= distance_to_right) {
        return desired_left;
    }

    return desired_right - viewport_width;
}

bool kl_strip_focus(kl_strip_t *strip, size_t index, double viewport_width)
{
    if (index >= strip->count || viewport_width <= 0.0) {
        return false;
    }

    double effective_viewport_width = kl_strip_effective_viewport_width(strip, viewport_width);
    size_t previous = strip->active;
    bool center = kl_strip_should_center_focus(strip, previous, index, effective_viewport_width);
    strip->active = index;
    strip->viewport_x = kl_strip_compute_focused_viewport_x(
        strip->viewport_x,
        effective_viewport_width,
        kl_strip_column_x(strip, index),
        strip->columns[index].width,
        0.0,
        center);

    return true;
}

bool kl_strip_focus_window(kl_strip_t *strip, kl_window_id_t window_id, double viewport_width)
{
    size_t column_index = 0;
    size_t row_index = 0;
    if (!kl_strip_find_window_location(strip, window_id, &column_index, &row_index)) {
        return false;
    }

    strip->columns[column_index].active = row_index;
    strip->columns[column_index].window_id = window_id;
    return kl_strip_focus(strip, column_index, viewport_width);
}

bool kl_strip_focus_next(kl_strip_t *strip, double viewport_width)
{
    if (strip->count == 0 || strip->active + 1 >= strip->count) {
        return false;
    }

    return kl_strip_focus(strip, strip->active + 1, viewport_width);
}

bool kl_strip_focus_previous(kl_strip_t *strip, double viewport_width)
{
    if (strip->count == 0 || strip->active == 0) {
        return false;
    }

    return kl_strip_focus(strip, strip->active - 1, viewport_width);
}

bool kl_strip_focus_active_column_window(kl_strip_t *strip, int direction, double viewport_width)
{
    if (strip->count == 0 || strip->active >= strip->count || direction == 0) {
        return false;
    }

    kl_column_t *column = &strip->columns[strip->active];
    if (column->count == 0) {
        return false;
    }

    if (direction < 0) {
        if (column->active == 0) {
            return false;
        }
        column->active--;
    } else {
        if (column->active + 1 >= column->count) {
            return false;
        }
        column->active++;
    }

    column->window_id = column->windows[column->active];
    return kl_strip_focus(strip, strip->active, viewport_width);
}

bool kl_strip_move_active(kl_strip_t *strip, size_t index, double viewport_width)
{
    if (strip->count == 0 || index >= strip->count) {
        return false;
    }

    if (index == strip->active) {
        return true;
    }

    kl_column_t column = strip->columns[strip->active];

    if (strip->active < index) {
        memmove(
            &strip->columns[strip->active],
            &strip->columns[strip->active + 1],
            (index - strip->active) * sizeof(strip->columns[0]));
    } else {
        memmove(
            &strip->columns[index + 1],
            &strip->columns[index],
            (strip->active - index) * sizeof(strip->columns[0]));
    }

    strip->columns[index] = column;
    strip->active = index;
    return kl_strip_focus(strip, index, viewport_width);
}

bool kl_strip_move_active_column_window(kl_strip_t *strip, int direction, double viewport_width)
{
    if (strip->count == 0 || strip->active >= strip->count || direction == 0) {
        return false;
    }

    kl_column_t *column = &strip->columns[strip->active];
    if (column->count <= 1) {
        return false;
    }

    size_t next = column->active;
    if (direction < 0) {
        if (next == 0) {
            return false;
        }
        next--;
    } else {
        if (next + 1 >= column->count) {
            return false;
        }
        next++;
    }

    kl_window_id_t window = column->windows[column->active];
    column->windows[column->active] = column->windows[next];
    column->windows[next] = window;
    column->active = next;
    column->window_id = window;
    return kl_strip_focus(strip, strip->active, viewport_width);
}

bool kl_strip_move_window_to_column(
    kl_strip_t *strip,
    kl_window_id_t window_id,
    size_t column_index,
    size_t row_index,
    double viewport_width)
{
    size_t source_column_index = 0;
    size_t source_row_index = 0;
    if (!kl_strip_find_window_location(strip, window_id, &source_column_index, &source_row_index) ||
        column_index >= strip->count) {
        return false;
    }

    if (source_column_index == column_index) {
        kl_column_t *column = &strip->columns[source_column_index];
        if (column->count == 1) {
            column->active = 0;
            column->window_id = window_id;
            strip->active = source_column_index;
            return kl_strip_focus(strip, source_column_index, viewport_width);
        }

        if (row_index > source_row_index) {
            row_index--;
        }

        memmove(
            &column->windows[source_row_index],
            &column->windows[source_row_index + 1],
            (column->count - source_row_index - 1) * sizeof(column->windows[0]));
        column->count--;

        if (row_index > column->count) {
            row_index = column->count;
        }

        if (row_index < column->count) {
            memmove(
                &column->windows[row_index + 1],
                &column->windows[row_index],
                (column->count - row_index) * sizeof(column->windows[0]));
        }

        column->windows[row_index] = window_id;
        column->count++;
        column->active = row_index;
        column->window_id = window_id;
        strip->active = source_column_index;
        return kl_strip_focus(strip, source_column_index, viewport_width);
    }

    kl_column_t *source_column = &strip->columns[source_column_index];
    if (source_column->count == 1) {
        kl_column_t removed;
        if (!kl_strip_remove_index(strip, source_column_index, viewport_width, &removed)) {
            return false;
        }

        if (source_column_index < column_index) {
            column_index--;
        }
    } else {
        memmove(
            &source_column->windows[source_row_index],
            &source_column->windows[source_row_index + 1],
            (source_column->count - source_row_index - 1) * sizeof(source_column->windows[0]));
        source_column->count--;

        if (source_column->active > source_row_index) {
            source_column->active--;
        } else if (source_column->active >= source_column->count) {
            source_column->active = source_column->count - 1;
        }
        source_column->window_id = source_column->windows[source_column->active];
    }

    if (strip->count == 0) {
        return false;
    }

    if (column_index >= strip->count) {
        column_index = strip->count - 1;
    }

    return kl_strip_insert_into_column(strip, column_index, row_index, window_id, viewport_width);
}

bool kl_strip_extract_window_to_column(
    kl_strip_t *strip,
    kl_window_id_t window_id,
    size_t column_index,
    double viewport_width)
{
    if (strip->count == KL_STRIP_MAX_COLUMNS) {
        return false;
    }

    size_t source_column_index = 0;
    size_t source_row_index = 0;
    if (!kl_strip_find_window_location(strip, window_id, &source_column_index, &source_row_index)) {
        return false;
    }

    if (strip->columns[source_column_index].count <= 1) {
        return false;
    }

    kl_column_t removed;
    if (!kl_strip_remove_window(strip, window_id, viewport_width, &removed)) {
        return false;
    }

    if (column_index > strip->count) {
        column_index = strip->count;
    }

    if (!kl_strip_insert_at(strip, column_index, window_id, removed.width)) {
        return false;
    }

    return kl_strip_focus_window(strip, window_id, viewport_width);
}

bool kl_strip_set_column_width(
    kl_strip_t *strip,
    size_t index,
    double width,
    double viewport_width)
{
    return kl_strip_reconcile_column_width(strip, index, width, viewport_width, false);
}

bool kl_strip_reconcile_column_width(
    kl_strip_t *strip,
    size_t index,
    double width,
    double viewport_width,
    bool preserve_restore_width)
{
    if (index >= strip->count || !isfinite(width)) {
        return false;
    }

    double next_width = kl_max_double(KL_STRIP_MIN_COLUMN_WIDTH, width);
    kl_column_t *column = &strip->columns[index];
    bool keep_restore = preserve_restore_width && column->has_restore_width;
    if (fabs(column->width - next_width) <= KL_STRIP_WIDTH_EPSILON &&
        (keep_restore || !column->has_restore_width)) {
        return false;
    }

    column->width = next_width;
    if (!keep_restore) {
        column->restore_width = 0.0;
        column->has_restore_width = false;
    }
    strip->viewport_x = kl_strip_clamp_viewport_x(strip, viewport_width, strip->viewport_x);
    return true;
}

bool kl_strip_toggle_column_maximized_width(
    kl_strip_t *strip,
    size_t index,
    double viewport_width)
{
    if (index >= strip->count || viewport_width <= 0.0) {
        return false;
    }

    kl_column_t *column = &strip->columns[index];
    if (column->has_restore_width) {
        double restored = kl_max_double(KL_STRIP_MIN_COLUMN_WIDTH, column->restore_width);
        bool changed = fabs(column->width - restored) > KL_STRIP_WIDTH_EPSILON;
        column->width = restored;
        column->restore_width = 0.0;
        column->has_restore_width = false;
        strip->viewport_x = kl_strip_clamp_viewport_x(strip, viewport_width, strip->viewport_x);
        return changed;
    }

    double target_width = kl_strip_effective_viewport_width(strip, viewport_width);
    column->restore_width = column->width;
    column->has_restore_width = true;
    if (fabs(column->width - target_width) <= KL_STRIP_WIDTH_EPSILON) {
        return false;
    }

    column->width = target_width;
    strip->viewport_x = kl_strip_clamp_viewport_x(strip, viewport_width, strip->viewport_x);
    return true;
}

bool kl_strip_remove_index(kl_strip_t *strip, size_t index, double viewport_width, kl_column_t *removed)
{
    if (index >= strip->count) {
        return false;
    }

    if (removed) {
        *removed = strip->columns[index];
    }

    memmove(
        &strip->columns[index],
        &strip->columns[index + 1],
        (strip->count - index - 1) * sizeof(strip->columns[0]));

    strip->count--;

    if (strip->count == 0) {
        strip->active = 0;
        strip->viewport_x = 0.0;
        return true;
    }

    if (strip->active > index) {
        strip->active--;
    } else if (strip->active >= strip->count) {
        strip->active = strip->count - 1;
    }

    return kl_strip_focus(strip, strip->active, viewport_width);
}

bool kl_strip_remove_window(kl_strip_t *strip, kl_window_id_t window_id, double viewport_width, kl_column_t *removed)
{
    size_t column_index = 0;
    size_t row_index = 0;
    if (!kl_strip_find_window_location(strip, window_id, &column_index, &row_index)) {
        return false;
    }

    kl_column_t *column = &strip->columns[column_index];
    if (column->count == 1) {
        return kl_strip_remove_index(strip, column_index, viewport_width, removed);
    }

    if (removed) {
        memset(removed, 0, sizeof(*removed));
        removed->window_id = window_id;
        removed->windows[0] = window_id;
        removed->count = 1;
        removed->active = 0;
        removed->width = column->width;
    }

    memmove(
        &column->windows[row_index],
        &column->windows[row_index + 1],
        (column->count - row_index - 1) * sizeof(column->windows[0]));
    column->count--;

    if (column->active > row_index) {
        column->active--;
    } else if (column->active >= column->count) {
        column->active = column->count - 1;
    }
    column->window_id = column->windows[column->active];

    return strip->count == 0 ||
        kl_strip_focus(strip, strip->active < strip->count ? strip->active : strip->count - 1, viewport_width);
}

void kl_strip_scroll_by(kl_strip_t *strip, double delta)
{
    strip->viewport_x += delta;
}

kl_rect_t kl_strip_column_frame(const kl_strip_t *strip, size_t index, kl_rect_t viewport)
{
    if (index >= strip->count) {
        return (kl_rect_t) {0};
    }

    return (kl_rect_t) {
        .x = viewport.x + strip->options.padding_left + kl_strip_column_x(strip, index) - strip->viewport_x,
        .y = viewport.y + strip->options.padding_top,
        .width = strip->columns[index].width,
        .height = kl_max_double(
            0.0,
            viewport.height - strip->options.padding_top - strip->options.padding_bottom),
    };
}

kl_rect_t kl_strip_window_frame(const kl_strip_t *strip, size_t column_index, size_t row_index, kl_rect_t viewport)
{
    if (column_index >= strip->count) {
        return (kl_rect_t) {0};
    }

    const kl_column_t *column = &strip->columns[column_index];
    if (row_index >= column->count || column->count == 0) {
        return (kl_rect_t) {0};
    }

    kl_rect_t frame = kl_strip_column_frame(strip, column_index, viewport);
    double total_gap = strip->options.gap * (double) (column->count - 1);
    double window_height = kl_max_double(0.0, (frame.height - total_gap) / (double) column->count);

    frame.y += (double) row_index * (window_height + strip->options.gap);
    frame.height = window_height;
    return frame;
}

size_t kl_strip_target_row_for_y(const kl_strip_t *strip, size_t column_index, kl_rect_t viewport, double y)
{
    if (column_index >= strip->count) {
        return 0;
    }

    const kl_column_t *column = &strip->columns[column_index];
    if (column->count == 0) {
        return 0;
    }

    for (size_t i = 0; i < column->count; i++) {
        kl_rect_t frame = kl_strip_window_frame(strip, column_index, i, viewport);
        double midpoint = frame.y + (frame.height / 2.0);
        if (y < midpoint) {
            return i;
        }
    }

    return column->count;
}

size_t kl_strip_arrange(const kl_strip_t *strip, kl_rect_t viewport, kl_rect_t *out, size_t capacity)
{
    size_t arranged = 0;

    for (size_t column_index = 0; column_index < strip->count && arranged < capacity; column_index++) {
        const kl_column_t *column = &strip->columns[column_index];
        for (size_t row_index = 0; row_index < column->count && arranged < capacity; row_index++) {
            out[arranged++] = kl_strip_window_frame(strip, column_index, row_index, viewport);
        }
    }

    return arranged;
}

size_t kl_strip_arrange_windows(
    const kl_strip_t *strip,
    kl_rect_t viewport,
    kl_arranged_window_t *out,
    size_t capacity)
{
    size_t arranged = 0;

    for (size_t column_index = 0; column_index < strip->count && arranged < capacity; column_index++) {
        const kl_column_t *column = &strip->columns[column_index];
        for (size_t row_index = 0; row_index < column->count && arranged < capacity; row_index++) {
            out[arranged++] = (kl_arranged_window_t) {
                .window_id = column->windows[row_index],
                .frame = kl_strip_window_frame(strip, column_index, row_index, viewport),
            };
        }
    }

    return arranged;
}

size_t kl_strip_find_window(const kl_strip_t *strip, kl_window_id_t window_id)
{
    size_t column_index = 0;
    if (kl_strip_find_window_location(strip, window_id, &column_index, NULL)) {
        return column_index;
    }

    return strip->count;
}

bool kl_strip_find_window_location(
    const kl_strip_t *strip,
    kl_window_id_t window_id,
    size_t *column_index,
    size_t *row_index)
{
    for (size_t i = 0; i < strip->count; i++) {
        for (size_t row = 0; row < strip->columns[i].count; row++) {
            if (strip->columns[i].windows[row] == window_id) {
                if (column_index) {
                    *column_index = i;
                }
                if (row_index) {
                    *row_index = row;
                }
                return true;
            }
        }
    }

    return false;
}

kl_window_id_t kl_strip_active_window(const kl_strip_t *strip)
{
    if (strip->count == 0 || strip->active >= strip->count) {
        return 0;
    }

    const kl_column_t *column = &strip->columns[strip->active];
    if (column->count == 0 || column->active >= column->count) {
        return 0;
    }

    return column->windows[column->active];
}
