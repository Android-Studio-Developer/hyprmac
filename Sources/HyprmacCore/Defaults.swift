import Foundation

public enum HyprmacInfo {
    public static let version = "0.2.0"

    /// Directory for the control sockets: /tmp/hyprmac-<uid>/
    public static func runtimeDir(uid: UInt32) -> String { "/tmp/hyprmac-\(uid)" }
    /// Request/response socket used by hyprmacctl (like Hyprland's .socket.sock).
    public static func socketPath(uid: UInt32) -> String { runtimeDir(uid: uid) + "/hyprmac.sock" }
    /// Event stream (like Hyprland's .socket2.sock): lines such as `workspace>>2`.
    public static func eventSocketPath(uid: UInt32) -> String { runtimeDir(uid: uid) + "/hyprmac.events.sock" }
}

public enum DefaultConfig {
    /// Written to ~/.config/hyprmac/hyprland.conf on first launch.
    public static let text = """
    # hyprmac config: Hyprland syntax, running on macOS.
    # Docs: README.md in the hyprmac repo. Reload: saved changes apply automatically.
    #
    # SUPER = Command, ALT = Option. Command clashes with app shortcuts (Cmd+Q, Cmd+1...),
    # so this default uses ALT as the main modifier. Change $mainMod to SUPER if you prefer.

    $mainMod = ALT
    $terminal = open -na Terminal
    $browser = open -a Safari
    $files = open ~

    # Caelestia-style shell: a bar across the top and a frame around the screen, colored from
    # your wallpaper. The macOS menu bar auto-hides while it runs (move the mouse to the top).
    hyprmac {
        shell = true          # false = tiling only
        hide_menubar = true
        scheme = auto         # or a seed color: rgb(89b4fa)
    }

    general {
        gaps_in = 5
        gaps_out = 10
        border_size = 2
        # Border colors follow the shell's scheme. Set them yourself to override:
        # col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
        # col.inactive_border = rgba(595959aa)
        layout = dwindle
    }

    decoration {
        rounding = 12
    }

    dwindle {
        preserve_split = true
    }

    master {
        new_status = slave
        mfact = 0.55
    }

    # Windows that should not tile.
    windowrulev2 = float, class:^(System Settings|Calculator|Archive Utility)$
    windowrulev2 = float, title:^(Picture-in-Picture)$

    # Apps
    bind = $mainMod, Return, exec, $terminal
    bind = $mainMod, B, exec, $browser
    bind = $mainMod, E, exec, $files

    # Windows
    bind = $mainMod SHIFT, Q, killactive,
    bind = $mainMod, V, togglefloating,
    bind = $mainMod, F, fullscreen,
    bind = $mainMod, J, togglesplit,
    bind = $mainMod SHIFT, M, exit,

    # Focus
    bind = $mainMod, left, movefocus, l
    bind = $mainMod, right, movefocus, r
    bind = $mainMod, up, movefocus, u
    bind = $mainMod, down, movefocus, d
    bind = $mainMod, H, movefocus, l
    bind = $mainMod, L, movefocus, r
    bind = $mainMod, K, movefocus, u
    bind = $mainMod, N, movefocus, d

    # Move windows
    bind = $mainMod SHIFT, left, movewindow, l
    bind = $mainMod SHIFT, right, movewindow, r
    bind = $mainMod SHIFT, up, movewindow, u
    bind = $mainMod SHIFT, down, movewindow, d

    # Resize the split
    bind = $mainMod, minus, splitratio, -0.1
    bind = $mainMod, equal, splitratio, +0.1

    # Workspaces
    bind = $mainMod, 1, workspace, 1
    bind = $mainMod, 2, workspace, 2
    bind = $mainMod, 3, workspace, 3
    bind = $mainMod, 4, workspace, 4
    bind = $mainMod, 5, workspace, 5
    bind = $mainMod, 6, workspace, 6
    bind = $mainMod, 7, workspace, 7
    bind = $mainMod, 8, workspace, 8
    bind = $mainMod, 9, workspace, 9
    bind = $mainMod, grave, workspace, previous

    bind = $mainMod SHIFT, 1, movetoworkspace, 1
    bind = $mainMod SHIFT, 2, movetoworkspace, 2
    bind = $mainMod SHIFT, 3, movetoworkspace, 3
    bind = $mainMod SHIFT, 4, movetoworkspace, 4
    bind = $mainMod SHIFT, 5, movetoworkspace, 5
    bind = $mainMod SHIFT, 6, movetoworkspace, 6
    bind = $mainMod SHIFT, 7, movetoworkspace, 7
    bind = $mainMod SHIFT, 8, movetoworkspace, 8
    bind = $mainMod SHIFT, 9, movetoworkspace, 9

    # Monitors
    bind = $mainMod, comma, focusmonitor, l
    bind = $mainMod, period, focusmonitor, r

    """
}
