#include "core/gesture.h"

#include "core/input.h"

#include <math.h>
#include <string.h>

typedef struct kl_snap_point {
    double viewport_x;
    size_t column_index;
} kl_snap_point_t;

typedef struct kl_gesture_target {
    double viewport_x;
    size_t column_index;
} kl_gesture_target_t;

void kl_horizontal_gesture_begin(kl_horizontal_gesture_t *gesture, const kl_controller_t *controller)
{
    const kl_workspace_t *workspace = kl_controller_workspace_const(controller);

    memset(gesture, 0, sizeof(*gesture));
    gesture->active = true;
    gesture->stationary_viewport_x = workspace->strip.viewport_x;
    gesture->visual_viewport_x = workspace->strip.viewport_x;
}

static void gesture_trim_history(kl_horizontal_gesture_t *gesture)
{
    if (gesture->history_count == 0) {
        return;
    }

    double newest = gesture->history[gesture->history_count - 1].timestamp;
    size_t first = 0;
    while (first < gesture->history_count &&
           newest > gesture->history[first].timestamp + KL_INPUT_SWIPE_HISTORY_SECONDS) {
        first++;
    }

    if (first > 0) {
        memmove(
            gesture->history,
            &gesture->history[first],
            (gesture->history_count - first) * sizeof(gesture->history[0]));
        gesture->history_count -= first;
    }
}

static void gesture_push(kl_horizontal_gesture_t *gesture, double delta, double timestamp)
{
    if (gesture->history_count > 0 &&
        timestamp < gesture->history[gesture->history_count - 1].timestamp) {
        return;
    }

    if (gesture->history_count == KL_GESTURE_HISTORY_MAX) {
        memmove(
            gesture->history,
            &gesture->history[1],
            (KL_GESTURE_HISTORY_MAX - 1) * sizeof(gesture->history[0]));
        gesture->history_count--;
    }

    gesture->history[gesture->history_count++] = (kl_gesture_event_t) {
        .delta = delta,
        .timestamp = timestamp,
    };
    gesture->position += delta;
    gesture_trim_history(gesture);
}

static double gesture_velocity(const kl_horizontal_gesture_t *gesture)
{
    if (gesture->history_count < 2) {
        return 0.0;
    }

    const kl_gesture_event_t *first = &gesture->history[0];
    const kl_gesture_event_t *last = &gesture->history[gesture->history_count - 1];
    double elapsed = last->timestamp - first->timestamp;
    if (elapsed <= 0.0) {
        return 0.0;
    }

    double delta = 0.0;
    for (size_t i = 0; i < gesture->history_count; i++) {
        delta += gesture->history[i].delta;
    }

    return delta / elapsed;
}

static double gesture_projected_end_position(const kl_horizontal_gesture_t *gesture)
{
    double velocity = gesture_velocity(gesture);
    return gesture->position - velocity / (1000.0 * log(KL_INPUT_TOUCHPAD_DECELERATION));
}

double kl_horizontal_gesture_update(
    kl_horizontal_gesture_t *gesture,
    const kl_controller_t *controller,
    double delta,
    double timestamp)
{
    if (!gesture->active) {
        kl_horizontal_gesture_begin(gesture, controller);
    }

    const kl_workspace_t *workspace = kl_controller_workspace_const(controller);

    gesture_push(gesture, delta, timestamp);
    gesture->visual_viewport_x = kl_strip_clamp_viewport_x(
        &workspace->strip,
        controller->viewport.width,
        gesture->stationary_viewport_x + gesture->position);
    return gesture->visual_viewport_x;
}

static void push_snap(kl_snap_point_t *snaps, size_t *count, double viewport_x, size_t column_index)
{
    snaps[(*count)++] = (kl_snap_point_t) {
        .viewport_x = viewport_x,
        .column_index = column_index,
    };
}

static void sort_snaps(kl_snap_point_t *snaps, size_t count)
{
    for (size_t i = 1; i < count; i++) {
        kl_snap_point_t snap = snaps[i];
        size_t j = i;
        while (j > 0 && snaps[j - 1].viewport_x > snap.viewport_x) {
            snaps[j] = snaps[j - 1];
            j--;
        }
        snaps[j] = snap;
    }
}

