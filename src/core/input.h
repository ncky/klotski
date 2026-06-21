#ifndef KLOTSKI_CORE_INPUT_H
#define KLOTSKI_CORE_INPUT_H

#include <stdbool.h>
#include <stddef.h>

#define KL_INPUT_SWIPE_HISTORY_MAX 64
#define KL_INPUT_WHEEL_SCROLL_TICK 120.0
#define KL_INPUT_FINGER_SCROLL_TICK 10.0
#define KL_INPUT_SWIPE_HISTORY_SECONDS 0.150
#define KL_INPUT_TOUCHPAD_DECELERATION 0.997
#define KL_INPUT_VIEW_GESTURE_WORKING_AREA_MOVEMENT 1200.0
#define KL_INPUT_THREE_FINGER_AXIS_THRESHOLD 16.0

typedef enum kl_input_axis {
    KL_INPUT_AXIS_NONE,
    KL_INPUT_AXIS_HORIZONTAL,
    KL_INPUT_AXIS_VERTICAL,
} kl_input_axis_t;

typedef struct kl_scroll_tracker {
    double tick;
    double last;
    double accumulator;
} kl_scroll_tracker_t;

typedef enum kl_scroll_swipe_action {
    KL_SCROLL_SWIPE_BEGIN_UPDATE,
    KL_SCROLL_SWIPE_UPDATE,
    KL_SCROLL_SWIPE_END,
} kl_scroll_swipe_action_t;

typedef struct kl_scroll_swipe_gesture {
    bool ongoing;
    bool vertical;
} kl_scroll_swipe_gesture_t;

typedef struct kl_swipe_event {
    double delta;
    double timestamp;
} kl_swipe_event_t;

typedef struct kl_swipe_tracker {
    kl_swipe_event_t history[KL_INPUT_SWIPE_HISTORY_MAX];
    size_t history_count;
    double position;
} kl_swipe_tracker_t;

typedef enum kl_three_finger_swipe_phase {
    KL_THREE_FINGER_SWIPE_IGNORED,
    KL_THREE_FINGER_SWIPE_RECOGNIZING,
    KL_THREE_FINGER_SWIPE_BEGIN,
    KL_THREE_FINGER_SWIPE_UPDATE,
    KL_THREE_FINGER_SWIPE_END,
} kl_three_finger_swipe_phase_t;

typedef struct kl_three_finger_swipe_result {
    kl_three_finger_swipe_phase_t phase;
    kl_input_axis_t axis;
    double delta_x;
    double delta_y;
} kl_three_finger_swipe_result_t;

typedef struct kl_three_finger_swipe {
    bool recognizing;
    bool active;
    kl_input_axis_t axis;
    double cumulative_x;
    double cumulative_y;
} kl_three_finger_swipe_t;

typedef struct kl_view_scroll_gesture {
    bool active;
    bool is_touchpad;
    kl_swipe_tracker_t tracker;
    double delta_from_tracker;
    double stationary_viewport_x;
    double current_viewport_x;
} kl_view_scroll_gesture_t;

typedef struct kl_view_scroll_gesture_result {
    bool ended;
    double current_viewport_x;
    double projected_viewport_x;
    double velocity_pixels;
} kl_view_scroll_gesture_result_t;

void kl_scroll_tracker_init(kl_scroll_tracker_t *tracker, double tick);
void kl_scroll_tracker_reset(kl_scroll_tracker_t *tracker);
int kl_scroll_tracker_accumulate(kl_scroll_tracker_t *tracker, double amount);

void kl_scroll_swipe_gesture_init(kl_scroll_swipe_gesture_t *gesture);
kl_scroll_swipe_action_t kl_scroll_swipe_gesture_update(
    kl_scroll_swipe_gesture_t *gesture,
    double dx,
    double dy);
bool kl_scroll_swipe_gesture_reset(kl_scroll_swipe_gesture_t *gesture);
bool kl_scroll_swipe_gesture_is_vertical(const kl_scroll_swipe_gesture_t *gesture);
bool kl_scroll_swipe_action_begins(kl_scroll_swipe_action_t action);
bool kl_scroll_swipe_action_ends(kl_scroll_swipe_action_t action);

void kl_swipe_tracker_init(kl_swipe_tracker_t *tracker);
void kl_swipe_tracker_reset(kl_swipe_tracker_t *tracker);
void kl_swipe_tracker_push(kl_swipe_tracker_t *tracker, double delta, double timestamp);
double kl_swipe_tracker_position(const kl_swipe_tracker_t *tracker);
double kl_swipe_tracker_velocity(const kl_swipe_tracker_t *tracker);
double kl_swipe_tracker_projected_end_position(const kl_swipe_tracker_t *tracker);

void kl_three_finger_swipe_begin(kl_three_finger_swipe_t *gesture, size_t fingers);
kl_three_finger_swipe_result_t kl_three_finger_swipe_update(
    kl_three_finger_swipe_t *gesture,
    double dx,
    double dy);
kl_three_finger_swipe_result_t kl_three_finger_swipe_end(kl_three_finger_swipe_t *gesture);

void kl_view_scroll_gesture_begin(
    kl_view_scroll_gesture_t *gesture,
    double current_viewport_x,
    bool is_touchpad);
bool kl_view_scroll_gesture_update(
    kl_view_scroll_gesture_t *gesture,
    double delta_x,
    double timestamp,
    double viewport_width,
    bool is_touchpad,
    double *viewport_x);
bool kl_view_scroll_gesture_end(
    kl_view_scroll_gesture_t *gesture,
    double timestamp,
    double viewport_width,
    bool has_is_touchpad,
    bool is_touchpad,
    kl_view_scroll_gesture_result_t *result);
void kl_view_scroll_gesture_adjust_after_clamp(
    kl_view_scroll_gesture_t *gesture,
    double requested_viewport_x,
    double applied_viewport_x);

double kl_input_touchpad_normalized_delta_to_units(double normalized_delta, double sensitivity);
double kl_input_touchpad_scroll_delta_to_units(
    double normalized_delta,
    double sensitivity,
    bool inverted);
double kl_input_touchpad_units_to_viewport_pixels(double units, double viewport_width);
double kl_input_wheel_delta_to_viewport_pixels(
    double wheel_delta,
    double viewport_width,
    double sensitivity);

#endif
