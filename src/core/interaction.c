#include "core/interaction.h"

#include <math.h>
#include <string.h>

static const kl_rubber_band_t kl_default_gesture_rubber_band = {
    .stiffness = 0.5,
    .limit = 0.05,
};

double kl_rubber_band_band(kl_rubber_band_t rubber_band, double x)
{
    double c = rubber_band.stiffness;
    double d = rubber_band.limit;
    return (1.0 - (1.0 / (x * c / d + 1.0))) * d;
}

double kl_rubber_band_derivative(kl_rubber_band_t rubber_band, double x)
{
    double c = rubber_band.stiffness;
    double d = rubber_band.limit;
    double denominator = (c * x + d) * (c * x + d);
    return c * d * d / denominator;
}

double kl_rubber_band_clamp(kl_rubber_band_t rubber_band, double min, double max, double x)
{
    double clamped = fmin(max, fmax(min, x));
    double sign = x < clamped ? -1.0 : 1.0;
    double diff = fabs(x - clamped);
    return clamped + sign * kl_rubber_band_band(rubber_band, diff);
}

double kl_rubber_band_clamp_derivative(
    kl_rubber_band_t rubber_band,
    double min,
    double max,
    double x)
{
    if (min <= x && x <= max) {
        return 1.0;
    }

    double clamped = fmin(max, fmax(min, x));
    return kl_rubber_band_derivative(rubber_band, fabs(x - clamped));
}

void kl_pointer_move_grab_begin(
    kl_pointer_move_grab_t *grab,
    double x,
    double y,
    bool enable_view_offset,
    bool is_tiled)
{
    memset(grab, 0, sizeof(*grab));
    grab->mode = KL_POINTER_MOVE_RECOGNIZING;
    grab->enable_view_offset = enable_view_offset;
    grab->is_tiled = is_tiled;
    grab->start_x = x;
    grab->start_y = y;
    grab->last_x = x;
    grab->last_y = y;
}

static kl_pointer_move_result_t pointer_move_result(
    kl_pointer_move_phase_t phase,
    const kl_pointer_move_grab_t *grab,
    double delta_x,
    double delta_y,
    double relative_delta_x,
    double relative_delta_y)
{
    return (kl_pointer_move_result_t) {
        .phase = phase,
        .mode = grab->mode,
        .delta_x = delta_x,
        .delta_y = delta_y,
        .relative_delta_x = relative_delta_x,
        .relative_delta_y = relative_delta_y,
        .view_scroll_delta_x = -relative_delta_x,
        .accumulated_x = grab->last_x - grab->start_x,
        .accumulated_y = grab->last_y - grab->start_y,
    };
}

kl_pointer_move_result_t kl_pointer_move_grab_update(
    kl_pointer_move_grab_t *grab,
    double x,
    double y,
    bool has_relative_delta,
    double relative_delta_x,
    double relative_delta_y)
{
    if (grab->mode == KL_POINTER_MOVE_IDLE) {
        return (kl_pointer_move_result_t) {0};
    }

    double delta_x = x - grab->last_x;
    double delta_y = y - grab->last_y;
    if (!has_relative_delta) {
        relative_delta_x = delta_x;
        relative_delta_y = delta_y;
    }

    grab->last_x = x;
    grab->last_y = y;

    if (grab->mode == KL_POINTER_MOVE_RECOGNIZING) {
        double cumulative_x = x - grab->start_x;
        double cumulative_y = y - grab->start_y;
        double threshold = KL_POINTER_GRAB_AXIS_THRESHOLD;
        double distance_squared = (cumulative_x * cumulative_x) + (cumulative_y * cumulative_y);
        if (distance_squared < threshold * threshold) {
            return pointer_move_result(
                KL_POINTER_MOVE_RECOGNIZING_PHASE,
                grab,
                0.0,
                0.0,
                0.0,
                0.0);
        }

        bool is_view_offset =
            grab->enable_view_offset &&
            grab->is_tiled &&
            fabs(cumulative_x) > fabs(cumulative_y);
        grab->mode = is_view_offset ? KL_POINTER_MOVE_VIEW_OFFSET : KL_POINTER_MOVE_WINDOW;
        delta_x = cumulative_x;
        delta_y = cumulative_y;
        relative_delta_x = cumulative_x;
        relative_delta_y = cumulative_y;

        return pointer_move_result(
            KL_POINTER_MOVE_BEGIN,
            grab,
            delta_x,
            delta_y,
            relative_delta_x,
            relative_delta_y);
    }

    return pointer_move_result(
        KL_POINTER_MOVE_UPDATE,
        grab,
        delta_x,
        delta_y,
        relative_delta_x,
        relative_delta_y);
}

