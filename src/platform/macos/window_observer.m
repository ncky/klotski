#include "platform/macos/window_observer.h"

#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KL_MACOS_MAX_OBSERVED_APPS 512
#define KL_MACOS_MAX_OBSERVED_WINDOWS 512

extern AXError _AXUIElementGetWindow(AXUIElementRef ref, uint32_t *wid) __attribute__((weak_import));

typedef struct kl_macos_observed_app kl_macos_observed_app_t;

typedef struct kl_macos_observed_window {
    pid_t pid;
    uint32_t window_id;
    kl_macos_observed_app_t *app;
    struct kl_macos_window_observer *owner;
    AXUIElementRef window;
    bool destroyed_registered;
    bool minimized_registered;
    bool deminimized_registered;
    bool resized_registered;
} kl_macos_observed_window_t;

struct kl_macos_observed_app {
    pid_t pid;
    struct kl_macos_window_observer *owner;
    AXUIElementRef app;
    AXObserverRef observer;
    bool created_registered;
    bool focused_window_registered;
};

struct kl_macos_window_observer {
    pid_t only_pid;
    kl_macos_window_observer_callback_t callback;
    void *context;
    kl_macos_observed_app_t apps[KL_MACOS_MAX_OBSERVED_APPS];
    kl_macos_observed_window_t windows[KL_MACOS_MAX_OBSERVED_WINDOWS];
    size_t app_count;
    size_t window_count;
    void *launch_token;
    void *terminate_token;
};

static bool observer_should_watch_pid(const kl_macos_window_observer_t *observer, pid_t pid)
{
    return pid > 0 && (observer->only_pid <= 0 || observer->only_pid == pid);
}

static kl_macos_observed_app_t *observer_find_app(kl_macos_window_observer_t *observer, pid_t pid)
{
    for (size_t i = 0; i < KL_MACOS_MAX_OBSERVED_APPS; i++) {
        if (observer->apps[i].pid == pid) {
            return &observer->apps[i];
        }
    }

    return NULL;
}

static bool observer_copy_window_id(AXUIElementRef window, uint32_t *out)
{
    if (!_AXUIElementGetWindow || !window) {
        return false;
    }

    uint32_t window_id = 0;
    if (_AXUIElementGetWindow(window, &window_id) != kAXErrorSuccess || window_id == 0) {
        return false;
    }

    *out = window_id;
    return true;
}

static kl_macos_observed_window_t *observer_find_window(
    kl_macos_window_observer_t *observer,
    pid_t pid,
    uint32_t window_id)
{
    for (size_t i = 0; i < KL_MACOS_MAX_OBSERVED_WINDOWS; i++) {
        if (observer->windows[i].pid == pid && observer->windows[i].window_id == window_id) {
            return &observer->windows[i];
        }
    }

    return NULL;
}

static void observer_notify(
    kl_macos_window_observer_t *observer,
    pid_t pid,
    AXUIElementRef element,
    uint32_t window_id,
    const char *reason)
{
    if (observer->callback) {
        observer->callback(pid, element, window_id, reason, observer->context);
    }
}

static void observer_clear_window(kl_macos_observed_window_t *window)
{
    if (window->app && window->app->observer && window->window) {
        if (window->destroyed_registered) {
            AXObserverRemoveNotification(
                window->app->observer,
                window->window,
                kAXUIElementDestroyedNotification);
        }
        if (window->minimized_registered) {
            AXObserverRemoveNotification(
                window->app->observer,
                window->window,
                kAXWindowMiniaturizedNotification);
        }
        if (window->deminimized_registered) {
            AXObserverRemoveNotification(
                window->app->observer,
                window->window,
                kAXWindowDeminiaturizedNotification);
        }
        if (window->resized_registered) {
            AXObserverRemoveNotification(
                window->app->observer,
                window->window,
                kAXWindowResizedNotification);
        }
    }

    if (window->window) {
        CFRelease(window->window);
    }

    if (window->owner && window->owner->window_count > 0) {
        window->owner->window_count--;
    }
    memset(window, 0, sizeof(*window));
}

