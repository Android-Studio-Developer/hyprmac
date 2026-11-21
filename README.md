# hyprmac

Hyprland-style tiling window manager for macOS. Reads `hyprland.conf` and Hyprland's newer Lua
config (`hyprland.lua`): dwindle and master layouts, gaps, gradient borders, workspaces, keybinds,
window rules, and a `hyprctl`-style CLI with an event socket for bars. Install Linux dotfiles
"rices" straight from GitHub with `hyprmac rice`.

macOS does not let anyone replace its compositor, so this is not Hyprland itself. It drives real
macOS windows through the Accessibility API, the same way yabai and AeroSpace do. It does not need
SIP disabled.

> Status: 0.1.0, early. The core (config, layouts, workspaces) has unit tests; the macOS layer
> builds and detects windows but has not been run day-to-day yet. Expect rough edges.

## Build

Needs macOS 14+ and Swift 5.9+ (Xcode or the Command Line Tools).

```sh
./scripts/bundle.sh          # build/Hyprmac.app + build/hyprmacctl
./scripts/test.sh            # unit tests
```

Install:

```sh
cp -R build/Hyprmac.app ~/Applications/
cp build/hyprmacctl /usr/local/bin/      # or anywhere on PATH
alias hyprctl=hyprmacctl                 # optional
open ~/Applications/Hyprmac.app
```

On first launch macOS asks for **Accessibility** permission (System Settings > Privacy & Security >
Accessibility). hyprmac waits until it is granted. After a rebuild you may need to switch the
permission off and on again, because the ad-hoc signature changes.

Start at login: System Settings > General > Login Items > add Hyprmac.

To try it without the app bundle: `swift run hyprmac` (the terminal app then needs Accessibility).

## Config

`~/.config/hyprmac/hyprland.conf`, created on first run from the default
(`hyprmac --print-default-config`). Saved changes reload automatically. Check a file with
`hyprmac --check-config path`. Set `HYPRMAC_CONFIG` or pass `--config` to use another path.

Modifiers: `SUPER` = Command, `ALT` = Option, `CTRL`, `SHIFT`. The default config uses `ALT`
because Command combos clash with app shortcuts (Cmd+Q, Cmd+1...).

Supported:

| Hyprland | Notes |
|---|---|
| `$var = value`, `source = file`, `section { }`, `section:key` | |
| `general`: `gaps_in`, `gaps_out` (1-4 values), `border_size`, `col.active_border`, `col.inactive_border` (gradients + angle), `layout` | |
| `decoration:rounding` | border corner radius |
| `dwindle`: `preserve_split`, `force_split`, `split_width_multiplier`, `default_split_ratio` | `force_split = 0` acts like 2 |
| `master`: `mfact`, `new_status`, `new_on_top`, `orientation` | |
| `bind`, `binde`, `bindl`, ... `unbind` | flags parsed; repeat (`e`) not yet |
| `exec-once`, `exec` | run with `/bin/sh -c`, Homebrew on PATH. Use `open -a App` for GUI apps |
| `windowrulev2`/`windowrule`: `float`, `tile`, `center`, `fullscreen`, `workspace N [silent]`, `size W H` (px or %) | `class:` matches the app name or bundle id; regex is full-match, case-insensitive |
| `hyprmac:status_bar = false` | hyprmac-only: hide the menu bar item |

Options that only make sense on Linux (`monitor`, `env`, `input`, `animations`, `decoration:blur`,
`bindm`, ...) are accepted and ignored, so a Linux config loads without errors.

Key names follow xkb: `Return`, `space`, `Tab`, `Escape`, `left`, `comma`, `period`, `minus`,
`equal`, `bracketleft`, `F1`...`F20`, letters, digits.

### Dispatchers

`exec`, `killactive`, `workspace` (`N`, `+1`, `-1`, `e+1`, `previous`, `empty`), `movetoworkspace`,
`movetoworkspacesilent`, `movefocus`, `movewindow`, `swapwindow`, `togglefloating`, `setfloating`,
`settiled`, `fullscreen`, `togglesplit`, `splitratio` (`+0.1`, `exact 1.2`), `layoutmsg`
(`togglesplit`, `swapwithmaster`, `mfact`, `orientationleft|right|top|bottom`), `focusmonitor`,
`cyclenext`, `centerwindow`, `exit`.

## Rices (dotfiles)

Apply someone's Hyprland dotfiles from GitHub:

```sh
hyprmac rice install https://github.com/43PR/dotfiles   # clone + show what will happen
hyprmac rice use 43pr --dry-run                         # list every change, change nothing
hyprmac rice use 43pr                                   # apply
hyprmac rice off                                        # undo, restore your old configs
hyprmac rice list | show NAME | update NAME | remove NAME
```

Or pick one from the menu bar item > Rice.

What `use` does:

