# klotski
Experimental niri-like window manager for macos

feature list
```
- Niri-style infinite horizontal tiling canvas for macOS.
- Configurable default column width, inner gaps, and outside padding.
- Smooth horizontal viewport movement from keyboard, mouse wheel, and trackpad input.
- Focus-follows-mouse with automatic viewport adjustment to keep the focused window visible.
- Tiled and floating window modes, with floating windows left unmanaged until tiled again.
- Column reordering and interactive drag reordering.
- Vertical window stacks inside columns, including drag-to-stack behavior.
- Interactive tiled-column resizing, including resizing from the grabbed side.
- Column maximize/full-width toggling.
- Config-backed input bindings for keyboard, mouse buttons, scroll wheel, move, resize, focus, and width actions.
- Config-backed window rules for opening matched macOS window roles/subroles as tiled, floating, or ignored.
- Window rules can match macOS role, subrole, bundle id, and app name.
- Transient macOS windows such as dialogs and file pickers can stay floating through rules.
- Unhinted or unknown macOS helper windows stay out of the tiled strip by default.
- Native fullscreen detection, with fullscreen windows leaving tiling while fullscreen and returning afterward.
- Virtualized offscreen layout keeps logical column positions authoritative even when CG stops reporting hidden windows.
- Fully offscreen tiled windows are hidden while parked so AX edge-clamping does not leave visible strips.
- New-window detection and burst-add handling benchmarked for fast layout convergence.
- Harness and benchmark coverage for scrolling, window creation, lifecycle events, window policy, fullscreen, and offscreen gap regressions.
- launchd user-agent tooling for daemon-style startup, logs, status, emergency stop, and disable/enable.
```

example config
```
# Klotski loads resources/default-config.kdl first, then overlays this file:
# ~/.config/klotski/klotski.conf

default-column-width-proportion = 0.5
gaps = 2
padding = 0

keyboard-scroll-fraction = 0.5
scroll-wheel-sensitivity = 3.0
gesture-scroll-sensitivity = 4.0
gesture-scroll-inverted = true
scroll-settle-delay = 0.08
horizontal-view-animation-speed = 18.0

center-focused-column = never
always-center-single-column = false
focus-follows-mouse = true
mod-key = alt

window-rule {
    match subrole="AXDialog"
    open-floating true
}

window-rule {
    match subrole="AXSystemDialog"
    open-floating true
}

window-rule {
    match subrole="AXFloatingWindow"
    open-floating true
}

window-rule {
    match subrole="AXUnknown"
    open-floating true
}

window-rule {
    match app-id="com.apple.systempreferences"
    open-floating true
}

window-rule {
    match app-name="System Settings"
    open-floating true
}

binds {
    Mod+Left  { scroll-left; }
    Mod+Right { scroll-right; }

    Mod+Shift+Left  { move-column-left; }
    Mod+Shift+Right { move-column-right; }

    Mod+F repeat=false { maximize-column; }
    Mod+W repeat=false { toggle-window-floating; }

    Mod+MouseLeft  { start-interactive-move; }
    Mod+MouseRight { start-interactive-resize; }

    Mod+WheelScrollUp    { scroll-left; }
    Mod+WheelScrollDown  { scroll-right; }
    Mod+WheelScrollLeft  { scroll-left; }
    Mod+WheelScrollRight { scroll-right; }
}
```

Full config reference: [`docs/config.md`](docs/config.md).

how to run
```sh
# Build and run the test suite.
make test

# Run against isolated test windows instead of your real desktop.
scripts/run-harness.sh

# Reproduce offscreen gap/hidden-window regressions against the harness.
make bench-window-gap

# Build Klotski, install ~/Applications/Klotski.app, create config/log dirs,
# and write ~/Library/LaunchAgents/dev.klotski.wm.plist.
make service-install

# Check app/config/plist/log paths and warn about obvious runtime conflicts.
make service-doctor

# Start or refresh the LaunchAgent. This also rebuilds and reinstalls the app.
make service-start

# Inspect launchd state, app path, config paths, log paths, and running pids.
make service-status

# Tail stderr/stdout logs.
make service-logs

# Stop the LaunchAgent and any running Klotski.app process.
make service-stop

# Rebuild, reinstall, and restart.
make service-restart

# Emergency disable until explicitly re-enabled.
make service-disable
make service-enable

# Remove the LaunchAgent plist. Config and logs are kept.
make service-uninstall
```

Service paths:

```text
app bundle:     ~/Applications/Klotski.app
app binary:     ~/Applications/Klotski.app/Contents/MacOS/Klotski
app default:    ~/Applications/Klotski.app/Contents/resources/default-config.kdl
user config:    ~/.config/klotski/klotski.conf
disabled flag:  ~/.config/klotski/disabled
LaunchAgent:    ~/Library/LaunchAgents/dev.klotski.wm.plist
stdout log:     ~/Library/Logs/klotski/klotski.out.log
stderr log:     ~/Library/Logs/klotski/klotski.err.log
launchd target: gui/$(id -u)/dev.klotski.wm
```

The LaunchAgent starts Klotski with:

```text
/usr/bin/open -gj ~/Applications/Klotski.app
```

Because `open` exits after handing the app to LaunchServices,
`make service-status` can show the LaunchAgent as `not running` even when
Klotski is active. Check the `running klotski pids` section or the app binary
path in `pgrep -fl Klotski`.

`make service-install` copies `resources/default-config.kdl` into the app bundle
and creates `~/.config/klotski/klotski.conf` only if the user config does not
already exist. `make service-start` also reinstalls the app bundle and plist so
the launched app matches the current checkout.

Do not run another tiling window manager at the same time. Klotski refuses to
start while `yabai` is running unless `KLOTSKI_ALLOW_WM_CONFLICT=1` is set.
macOS Accessibility and Input Monitoring permissions may need to be granted when
first running the harness or service.