static void column_snap_points(
    const kl_strip_t *strip,
    size_t index,
    double viewport_width,
    double *left,
    double *right)
{
    double effective_width = kl_strip_effective_viewport_width(strip, viewport_width);
    double column_x = kl_strip_column_x(strip, index);
    double column_width = strip->columns[index].width;
    double padding = kl_clamp_double((effective_width - column_width) / 2.0, 0.0, strip->options.gap);
    double center = effective_width <= column_width
        ? column_x - strip->options.padding_left
        : column_x - ((effective_width - column_width) / 2.0) - strip->options.padding_left;

    bool center_on_overflow = strip->options.center_mode == KL_CENTER_ON_OVERFLOW;
    bool prev_overflows = false;
    bool next_overflows = false;

    if (center_on_overflow) {
        if (index > 0) {
            prev_overflows =
                strip->columns[index - 1].width + (3.0 * strip->options.gap) + column_width > effective_width;
        }
        if (index + 1 < strip->count) {
            next_overflows =
                strip->columns[index + 1].width + (3.0 * strip->options.gap) + column_width > effective_width;
        }
    }

    *left = next_overflows
        ? center
        : column_x - padding - strip->options.padding_left;
    *right = prev_overflows
        ? center + viewport_width
        : column_x + column_width + padding + strip->options.padding_right;
}

static size_t build_snap_points(
    const kl_strip_t *strip,
    double viewport_width,
    kl_snap_point_t *snaps,
    size_t capacity)
{
    if (strip->count == 0 || capacity < 2) {
        return 0;
    }

    if (strip->options.center_mode == KL_CENTER_ALWAYS ||
        (strip->options.always_center_single_column && strip->count == 1)) {
        size_t count = 0;
        double effective_width = kl_strip_effective_viewport_width(strip, viewport_width);
        for (size_t i = 0; i < strip->count && count < capacity; i++) {
            double column_x = kl_strip_column_x(strip, i);
            double column_width = strip->columns[i].width;
            double viewport_x = effective_width <= column_width
                ? column_x - strip->options.padding_left
                : column_x - ((effective_width - column_width) / 2.0) - strip->options.padding_left;
            push_snap(snaps, &count, viewport_x, i);
        }
        return count;
    }

    double first_left = 0.0;
    double first_right = 0.0;
    column_snap_points(strip, 0, viewport_width, &first_left, &first_right);

    size_t last = strip->count - 1;
    double last_left = 0.0;
    double last_right = 0.0;
    column_snap_points(strip, last, viewport_width, &last_left, &last_right);

    double leftmost_snap = first_left;
    double rightmost_snap = last_right - viewport_width;
    size_t count = 0;

    push_snap(snaps, &count, leftmost_snap, 0);
    push_snap(snaps, &count, rightmost_snap, last);

    for (size_t i = 0; i < strip->count && count + 2 <= capacity; i++) {
        double left = 0.0;
        double right = 0.0;
        column_snap_points(strip, i, viewport_width, &left, &right);

        if (leftmost_snap < left && left < rightmost_snap) {
            push_snap(snaps, &count, left, i);
        }

        right -= viewport_width;
        if (leftmost_snap < right && right < rightmost_snap) {
            push_snap(snaps, &count, right, i);
        }
    }

    return count;
}

static kl_snap_point_t closest_snap(
    const kl_snap_point_t *snaps,
    size_t count,
    double target_viewport_x)
{
    kl_snap_point_t best = snaps[0];
    double best_distance = fabs(best.viewport_x - target_viewport_x);

    for (size_t i = 1; i < count; i++) {
        double distance = fabs(snaps[i].viewport_x - target_viewport_x);
        if (distance < best_distance) {
            best = snaps[i];
            best_distance = distance;
        }
    }

    return best;
}