static bool observer_add_window(kl_macos_observed_app_t *app, AXUIElementRef element)
{
    if (!app || !app->owner || !app->observer || !element) {
        return false;
    }

    uint32_t window_id = 0;
    if (!observer_copy_window_id(element, &window_id)) {
        return false;
    }

    if (observer_find_window(app->owner, app->pid, window_id)) {
        return true;
    }

    kl_macos_observed_window_t *window = NULL;
    for (size_t i = 0; i < KL_MACOS_MAX_OBSERVED_WINDOWS; i++) {
        if (app->owner->windows[i].pid == 0) {
            window = &app->owner->windows[i];
            break;
        }
    }

    if (!window) {
        fprintf(stderr, "too many windows to observe for lifecycle events\n");
        return false;
    }

    memset(window, 0, sizeof(*window));
    window->pid = app->pid;
    window->window_id = window_id;
    window->app = app;
    window->owner = app->owner;
    window->window = (AXUIElementRef) CFRetain(element);

    AXError error = AXObserverAddNotification(
        app->observer,
        window->window,
        kAXUIElementDestroyedNotification,
        window);
    window->destroyed_registered =
        error == kAXErrorSuccess || error == kAXErrorNotificationAlreadyRegistered;

    error = AXObserverAddNotification(
        app->observer,
        window->window,
        kAXWindowMiniaturizedNotification,
        window);
    window->minimized_registered =
        error == kAXErrorSuccess || error == kAXErrorNotificationAlreadyRegistered;

    error = AXObserverAddNotification(
        app->observer,
        window->window,
        kAXWindowDeminiaturizedNotification,
        window);
    window->deminimized_registered =
        error == kAXErrorSuccess || error == kAXErrorNotificationAlreadyRegistered;

    error = AXObserverAddNotification(
        app->observer,
        window->window,
        kAXWindowResizedNotification,
        window);
    window->resized_registered =
        error == kAXErrorSuccess || error == kAXErrorNotificationAlreadyRegistered;

    if (!window->destroyed_registered &&
        !window->minimized_registered &&
        !window->deminimized_registered &&
        !window->resized_registered) {
        observer_clear_window(window);
        return false;
    }

    app->owner->window_count++;
    return true;
}

static void observer_observe_existing_windows(kl_macos_observed_app_t *app)
{
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(app->app, kAXWindowsAttribute, &value);
    if (error != kAXErrorSuccess || !value || CFGetTypeID(value) != CFArrayGetTypeID()) {
        if (value) {
            CFRelease(value);
        }
        return;
    }

    CFArrayRef windows = (CFArrayRef) value;
    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; i++) {
        observer_add_window(app, (AXUIElementRef) CFArrayGetValueAtIndex(windows, i));
    }

    CFRelease(value);
}

static void observer_notify_focused_window(kl_macos_observed_app_t *app)
{
    if (!app || !app->owner || !app->app) {
        return;
    }

    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(app->app, kAXFocusedWindowAttribute, &value);
    if (error != kAXErrorSuccess || !value || CFGetTypeID(value) != AXUIElementGetTypeID()) {
        if (value) {
            CFRelease(value);
        }
        return;
    }

    AXUIElementRef focused_window = (AXUIElementRef) value;
    uint32_t window_id = 0;
    observer_copy_window_id(focused_window, &window_id);
    observer_add_window(app, focused_window);
    observer_notify(app->owner, app->pid, focused_window, window_id, "ax-focused");

    CFRelease(value);
}

static void observer_clear_windows_for_app(kl_macos_window_observer_t *observer, kl_macos_observed_app_t *app)
{
    for (size_t i = 0; i < KL_MACOS_MAX_OBSERVED_WINDOWS; i++) {
        if (observer->windows[i].app == app) {
            observer_clear_window(&observer->windows[i]);
        }
    }
}

static void window_observer_callback(
    __unused AXObserverRef ax_observer,
    __unused AXUIElementRef element,
    CFStringRef notification,
    void *context)
{
    kl_macos_observed_app_t *app = context;
    if (app && CFEqual(notification, kAXCreatedNotification)) {
        uint32_t window_id = 0;
        observer_copy_window_id(element, &window_id);
        observer_notify(app->owner, app->pid, element, window_id, "ax-created");
        observer_add_window(app, element);
        return;
    }
    if (app && CFEqual(notification, kAXFocusedWindowChangedNotification)) {
        observer_notify_focused_window(app);
        return;
    }

    kl_macos_observed_window_t *window = context;
    if (!window || !window->owner) {
        return;
    }

    if (CFEqual(notification, kAXWindowMiniaturizedNotification)) {
        observer_notify(window->owner, window->pid, element, window->window_id, "ax-minimized");
    } else if (CFEqual(notification, kAXWindowDeminiaturizedNotification)) {
        observer_notify(window->owner, window->pid, element, window->window_id, "ax-deminimized");
    } else if (CFEqual(notification, kAXWindowResizedNotification)) {
        observer_notify(window->owner, window->pid, element, window->window_id, "ax-resized");
    } else if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        observer_notify(window->owner, window->pid, element, window->window_id, "ax-destroyed");
        observer_clear_window(window);
    }
}

static void observer_clear_app(kl_macos_observed_app_t *app)
{
    if (app->owner) {
        observer_clear_windows_for_app(app->owner, app);
    }

    if (app->observer && app->app && app->created_registered) {
        AXObserverRemoveNotification(app->observer, app->app, kAXCreatedNotification);
    }
    if (app->observer && app->app && app->focused_window_registered) {
        AXObserverRemoveNotification(app->observer, app->app, kAXFocusedWindowChangedNotification);
    }

    if (app->observer) {
        CFRunLoopSourceRef source = AXObserverGetRunLoopSource(app->observer);
        if (source) {
            CFRunLoopSourceInvalidate(source);
        }
        CFRelease(app->observer);
    }

    if (app->app) {
        CFRelease(app->app);
    }

    memset(app, 0, sizeof(*app));
}