kl_pointer_move_result_t kl_pointer_move_grab_force_move(kl_pointer_move_grab_t *grab)
{
    if (grab->mode == KL_POINTER_MOVE_IDLE) {
        return (kl_pointer_move_result_t) {0};
    }

    if (grab->mode != KL_POINTER_MOVE_RECOGNIZING) {
        return pointer_move_result(KL_POINTER_MOVE_UPDATE, grab, 0.0, 0.0, 0.0, 0.0);
    }

    grab->mode = KL_POINTER_MOVE_WINDOW;
    double cumulative_x = grab->last_x - grab->start_x;
    double cumulative_y = grab->last_y - grab->start_y;
    return pointer_move_result(
        KL_POINTER_MOVE_BEGIN,
        grab,
        cumulative_x,
        cumulative_y,
        cumulative_x,
        cumulative_y);
}

kl_pointer_move_result_t kl_pointer_move_grab_end(kl_pointer_move_grab_t *grab)
{
    kl_pointer_move_result_t result =
        pointer_move_result(KL_POINTER_MOVE_END, grab, 0.0, 0.0, 0.0, 0.0);
    memset(grab, 0, sizeof(*grab));
    return result;
}

void kl_pointer_resize_grab_begin(kl_pointer_resize_grab_t *grab, double x, double y)
{
    memset(grab, 0, sizeof(*grab));
    grab->active = true;
    grab->start_x = x;
    grab->start_y = y;
}

kl_pointer_resize_result_t kl_pointer_resize_grab_update(
    kl_pointer_resize_grab_t *grab,
    double x,
    double y)
{
    if (!grab->active) {
        return (kl_pointer_resize_result_t) {0};
    }

    return (kl_pointer_resize_result_t) {
        .active = true,
        .delta_x = x - grab->start_x,
        .delta_y = y - grab->start_y,
    };
}

void kl_pointer_resize_grab_end(kl_pointer_resize_grab_t *grab)
{
    memset(grab, 0, sizeof(*grab));
}

void kl_overview_gesture_begin(kl_overview_gesture_t *gesture, double current_value)
{
    memset(gesture, 0, sizeof(*gesture));
    gesture->active = true;
    gesture->open = true;
    gesture->start = current_value;
    gesture->value = current_value;
    kl_swipe_tracker_init(&gesture->tracker);
}

bool kl_overview_gesture_update(
    kl_overview_gesture_t *gesture,
    double delta_y,
    double timestamp,
    kl_overview_gesture_result_t *result)
{
    if (result) {
        memset(result, 0, sizeof(*result));
    }

    if (!gesture->active) {
        return false;
    }

    kl_swipe_tracker_push(&gesture->tracker, delta_y, timestamp);
    double position = kl_swipe_tracker_position(&gesture->tracker) / KL_OVERVIEW_GESTURE_MOVEMENT;
    double new_value = kl_rubber_band_clamp(
        kl_default_gesture_rubber_band,
        0.0,
        1.0,
        gesture->start + position);

    bool changed = gesture->value != new_value;
    gesture->value = new_value;

    if (result) {
        result->changed = changed;
        result->open = gesture->open;
        result->value = gesture->value;
        result->target_value = gesture->value;
        result->velocity = 0.0;
    }
    return true;
}

bool kl_overview_gesture_end(
    kl_overview_gesture_t *gesture,
    double timestamp,
    kl_overview_gesture_result_t *result)
{
    if (result) {
        memset(result, 0, sizeof(*result));
    }

    if (!gesture->active) {
        return false;
    }

    kl_swipe_tracker_push(&gesture->tracker, 0.0, timestamp);

    double velocity = kl_swipe_tracker_velocity(&gesture->tracker) / KL_OVERVIEW_GESTURE_MOVEMENT;
    double current_pos = kl_swipe_tracker_position(&gesture->tracker) / KL_OVERVIEW_GESTURE_MOVEMENT;
    double projected_pos =
        kl_swipe_tracker_projected_end_position(&gesture->tracker) / KL_OVERVIEW_GESTURE_MOVEMENT;
    double projected_value = fmin(1.0, fmax(0.0, gesture->start + projected_pos));
    double target_value = round(projected_value);
    velocity *= kl_rubber_band_clamp_derivative(
        kl_default_gesture_rubber_band,
        0.0,
        1.0,
        gesture->start + current_pos);

    gesture->active = false;
    gesture->open = target_value == 1.0;
    gesture->value = target_value;

    if (result) {
        result->changed = true;
        result->open = gesture->open;
        result->value = gesture->value;
        result->target_value = target_value;
        result->velocity = velocity;
    }
    return true;
}

