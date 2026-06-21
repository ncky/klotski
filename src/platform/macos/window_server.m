#include "platform/macos/window_server.h"

#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

extern AXError _AXUIElementGetWindow(AXUIElementRef ref, uint32_t *wid) __attribute__((weak_import));

static const CFStringRef kl_ax_fullscreen_attribute = CFSTR("AXFullScreen");

typedef int (*sls_main_connection_id_fn)(void);
typedef int (*sls_move_window_fn)(int cid, uint32_t wid, CGPoint *point);
typedef int (*sls_move_window_with_group_fn)(int cid, uint32_t wid, CGPoint *point);
typedef int (*sls_reassociate_windows_spaces_by_geometry_fn)(int cid, CFArrayRef window_list);
typedef int (*sls_set_window_alpha_fn)(int cid, uint32_t wid, float alpha);
typedef int (*sls_disable_update_fn)(int cid);
typedef int (*sls_reenable_update_fn)(int cid);

typedef struct sls_api {
    bool initialized;
    bool available;
    bool verified;
    sls_main_connection_id_fn main_connection_id;
    sls_move_window_fn move_window;
    sls_move_window_with_group_fn move_window_with_group;
    sls_reassociate_windows_spaces_by_geometry_fn reassociate_windows_spaces_by_geometry;
    sls_set_window_alpha_fn set_window_alpha;
    sls_disable_update_fn disable_update;
    sls_reenable_update_fn reenable_update;
} sls_api_t;

static size_t sls_update_disable_depth;

static bool dictionary_get_number(CFDictionaryRef dictionary, CFStringRef key, int64_t *out)
{
    CFNumberRef value = CFDictionaryGetValue(dictionary, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return false;
    }

    return CFNumberGetValue(value, kCFNumberSInt64Type, out);
}

static bool dictionary_get_rect(CFDictionaryRef dictionary, CFStringRef key, kl_rect_t *out)
{
    CFDictionaryRef bounds = CFDictionaryGetValue(dictionary, key);
    if (!bounds || CFGetTypeID(bounds) != CFDictionaryGetTypeID()) {
        return false;
    }

    CGRect rect;
    if (!CGRectMakeWithDictionaryRepresentation(bounds, &rect)) {
        return false;
    }

    *out = (kl_rect_t) {
        .x = rect.origin.x,
        .y = rect.origin.y,
        .width = rect.size.width,
        .height = rect.size.height,
    };
    return true;
}

static bool rect_contains_point(kl_rect_t rect, kl_point_t point)
{
    return point.x >= rect.x &&
           point.x < rect.x + rect.width &&
           point.y >= rect.y &&
           point.y < rect.y + rect.height;
}

static bool rect_origin_close(kl_rect_t a, kl_rect_t b)
{
    return fabs(a.x - b.x) <= 1.0 && fabs(a.y - b.y) <= 1.0;
}

static bool copy_cg_window_frame(uint32_t window_id, kl_rect_t *out)
{
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionIncludingWindow,
        window_id);
    if (!windows) {
        return false;
    }

    bool found = false;
    if (CFArrayGetCount(windows) > 0) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(windows, 0);
        int64_t found_id = 0;
        if (dictionary_get_number(info, kCGWindowNumber, &found_id) &&
            (uint32_t) found_id == window_id &&
            dictionary_get_rect(info, kCGWindowBounds, out)) {
            found = true;
        }
    }

    CFRelease(windows);
    return found;
}

static bool cg_window_reaches_frame(uint32_t window_id, kl_rect_t frame)
{
    for (size_t attempt = 0; attempt < 8; attempt++) {
        kl_rect_t actual;
        if (copy_cg_window_frame(window_id, &actual) && rect_origin_close(actual, frame)) {
            return true;
        }
        usleep(1000);
    }

    return false;
}

static bool sls_move_disabled(void)
{
    const char *value = getenv("KLOTSKI_DISABLE_SLS_MOVE");
    return value && *value != '\0' && strcmp(value, "0") != 0;
}

static bool sls_move_trusted_without_verification(void)
{
    const char *value = getenv("KLOTSKI_TRUST_SLS_MOVE");
    return value && *value != '\0' && strcmp(value, "0") != 0;
}

static bool sls_updates_are_disabled(void)
{
    return sls_update_disable_depth > 0;
}

