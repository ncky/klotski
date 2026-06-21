# Klotski Config Reference

Klotski uses a small KDL-like config format. It is intentionally compatible with
some niri naming, but it is not a full niri config parser and it is not a full
KDL parser.

## Load Order

At startup Klotski loads config in this order:

1. Compiled defaults from the binary.
2. Default config from `KLOTSKI_DEFAULT_CONFIG`, if set, otherwise
   `resources/default-config.kdl` from the repo or app bundle.
3. User config from `KLOTSKI_CONFIG`, if set, otherwise
   `~/.config/klotski/klotski.conf`.

Later files override scalar settings. Window rules append, and later matching
rules win at runtime. A `binds` block replaces all previously loaded binds the
first time a `binds` block is seen in that file.

Config is read at startup only. Restart Klotski after editing it.

## Syntax

Supported comments:

```kdl
# comment
// comment
```

Scalar settings use `key = value`.

```kdl
gaps = 2
focus-follows-mouse = true
mod-key = alt
```

Booleans accept `true`, `yes`, `1`, `false`, `no`, and `0`.

Unknown top-level scalar keys are errors. Unknown blocks are skipped. Unsupported
bind actions are ignored and reported on stderr. A `window-rule` with an
unsupported matcher key is ignored.

## Layout Settings

| Setting | Values | Default | Notes |
| --- | --- | --- | --- |
| `default-column-width-proportion` | number > 0 | `0.5` | New tiled window width as a fraction of the effective screen width. |
| `default-width-fraction` | number > 0 | `0.5` | Alias for `default-column-width-proportion`. |
| `default-column-width` | number > 0 | `0.5` | Alias for `default-column-width-proportion`. |
| `gaps` | number >= 0 | `2` | Inner gap between tiled columns/windows. |
| `gap` | number >= 0 | `2` | Alias for `gaps`. |
| `padding` | number >= 0 | `0` | Sets all outside padding edges. |
| `padding-left` | number >= 0 | `0` | Overrides left outside padding. |
| `padding-right` | number >= 0 | `0` | Overrides right outside padding. |
| `padding-top` | number >= 0 | `0` | Overrides top outside padding. |
| `padding-bottom` | number >= 0 | `0` | Overrides bottom outside padding. |
| `center-focused-column` | `never`, `always`, `on-overflow` | `never` | Controls whether focused columns are centered when scrolling/focusing. |
| `always-center-single-column` | boolean | `false` | Centers a lone tiled column. |

The default column width subtracts the shared inner gap so two `0.5` columns fit
on screen with one gap between them.

## Input And Motion Settings

| Setting | Values | Default | Notes |
| --- | --- | --- | --- |
| `mod-key` | `alt`, `option`, `super`, `win`, `cmd`, `command`, `ctrl`, `control`, `shift` | `alt` | Defines what `Mod` means in binds. Can also be set inside `input {}`. |
| `keyboard-scroll-fraction` | number > 0 | `0.5` | Viewport fraction moved by `scroll-left` and `scroll-right`. |
| `scroll-wheel-sensitivity` | number > 0 | `3.0` | Multiplier for modified wheel scrolling. |
| `gesture-scroll-sensitivity` | number > 0 | `4.0` | Multiplier for three-finger horizontal drag. |
| `gesture-scroll-inverted` | boolean | `true` | Inverts three-finger drag direction. |
| `invert-gesture-scroll` | boolean | `true` | Alias for `gesture-scroll-inverted`. |
| `scroll-settle-delay` | number >= `0.01` | `0.08` | Seconds before focus settling after scroll input. |
| `horizontal-view-animation-speed` | number > 0 | `18.0` | Higher values make viewport animation catch up faster. |
| `animation-speed` | number > 0 | `18.0` | Alias for `horizontal-view-animation-speed`. |
| `focus-follows-mouse` | boolean | `true` | Focus hovered tiled windows when not actively scrolling/dragging/resizing. |

`input {}` currently supports only `mod-key`.

```kdl
input {
    mod-key "Super"
}
```

## Window Rules

Rules are additive. At runtime Klotski checks rules from newest to oldest, so
rules later in the load order have priority.

```kdl
window-rule {
    match role="AXWindow" subrole="AXDialog" app-id="com.example.App" app-name="Example"
    open-floating true
}
```

Supported match keys:

| Key | Match |
| --- | --- |
| `role` | Exact macOS accessibility role. |
| `subrole` | Exact macOS accessibility subrole. |
| `app-id` | Exact bundle identifier. |
| `app-name` | Exact application name. |

All specified match keys must match exactly. There is no glob or regex support
yet. A rule with no match keys applies to every otherwise eligible window, so use
that deliberately.

Supported rule actions:

| Action | Effect |
| --- | --- |
| `open-floating true` | Open matching windows as floating/unmanaged. |
| `open-floating false` | Open matching windows as tiled. |
| `open-tiled true` | Open matching windows as tiled. |
| `ignore true` | Ignore matching windows entirely. |
| `open-ignored true` | Alias for `ignore true`. |
| `manage true` | Open matching windows as tiled. |
| `manage false` | Ignore matching windows entirely. |

