#import <Cocoa/Cocoa.h>

#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>

#define KLOTSKI_HARNESS_MAX_WINDOWS 64

static volatile sig_atomic_t pending_window_creates;
static volatile sig_atomic_t pending_panel_creates;
static volatile sig_atomic_t pending_window_closes;
static volatile sig_atomic_t pending_window_minimizes;
static volatile sig_atomic_t pending_window_deminiaturizes;
static volatile sig_atomic_t pending_window_fullscreen_toggles;
static volatile sig_atomic_t pending_app_terminates;
static volatile sig_atomic_t pending_ghost_creates;
static sig_atomic_t burst_window_creates = 1;

static void handle_create_window_signal(int signum)
{
    sig_atomic_t requested = 0;
    if (signum == SIGUSR1) {
        requested = 1;
    } else if (signum == SIGUSR2) {
        requested = burst_window_creates;
    } else if (signum == SIGALRM) {
        pending_panel_creates++;
        return;
    } else if (signum == SIGHUP) {
        pending_window_closes++;
        return;
    } else if (signum == SIGWINCH) {
        pending_window_minimizes++;
        return;
    } else if (signum == SIGURG) {
        pending_window_deminiaturizes++;
        return;
    } else if (signum == SIGXCPU) {
        pending_window_fullscreen_toggles++;
        return;
    } else if (signum == SIGVTALRM) {
        pending_ghost_creates++;
        return;
    } else if (signum == SIGTERM) {
        pending_app_terminates = 1;
        return;
    }

    if (requested <= 0) {
        return;
    }

    if (pending_window_creates > KLOTSKI_HARNESS_MAX_WINDOWS - requested) {
        pending_window_creates = KLOTSKI_HARNESS_MAX_WINDOWS;
    } else {
        pending_window_creates += requested;
    }
}

static NSWindow *make_window(NSRect frame, NSString *title, NSColor *color)
{
    NSWindowStyleMask style =
        NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskResizable |
        NSWindowStyleMaskMiniaturizable;

    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:style
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:title];
    [window setReleasedWhenClosed:NO];
    [window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
    [window setBackgroundColor:color];

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 20, frame.size.width - 40, 40)];
    [label setStringValue:title];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setTextColor:[NSColor whiteColor]];
    [label setFont:[NSFont boldSystemFontOfSize:22]];
    [[window contentView] addSubview:label];

    [window makeKeyAndOrderFront:nil];
    return window;
}

static NSWindow *make_panel(NSRect frame, NSString *title, NSColor *color)
{
    NSWindowStyleMask style =
        NSWindowStyleMaskTitled |
        NSWindowStyleMaskClosable |
        NSWindowStyleMaskResizable |
        NSWindowStyleMaskUtilityWindow;

    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame
                                                styleMask:style
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    [panel setTitle:title];
    [panel setReleasedWhenClosed:NO];
    [panel setFloatingPanel:YES];
    [panel setHidesOnDeactivate:NO];
    [panel setBackgroundColor:color];

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 20, frame.size.width - 40, 40)];
    [label setStringValue:title];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setTextColor:[NSColor whiteColor]];
    [label setFont:[NSFont boldSystemFontOfSize:18]];
    [[panel contentView] addSubview:label];

    [panel makeKeyAndOrderFront:nil];
    return panel;
}

static int harness_window_count(void)
{
    const char *value = getenv("KLOTSKI_HARNESS_WINDOWS");
    if (!value || *value == '\0') {
        return 3;
    }

    char *end = NULL;
    long count = strtol(value, &end, 10);
    if (end == value || *end != '\0' || count < 1) {
        return 3;
    }

    if (count > KLOTSKI_HARNESS_MAX_WINDOWS) {
        count = KLOTSKI_HARNESS_MAX_WINDOWS;
    }

    return (int) count;
}

static int harness_burst_window_count(void)
{
    const char *value = getenv("KLOTSKI_HARNESS_BURST_WINDOWS");
    if (!value || *value == '\0') {
        return 1;
    }

    char *end = NULL;
    long count = strtol(value, &end, 10);
    if (end == value || *end != '\0' || count < 1) {
        return 1;
    }

    if (count > KLOTSKI_HARNESS_MAX_WINDOWS) {
        count = KLOTSKI_HARNESS_MAX_WINDOWS;
    }

    return (int) count;
}