static bool sls_reassociate_enabled(void)
{
    const char *value = getenv("KLOTSKI_SLS_REASSOCIATE");
    return value && *value != '\0' && strcmp(value, "0") != 0;
}

static bool sls_alpha_disabled(void)
{
    const char *value = getenv("KLOTSKI_DISABLE_SLS_ALPHA");
    return value && *value != '\0' && strcmp(value, "0") != 0;
}

static sls_api_t *sls_api(void)
{
    static sls_api_t api;
    if (api.initialized) {
        return &api;
    }

    api.initialized = true;

    void *handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY | RTLD_LOCAL);
    if (!handle) {
        return &api;
    }

    api.main_connection_id = (sls_main_connection_id_fn) dlsym(handle, "SLSMainConnectionID");
    api.move_window = (sls_move_window_fn) dlsym(handle, "SLSMoveWindow");
    api.move_window_with_group =
        (sls_move_window_with_group_fn) dlsym(handle, "SLSMoveWindowWithGroup");
    api.reassociate_windows_spaces_by_geometry =
        (sls_reassociate_windows_spaces_by_geometry_fn) dlsym(
            handle,
            "SLSReassociateWindowsSpacesByGeometry");
    api.set_window_alpha = (sls_set_window_alpha_fn) dlsym(handle, "SLSSetWindowAlpha");
    api.disable_update = (sls_disable_update_fn) dlsym(handle, "SLSDisableUpdate");
    api.reenable_update = (sls_reenable_update_fn) dlsym(handle, "SLSReenableUpdate");
    api.available = !sls_move_disabled() &&
        api.main_connection_id &&
        (api.move_window || api.move_window_with_group);
    return &api;
}

static bool set_window_alpha_with_sls(uint32_t window_id, float alpha)
{
    if (sls_alpha_disabled()) {
        return false;
    }

    sls_api_t *api = sls_api();
    if (!api->main_connection_id || !api->set_window_alpha) {
        return false;
    }

    return api->set_window_alpha(api->main_connection_id(), window_id, alpha) == 0;
}

static bool move_window_with_sls(uint32_t window_id, kl_rect_t frame)
{
    sls_api_t *api = sls_api();
    if (!api->available) {
        return false;
    }

    if (!api->verified &&
        sls_updates_are_disabled() &&
        !sls_move_trusted_without_verification()) {
        return false;
    }

    int cid = api->main_connection_id();
    CGPoint point = CGPointMake(frame.x, frame.y);
    bool used_group_move = !api->move_window;
    int move_error = api->move_window
        ? api->move_window(cid, window_id, &point)
        : api->move_window_with_group(cid, window_id, &point);
    if (move_error != 0) {
        return false;
    }

    if (used_group_move &&
        api->reassociate_windows_spaces_by_geometry &&
        sls_reassociate_enabled()) {
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &window_id);
        if (number) {
            const void *values[] = {number};
            CFArrayRef windows = CFArrayCreate(kCFAllocatorDefault, values, 1, &kCFTypeArrayCallBacks);
            if (windows) {
                api->reassociate_windows_spaces_by_geometry(cid, windows);
                CFRelease(windows);
            }
            CFRelease(number);
        }
    }

    if (!api->verified) {
        if (!sls_move_trusted_without_verification() &&
            !sls_updates_are_disabled() &&
            !cg_window_reaches_frame(window_id, frame)) {
            api->available = false;
            fprintf(stderr, "SLS move did not update CG frame; falling back to AX window movement.\n");
            return false;
        }
        api->verified = true;
    }

    return true;
}

static AXUIElementRef copy_ax_window(pid_t pid, uint32_t window_id)
{
    if (!_AXUIElementGetWindow) {
        return NULL;
    }

    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) {
        return NULL;
    }

    CFArrayRef windows = NULL;
    AXError error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *) &windows);
    CFRelease(app);

    if (error != kAXErrorSuccess || !windows) {
        return NULL;
    }

    AXUIElementRef match = NULL;
    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef candidate = (AXUIElementRef) CFArrayGetValueAtIndex(windows, i);
        uint32_t candidate_id = 0;

        if (_AXUIElementGetWindow(candidate, &candidate_id) == kAXErrorSuccess &&
            candidate_id == window_id) {
            match = (AXUIElementRef) CFRetain(candidate);
            break;
        }
    }

    CFRelease(windows);
    return match;
}

