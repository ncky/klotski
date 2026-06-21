#include "core/input.h"

#include <math.h>
#include <string.h>

static double input_norm_factor(bool is_touchpad, double viewport_width)
{
    if (!is_touchpad) {
        return 1.0;
    }

    return viewport_width / KL_INPUT_VIEW_GESTURE_WORKING_AREA_MOVEMENT;
}

void kl_scroll_tracker_init(kl_scroll_tracker_t *tracker, double tick)
{
    memset(tracker, 0, sizeof(*tracker));
    tracker->tick = tick > 0.0 ? tick : KL_INPUT_WHEEL_SCROLL_TICK;
}

void kl_scroll_tracker_reset(kl_scroll_tracker_t *tracker)
{
    tracker->last = 0.0;
    tracker->accumulator = 0.0;
}

int kl_scroll_tracker_accumulate(kl_scroll_tracker_t *tracker, double amount)
{
    bool changed_direction =
        (tracker->last > 0.0 && amount < 0.0) ||
        (tracker->last < 0.0 && amount > 0.0);
    if (changed_direction) {
        tracker->accumulator = 0.0;
    }

    tracker->last = amount;
    tracker->accumulator += amount;

    if (fabs(tracker->accumulator) < tracker->tick) {
        return 0;
    }

    double clamped = fmin(
        127.0 * tracker->tick,
        fmax(-127.0 * tracker->tick, tracker->accumulator));
    int ticks = (int) ((int) clamped / (int) tracker->tick);
    tracker->accumulator = fmod(tracker->accumulator, tracker->tick);
    return ticks;
}

void kl_scroll_swipe_gesture_init(kl_scroll_swipe_gesture_t *gesture)
{
    memset(gesture, 0, sizeof(*gesture));
}

kl_scroll_swipe_action_t kl_scroll_swipe_gesture_update(
    kl_scroll_swipe_gesture_t *gesture,
    double dx,
    double dy)
{
    if (dx == 0.0 && dy == 0.0) {
        gesture->ongoing = false;
        return KL_SCROLL_SWIPE_END;
    }

    if (!gesture->ongoing) {
        gesture->ongoing = true;
        gesture->vertical = dy != 0.0;
        return KL_SCROLL_SWIPE_BEGIN_UPDATE;
    }

    return KL_SCROLL_SWIPE_UPDATE;
}

bool kl_scroll_swipe_gesture_reset(kl_scroll_swipe_gesture_t *gesture)
{
    if (!gesture->ongoing) {
        return false;
    }

    gesture->ongoing = false;
    return true;
}

bool kl_scroll_swipe_gesture_is_vertical(const kl_scroll_swipe_gesture_t *gesture)
{
    return gesture->vertical;
}

bool kl_scroll_swipe_action_begins(kl_scroll_swipe_action_t action)
{
    return action == KL_SCROLL_SWIPE_BEGIN_UPDATE;
}

bool kl_scroll_swipe_action_ends(kl_scroll_swipe_action_t action)
{
    return action == KL_SCROLL_SWIPE_END;
}

void kl_swipe_tracker_init(kl_swipe_tracker_t *tracker)
{
    memset(tracker, 0, sizeof(*tracker));
}

void kl_swipe_tracker_reset(kl_swipe_tracker_t *tracker)
{
    memset(tracker, 0, sizeof(*tracker));
}

static void swipe_tracker_trim_history(kl_swipe_tracker_t *tracker)
{
    if (tracker->history_count == 0) {
        return;
    }

    double newest = tracker->history[tracker->history_count - 1].timestamp;
    size_t first = 0;
    while (first < tracker->history_count &&
           newest > tracker->history[first].timestamp + KL_INPUT_SWIPE_HISTORY_SECONDS) {
        first++;
    }

    if (first > 0) {
        memmove(
            tracker->history,
            &tracker->history[first],
            (tracker->history_count - first) * sizeof(tracker->history[0]));
        tracker->history_count -= first;
    }
}

