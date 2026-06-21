#ifndef KLOTSKI_LAYOUT_STRIP_H
#define KLOTSKI_LAYOUT_STRIP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "layout/geometry.h"

#define KL_STRIP_MAX_COLUMNS 256
#define KL_COLUMN_MAX_WINDOWS 8

typedef uint64_t kl_window_id_t;

typedef enum kl_center_mode {
    KL_CENTER_NEVER,
    KL_CENTER_ALWAYS,
    KL_CENTER_ON_OVERFLOW,
} kl_center_mode_t;

typedef struct kl_layout_options {
    double gap;
    double padding_left;
    double padding_right;
    double padding_top;
    double padding_bottom;
    double default_width_fraction;
    kl_center_mode_t center_mode;
    bool always_center_single_column;
} kl_layout_options_t;

typedef struct kl_column {
    kl_window_id_t window_id;
    kl_window_id_t windows[KL_COLUMN_MAX_WINDOWS];
    size_t count;
    size_t active;
    double width;
    double restore_width;
    bool has_restore_width;
} kl_column_t;

typedef struct kl_arranged_window {
    kl_window_id_t window_id;
    kl_rect_t frame;
} kl_arranged_window_t;

typedef struct kl_strip {
    kl_layout_options_t options;
    kl_column_t columns[KL_STRIP_MAX_COLUMNS];
    size_t count;
    size_t active;
    double viewport_x;
} kl_strip_t;

kl_layout_options_t kl_layout_default_options(void);

void kl_strip_init(kl_strip_t *strip, kl_layout_options_t options);
bool kl_strip_append(kl_strip_t *strip, kl_window_id_t window_id, double width);
bool kl_strip_insert_at(kl_strip_t *strip, size_t index, kl_window_id_t window_id, double width);
bool kl_strip_insert_after_active(kl_strip_t *strip, kl_window_id_t window_id, double width);
bool kl_strip_insert_into_column(
    kl_strip_t *strip,
    size_t column_index,
    size_t row_index,
    kl_window_id_t window_id,
    double viewport_width);
bool kl_strip_focus(kl_strip_t *strip, size_t index, double viewport_width);
bool kl_strip_focus_window(kl_strip_t *strip, kl_window_id_t window_id, double viewport_width);
bool kl_strip_focus_next(kl_strip_t *strip, double viewport_width);
bool kl_strip_focus_previous(kl_strip_t *strip, double viewport_width);
bool kl_strip_focus_active_column_window(kl_strip_t *strip, int direction, double viewport_width);
bool kl_strip_move_active(kl_strip_t *strip, size_t index, double viewport_width);
bool kl_strip_move_active_column_window(kl_strip_t *strip, int direction, double viewport_width);
bool kl_strip_move_window_to_column(
    kl_strip_t *strip,
    kl_window_id_t window_id,
    size_t column_index,
    size_t row_index,
    double viewport_width);
bool kl_strip_extract_window_to_column(
    kl_strip_t *strip,
    kl_window_id_t window_id,
    size_t column_index,
    double viewport_width);
bool kl_strip_set_column_width(
    kl_strip_t *strip,
    size_t index,
    double width,
    double viewport_width);
bool kl_strip_reconcile_column_width(
    kl_strip_t *strip,
    size_t index,
    double width,
    double viewport_width,
    bool preserve_restore_width);
bool kl_strip_toggle_column_maximized_width(
    kl_strip_t *strip,
    size_t index,
    double viewport_width);
bool kl_strip_remove_index(kl_strip_t *strip, size_t index, double viewport_width, kl_column_t *removed);
bool kl_strip_remove_window(kl_strip_t *strip, kl_window_id_t window_id, double viewport_width, kl_column_t *removed);
void kl_strip_scroll_by(kl_strip_t *strip, double delta);

double kl_strip_default_column_width(const kl_strip_t *strip, double viewport_width);
double kl_strip_effective_viewport_width(const kl_strip_t *strip, double viewport_width);
double kl_strip_max_viewport_x(const kl_strip_t *strip, double viewport_width);
double kl_strip_min_scroll_viewport_x(const kl_strip_t *strip, double viewport_width);
double kl_strip_max_scroll_viewport_x(const kl_strip_t *strip, double viewport_width);
double kl_strip_clamp_viewport_x(const kl_strip_t *strip, double viewport_width, double viewport_x);
double kl_strip_snap_viewport_x_for_column(const kl_strip_t *strip, size_t index, double viewport_width);
double kl_strip_column_x(const kl_strip_t *strip, size_t index);
size_t kl_strip_target_index_for_x(const kl_strip_t *strip, double x);
size_t kl_strip_target_row_for_y(const kl_strip_t *strip, size_t column_index, kl_rect_t viewport, double y);
kl_rect_t kl_strip_column_frame(const kl_strip_t *strip, size_t index, kl_rect_t viewport);
kl_rect_t kl_strip_window_frame(const kl_strip_t *strip, size_t column_index, size_t row_index, kl_rect_t viewport);
size_t kl_strip_arrange(const kl_strip_t *strip, kl_rect_t viewport, kl_rect_t *out, size_t capacity);
size_t kl_strip_arrange_windows(
    const kl_strip_t *strip,
    kl_rect_t viewport,
    kl_arranged_window_t *out,
    size_t capacity);
size_t kl_strip_find_window(const kl_strip_t *strip, kl_window_id_t window_id);
bool kl_strip_find_window_location(
    const kl_strip_t *strip,
    kl_window_id_t window_id,
    size_t *column_index,
    size_t *row_index);
kl_window_id_t kl_strip_active_window(const kl_strip_t *strip);

double kl_strip_compute_focused_viewport_x(
    double current_viewport_x,
    double viewport_width,
    double column_x,
    double column_width,
    double gap,
    bool center);

#endif
