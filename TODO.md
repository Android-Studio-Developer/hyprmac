# TODO

## Windows (hyprwin, `windows/`)

Built in C# / .NET 10: core ported from Swift with the same tests, Lua through KeraLua (real
Lua 5.4) with the shared `hl-prelude.lua`, Win32 + DWM window layer, tray icon, named pipes,
`hyprwinctl`, rices with junctions and `.cmd` stand-ins. CI runs it on a Windows runner.

- [ ] Use it day-to-day on a real Windows 11 desktop (multi-monitor, mixed DPI, UWP apps,
      Explorer, Chrome/Electron, games in exclusive fullscreen).
- [ ] Cloak hidden windows (komorebi-style, `IApplicationView`) instead of moving them off screen.
- [ ] Gradient / thick borders with click-through overlay windows (DWM border is 1px, one color).
- [ ] Low-level keyboard hook for Win-key combos Windows reserves (Win+L can't be taken at all).
- [ ] Run rice scripts through Git Bash when installed (they're POSIX shell; cmd.exe can't run them).
- [ ] Media keys (`XF86Audio*` -> VK_VOLUME_*), `binde` repeat, `bindm` mouse binds.
- [ ] Self-contained single-file build + winget/Scoop manifests + signed releases.
- [ ] Keep the two cores in sync: shared test fixtures (configs + expected frames as JSON) run by both.

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