static NSColor *window_color(int index)
{
    static const CGFloat colors[][3] = {
        {0.12, 0.32, 0.62},
        {0.18, 0.48, 0.30},
        {0.58, 0.22, 0.22},
        {0.40, 0.28, 0.58},
        {0.58, 0.42, 0.18},
        {0.16, 0.46, 0.48},
    };
    size_t color_count = sizeof(colors) / sizeof(colors[0]);
    const CGFloat *color = colors[(size_t) index % color_count];
    return [NSColor colorWithCalibratedRed:color[0] green:color[1] blue:color[2] alpha:1.0];
}

static NSWindow *create_indexed_window(NSMutableArray<NSWindow *> *windows, int index)
{
    double requested_at = CFAbsoluteTimeGetCurrent();
    NSString *title = [NSString stringWithFormat:@"Klotski Harness %02d", index + 1];
    NSRect frame = NSMakeRect(
        80 + ((index % 4) * 120),
        520 - ((index % 5) * 28),
        420,
        360);
    NSWindow *window = make_window(frame, title, window_color(index));
    [windows addObject:window];

    printf(
        "KLOTSKI_HARNESS_WINDOW_CREATED index=%d id=%ld kind=standard t=%.6f shown_t=%.6f\n",
        index + 1,
        (long) [window windowNumber],
        requested_at,
        CFAbsoluteTimeGetCurrent());
    fflush(stdout);
    return window;
}

static NSWindow *create_indexed_panel(NSMutableArray<NSWindow *> *windows, int index)
{
    double requested_at = CFAbsoluteTimeGetCurrent();
    NSString *title = [NSString stringWithFormat:@"Klotski Harness Panel %02d", index + 1];
    NSRect frame = NSMakeRect(
        180 + ((index % 4) * 80),
        420 - ((index % 5) * 20),
        360,
        220);
    NSWindow *window = make_panel(frame, title, window_color(index));
    [windows addObject:window];

    printf(
        "KLOTSKI_HARNESS_WINDOW_CREATED index=%d id=%ld kind=panel t=%.6f shown_t=%.6f\n",
        index + 1,
        (long) [window windowNumber],
        requested_at,
        CFAbsoluteTimeGetCurrent());
    fflush(stdout);
    return window;
}

static NSWindow *create_ghost_window(NSMutableArray<NSWindow *> *windows, int index)
{
    double requested_at = CFAbsoluteTimeGetCurrent();
    NSString *title = [NSString stringWithFormat:@"Klotski Harness Ghost %02d", index + 1];
    NSWindowStyleMask style = NSWindowStyleMaskBorderless;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 0, 0)
                                                   styleMask:style
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:title];
    [window setReleasedWhenClosed:NO];
    [window orderFront:nil];
    [windows addObject:window];

    printf(
        "KLOTSKI_HARNESS_WINDOW_CREATED index=%d id=%ld kind=ghost t=%.6f shown_t=%.6f\n",
        index + 1,
        (long) [window windowNumber],
        requested_at,
        CFAbsoluteTimeGetCurrent());
    fflush(stdout);
    return window;
}

static NSWindow *last_indexed_window(NSMutableArray<NSWindow *> *windows)
{
    return [windows count] > 0 ? [windows lastObject] : nil;
}

static void close_last_window(NSMutableArray<NSWindow *> *windows)
{
    NSWindow *window = last_indexed_window(windows);
    if (!window) {
        return;
    }

    printf(
        "KLOTSKI_HARNESS_WINDOW_CLOSE_REQUESTED id=%ld t=%.6f\n",
        (long) [window windowNumber],
        CFAbsoluteTimeGetCurrent());
    [window close];
    [windows removeLastObject];
    fflush(stdout);
}

