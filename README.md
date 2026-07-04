# briarWM

A BSP tiling window manager for macOS. Windows tile automatically, you drive
everything from a YAML file with i3-style keybindings, and there is no GUI to configure.

It runs with System Integrity Protection fully enabled. Tiling uses the public
Accessibility API. Per-desktop layouts also read a few private but non-SIP
CoreGraphics/SkyLight symbols to tell which Space a window is on; if those are ever
unavailable, briarWM falls back to one tree per display.

## Features

- Automatic BSP tiling. Each new window splits the focused pane along its longer edge,
  or the direction you preselect.
- i3-style keybindings: vim `h/j/k/l` to focus, add `shift` to move or swap, inner and
  outer gaps.
- Per-desktop layouts. Each macOS Space keeps its own tree. Move a window to another
  desktop and the source refills the gap while the destination tiles it in.
- Multi-monitor. One tree per display and desktop.
- Resize (direct and a modal mode), balance, toggle split orientation, zoom to fill the
  tiling area, floating windows, per-app float rules, and live gaps tweaks.
- Minimize reflow. Minimizing fills the slot and restores it on un-minimize.
- YAML config with hot reload. A valid config applies on save. A broken one keeps your
  current settings and flags the error in the menu bar.
- Menu-bar status item, runs as a background accessory with no Dock icon.

## Requirements

- macOS 14 or later.
- A working Swift toolchain. Check it with:

  ```sh
  echo 'import Foundation; print("ok")' | swift -
  ```

  If it complains that the SDK does not match the compiler, reinstall the Command Line
  Tools: `sudo rm -rf /Library/Developer/CommandLineTools && sudo xcode-select --install`.

## Install

```sh
make build                                              # or: swift build
cp config.example.yaml ~/.config/briarWM/config.yaml    # if you don't have one yet
make check                                              # validate the config
.build/debug/briarWM                                    # launch
```

On first launch briarWM asks for Accessibility permission. Grant it in
System Settings > Privacy & Security > Accessibility, enable briarWM, then relaunch.
It adopts your open windows and tiles them.

Launching briarWM rearranges the windows on your active Space. Apps that can't be tiled
(System Settings, fixed-size dialogs, native fullscreen) are left floating.

## Configuration

Config lives at `~/.config/briarWM/config.yaml` and hot-reloads on save. Every field is
optional and falls back to a default. See [`config.example.yaml`](config.example.yaml)
for the full reference. A small taste:

```yaml
modifier: alt            # $mod: alt | cmd | ctrl | shift | hyper

gaps:
  inner: 10              # between windows
  outer: 6              # screen margin

layout:
  default_ratio: 0.5     # new split's share for the existing window
  auto_split: longer_edge

keybindings:
  "alt+h": "focus left"
  "alt+shift+h": "move left"
  "alt+e": "toggle split"
  "alt+f": "fullscreen"
  "alt+shift+space": "toggle float"
  "alt+1": "workspace 1"
  "alt+shift+1": "move workspace 1"
  "alt+return": "exec terminal"

floating:
  bundle_ids:
    - com.apple.systempreferences
```

`make check` validates more than YAML syntax. It fails on unknown modifier names, bad
`insert_at` / `auto_split` / `preset_cycle` values, bindings whose key or action doesn't
parse, `mode` actions that reference undefined modes, and regexes that don't compile.

### Default keybindings (`$mod` = Alt/Option)

| Action | Keys |
|---|---|
| focus left/down/up/right | `alt+h/j/k/l` (or arrows) |
| move/swap window | `alt+shift+h/j/k/l` |
| preselect split horizontal / vertical | `alt+ctrl+h` / `alt+ctrl+v` |
| toggle split orientation | `alt+e` |
| resize (direct) | `alt+ctrl+arrows` (expand toward the arrow, shrink if flush to that edge) |
| resize mode (modal) | `alt+r`, then `h/j/k/l`, `escape` to exit |
| balance ratios | `alt+shift+e` |
| fullscreen (zoom) | `alt+f` |
| toggle floating | `alt+shift+space` |
| close window | `alt+shift+q` |
| switch to desktop 1-5 | `alt+1` ... `alt+5` |
| move window to desktop 1-5 | `alt+shift+1` ... `alt+shift+5` |
| terminal / launcher | `alt+return` / `alt+d` |
| reload / restart config | `alt+shift+c` / `alt+shift+r` |
| dump tree to log | `alt+shift+t` |

Desktop numbers are 1-based, left to right, among the user desktops of the focused
display. You can still switch with `Ctrl+left/right`; briarWM reconciles either way.
Change `modifier:` if Alt's dead-key behavior gets in your way.

## Develop

```sh
make build     # swift build
make test      # swift-testing unit suite (pure tree/layout/geometry/keycodes/config)
make run       # build and run in the foreground
make check CONFIG=path/to/config.yaml
make sign      # self-sign so the Accessibility grant survives rebuilds
```

macOS keys the Accessibility grant to the binary's signature, which changes on every
`swift build`. To keep the grant across rebuilds, create a self-signed Code Signing
certificate named `briarWM-dev` (Keychain Access > Certificate Assistant), then run
`make sign` after building.

Follow the branch and commit conventions in [`AGENTS.md`](AGENTS.md): work on a feature
branch, never commit straight to `main`.

### Architecture

```
Sources/briarWM/
  AX/        AXClient, AXWindow, AXApplication   # Accessibility wrappers + observers
  Tree/      Orientation, BSPNode, BSPTree       # BSP data model and algorithms
  Layout/    LayoutEngine, Tiler                 # pure tree to rects, then apply via AX
  Screen/    ScreenManager, Geometry, SpacesManager  # displays, coords, private Space APIs
  Hotkey/    HotkeyManager, Keycodes, Keymap     # Carbon global hotkeys + binding parse
  Config/    Config, ConfigLoader, ConfigWatcher # YAML schema, load, hot reload
  Command/   Action, CommandRouter               # command vocabulary + dispatch
  Core/      WindowManager, WindowRegistry       # the orchestrator
  Lifecycle/ AppWatcher                          # NSWorkspace/screen notifications
  App/       AppDelegate, PermissionGate, StatusItem
```

The tree, layout, and geometry logic is pure and unit-tested. AX, Carbon, and AppKit are
kept thin around it.

## Logs

```sh
tail -f ~/.local/state/briarWM/briarWM.log
```
