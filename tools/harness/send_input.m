#import <ApplicationServices/ApplicationServices.h>

#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
    KL_SEND_KEY_F = 3,
    KL_SEND_KEY_W = 13,
    KL_SEND_KEY_BRACKET_RIGHT = 30,
    KL_SEND_KEY_BRACKET_LEFT = 33,
    KL_SEND_KEY_LEFT = 123,
    KL_SEND_KEY_RIGHT = 124,
};

typedef struct options {
    int scroll_events;
    double delta;
    int delay_ms;
    bool horizontal;
    bool move_mouse;
    bool drag_mouse;
    bool right_drag_mouse;
    bool key_event;
    bool key_shift;
    double mouse_x;
    double mouse_y;
    double drag_from_x;
    double drag_from_y;
    double drag_to_x;
    double drag_to_y;
    int drag_steps;
    int keycode;
} options_t;

static void usage(const char *program)
{
    fprintf(
        stderr,
        "usage: %s [--scroll-events n] [--delta value] [--delay-ms n] [--axis horizontal|vertical] [--move-to x y] [--alt-drag x1 y1 x2 y2] [--alt-right-drag x1 y1 x2 y2] [--drag-steps n] [--alt-key f|w|left|right|bracket-left|bracket-right] [--alt-shift-key left|right]\n",
        program);
}

static bool parse_int(const char *value, int *out)
{
    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed < 0 || parsed > 1000000) {
        return false;
    }

    *out = (int) parsed;
    return true;
}

static bool parse_double(const char *value, double *out)
{
    char *end = NULL;
    double parsed = strtod(value, &end);
    if (end == value || *end != '\0' || !isfinite(parsed)) {
        return false;
    }

    *out = parsed;
    return true;
}

static bool parse_options(int argc, char **argv, options_t *options)
{
    *options = (options_t) {
        .scroll_events = 160,
        .delta = 3.0,
        .delay_ms = 4,
        .horizontal = true,
        .move_mouse = false,
        .drag_mouse = false,
        .right_drag_mouse = false,
        .key_event = false,
        .key_shift = false,
        .mouse_x = 0.0,
        .mouse_y = 0.0,
        .drag_from_x = 0.0,
        .drag_from_y = 0.0,
        .drag_to_x = 0.0,
        .drag_to_y = 0.0,
        .drag_steps = 24,
        .keycode = 0,
    };

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--scroll-events") == 0 && i + 1 < argc) {
            if (!parse_int(argv[++i], &options->scroll_events)) {
                return false;
            }
        } else if (strcmp(argv[i], "--delta") == 0 && i + 1 < argc) {
            if (!parse_double(argv[++i], &options->delta)) {
                return false;
            }
        } else if (strcmp(argv[i], "--delay-ms") == 0 && i + 1 < argc) {
            if (!parse_int(argv[++i], &options->delay_ms)) {
                return false;
            }
        } else if (strcmp(argv[i], "--axis") == 0 && i + 1 < argc) {
            const char *axis = argv[++i];
            if (strcmp(axis, "horizontal") == 0) {
                options->horizontal = true;
            } else if (strcmp(axis, "vertical") == 0) {
                options->horizontal = false;
            } else {
                return false;
            }
        } else if (strcmp(argv[i], "--move-to") == 0 && i + 2 < argc) {
            if (!parse_double(argv[++i], &options->mouse_x) ||
                !parse_double(argv[++i], &options->mouse_y)) {
                return false;
            }
            options->move_mouse = true;
        } else if (strcmp(argv[i], "--alt-drag") == 0 && i + 4 < argc) {
            if (!parse_double(argv[++i], &options->drag_from_x) ||
                !parse_double(argv[++i], &options->drag_from_y) ||
                !parse_double(argv[++i], &options->drag_to_x) ||
                !parse_double(argv[++i], &options->drag_to_y)) {
                return false;
            }
            options->drag_mouse = true;
            options->right_drag_mouse = false;
        } else if (strcmp(argv[i], "--alt-right-drag") == 0 && i + 4 < argc) {
            if (!parse_double(argv[++i], &options->drag_from_x) ||
                !parse_double(argv[++i], &options->drag_from_y) ||
                !parse_double(argv[++i], &options->drag_to_x) ||
                !parse_double(argv[++i], &options->drag_to_y)) {
                return false;
            }
            options->drag_mouse = true;
            options->right_drag_mouse = true;
        } else if (strcmp(argv[i], "--drag-steps") == 0 && i + 1 < argc) {
            if (!parse_int(argv[++i], &options->drag_steps) || options->drag_steps < 1) {
                return false;
            }
        } else if (strcmp(argv[i], "--alt-key") == 0 && i + 1 < argc) {
            const char *key = argv[++i];
            if (strcmp(key, "f") == 0) {
                options->keycode = KL_SEND_KEY_F;
            } else if (strcmp(key, "w") == 0) {
                options->keycode = KL_SEND_KEY_W;
            } else if (strcmp(key, "bracket-left") == 0 || strcmp(key, "[") == 0) {
                options->keycode = KL_SEND_KEY_BRACKET_LEFT;
            } else if (strcmp(key, "bracket-right") == 0 || strcmp(key, "]") == 0) {
                options->keycode = KL_SEND_KEY_BRACKET_RIGHT;
            } else if (strcmp(key, "left") == 0) {
                options->keycode = KL_SEND_KEY_LEFT;
            } else if (strcmp(key, "right") == 0) {
                options->keycode = KL_SEND_KEY_RIGHT;
            } else {
                return false;
            }
            options->key_event = true;
            options->key_shift = false;
        } else if (strcmp(argv[i], "--alt-shift-key") == 0 && i + 1 < argc) {
            const char *key = argv[++i];
            if (strcmp(key, "left") == 0) {
                options->keycode = KL_SEND_KEY_LEFT;
            } else if (strcmp(key, "right") == 0) {
                options->keycode = KL_SEND_KEY_RIGHT;
            } else {
                return false;
            }
            options->key_event = true;
            options->key_shift = true;
        } else if (strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            exit(0);
        } else {
            return false;
        }
    }

    return true;
}

