# briarWM

A simple, config-only **BSP tiling window manager for macOS** — i3-gaps/bspwm vibes,
no SIP disabling, no GUI configuration. Windows auto-tile via binary space partitioning;
everything is driven by a YAML file and i3-style keybindings.

> Built with the public Accessibility API only (like Amethyst/AeroSpace), so it runs with
> System Integrity Protection fully enabled.

## Features

- **Automatic BSP tiling** — each new window halves the focused pane; split direction
  follows the longer edge, or your bspwm-style *preselection* (`alt+ctrl+h` / `alt+ctrl+v`).
- **i3-gaps keybindings** — vim `h/j/k/l` focus, `shift` to move/swap, gaps (inner/outer).
- **Multi-monitor** — one BSP tree per display; tiles the currently active macOS Space.
- **Resize** (direct + a modal resize mode), **balance**, **toggle split orientation**,
  **fullscreen (zoom)**, **floating** windows + per-app float rules.
- **YAML config with hot reload** — edit and save; changes apply instantly.
- Menu-bar status item; runs as a background accessory (no Dock icon).

## Requirements

- macOS 14+, Swift 6.1 toolchain (`swift --version`).
- A healthy toolchain: `echo 'import Foundation; print("ok")' | swift -` should print `ok`.
  If it complains the SDK doesn't match the compiler, reinstall the Command Line Tools
  (`sudo rm -rf /Library/Developer/CommandLineTools && sudo xcode-select --install`).

## Quick start

```sh
make build                 # or: swift build
cp config.example.yaml ~/.config/briarWM/config.yaml   # if you don't have one yet
make check                 # validate your config
.build/debug/briarWM         # launch
```

On first launch briarWM asks for **Accessibility** permission. Grant it in
**System Settings → Privacy & Security → Accessibility** (enable “briarWM”), then relaunch —
briarWM adopts your open windows and tiles them.

> ⚠️ Launching briarWM will rearrange the windows on your active Space. Apps that can't be
> tiled (System Settings, fixed-size dialogs, native-fullscreen) are left floating.

### Keep the permission grant across rebuilds (dev)

macOS keys the Accessibility grant to the binary's signature, which changes on every
`swift build`. Create a self-signed **Code Signing** certificate named `briarWM-dev`
(Keychain Access → Certificate Assistant), then:

```sh
make sign      # codesign --force --sign briarWM-dev .build/debug/briarWM
```

## Default keybindings (`$mod` = Alt/Option)

| Action | Keys |
|---|---|
| focus left/down/up/right | `alt+h/j/k/l` (or arrows) |
| move/swap window | `alt+shift+h/j/k/l` |
| preselect split horizontal / vertical | `alt+ctrl+h` / `alt+ctrl+v` |
| toggle split orientation | `alt+e` |
| resize (direct) | `alt+ctrl+arrows` |
| resize mode (modal) | `alt+r`, then `h/j/k/l`, `escape` to exit |
| balance ratios | `alt+shift+e` |
| fullscreen (zoom) | `alt+f` |
| toggle floating | `alt+shift+space` |
| close window | `alt+shift+q` |
| terminal / launcher | `alt+return` / `alt+d` |
| reload / restart config | `alt+shift+c` / `alt+shift+r` |
| dump tree to log | `alt+shift+t` |

Switch macOS Spaces with the usual `Ctrl+←/→`; briarWM re-tiles the active one.
Change `modifier:` in the config if Alt's dead-key behavior gets in your way.

## Configuration

See [`config.example.yaml`](config.example.yaml). Lives at `~/.config/briarWM/config.yaml`,
hot-reloads on save. Every field is optional and falls back to a default.

## Logs

```sh
tail -f ~/.local/state/briarWM/briarWM.log
```

## Development

```sh
make test     # swift-testing unit suite (pure tree/layout/geometry/keycodes/config)
make run      # build + run in foreground
make check CONFIG=path/to/config.yaml
```

### Architecture

```
Sources/briarWM/
  AX/        AXClient, AXWindow, AXApplication   # Accessibility wrappers + observers
  Tree/      Orientation, BSPNode, BSPTree       # the BSP data model + algorithms
  Layout/    LayoutEngine, Tiler                 # pure tree→rects, then apply via AX
  Screen/    ScreenManager, Geometry             # displays + Cocoa↔AX coordinates
  Hotkey/    HotkeyManager, Keycodes, Keymap     # Carbon global hotkeys + binding parse
  Config/    Config, ConfigLoader, ConfigWatcher # YAML schema, load, hot reload
  Command/   Action, CommandRouter               # command vocabulary + dispatch
  Core/      WindowManager, WindowRegistry       # the orchestrator
  Lifecycle/ AppWatcher                          # NSWorkspace/screen notifications
  App/       AppDelegate, PermissionGate, StatusItem
```

The tree, layout, and geometry logic is pure and unit-tested; AX/Carbon/AppKit are kept
thin around it.
