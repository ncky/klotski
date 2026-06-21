#import <ApplicationServices/ApplicationServices.h>

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static bool dictionary_get_number(CFDictionaryRef dictionary, CFStringRef key, int64_t *out)
{
    CFNumberRef value = CFDictionaryGetValue(dictionary, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return false;
    }

    return CFNumberGetValue(value, kCFNumberSInt64Type, out);
}

static bool dictionary_get_rect(CFDictionaryRef dictionary, CFStringRef key, CGRect *out)
{
    CFDictionaryRef bounds = CFDictionaryGetValue(dictionary, key);
    return bounds &&
        CFGetTypeID(bounds) == CFDictionaryGetTypeID() &&
        CGRectMakeWithDictionaryRepresentation(bounds, out);
}

static bool parse_pid(const char *value, pid_t *out)
{
    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed <= 0) {
        return false;
    }

    *out = (pid_t) parsed;
    return true;
}

static void usage(const char *program)
{
    fprintf(stderr, "usage: %s --pid pid\n", program);
}

int main(int argc, char **argv)
{
    pid_t only_pid = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--pid") == 0 && i + 1 < argc) {
            if (!parse_pid(argv[++i], &only_pid)) {
                usage(argv[0]);
                return 2;
            }
        } else if (strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (only_pid <= 0) {
        usage(argv[0]);
        return 2;
    }

    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!windows) {
        return 1;
    }

    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(windows, i);
        int64_t layer = 0;
        int64_t owner_pid = 0;
        int64_t window_id = 0;
        CGRect frame;

        if (!dictionary_get_number(info, kCGWindowLayer, &layer) ||
            !dictionary_get_number(info, kCGWindowOwnerPID, &owner_pid) ||
            !dictionary_get_number(info, kCGWindowNumber, &window_id) ||
            !dictionary_get_rect(info, kCGWindowBounds, &frame)) {
            continue;
        }

        if (layer != 0 || owner_pid != only_pid || frame.size.width <= 1.0 || frame.size.height <= 1.0) {
            continue;
        }

        printf(
            "%lld %.3f %.3f %.3f %.3f\n",
            window_id,
            frame.origin.x,
            frame.origin.y,
            frame.size.width,
            frame.size.height);
    }

    CFRelease(windows);
    return 0;
}