static void workspace_switch_min_max(
    const kl_workspace_switch_gesture_t *gesture,
    double *min,
    double *max)
{
    if (gesture->workspace_count == 0) {
        *min = 0.0;
        *max = 0.0;
        return;
    }

    if (gesture->is_clamped) {
        *min = gesture->center_index == 0 ? 0.0 : (double) (gesture->center_index - 1);
        size_t max_index = gesture->center_index + 1;
        if (max_index >= gesture->workspace_count) {
            max_index = gesture->workspace_count - 1;
        }
        *max = (double) max_index;
        return;
    }

    *min = 0.0;
    *max = (double) (gesture->workspace_count - 1);
}

static double workspace_switch_total_height(bool is_touchpad, double workspace_height)
{
    if (is_touchpad) {
        return KL_WORKSPACE_GESTURE_MOVEMENT;
    }

    return workspace_height > 0.0 ? workspace_height : KL_WORKSPACE_GESTURE_MOVEMENT;
}

void kl_workspace_switch_gesture_begin(
    kl_workspace_switch_gesture_t *gesture,
    size_t active_index,
    double current_index,
    size_t workspace_count,
    bool is_touchpad,
    bool overview_open)
{
    memset(gesture, 0, sizeof(*gesture));
    gesture->active = true;
    gesture->is_touchpad = is_touchpad;
    gesture->is_clamped = !overview_open;
    gesture->workspace_count = workspace_count;
    gesture->center_index = active_index < workspace_count ? active_index : 0;
    gesture->start_index = current_index;
    gesture->current_index = current_index;
    kl_swipe_tracker_init(&gesture->tracker);
}

bool kl_workspace_switch_gesture_update(
    kl_workspace_switch_gesture_t *gesture,
    double delta_y,
    double timestamp,
    bool is_touchpad,
    double zoom,
    double workspace_height,
    kl_workspace_switch_result_t *result)
{
    if (result) {
        memset(result, 0, sizeof(*result));
    }

    if (!gesture->active || gesture->is_touchpad != is_touchpad) {
        return false;
    }

    if (zoom <= 0.0) {
        zoom = 1.0;
    }

    double delta_scale = gesture->is_touchpad ? ((zoom - 1.0) / 2.5) + 1.0 : zoom;
    double scaled_delta = delta_y / delta_scale;
    kl_swipe_tracker_push(&gesture->tracker, scaled_delta, timestamp);

    double total_height = workspace_switch_total_height(gesture->is_touchpad, workspace_height);
    double position = kl_swipe_tracker_position(&gesture->tracker) / total_height;
    double min = 0.0;
    double max = 0.0;
    workspace_switch_min_max(gesture, &min, &max);

    kl_rubber_band_t rubber_band = kl_default_gesture_rubber_band;
    rubber_band.limit /= zoom;

    double new_index =
        kl_rubber_band_clamp(rubber_band, min, max, gesture->start_index + position);
    bool changed = gesture->current_index != new_index;
    gesture->current_index = new_index;

    if (result) {
        result->changed = changed;
        result->active_index = (size_t) round(fmin(max, fmax(min, new_index)));
        result->current_index = gesture->current_index;
        result->target_index = gesture->current_index;
        result->velocity = 0.0;
    }
    return true;
}

bool kl_workspace_switch_gesture_end(
    kl_workspace_switch_gesture_t *gesture,
    double timestamp,
    bool has_is_touchpad,
    bool is_touchpad,
    double zoom,
    double workspace_height,
    kl_workspace_switch_result_t *result)
{
    if (result) {
        memset(result, 0, sizeof(*result));
    }

    if (!gesture->active || (has_is_touchpad && gesture->is_touchpad != is_touchpad)) {
        return false;
    }

    if (zoom <= 0.0) {
        zoom = 1.0;
    }

    kl_swipe_tracker_push(&gesture->tracker, 0.0, timestamp);

    double total_height = workspace_switch_total_height(gesture->is_touchpad, workspace_height);
    double min = 0.0;
    double max = 0.0;
    workspace_switch_min_max(gesture, &min, &max);

    kl_rubber_band_t rubber_band = kl_default_gesture_rubber_band;
    rubber_band.limit /= zoom;

    double velocity = kl_swipe_tracker_velocity(&gesture->tracker) / total_height;
    double current_pos = kl_swipe_tracker_position(&gesture->tracker) / total_height;
    double projected_pos = kl_swipe_tracker_projected_end_position(&gesture->tracker) / total_height;
    double target_index = fmin(max, fmax(min, gesture->start_index + projected_pos));
    target_index = round(target_index);
    velocity *= kl_rubber_band_clamp_derivative(
        rubber_band,
        min,
        max,
        gesture->start_index + current_pos);

    gesture->active = false;
    gesture->current_index = target_index;

    if (result) {
        result->changed = true;
        result->active_index = (size_t) target_index;
        result->current_index = target_index;
        result->target_index = target_index;
        result->velocity = velocity;
    }
    return true;
}