static void copy_cfstring_to_buffer(CFStringRef value, char *buffer, size_t buffer_size)
{
    if (!buffer || buffer_size == 0) {
        return;
    }

    buffer[0] = '\0';
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return;
    }

    CFStringGetCString(value, buffer, buffer_size, kCFStringEncodingUTF8);
}

static void copy_nsstring_to_buffer(NSString *value, char *buffer, size_t buffer_size)
{
    if (!buffer || buffer_size == 0) {
        return;
    }

    buffer[0] = '\0';
    if (!value) {
        return;
    }

    snprintf(buffer, buffer_size, "%s", [value UTF8String]);
}

static bool copy_ax_window_frame(AXUIElementRef ax_window, kl_rect_t *out)
{
    CFTypeRef position_value = NULL;
    CFTypeRef size_value = NULL;
    CGPoint position = CGPointZero;
    CGSize size = CGSizeZero;

    AXError position_error =
        AXUIElementCopyAttributeValue(ax_window, kAXPositionAttribute, &position_value);
    AXError size_error =
        AXUIElementCopyAttributeValue(ax_window, kAXSizeAttribute, &size_value);

    bool ok =
        position_error == kAXErrorSuccess &&
        size_error == kAXErrorSuccess &&
        position_value &&
        size_value &&
        AXValueGetValue((AXValueRef) position_value, kAXValueCGPointType, &position) &&
        AXValueGetValue((AXValueRef) size_value, kAXValueCGSizeType, &size);

    if (position_value) {
        CFRelease(position_value);
    }
    if (size_value) {
        CFRelease(size_value);
    }

    if (!ok) {
        return false;
    }

    *out = (kl_rect_t) {
        .x = position.x,
        .y = position.y,
        .width = size.width,
        .height = size.height,
    };
    return true;
}

static void copy_window_hints_from_ax_window(AXUIElementRef ax_window, kl_macos_window_hints_t *out)
{
    memset(out, 0, sizeof(*out));

    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(ax_window, kl_ax_fullscreen_attribute, &value) == kAXErrorSuccess &&
        value) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            out->fullscreen_known = true;
            out->fullscreen = CFBooleanGetValue(value);
        }
        CFRelease(value);
        value = NULL;
    }

    if (AXUIElementCopyAttributeValue(ax_window, kAXRoleAttribute, &value) == kAXErrorSuccess && value) {
        copy_cfstring_to_buffer((CFStringRef) value, out->role, sizeof(out->role));
        CFRelease(value);
        value = NULL;
    }

    if (AXUIElementCopyAttributeValue(ax_window, kAXSubroleAttribute, &value) == kAXErrorSuccess && value) {
        copy_cfstring_to_buffer((CFStringRef) value, out->subrole, sizeof(out->subrole));
        CFRelease(value);
    }
}

static void copy_app_hints(pid_t pid, kl_macos_window_hints_t *out)
{
    NSRunningApplication *application =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!application) {
        return;
    }

    copy_nsstring_to_buffer([application bundleIdentifier], out->app_id, sizeof(out->app_id));
    copy_nsstring_to_buffer([application localizedName], out->app_name, sizeof(out->app_name));
}

static bool rect_nearly_equal(kl_rect_t a, kl_rect_t b)
{
    return fabs(a.x - b.x) <= 0.5 &&
           fabs(a.y - b.y) <= 0.5 &&
           fabs(a.width - b.width) <= 0.5 &&
           fabs(a.height - b.height) <= 0.5;
}

static bool rect_size_nearly_equal(kl_rect_t a, kl_rect_t b)
{
    return fabs(a.width - b.width) <= 0.5 &&
           fabs(a.height - b.height) <= 0.5;
}

static bool rect_origin_nearly_equal(kl_rect_t a, kl_rect_t b)
{
    return rect_origin_close(a, b);
}

static bool ensure_cache_entry_ax_window(kl_macos_window_frame_cache_entry_t *entry);