static bool observer_add_pid(kl_macos_window_observer_t *observer, pid_t pid)
{
    if (!observer_should_watch_pid(observer, pid) || observer_find_app(observer, pid)) {
        return true;
    }

    kl_macos_observed_app_t *app = NULL;
    for (size_t i = 0; i < KL_MACOS_MAX_OBSERVED_APPS; i++) {
        if (observer->apps[i].pid == 0) {
            app = &observer->apps[i];
            break;
        }
    }

    if (!app) {
        fprintf(stderr, "too many applications to observe for window creation\n");
        return false;
    }

    memset(app, 0, sizeof(*app));
    app->pid = pid;
    app->owner = observer;
    app->app = AXUIElementCreateApplication(pid);
    if (!app->app) {
        memset(app, 0, sizeof(*app));
        return false;
    }

    AXError error = AXObserverCreate(pid, window_observer_callback, &app->observer);
    if (error != kAXErrorSuccess || !app->observer) {
        observer_clear_app(app);
        return false;
    }

    error = AXObserverAddNotification(app->observer, app->app, kAXCreatedNotification, app);
    if (error != kAXErrorSuccess && error != kAXErrorNotificationAlreadyRegistered) {
        observer_clear_app(app);
        return false;
    }

    app->created_registered = true;
    error = AXObserverAddNotification(
        app->observer,
        app->app,
        kAXFocusedWindowChangedNotification,
        app);
    app->focused_window_registered =
        error == kAXErrorSuccess || error == kAXErrorNotificationAlreadyRegistered;

    CFRunLoopSourceRef source = AXObserverGetRunLoopSource(app->observer);
    if (source) {
        CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    }

    observer_observe_existing_windows(app);
    observer->app_count++;
    return true;
}

static void observer_remove_pid(kl_macos_window_observer_t *observer, pid_t pid)
{
    for (size_t i = 0; i < KL_MACOS_MAX_OBSERVED_APPS; i++) {
        if (observer->apps[i].pid != pid) {
            continue;
        }

        observer_clear_app(&observer->apps[i]);
        if (observer->app_count > 0) {
            observer->app_count--;
        }
        return;
    }
}

static pid_t notification_pid(NSNotification *notification)
{
    NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
    if (!application) {
        return 0;
    }

    return [application processIdentifier];
}

kl_macos_window_observer_t *kl_macos_window_observer_create(void)
{
    return calloc(1, sizeof(kl_macos_window_observer_t));
}

bool kl_macos_window_observer_start(
    kl_macos_window_observer_t *observer,
    pid_t only_pid,
    kl_macos_window_observer_callback_t callback,
    void *context)
{
    if (!observer) {
        return false;
    }

    observer->only_pid = only_pid;
    observer->callback = callback;
    observer->context = context;

    if (only_pid > 0) {
        if (!observer_add_pid(observer, only_pid)) {
            return false;
        }
    } else {
        for (NSRunningApplication *application in [[NSWorkspace sharedWorkspace] runningApplications]) {
            observer_add_pid(observer, [application processIdentifier]);
        }
    }

    NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
    id launch_token = [center addObserverForName:NSWorkspaceDidLaunchApplicationNotification
                                          object:nil
                                           queue:[NSOperationQueue mainQueue]
                                      usingBlock:^(NSNotification *notification) {
        pid_t pid = notification_pid(notification);
        if (observer_add_pid(observer, pid)) {
            observer_notify(observer, pid, NULL, 0, "app-launched");
        }
    }];

    id terminate_token = [center addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                                            object:nil
                                             queue:[NSOperationQueue mainQueue]
                                        usingBlock:^(NSNotification *notification) {
        pid_t pid = notification_pid(notification);
        observer_remove_pid(observer, pid);
        observer_notify(observer, pid, NULL, 0, "app-terminated");
    }];

    observer->launch_token = (__bridge_retained void *) launch_token;
    observer->terminate_token = (__bridge_retained void *) terminate_token;
    return true;
}

void kl_macos_window_observer_destroy(kl_macos_window_observer_t *observer)
{
    if (!observer) {
        return;
    }

    NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
    if (observer->launch_token) {
        id token = (__bridge_transfer id) observer->launch_token;
        [center removeObserver:token];
        observer->launch_token = NULL;
    }
    if (observer->terminate_token) {
        id token = (__bridge_transfer id) observer->terminate_token;
        [center removeObserver:token];
        observer->terminate_token = NULL;
    }

    for (size_t i = 0; i < KL_MACOS_MAX_OBSERVED_APPS; i++) {
        if (observer->apps[i].pid != 0) {
            observer_clear_app(&observer->apps[i]);
        }
    }
    observer->app_count = 0;

    free(observer);
}