static void minimize_last_window(NSMutableArray<NSWindow *> *windows)
{
    NSWindow *window = last_indexed_window(windows);
    if (!window) {
        return;
    }

    printf(
        "KLOTSKI_HARNESS_WINDOW_MINIMIZE_REQUESTED id=%ld t=%.6f\n",
        (long) [window windowNumber],
        CFAbsoluteTimeGetCurrent());
    [window miniaturize:nil];
    fflush(stdout);
}

static void deminiaturize_last_window(NSMutableArray<NSWindow *> *windows)
{
    NSWindow *window = last_indexed_window(windows);
    if (!window) {
        return;
    }

    printf(
        "KLOTSKI_HARNESS_WINDOW_DEMINIMIZE_REQUESTED id=%ld t=%.6f\n",
        (long) [window windowNumber],
        CFAbsoluteTimeGetCurrent());
    [window deminiaturize:nil];
    [window makeKeyAndOrderFront:nil];
    fflush(stdout);
}

static void toggle_fullscreen_last_window(NSMutableArray<NSWindow *> *windows)
{
    NSWindow *window = last_indexed_window(windows);
    if (!window) {
        return;
    }

    printf(
        "KLOTSKI_HARNESS_WINDOW_FULLSCREEN_TOGGLE_REQUESTED id=%ld t=%.6f\n",
        (long) [window windowNumber],
        CFAbsoluteTimeGetCurrent());
    [window makeKeyAndOrderFront:nil];
    [window toggleFullScreen:nil];
    fflush(stdout);
}

static void terminate_app(void)
{
    printf(
        "KLOTSKI_HARNESS_APP_TERMINATE_REQUESTED t=%.6f\n",
        CFAbsoluteTimeGetCurrent());
    fflush(stdout);
    [NSApp terminate:nil];
}

int main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        burst_window_creates = harness_burst_window_count();

        struct sigaction action = {0};
        action.sa_handler = handle_create_window_signal;
        sigemptyset(&action.sa_mask);
        sigaction(SIGUSR1, &action, NULL);
        sigaction(SIGUSR2, &action, NULL);
        sigaction(SIGALRM, &action, NULL);
        sigaction(SIGHUP, &action, NULL);
        sigaction(SIGWINCH, &action, NULL);
        sigaction(SIGURG, &action, NULL);
        sigaction(SIGXCPU, &action, NULL);
        sigaction(SIGVTALRM, &action, NULL);
        sigaction(SIGTERM, &action, NULL);

        NSMutableArray<NSWindow *> *windows = [NSMutableArray array];
        int count = harness_window_count();
        __block int next_index = count;
        for (int i = 0; i < count; i++) {
            create_indexed_window(windows, i);
        }

        printf("KLOTSKI_HARNESS_PID=%d\n", getpid());
        fflush(stdout);

        [NSTimer scheduledTimerWithTimeInterval:0.02 repeats:YES block:^(__unused NSTimer *timer) {
            while (pending_window_creates > 0 && next_index < KLOTSKI_HARNESS_MAX_WINDOWS) {
                pending_window_creates--;
                create_indexed_window(windows, next_index++);
            }

            while (pending_panel_creates > 0 && next_index < KLOTSKI_HARNESS_MAX_WINDOWS) {
                pending_panel_creates--;
                create_indexed_panel(windows, next_index++);
            }

            while (pending_window_minimizes > 0) {
                pending_window_minimizes--;
                minimize_last_window(windows);
            }

            while (pending_window_deminiaturizes > 0) {
                pending_window_deminiaturizes--;
                deminiaturize_last_window(windows);
            }

            while (pending_window_fullscreen_toggles > 0) {
                pending_window_fullscreen_toggles--;
                toggle_fullscreen_last_window(windows);
            }

            while (pending_ghost_creates > 0 && next_index < KLOTSKI_HARNESS_MAX_WINDOWS) {
                pending_ghost_creates--;
                create_ghost_window(windows, next_index++);
            }

            while (pending_window_closes > 0) {
                pending_window_closes--;
                close_last_window(windows);
            }

            if (pending_app_terminates) {
                pending_app_terminates = 0;
                terminate_app();
            }
        }];

        [NSApp activate];
        [NSApp run];
        (void) windows;
    }

    return 0;
}
