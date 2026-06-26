# AGENTS.md — working on briarWM

briarWM is a simple **BSP tiling window manager for macOS**, written in Swift (SwiftPM).
Automatic binary space partitioning, i3-gaps keybindings, YAML config, pure Accessibility
API (no SIP disabling). See `README.md` for the user-facing overview.

## Commands

```sh
make build      # swift build
make test       # swift test  (unit suite)
make run        # build + run in foreground (Ctrl-C to stop)
make check      # validate ~/.config/briarWM/config.yaml  (or CONFIG=path)
make sign       # self-sign so the Accessibility grant survives rebuilds
```

## Toolchain gotchas (read before debugging build failures)

- **Swift 5 language mode.** `Package.swift` sets `swiftLanguageModes: [.v5]`. The app is
  single-threaded on the main run loop and uses C callbacks / global state that Swift 6
  strict concurrency rejects. Don't switch to Swift 6 mode without a real concurrency pass.
- **Tests use `swift-testing`, not XCTest.** Command Line Tools ship `import Testing` but
  **not** XCTest (that's Xcode-only). Write tests with `@Test` / `@Suite` / `#expect`.
- **Compiler/SDK must match.** If a build fails with "this SDK is not supported by the
  compiler" or `PackageDescription` link errors, the Command Line Tools install is
  inconsistent — reinstall it (`sudo rm -rf /Library/Developer/CommandLineTools &&
  sudo xcode-select --install`). It is not a code problem. Sanity check:
  `echo 'import Foundation; print("ok")' | swift -`.

## Architecture & conventions

```
Sources/briarWM/
  Tree/      Orientation, BSPNode, BSPTree   # BSP data model + algorithms  (PURE)
  Layout/    LayoutEngine, Tiler             # LayoutEngine pure; Tiler applies via AX
  Screen/    Geometry, ScreenManager, SpacesManager  # Geometry pure; ScreenManager = AppKit; SpacesManager = private CGS
  Hotkey/    Keycodes, Keymap, HotkeyManager # Keycodes/Keymap pure; HotkeyManager = Carbon
  Command/   Action, CommandRouter           # Action pure (parsing); router dispatches
  Config/    Config, ConfigLoader, ConfigWatcher  # Config pure (Decodable); loader = Yams
  AX/        AXClient, AXWindow, AXApplication     # Accessibility wrappers + AXObserver
  Core/      WindowManager, WindowRegistry         # the orchestrator
  Lifecycle/ AppWatcher                            # NSWorkspace / screen notifications
  App/       AppDelegate, PermissionGate, StatusItem
  Util/      Log
```

- **Keep the pure layer pure.** `Tree`, `LayoutEngine`, `Geometry`, `Keycodes`, `Action`,
  and the `Config` structs must not import AppKit/AX. That's what makes them unit-testable
  (see `Tests/briarWMTests/`). Add new tests there for any pure logic you touch.
- **Single-threaded on the main run loop.** AX observers and Carbon hotkeys both require it;
  no locking is used or needed. Do AX work on the main thread.
- **Feedback-loop safety.** When briarWM sets a window's frame it records the desired frame;
  AX move/resize notifications that match it are ignored, others are treated as a user drag
  (snap back). Preserve this when changing tiling.
- **One tree per Space (desktop).** `WindowManager.trees` is keyed by `SpaceID`; each tree
  also carries its `display`. The core invariant: **`retile` only applies frames to windows
  on the *active* Space of their display** (`isActive`) — hidden desktops recompute but never
  touch AX. `reconcileSpaces()` (driven by Space-change/app-activation notifications and a
  backstop timer in `AppWatcher`) re-homes windows whose real Space drifted. Space membership
  comes from `SpacesManager` (private, non-SIP CGS/SkyLight via `dlsym`); when it's
  unavailable everything falls back to a per-display pseudo-Space = the old behavior. Keep
  the private API surface confined to `SpacesManager`.
- **Coordinates:** everything in the tiling path is AX (top-left origin). Convert exactly
  once at the NSScreen boundary via `Geometry`.

## Originality

briarWM is *inspired by* i3 / bspwm / Amethyst / AeroSpace and deliberately speaks their
keybinding dialect, but contains no copied code — implement from the public Apple APIs and
first principles. Don't paste source from those projects.

## Config & logs

- Config: `~/.config/briarWM/config.yaml` (hot-reloads on save). Template: `config.example.yaml`.
- Logs: `~/.local/state/briarWM/briarWM.log` (`tail -f` while iterating).