If multiple action lines are present in one rule, the last action wins.

Window policy order:

1. Missing window hints open floating.
2. Non-`AXWindow` roles are ignored.
3. Native fullscreen windows are floating while fullscreen.
4. The newest matching `window-rule` decides.
5. Otherwise the window opens tiled.

## Binds

Binds must be one line each:

```kdl
binds {
    Mod+Left { scroll-left; }
    Mod+F repeat=false { maximize-column; }
    Mod+BracketLeft cooldown-ms=50 { set-column-width "-10%"; }
}
```

Bind properties:

| Property | Values | Default | Notes |
| --- | --- | --- | --- |
| `repeat` | boolean | `true` | If false, keyboard autorepeat is ignored. |
| `cooldown-ms` | number >= 0 | `0` | Minimum delay between accepted triggers for this bind. |

Modifiers:

| Name | Notes |
| --- | --- |
| `Mod` | Expands to `mod-key`. |
| `Ctrl`, `Control` | Control modifier. |
| `Shift` | Shift modifier. |
| `Alt`, `Option` | Option modifier. |
| `Super`, `Win`, `Cmd`, `Command` | Command modifier on macOS. |

Key triggers:

```text
A-Z
0-9
Left Right Up Down
Home End
Page_Up PageUp Page_Down PageDown
Minus Equal Equals
BracketLeft Bracket_Left BracketRight Bracket_Right
Comma Period Dot
Tab Space Return Enter Escape Esc
```

Mouse and wheel triggers dispatched by the current macOS runtime:

```text
MouseLeft MouseRight
WheelScrollUp WheelScrollDown WheelScrollLeft WheelScrollRight
```

The parser also accepts these names, but the current macOS runtime does not
dispatch them as bind triggers:

```text
MouseMiddle MouseBack MouseForward
TouchpadScrollUp TouchpadScrollDown TouchpadScrollLeft TouchpadScrollRight
```

Three-finger trackpad scrolling is handled by the gesture settings above rather
than by bind actions.

## Bind Actions

`scroll-left` and `scroll-right` are also used for wheel binds. Keyboard and
mouse-button triggers move by `keyboard-scroll-fraction`; wheel triggers use the
wheel delta and `scroll-wheel-sensitivity`.

| Action | Aliases | Effect |
| --- | --- | --- |
| `scroll-left` | | Scroll the viewport left. |
| `scroll-right` | | Scroll the viewport right. |
| `focus-column-left` | `focus-column-left-or-last`, `focus-column-or-monitor-left` | Focus the column to the left. |
| `focus-column-right` | `focus-column-right-or-first`, `focus-column-or-monitor-right` | Focus the column to the right. |
| `focus-column-first` | | Focus the first column. |
| `focus-column-last` | | Focus the last column. |
| `focus-window-up` | `focus-window-up-or-bottom`, `focus-window-up-or-column-left` | Focus the window above in the active vertical column. |
| `focus-window-down` | `focus-window-down-or-top`, `focus-window-down-or-column-right` | Focus the window below in the active vertical column. |
| `move-column-left` | `move-column-left-or-to-monitor-left` | Move the active column left. |
| `move-column-right` | `move-column-right-or-to-monitor-right` | Move the active column right. |
| `move-column-to-first` | | Move the active column to the start. |
| `move-column-to-last` | | Move the active column to the end. |
| `move-window-up` | | Move the active window up inside its vertical column. |
| `move-window-down` | | Move the active window down inside its vertical column. |
| `toggle-window-floating` | `toggle-floating` | Toggle the target window between tiled and floating. |
| `move-window-to-floating` | | Force the target window to floating. |
| `move-window-to-tiling` | | Force the target window to tiled. |
| `maximize-column` | `maximize-window-to-edges` | Toggle the target column between full effective width and its restore width. |
| `set-column-width` | `set-window-width` | Set or adjust the active column width. Requires an argument. |
| `start-interactive-move` | `interactive-move`, `move-window` | Begin drag/reorder. Useful on mouse triggers. |
| `start-interactive-resize` | `interactive-resize`, `resize-window`, `resize-column` | Begin interactive resize. Useful on mouse triggers. |

`set-column-width` arguments can be absolute pixels or viewport-relative
percentages. A leading `+` or `-` makes the change relative to the current column
width.

```kdl
Mod+Minus { set-column-width "-10%"; }
Mod+Equal { set-column-width "+10%"; }
Mod+1 { set-column-width "50%"; }
Mod+2 { set-column-width "900"; }
Mod+3 { set-column-width "-64"; }
```

`start-interactive-move` and `start-interactive-resize` are only meaningful for
mouse bindings in the current macOS runtime.

## Limits

| Limit | Value |
| --- | --- |
| Binds | 192 |
| Window rules | 64 |
| Remembered unsupported bind action names | 128 |
| Bind action argument length | 95 bytes |
| Bind action name length | 63 bytes |
| Window rule match value length | 63 bytes |

## Current Default Config

The maintained default config lives at
[`resources/default-config.kdl`](../resources/default-config.kdl). Service
install copies it to `~/.config/klotski/klotski.conf` if that file does not
already exist.