static bool set_ax_window_frame_attributes(
    AXUIElementRef ax_window,
    kl_rect_t frame,
    bool set_size,
    bool set_origin)
{
    AXError size_error = kAXErrorSuccess;
    AXError origin_error = kAXErrorSuccess;

    if (set_size) {
        CGSize size = CGSizeMake(frame.width, frame.height);
        AXValueRef size_value = AXValueCreate(kAXValueCGSizeType, &size);
        if (!size_value) {
            return false;
        }
        size_error = AXUIElementSetAttributeValue(ax_window, kAXSizeAttribute, size_value);
        CFRelease(size_value);
    }

    if (set_origin) {
        CGPoint origin = CGPointMake(frame.x, frame.y);
        AXValueRef origin_value = AXValueCreate(kAXValueCGPointType, &origin);
        if (!origin_value) {
            return false;
        }
        origin_error = AXUIElementSetAttributeValue(ax_window, kAXPositionAttribute, origin_value);
        CFRelease(origin_value);
    }

    return size_error == kAXErrorSuccess && origin_error == kAXErrorSuccess;
}

static void cache_entry_drop_ax_window(kl_macos_window_frame_cache_entry_t *entry)
{
    if (entry->ax_window) {
        CFRelease(entry->ax_window);
        entry->ax_window = NULL;
    }
    entry->has_last_frame = false;
}

static bool cache_entry_restore_visible_frame(kl_macos_window_frame_cache_entry_t *entry)
{
    if (!entry->has_last_visible_frame) {
        return true;
    }

    if (!ensure_cache_entry_ax_window(entry)) {
        return false;
    }

    if (!set_ax_window_frame_attributes(entry->ax_window, entry->last_visible_frame, true, true)) {
        cache_entry_drop_ax_window(entry);
        return false;
    }

    entry->last_frame = entry->last_visible_frame;
    entry->has_last_frame = true;
    return true;
}

static bool cache_entry_restore_hidden(kl_macos_window_frame_cache_entry_t *entry)
{
    if (!entry->has_hidden_state || !entry->hidden) {
        return true;
    }

    cache_entry_restore_visible_frame(entry);
    if (!set_window_alpha_with_sls(entry->window_id, 1.0f)) {
        return false;
    }

    entry->hidden = false;
    return true;
}

static void release_cache_entry(kl_macos_window_frame_cache_entry_t *entry)
{
    if (entry->has_hidden_state && entry->hidden) {
        cache_entry_restore_hidden(entry);
    }
    if (entry->ax_window) {
        CFRelease(entry->ax_window);
    }
    memset(entry, 0, sizeof(*entry));
}

static void remove_cache_entry(kl_macos_window_frame_cache_t *cache, size_t index)
{
    release_cache_entry(&cache->entries[index]);

    if (index + 1 < cache->count) {
        memmove(
            &cache->entries[index],
            &cache->entries[index + 1],
            (cache->count - index - 1) * sizeof(cache->entries[0]));
    }

    cache->count--;
}

static kl_macos_window_frame_cache_entry_t *find_cache_entry(
    kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window)
{
    for (size_t i = 0; i < cache->count; i++) {
        kl_macos_window_frame_cache_entry_t *entry = &cache->entries[i];
        if (entry->window_id == window->window_id && entry->pid == window->pid) {
            return entry;
        }
    }

    return NULL;
}

static bool ensure_cache_entry_ax_window(kl_macos_window_frame_cache_entry_t *entry)
{
    if (entry->ax_window) {
        return true;
    }

    entry->ax_window = copy_ax_window(entry->pid, entry->window_id);
    return entry->ax_window != NULL;
}

static const kl_macos_window_frame_cache_entry_t *find_cache_entry_const(
    const kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window)
{
    for (size_t i = 0; i < cache->count; i++) {
        const kl_macos_window_frame_cache_entry_t *entry = &cache->entries[i];
        if (entry->window_id == window->window_id && entry->pid == window->pid) {
            return entry;
        }
    }

    return NULL;
}

static bool window_is_live(const kl_macos_window_list_t *list, const kl_macos_window_frame_cache_entry_t *entry)
{
    for (size_t i = 0; i < list->count; i++) {
        if (list->windows[i].window_id == entry->window_id &&
            list->windows[i].pid == entry->pid) {
            return true;
        }
    }

    return false;
}

static bool window_id_is_listed(const uint32_t *window_ids, size_t count, uint32_t window_id)
{
    for (size_t i = 0; i < count; i++) {
        if (window_ids[i] == window_id) {
            return true;
        }
    }

    return false;
}