void kl_swipe_tracker_push(kl_swipe_tracker_t *tracker, double delta, double timestamp)
{
    if (tracker->history_count > 0 &&
        timestamp < tracker->history[tracker->history_count - 1].timestamp) {
        return;
    }

    if (tracker->history_count == KL_INPUT_SWIPE_HISTORY_MAX) {
        memmove(
            tracker->history,
            &tracker->history[1],
            (KL_INPUT_SWIPE_HISTORY_MAX - 1) * sizeof(tracker->history[0]));
        tracker->history_count--;
    }

    tracker->history[tracker->history_count++] = (kl_swipe_event_t) {
        .delta = delta,
        .timestamp = timestamp,
    };
    tracker->position += delta;
    swipe_tracker_trim_history(tracker);
}

double kl_swipe_tracker_position(const kl_swipe_tracker_t *tracker)
{
    return tracker->position;
}

double kl_swipe_tracker_velocity(const kl_swipe_tracker_t *tracker)
{
    if (tracker->history_count < 2) {
        return 0.0;
    }

    const kl_swipe_event_t *first = &tracker->history[0];
    const kl_swipe_event_t *last = &tracker->history[tracker->history_count - 1];
    double elapsed = last->timestamp - first->timestamp;
    if (elapsed <= 0.0) {
        return 0.0;
    }

    double total_delta = 0.0;
    for (size_t i = 0; i < tracker->history_count; i++) {
        total_delta += tracker->history[i].delta;
    }

    return total_delta / elapsed;
}

double kl_swipe_tracker_projected_end_position(const kl_swipe_tracker_t *tracker)
{
    double velocity = kl_swipe_tracker_velocity(tracker);
    return tracker->position -
           velocity / (1000.0 * log(KL_INPUT_TOUCHPAD_DECELERATION));
}

void kl_three_finger_swipe_begin(kl_three_finger_swipe_t *gesture, size_t fingers)
{
    memset(gesture, 0, sizeof(*gesture));
    if (fingers == 3) {
        gesture->recognizing = true;
    }
}

kl_three_finger_swipe_result_t kl_three_finger_swipe_update(
    kl_three_finger_swipe_t *gesture,
    double dx,
    double dy)
{
    kl_three_finger_swipe_result_t result = {
        .phase = KL_THREE_FINGER_SWIPE_IGNORED,
        .axis = KL_INPUT_AXIS_NONE,
        .delta_x = dx,
        .delta_y = dy,
    };

    if (gesture->active) {
        result.phase = KL_THREE_FINGER_SWIPE_UPDATE;
        result.axis = gesture->axis;
        return result;
    }

    if (!gesture->recognizing) {
        return result;
    }

    gesture->cumulative_x += dx;
    gesture->cumulative_y += dy;

    double threshold = KL_INPUT_THREE_FINGER_AXIS_THRESHOLD;
    double distance_squared =
        (gesture->cumulative_x * gesture->cumulative_x) +
        (gesture->cumulative_y * gesture->cumulative_y);
    if (distance_squared < threshold * threshold) {
        result.phase = KL_THREE_FINGER_SWIPE_RECOGNIZING;
        result.delta_x = gesture->cumulative_x;
        result.delta_y = gesture->cumulative_y;
        return result;
    }

    gesture->recognizing = false;
    gesture->active = true;
    gesture->axis = fabs(gesture->cumulative_x) > fabs(gesture->cumulative_y)
        ? KL_INPUT_AXIS_HORIZONTAL
        : KL_INPUT_AXIS_VERTICAL;

    result.phase = KL_THREE_FINGER_SWIPE_BEGIN;
    result.axis = gesture->axis;
    result.delta_x = gesture->cumulative_x;
    result.delta_y = gesture->cumulative_y;
    return result;
}

kl_three_finger_swipe_result_t kl_three_finger_swipe_end(kl_three_finger_swipe_t *gesture)
{
    kl_three_finger_swipe_result_t result = {
        .phase = gesture->active ? KL_THREE_FINGER_SWIPE_END : KL_THREE_FINGER_SWIPE_IGNORED,
        .axis = gesture->axis,
        .delta_x = 0.0,
        .delta_y = 0.0,
    };
    memset(gesture, 0, sizeof(*gesture));
    return result;
}

