#ifndef KLOTSKI_PLATFORM_MACOS_WINDOW_OBSERVER_H
#define KLOTSKI_PLATFORM_MACOS_WINDOW_OBSERVER_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

#include <ApplicationServices/ApplicationServices.h>

typedef struct kl_macos_window_observer kl_macos_window_observer_t;

typedef void (*kl_macos_window_observer_callback_t)(
    pid_t pid,
    AXUIElementRef element,
    uint32_t window_id,
    const char *reason,
    void *context);

kl_macos_window_observer_t *kl_macos_window_observer_create(void);
bool kl_macos_window_observer_start(
    kl_macos_window_observer_t *observer,
    pid_t only_pid,
    kl_macos_window_observer_callback_t callback,
    void *context);
void kl_macos_window_observer_destroy(kl_macos_window_observer_t *observer);

#endif
