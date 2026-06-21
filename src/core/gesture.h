#ifndef KLOTSKI_CORE_GESTURE_H
#define KLOTSKI_CORE_GESTURE_H

#include <stdbool.h>
#include <stddef.h>

#include "core/controller.h"

#define KL_GESTURE_HISTORY_MAX 32

typedef struct kl_gesture_event {
    double delta;
    double timestamp;
} kl_gesture_event_t;

typedef struct kl_horizontal_gesture {
    bool active;
    kl_gesture_event_t history[KL_GESTURE_HISTORY_MAX];
    size_t history_count;
    double position;
    double stationary_viewport_x;
    double visual_viewport_x;
} kl_horizontal_gesture_t;

typedef struct kl_horizontal_gesture_result {
    bool committed;
    bool changed_focus;
    double target_viewport_x;
} kl_horizontal_gesture_result_t;

void kl_horizontal_gesture_begin(
    kl_horizontal_gesture_t *gesture,
    const kl_controller_t *controller);
double kl_horizontal_gesture_update(
    kl_horizontal_gesture_t *gesture,
    const kl_controller_t *controller,
    double delta,
    double timestamp);
kl_horizontal_gesture_result_t kl_horizontal_gesture_finish(
    kl_horizontal_gesture_t *gesture,
    kl_controller_t *controller,
    double timestamp);

#endif