- Symlinks the rice's macOS-friendly `.config` folders into `~/.config` (kitty, btop, cava,
  fastfetch, nvim, starship, spicetify, sketchybar, ...). Anything already there is moved to
  `~/.local/share/hyprmac/backups/` and comes back on `rice off`.
- Skips Linux-only parts (Quickshell, Waybar, rofi, GTK, dunst, ...). Shell files (`.zshrc`) only
  with `--with-shell`; folders it doesn't know only with `--all`.
- Points hyprmac at the rice's `hyprland.lua` / `hyprland.conf` through a small
  `~/.config/hyprmac/hyprland.conf` that also maps SUPER to Option, so the rice's SUPER+C / SUPER+V
  don't take over Cmd+C / Cmd+V. Add your own tweaks below the `source =` line.
- Sets the rice's wallpaper (`--no-wallpaper` to skip); `rice off` puts yours back.
- Never runs the rice's install script. Its Lua config and keybinds do run commands, like on
  Linux, so only use rices you trust.

### Hyprland Lua configs

Hyprland 0.5x configs written in Lua (`hl.config`, `hl.bind`, `hl.dsp.*`, `hl.window_rule`,
`hl.on`, `hl.exec_cmd`, `hl.dispatch`, `hl.get_active_window`, `require`, `dofile`) run in an
embedded Lua 5.4. Function binds work too. `hl.monitor`, `hl.layer_rule`, `hl.animation`,
`hl.env`... are accepted and ignored. `hyprmac --check-config` shows what loaded, what was
ignored and which binds were skipped.

### Linux commands on a Mac

Commands from configs run with stand-ins for missing Linux tools (in
`~/.local/share/hyprmac/shims`, only when the real program isn't installed):

| Linux | macOS stand-in |
|---|---|
| `hyprctl` | `hyprmacctl` |
| `wl-copy` / `wl-paste` | `pbcopy` / `pbpaste` |
| `notify-send` | notification via `osascript` |
| `xdg-open` | `open` |
| `thunar`, `nautilus`, `dolphin`, `nemo` | `open ~` (Finder) |
| `kitty`, `alacritty`, `wezterm`, `ghostty` | the Mac app if installed, else Terminal |
| `brave`, `firefox`, `chromium`, `google-chrome` | the Mac app, if installed |
| `rofi`, `wofi`, `fuzzel` (launcher mode) | Raycast, Alfred or Spotlight |
| `hyprlock`, `swaylock` | `pmset displaysleepnow` (locks if your Mac asks for a password) |

A bind that needs a program with no stand-in (Quickshell `qs`, `grim`, `slurp`, `cliphist`,
`wpctl`, ...) is not registered at all, so it doesn't steal the key. Scripts the bind runs are
checked too. `hyprmacctl skippedbinds` lists them.

## hyprmacctl

```sh
hyprmacctl dispatch workspace 3
hyprmacctl -j clients
hyprmacctl activewindow | workspaces | monitors | binds | configerrors | skippedbinds | reload | version
hyprmacctl listen          # event stream
```

Events (Hyprland socket2 format): `workspace>>N`, `workspacev2>>N,N`, `focusedmon>>name,N`,
`activewindow>>App,Title`, `activewindowv2>>0xID`, `openwindow>>0xID,N,App,Title`,
`closewindow>>0xID`, `movewindow>>0xID,N`, `configreloaded>>`.
Sockets live in `/tmp/hyprmac-<uid>/`.

Example SketchyBar hook: `hyprmacctl listen | while read -r l; do case $l in workspace\>\>*) sketchybar --trigger hyprmac_ws WS=${l#*>>};; esac; done`

## How it differs from Hyprland

- Workspaces are hyprmac's own, not macOS Spaces. Hidden windows are parked in a screen corner
  with 1px showing (macOS won't put windows fully off screen). Use one macOS Space per display.
- No animations, blur, shadows or opacity on other apps' windows: macOS gives no access to that
  without disabling SIP.
- Borders are separate click-through overlay windows drawn in the gap around each window.
- Minimized, hidden (Cmd+H) and native-fullscreen windows leave the layout until they come back.
- Dragging a tiled window snaps it back when you let go of the mouse.

## Recovery

Quitting (menu bar item > Quit, `hyprmacctl dispatch exit`, Ctrl+C or SIGTERM) moves every hidden
window back on screen. If hyprmac crashes, start it again: it picks up the parked windows and lays
them out on the current workspace.

## Layout

- `Sources/HyprmacCore`: platform-free core (config parser, dwindle/master layouts, workspaces,
  focus, dispatchers, Linux-compat tables, rice catalog). Shared with the planned Windows port.
- `Sources/CLua`: Lua 5.4.7, vendored unchanged (MIT).
- `Sources/HyprLua`: the `hl.*` API shim that turns Hyprland Lua configs into hyprmac config.
- `Sources/hyprmac`: macOS daemon (Accessibility, Carbon hotkeys, borders, menu bar, sockets).
- `Sources/hyprmacctl`: CLI.
- `TODO.md`: roadmap, including the Windows version.