bool kl_macos_copy_window_list(kl_macos_window_list_t *out, pid_t only_pid)
{
    out->count = 0;

    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);

    if (!windows) {
        return false;
    }

    pid_t own_pid = getpid();
    CFIndex count = CFArrayGetCount(windows);

    for (CFIndex i = 0; i < count && out->count < KL_MACOS_MAX_WINDOWS; i++) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(windows, i);

        int64_t layer = 0;
        int64_t owner_pid = 0;
        int64_t window_id = 0;
        kl_rect_t frame;

        if (!dictionary_get_number(info, kCGWindowLayer, &layer) ||
            !dictionary_get_number(info, kCGWindowOwnerPID, &owner_pid) ||
            !dictionary_get_number(info, kCGWindowNumber, &window_id) ||
            !dictionary_get_rect(info, kCGWindowBounds, &frame)) {
            continue;
        }

        if (layer != 0 ||
            owner_pid == own_pid ||
            (only_pid > 0 && owner_pid != only_pid) ||
            frame.width <= 1.0 ||
            frame.height <= 1.0) {
            continue;
        }

        out->windows[out->count++] = (kl_macos_window_t) {
            .window_id = (uint32_t) window_id,
            .pid = (pid_t) owner_pid,
            .frame = frame,
        };
    }

    CFRelease(windows);
    return true;
}

bool kl_macos_find_window(const kl_macos_window_list_t *list, uint32_t window_id, kl_macos_window_t *out)
{
    for (size_t i = 0; i < list->count; i++) {
        if (list->windows[i].window_id == window_id) {
            if (out) {
                *out = list->windows[i];
            }
            return true;
        }
    }

    return false;
}

bool kl_macos_copy_window_hints(const kl_macos_window_t *window, kl_macos_window_hints_t *out)
{
    memset(out, 0, sizeof(*out));

    AXUIElementRef ax_window = copy_ax_window(window->pid, window->window_id);
    if (!ax_window) {
        return false;
    }

    copy_window_hints_from_ax_window(ax_window, out);
    copy_app_hints(window->pid, out);
    CFRelease(ax_window);
    return true;
}

bool kl_macos_copy_window_from_ax_element(
    pid_t pid,
    AXUIElementRef ax_window,
    kl_macos_window_t *out,
    kl_macos_window_hints_t *hints)
{
    if (!_AXUIElementGetWindow || !ax_window) {
        return false;
    }

    uint32_t window_id = 0;
    if (_AXUIElementGetWindow(ax_window, &window_id) != kAXErrorSuccess || window_id == 0) {
        return false;
    }

    kl_rect_t frame = {0};
    if (!copy_ax_window_frame(ax_window, &frame) ||
        frame.width <= 1.0 ||
        frame.height <= 1.0) {
        return false;
    }
    *out = (kl_macos_window_t) {
        .window_id = window_id,
        .pid = pid,
        .frame = frame,
    };

    if (hints) {
        copy_window_hints_from_ax_window(ax_window, hints);
        copy_app_hints(pid, hints);
    }

    return true;
}

bool kl_macos_copy_window_identity_from_ax_element(
    pid_t pid,
    AXUIElementRef ax_window,
    kl_macos_window_t *out)
{
    if (!_AXUIElementGetWindow || !ax_window) {
        return false;
    }

    uint32_t window_id = 0;
    if (_AXUIElementGetWindow(ax_window, &window_id) != kAXErrorSuccess || window_id == 0) {
        return false;
    }

    *out = (kl_macos_window_t) {
        .window_id = window_id,
        .pid = pid,
        .frame = {0},
    };
    return true;
}

bool kl_macos_window_at_point(kl_point_t point, pid_t only_pid, kl_macos_window_t *out)
{
    kl_macos_window_list_t list;
    if (!kl_macos_copy_window_list(&list, only_pid)) {
        return false;
    }

    for (size_t i = 0; i < list.count; i++) {
        if (rect_contains_point(list.windows[i].frame, point)) {
            if (out) {
                *out = list.windows[i];
            }
            return true;
        }
    }

    return false;
}

bool kl_macos_focus_window(const kl_macos_window_t *window)
{
    NSRunningApplication *application =
        [NSRunningApplication runningApplicationWithProcessIdentifier:window->pid];
    [application activateWithOptions:NSApplicationActivateAllWindows];

    AXUIElementRef ax_window = copy_ax_window(window->pid, window->window_id);
    if (!ax_window) {
        return false;
    }

    AXUIElementPerformAction(ax_window, kAXRaiseAction);
    CFRelease(ax_window);
    return true;
}

