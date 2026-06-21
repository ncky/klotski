#ifndef KLOTSKI_CORE_INTERACTION_H
#define KLOTSKI_CORE_INTERACTION_H

#include <stdbool.h>
#include <stddef.h>

#include "core/input.h"

#define KL_POINTER_GRAB_AXIS_THRESHOLD 8.0
#define KL_INTERACTIVE_MOVE_PULL_THRESHOLD 256.0
#define KL_OVERVIEW_GESTURE_MOVEMENT 300.0
#define KL_WORKSPACE_GESTURE_MOVEMENT 300.0
#define KL_WORKSPACE_DND_EDGE_SCROLL_MOVEMENT 1500.0

typedef struct kl_rubber_band {
    double stiffness;
    double limit;
} kl_rubber_band_t;

typedef enum kl_pointer_move_mode {
    KL_POINTER_MOVE_IDLE,
    KL_POINTER_MOVE_RECOGNIZING,
    KL_POINTER_MOVE_WINDOW,
    KL_POINTER_MOVE_VIEW_OFFSET,
} kl_pointer_move_mode_t;

typedef enum kl_pointer_move_phase {
    KL_POINTER_MOVE_NONE,
    KL_POINTER_MOVE_RECOGNIZING_PHASE,
    KL_POINTER_MOVE_BEGIN,
    KL_POINTER_MOVE_UPDATE,
    KL_POINTER_MOVE_END,
} kl_pointer_move_phase_t;

typedef struct kl_pointer_move_grab {
    kl_pointer_move_mode_t mode;
    bool enable_view_offset;
    bool is_tiled;
    double start_x;
    double start_y;
    double last_x;
    double last_y;
} kl_pointer_move_grab_t;

typedef struct kl_pointer_move_result {
    kl_pointer_move_phase_t phase;
    kl_pointer_move_mode_t mode;
    double delta_x;
    double delta_y;
    double relative_delta_x;
    double relative_delta_y;
    double view_scroll_delta_x;
    double accumulated_x;
    double accumulated_y;
} kl_pointer_move_result_t;

typedef struct kl_pointer_resize_grab {
    bool active;
    double start_x;
    double start_y;
} kl_pointer_resize_grab_t;

typedef struct kl_pointer_resize_result {
    bool active;
    double delta_x;
    double delta_y;
} kl_pointer_resize_result_t;

typedef struct kl_overview_gesture {
    bool active;
    bool open;
    kl_swipe_tracker_t tracker;
    double start;
    double value;
} kl_overview_gesture_t;

typedef struct kl_overview_gesture_result {
    bool changed;
    bool open;
    double value;
    double target_value;
    double velocity;
} kl_overview_gesture_result_t;

typedef struct kl_workspace_switch_gesture {
    bool active;
    bool is_touchpad;
    bool is_clamped;
    size_t center_index;
    size_t workspace_count;
    kl_swipe_tracker_t tracker;
    double start_index;
    double current_index;
} kl_workspace_switch_gesture_t;

typedef struct kl_workspace_switch_result {
    bool changed;
    size_t active_index;
    double current_index;
    double target_index;
    double velocity;
} kl_workspace_switch_result_t;

double kl_rubber_band_band(kl_rubber_band_t rubber_band, double x);
double kl_rubber_band_derivative(kl_rubber_band_t rubber_band, double x);
double kl_rubber_band_clamp(kl_rubber_band_t rubber_band, double min, double max, double x);
double kl_rubber_band_clamp_derivative(
    kl_rubber_band_t rubber_band,
    double min,
    double max,
    double x);

void kl_pointer_move_grab_begin(
    kl_pointer_move_grab_t *grab,
    double x,
    double y,
    bool enable_view_offset,
    bool is_tiled);
kl_pointer_move_result_t kl_pointer_move_grab_update(
    kl_pointer_move_grab_t *grab,
    double x,
    double y,
    bool has_relative_delta,
    double relative_delta_x,
    double relative_delta_y);
kl_pointer_move_result_t kl_pointer_move_grab_force_move(kl_pointer_move_grab_t *grab);
kl_pointer_move_result_t kl_pointer_move_grab_end(kl_pointer_move_grab_t *grab);

void kl_pointer_resize_grab_begin(kl_pointer_resize_grab_t *grab, double x, double y);
kl_pointer_resize_result_t kl_pointer_resize_grab_update(
    kl_pointer_resize_grab_t *grab,
    double x,
    double y);
void kl_pointer_resize_grab_end(kl_pointer_resize_grab_t *grab);

void kl_overview_gesture_begin(kl_overview_gesture_t *gesture, double current_value);
bool kl_overview_gesture_update(
    kl_overview_gesture_t *gesture,
    double delta_y,
    double timestamp,
    kl_overview_gesture_result_t *result);
bool kl_overview_gesture_end(
    kl_overview_gesture_t *gesture,
    double timestamp,
    kl_overview_gesture_result_t *result);

void kl_workspace_switch_gesture_begin(
    kl_workspace_switch_gesture_t *gesture,
    size_t active_index,
    double current_index,
    size_t workspace_count,
    bool is_touchpad,
    bool overview_open);
bool kl_workspace_switch_gesture_update(
    kl_workspace_switch_gesture_t *gesture,
    double delta_y,
    double timestamp,
    bool is_touchpad,
    double zoom,
    double workspace_height,
    kl_workspace_switch_result_t *result);
bool kl_workspace_switch_gesture_end(
    kl_workspace_switch_gesture_t *gesture,
    double timestamp,
    bool has_is_touchpad,
    bool is_touchpad,
    double zoom,
    double workspace_height,
    kl_workspace_switch_result_t *result);

#endif