void kl_view_scroll_gesture_begin(
    kl_view_scroll_gesture_t *gesture,
    double current_viewport_x,
    bool is_touchpad)
{
    memset(gesture, 0, sizeof(*gesture));
    gesture->active = true;
    gesture->is_touchpad = is_touchpad;
    gesture->delta_from_tracker = current_viewport_x;
    gesture->stationary_viewport_x = current_viewport_x;
    gesture->current_viewport_x = current_viewport_x;
    kl_swipe_tracker_init(&gesture->tracker);
}

bool kl_view_scroll_gesture_update(
    kl_view_scroll_gesture_t *gesture,
    double delta_x,
    double timestamp,
    double viewport_width,
    bool is_touchpad,
    double *viewport_x)
{
    if (!gesture->active || gesture->is_touchpad != is_touchpad) {
        return false;
    }

    kl_swipe_tracker_push(&gesture->tracker, delta_x, timestamp);

    double norm_factor = input_norm_factor(gesture->is_touchpad, viewport_width);
    double position = kl_swipe_tracker_position(&gesture->tracker) * norm_factor;
    gesture->current_viewport_x = position + gesture->delta_from_tracker;

    if (viewport_x) {
        *viewport_x = gesture->current_viewport_x;
    }
    return true;
}

bool kl_view_scroll_gesture_end(
    kl_view_scroll_gesture_t *gesture,
    double timestamp,
    double viewport_width,
    bool has_is_touchpad,
    bool is_touchpad,
    kl_view_scroll_gesture_result_t *result)
{
    if (result) {
        memset(result, 0, sizeof(*result));
    }

    if (!gesture->active || (has_is_touchpad && gesture->is_touchpad != is_touchpad)) {
        return false;
    }

    kl_swipe_tracker_push(&gesture->tracker, 0.0, timestamp);

    double norm_factor = input_norm_factor(gesture->is_touchpad, viewport_width);
    double position = kl_swipe_tracker_position(&gesture->tracker) * norm_factor;
    double projected = kl_swipe_tracker_projected_end_position(&gesture->tracker) * norm_factor;
    double velocity = kl_swipe_tracker_velocity(&gesture->tracker) * norm_factor;
    double current = position + gesture->delta_from_tracker;
    double target = projected + gesture->delta_from_tracker;

    if (result) {
        result->ended = true;
        result->current_viewport_x = current;
        result->projected_viewport_x = target;
        result->velocity_pixels = velocity;
    }

    memset(gesture, 0, sizeof(*gesture));
    return true;
}

void kl_view_scroll_gesture_adjust_after_clamp(
    kl_view_scroll_gesture_t *gesture,
    double requested_viewport_x,
    double applied_viewport_x)
{
    if (!gesture->active) {
        return;
    }

    gesture->delta_from_tracker += applied_viewport_x - requested_viewport_x;
    gesture->current_viewport_x = applied_viewport_x;
}

double kl_input_touchpad_normalized_delta_to_units(double normalized_delta, double sensitivity)
{
    return normalized_delta * KL_INPUT_VIEW_GESTURE_WORKING_AREA_MOVEMENT * sensitivity;
}

double kl_input_touchpad_scroll_delta_to_units(
    double normalized_delta,
    double sensitivity,
    bool inverted)
{
    double units = kl_input_touchpad_normalized_delta_to_units(normalized_delta, sensitivity);
    return inverted ? -units : units;
}

double kl_input_touchpad_units_to_viewport_pixels(double units, double viewport_width)
{
    return units * (viewport_width / KL_INPUT_VIEW_GESTURE_WORKING_AREA_MOVEMENT);
}

double kl_input_wheel_delta_to_viewport_pixels(
    double wheel_delta,
    double viewport_width,
    double sensitivity)
{
    return -wheel_delta * viewport_width * 0.005 * sensitivity;
}