bool kl_macos_set_window_frame(const kl_macos_window_t *window, kl_rect_t frame)
{
    AXUIElementRef ax_window = copy_ax_window(window->pid, window->window_id);
    if (!ax_window) {
        return false;
    }

    bool ok = set_ax_window_frame_attributes(ax_window, frame, true, true);
    CFRelease(ax_window);
    return ok;
}

bool kl_macos_copy_window_frame(const kl_macos_window_t *window, kl_rect_t *out)
{
    if (!window || !out) {
        return false;
    }

    if (copy_cg_window_frame(window->window_id, out)) {
        return true;
    }

    AXUIElementRef ax_window = copy_ax_window(window->pid, window->window_id);
    if (!ax_window) {
        return false;
    }

    bool ok = copy_ax_window_frame(ax_window, out);
    CFRelease(ax_window);
    return ok;
}

bool kl_macos_begin_frame_updates(void)
{
    sls_api_t *api = sls_api();
    if (!api->main_connection_id || !api->disable_update || !api->reenable_update) {
        return false;
    }

    if (api->disable_update(api->main_connection_id()) != 0) {
        return false;
    }

    sls_update_disable_depth++;
    return true;
}

void kl_macos_end_frame_updates(bool active)
{
    if (!active) {
        return;
    }

    sls_api_t *api = sls_api();
    if (api->main_connection_id && api->reenable_update) {
        api->reenable_update(api->main_connection_id());
    }
    if (sls_update_disable_depth > 0) {
        sls_update_disable_depth--;
    }
}

void kl_macos_window_frame_cache_init(kl_macos_window_frame_cache_t *cache)
{
    memset(cache, 0, sizeof(*cache));
}

void kl_macos_window_frame_cache_destroy(kl_macos_window_frame_cache_t *cache)
{
    for (size_t i = 0; i < cache->count; i++) {
        release_cache_entry(&cache->entries[i]);
    }
    cache->count = 0;
}

void kl_macos_window_frame_cache_prune(
    kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_list_t *live_windows)
{
    size_t i = 0;
    while (i < cache->count) {
        if (window_is_live(live_windows, &cache->entries[i])) {
            i++;
        } else {
            remove_cache_entry(cache, i);
        }
    }
}

void kl_macos_window_frame_cache_forget(
    kl_macos_window_frame_cache_t *cache,
    uint32_t window_id)
{
    for (size_t i = 0; i < cache->count; i++) {
        if (cache->entries[i].window_id == window_id) {
            remove_cache_entry(cache, i);
            return;
        }
    }
}

bool kl_macos_window_frame_cache_needs_frame(
    const kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window,
    kl_rect_t frame)
{
    const kl_macos_window_frame_cache_entry_t *entry = find_cache_entry_const(cache, window);
    return !entry || !entry->has_last_frame || !rect_nearly_equal(entry->last_frame, frame);
}

bool kl_macos_window_frame_cache_matches_width(
    const kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window,
    kl_rect_t frame)
{
    const kl_macos_window_frame_cache_entry_t *entry = find_cache_entry_const(cache, window);
    return entry && entry->has_last_frame && fabs(entry->last_frame.width - frame.width) <= 0.5;
}

bool kl_macos_window_frame_cache_set_hidden(
    kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window,
    bool hidden)
{
    kl_macos_window_frame_cache_entry_t *entry = find_cache_entry(cache, window);
    if (!entry) {
        if (cache->count == KL_MACOS_MAX_WINDOWS) {
            return !hidden;
        }

        entry = &cache->entries[cache->count++];
        *entry = (kl_macos_window_frame_cache_entry_t) {
            .window_id = window->window_id,
            .pid = window->pid,
        };
    }

    if (entry->has_hidden_state && entry->hidden == hidden && !hidden) {
        return true;
    }

    if (!set_window_alpha_with_sls(window->window_id, hidden ? 0.0f : 1.0f)) {
        return !hidden;
    }

    entry->hidden = hidden;
    entry->has_hidden_state = true;
    return true;
}