static kl_snap_point_t closest_snap_for_column(
    const kl_snap_point_t *snaps,
    size_t count,
    size_t column_index,
    double target_viewport_x)
{
    bool found = false;
    kl_snap_point_t best = {0};
    double best_distance = 0.0;

    for (size_t i = 0; i < count; i++) {
        if (snaps[i].column_index != column_index) {
            continue;
        }

        double distance = fabs(snaps[i].viewport_x - target_viewport_x);
        if (!found || distance < best_distance) {
            best = snaps[i];
            best_distance = distance;
            found = true;
        }
    }

    return found ? best : closest_snap(snaps, count, target_viewport_x);
}

static kl_gesture_target_t gesture_target(
    const kl_strip_t *strip,
    double viewport_width,
    double current_viewport_x,
    double target_viewport_x)
{
    kl_snap_point_t snaps[KL_STRIP_MAX_COLUMNS * 2];
    size_t count = build_snap_points(strip, viewport_width, snaps, KL_STRIP_MAX_COLUMNS * 2);
    if (count == 0) {
        return (kl_gesture_target_t) {
            .viewport_x = strip->viewport_x,
            .column_index = strip->active,
        };
    }

    sort_snaps(snaps, count);
    kl_snap_point_t target_snap = closest_snap(snaps, count, target_viewport_x);
    size_t new_index = target_snap.column_index;
    size_t previous_index = strip->active;
    bool moving_right = target_viewport_x >= current_viewport_x;

    if (strip->options.center_mode == KL_CENTER_ALWAYS) {
        return (kl_gesture_target_t) {
            .viewport_x = target_snap.viewport_x,
            .column_index = new_index,
        };
    }

    double effective_width = kl_strip_effective_viewport_width(strip, viewport_width);
    if (moving_right) {
        for (size_t i = new_index + 1; i < strip->count; i++) {
            double column_x = kl_strip_column_x(strip, i);
            double column_width = strip->columns[i].width;
            double padding = kl_clamp_double((effective_width - column_width) / 2.0, 0.0, strip->options.gap);
            double column_right = column_x + column_width;
            if (target_snap.viewport_x + strip->options.padding_left + effective_width < column_right + padding) {
                break;
            }
            new_index = i;
        }
    } else {
        for (size_t i = new_index; i > 0; i--) {
            size_t candidate = i - 1;
            double column_left = kl_strip_column_x(strip, candidate);
            double column_width = strip->columns[candidate].width;
            double padding = kl_clamp_double((effective_width - column_width) / 2.0, 0.0, strip->options.gap);
            if (column_left - padding < target_snap.viewport_x + strip->options.padding_left) {
                break;
            }
            new_index = candidate;
        }
    }

    if (moving_right && new_index > previous_index + 1) {
        new_index = previous_index + 1;
        target_snap = closest_snap_for_column(snaps, count, new_index, target_viewport_x);
    } else if (!moving_right && new_index + 1 < previous_index) {
        new_index = previous_index - 1;
        target_snap = closest_snap_for_column(snaps, count, new_index, target_viewport_x);
    }

    return (kl_gesture_target_t) {
        .viewport_x = target_snap.viewport_x,
        .column_index = new_index,
    };
}

kl_horizontal_gesture_result_t kl_horizontal_gesture_finish(
    kl_horizontal_gesture_t *gesture,
    kl_controller_t *controller,
    double timestamp)
{
    kl_horizontal_gesture_result_t result = {0};
    kl_strip_t *strip = &kl_controller_workspace(controller)->strip;

    if (!gesture->active) {
        result.target_viewport_x = strip->viewport_x;
        return result;
    }

    gesture_push(gesture, 0.0, timestamp);
    double current_viewport_x = gesture->stationary_viewport_x + gesture->position;
    double target_viewport_x = gesture->stationary_viewport_x + gesture_projected_end_position(gesture);

    if (strip->count != 0) {
        size_t previous_active = strip->active;
        kl_gesture_target_t target =
            gesture_target(strip, controller->viewport.width, current_viewport_x, target_viewport_x);

        if (target.column_index < strip->count) {
            strip->active = target.column_index;
            strip->viewport_x = target.viewport_x;
        }

        result.changed_focus = previous_active != strip->active;
    }

    result.committed = true;
    result.target_viewport_x = strip->viewport_x;
    memset(gesture, 0, sizeof(*gesture));
    return result;
}