static void post_mouse_move(CGEventSourceRef source, double x, double y)
{
    CGPoint point = CGPointMake(x, y);
    CGEventRef event = CGEventCreateMouseEvent(source, kCGEventMouseMoved, point, kCGMouseButtonLeft);
    if (!event) {
        return;
    }

    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void post_key_event(CGEventSourceRef source, int keycode, bool down, CGEventFlags flags)
{
    CGEventRef event = CGEventCreateKeyboardEvent(source, (CGKeyCode) keycode, down);
    if (!event) {
        return;
    }

    CGEventSetFlags(event, flags);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void post_alt_key(CGEventSourceRef source, int keycode, bool shift)
{
    CGEventFlags flags = kCGEventFlagMaskAlternate;
    if (shift) {
        flags |= kCGEventFlagMaskShift;
    }
    post_key_event(source, keycode, true, flags);
    usleep(10000);
    post_key_event(source, keycode, false, flags);
}

static void post_mouse_button_event(
    CGEventSourceRef source,
    CGEventType type,
    double x,
    double y,
    CGEventFlags flags,
    CGMouseButton button)
{
    CGPoint point = CGPointMake(x, y);
    CGEventRef event = CGEventCreateMouseEvent(source, type, point, button);
    if (!event) {
        return;
    }

    CGEventSetFlags(event, flags);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void post_alt_drag(CGEventSourceRef source, const options_t *options)
{
    CGEventFlags flags = kCGEventFlagMaskAlternate;
    CGMouseButton button = options->right_drag_mouse ? kCGMouseButtonRight : kCGMouseButtonLeft;
    CGEventType down = options->right_drag_mouse ? kCGEventRightMouseDown : kCGEventLeftMouseDown;
    CGEventType dragged = options->right_drag_mouse ? kCGEventRightMouseDragged : kCGEventLeftMouseDragged;
    CGEventType up = options->right_drag_mouse ? kCGEventRightMouseUp : kCGEventLeftMouseUp;

    post_mouse_button_event(
        source,
        down,
        options->drag_from_x,
        options->drag_from_y,
        flags,
        button);
    usleep((useconds_t) options->delay_ms * 1000);

    for (int i = 1; i <= options->drag_steps; i++) {
        double t = (double) i / (double) options->drag_steps;
        double x = options->drag_from_x + ((options->drag_to_x - options->drag_from_x) * t);
        double y = options->drag_from_y + ((options->drag_to_y - options->drag_from_y) * t);
        post_mouse_button_event(source, dragged, x, y, flags, button);
        if (options->delay_ms > 0) {
            usleep((useconds_t) options->delay_ms * 1000);
        }
    }

    post_mouse_button_event(
        source,
        up,
        options->drag_to_x,
        options->drag_to_y,
        flags,
        button);
}

static void post_scroll_event(CGEventSourceRef source, double delta, bool horizontal)
{
    CGEventRef event = CGEventCreateScrollWheelEvent(
        source,
        kCGScrollEventUnitPixel,
        2,
        horizontal ? 0 : (int32_t) lround(delta),
        horizontal ? (int32_t) lround(delta) : 0);
    if (!event) {
        return;
    }

    CGEventSetFlags(event, kCGEventFlagMaskAlternate);
    CGEventSetIntegerValueField(event, kCGScrollWheelEventIsContinuous, 1);

    if (horizontal) {
        CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2, delta);
        CGEventSetDoubleValueField(event, kCGScrollWheelEventPointDeltaAxis2, delta);
    } else {
        CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1, delta);
        CGEventSetDoubleValueField(event, kCGScrollWheelEventPointDeltaAxis1, delta);
    }

    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

int main(int argc, char **argv)
{
    options_t options;
    if (!parse_options(argc, argv, &options)) {
        usage(argv[0]);
        return 2;
    }

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!source) {
        fprintf(stderr, "failed to create CGEventSource\n");
        return 1;
    }

    if (options.key_event) {
        post_alt_key(source, options.keycode, options.key_shift);
    } else if (options.drag_mouse) {
        post_alt_drag(source, &options);
    } else if (options.move_mouse) {
        for (int i = 0; i < 3; i++) {
            post_mouse_move(source, options.mouse_x, options.mouse_y);
            usleep(10000);
        }
    } else {
        for (int i = 0; i < options.scroll_events; i++) {
            post_scroll_event(source, options.delta, options.horizontal);
            if (options.delay_ms > 0) {
                usleep((useconds_t) options.delay_ms * 1000);
            }
        }
    }

    CFRelease(source);
    return 0;
}
