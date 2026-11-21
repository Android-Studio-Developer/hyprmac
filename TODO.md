# TODO

## Windows version (working name: hyprwin)

Same idea as hyprmac: a Hyprland-style tiler that reads `hyprland.conf`, built on Win32 instead of
the macOS Accessibility API.

### Approach

- [ ] Write it in **Swift for Windows** so `HyprmacCore` (config parser, dwindle/master layouts,
      workspaces, focus, dispatchers) is reused unchanged, along with its tests. Core is already
      free of AppKit/CoreGraphics; `Control.swift` is `#if canImport(Darwin)` and needs a Windows twin.
      Fallback if the Swift toolchain on Windows is too painful: port Core to Rust and keep both in sync
      with shared test fixtures (config files + expected frames as JSON).
- [ ] Rename the shared core to something neutral (e.g. `HyprCore`) once a second platform uses it.
- [ ] Windows key-code table (`VK_*`) next to `MacKeyCodes`; make the config parser validate keys
      against the platform table.

### Platform layer (Win32)

- [ ] Window discovery: `EnumWindows`; manage visible top-level windows with a caption, no owner,
      not `WS_EX_TOOLWINDOW`, not DWM-cloaked (`DWMWA_CLOAKED`), not UWP host frames that are empty.
- [ ] Events: `SetWinEventHook` for `EVENT_OBJECT_SHOW/HIDE/DESTROY`, `EVENT_SYSTEM_FOREGROUND`,
      `EVENT_SYSTEM_MINIMIZESTART/END`, `EVENT_SYSTEM_MOVESIZEEND`, `EVENT_OBJECT_NAMECHANGE`.
- [ ] Moving windows: `SetWindowPos` / `DeferWindowPos`, correcting for invisible resize borders via
      `DWMWA_EXTENDED_FRAME_BOUNDS`. Restore maximized windows first.
- [ ] DPI: per-monitor DPI awareness v2; monitors from `EnumDisplayMonitors` + `rcWork`.
- [ ] Hotkeys: `RegisterHotKey` with `MOD_NOREPEAT`. `SUPER` = Windows key. Some Win combos are
      reserved (Win+L); fall back to a low-level keyboard hook (`WH_KEYBOARD_LL`) for those.
- [ ] Hiding workspaces: cloak windows (komorebi-style, via the undocumented `IApplicationView`
      COM interface) so taskbar icons stay; `ShowWindow(SW_HIDE)` as a fallback.
- [ ] Focus: `SetForegroundWindow` is restricted; use the Alt-key trick or `AttachThreadInput`.
- [ ] Borders: on Windows 11 use native `DWMWA_BORDER_COLOR` (single color) for the focused window;
      layered click-through overlay windows for gradients and Windows 10.
      Rounded corners via `DWMWA_WINDOW_CORNER_PREFERENCE`.
- [ ] Elevated (admin) windows can't be moved from a normal process (UIPI): skip them, or offer
      running hyprwin elevated.
- [ ] `exec`: `cmd /c` / `CreateProcess`; config at `%USERPROFILE%\.config\hyprwin\hyprland.conf`.
- [ ] IPC: named pipes `\\.\pipe\hyprwin` and `\\.\pipe\hyprwin-events`; `hyprwinctl` CLI with the
      same commands and JSON as `hyprmacctl`.
- [ ] Tray icon showing workspaces (like the macOS menu bar item); events usable from Zebar / YASB.
- [ ] Packaging: winget + Scoop manifests; GitHub Actions `windows-latest` build + tests.

### Rices on Windows

- [ ] `hyprwin rice` with the same commands; link targets under `%USERPROFILE%\.config` and
      `%APPDATA%` (kitty/alacritty/wezterm read different places on Windows).
- [ ] Windows stand-ins: `wl-copy` -> `clip.exe`, `notify-send` -> toast, `thunar` -> `explorer`,
      `rofi` -> PowerToys Run / Flow Launcher, `hyprlock` -> `rundll32 user32.dll,LockWorkStation`.
- [ ] Wallpaper via `SystemParametersInfo(SPI_SETDESKWALLPAPER)`.

## Rices (macOS)

- [ ] Run a real rice live (43PR/dotfiles is the test case): check borders, gaps, the
      float-toggle Lua bind, kitty/btop look.
- [ ] Rice theme engines: 43PR's `theme.py` needs Python 3.11+ (`tomllib`) and writes
      `~/.config/hypr/colors.lua`; until it runs, its borders fall back to white. Offer
      `hyprmac rice theme <name>` that renders a rice's theme templates, or detect and run its script.
- [ ] Stow-style repos (`kitty/.config/kitty/...`) and `home/` layouts; chezmoi repos.
- [ ] Mac counterparts for Linux-only parts: Waybar/Quickshell bar -> generated SketchyBar config
      from the rice's colors; rofi theme -> Raycast theme; GTK colors -> macOS accent color.
- [ ] Rice gallery: a curated list (`hyprmac rice browse`) with screenshots on the site.
- [ ] Media keys (`XF86Audio*`, brightness) and `code:NN` binds via an event tap.
- [ ] Mouse binds from rices (`SUPER + mouse:272` drag) once `bindm` lands.
- [ ] Window rules that match on state (`fullscreen = true`) and opacity rules.

## macOS: before calling it 1.0

- [ ] Run it day-to-day on real hardware: multi-monitor, Stage Manager on/off, several macOS Spaces,
      apps with odd windows (Electron, Java, Steam, System Settings, Finder).
- [ ] Smarter hidden-window corner for complex monitor layouts (pick a corner no other display touches).
- [ ] Integration tests for the daemon (scripted test app that opens windows; check frames).
- [ ] Notarized, Developer-ID-signed build so the Accessibility permission survives updates;
      Homebrew cask.
- [ ] Launch-at-login toggle in the menu (`SMAppService`).

## macOS: more Hyprland features

- [ ] `binde` key repeat (Carbon hotkeys fire once; needs a repeat timer or an event tap).
- [ ] `bindm` mouse binds: SUPER+drag to move/resize, via `CGEventTap` (needs Input Monitoring).
- [ ] Drag a tiled window onto another to swap them.
- [ ] `input:follow_mouse` (focus follows mouse).
- [ ] Submaps (`submap = resize`), `hyprctl keyword`, `hyprctl dispatch` batching (`--batch`).
- [ ] Special workspace / scratchpad (`togglespecialworkspace`), named workspaces (`name:web`),
      workspace rules (`workspace = 3, monitor:...`, `persistent:true`).
- [ ] `pseudo`, `pin`, groups/tabbed windows (`togglegroup`, `changegroupactive`).
- [ ] `movecurrentworkspacetomonitor`, `swapactiveworkspaces`, `focuswindow class:...`.
- [ ] `resizeactive` / `moveactive` for floating windows.
- [ ] Window-rule extras: `opacity` (only for hyprmac's own overlays), `nofocus`, `noborder`,
      `monitor`, `move X Y`.
- [ ] Animations where possible without SIP: fade borders, slide the border overlay on focus change.
- [ ] Match the border radius to the macOS window corner radius (Tahoe uses larger corners).
- [ ] Ready-made SketchyBar plugin and an example rice in `examples/`.