size_t kl_macos_window_frame_cache_restore_hidden_except(
    kl_macos_window_frame_cache_t *cache,
    const uint32_t *window_ids,
    size_t window_id_count,
    size_t *failed)
{
    size_t restored = 0;
    size_t failed_count = 0;

    for (size_t i = 0; i < cache->count; i++) {
        kl_macos_window_frame_cache_entry_t *entry = &cache->entries[i];
        if (!entry->has_hidden_state ||
            !entry->hidden ||
            window_id_is_listed(window_ids, window_id_count, entry->window_id)) {
            continue;
        }

        if (cache_entry_restore_hidden(entry)) {
            restored++;
        } else {
            failed_count++;
        }
    }

    if (failed) {
        *failed = failed_count;
    }

    return restored;
}

void kl_macos_window_frame_cache_remember_ax_window(
    kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window,
    AXUIElementRef ax_window)
{
    if (!ax_window) {
        return;
    }

    kl_macos_window_frame_cache_entry_t *entry = find_cache_entry(cache, window);
    if (!entry) {
        if (cache->count == KL_MACOS_MAX_WINDOWS) {
            return;
        }

        entry = &cache->entries[cache->count++];
        *entry = (kl_macos_window_frame_cache_entry_t) {
            .window_id = window->window_id,
            .pid = window->pid,
        };
    }

    if (entry->ax_window != ax_window) {
        if (entry->ax_window) {
            CFRelease(entry->ax_window);
        }
        entry->ax_window = (AXUIElementRef) CFRetain(ax_window);
    }
}

void kl_macos_window_frame_cache_note_frame(
    kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window,
    kl_rect_t frame)
{
    kl_macos_window_frame_cache_entry_t *entry = find_cache_entry(cache, window);
    if (!entry) {
        if (cache->count == KL_MACOS_MAX_WINDOWS) {
            return;
        }

        entry = &cache->entries[cache->count++];
        *entry = (kl_macos_window_frame_cache_entry_t) {
            .window_id = window->window_id,
            .pid = window->pid,
        };
    }

    entry->last_frame = frame;
    entry->has_last_frame = true;
    if (!entry->has_hidden_state || !entry->hidden) {
        entry->last_visible_frame = frame;
        entry->has_last_visible_frame = true;
    }
}

bool kl_macos_set_window_frame_cached(
    kl_macos_window_frame_cache_t *cache,
    const kl_macos_window_t *window,
    kl_rect_t frame,
    bool *wrote_frame)
{
    if (wrote_frame) {
        *wrote_frame = false;
    }

    kl_macos_window_frame_cache_entry_t *entry = find_cache_entry(cache, window);
    if (!entry) {
        if (cache->count == KL_MACOS_MAX_WINDOWS) {
            if (wrote_frame) {
                *wrote_frame = true;
            }
            return kl_macos_set_window_frame(window, frame);
        }

        entry = &cache->entries[cache->count++];
        *entry = (kl_macos_window_frame_cache_entry_t) {
            .window_id = window->window_id,
            .pid = window->pid,
        };
    }

    if (entry->has_last_frame && rect_nearly_equal(entry->last_frame, frame)) {
        if (!entry->has_hidden_state || !entry->hidden) {
            entry->last_visible_frame = frame;
            entry->has_last_visible_frame = true;
        }
        return true;
    }

    bool set_size = !entry->has_last_frame ||
        !rect_size_nearly_equal(entry->last_frame, frame);
    bool set_origin = !entry->has_last_frame ||
        !rect_origin_nearly_equal(entry->last_frame, frame);

    for (size_t attempt = 0; attempt < 2; attempt++) {
        if (set_size) {
            if (!ensure_cache_entry_ax_window(entry)) {
                return false;
            }

            if (!set_ax_window_frame_attributes(entry->ax_window, frame, true, false)) {
                cache_entry_drop_ax_window(entry);
                continue;
            }
        }

        if (set_origin && !move_window_with_sls(entry->window_id, frame)) {
            if (!ensure_cache_entry_ax_window(entry)) {
                return false;
            }

            if (!set_ax_window_frame_attributes(entry->ax_window, frame, false, true)) {
                cache_entry_drop_ax_window(entry);
                continue;
            }
        }

        entry->last_frame = frame;
        entry->has_last_frame = true;
        if (!entry->has_hidden_state || !entry->hidden) {
            entry->last_visible_frame = frame;
            entry->has_last_visible_frame = true;
        }
        if (wrote_frame) {
            *wrote_frame = true;
        }
        return true;
    }

    return false;
}
