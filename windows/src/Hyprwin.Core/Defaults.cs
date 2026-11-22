namespace Hyprwin.Core;

public static class HyprwinInfo
{
    public const string Version = "0.1.0";

    static string User => Environment.UserName.Replace(' ', '_');
    /// <summary>Request/response pipe used by hyprwinctl (like Hyprland's .socket.sock).</summary>
    public static string PipeName => $"hyprwin-{User}";
    /// <summary>Event stream (like socket2): lines such as "workspace>>2".</summary>
    public static string EventPipeName => $"hyprwin-events-{User}";

    /// <summary>%LOCALAPPDATA%\hyprwin: rices, backups, shims, active-rice.json.</summary>
    public static string DataDir
    {
        get
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrEmpty(local)) local = Path.Combine(ConfigParser.Home, ".local", "share");
            return Path.Combine(local, "hyprwin");
        }
    }
}

public static class DefaultConfig
{
    /// <summary>Written to ~/.config/hyprwin/hyprland.conf on first launch.</summary>
    public const string Text = """
    # hyprwin config: Hyprland syntax, running on Windows.
    # Docs: windows/README.md in the hyprmac repo. Saved changes apply automatically.
    #
    # SUPER = Windows key, ALT = Alt. Windows reserves many Win+key combos (Win+L, Win+D,
    # Win+1..9), so this default uses ALT as the main modifier. Change $mainMod if you prefer.
    # Commands run with cmd.exe; `start "" app` launches GUI apps.

    $mainMod = ALT
    $terminal = start "" wt.exe
    $browser = start "" msedge.exe
    $files = start "" explorer.exe

    # Desktop shell: bar on the left, a frame around the screen, and panels that open from it.
    # Colors come from your wallpaper (scheme = auto) or a seed color like rgb(89b4fa).
    hyprwin {
        shell = true
        hide_taskbar = true
        scheme = auto
    }

    general {
        gaps_in = 6
        gaps_out = 18
        border_size = 2
        # Border colors follow the shell scheme. Set col.active_border / col.inactive_border to override.
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

    # Windows that should not tile (class = process name or window class).
    windowrulev2 = float, class:^(SystemSettings|CalculatorApp|Taskmgr|mmc)$
    windowrulev2 = float, title:^(Picture-in-Picture|Picture in picture)$

    # Shell
    bind = $mainMod, D, global, shell:launcher
    bind = $mainMod SHIFT, D, global, shell:dashboard
    bind = $mainMod SHIFT, P, global, shell:session

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

    """;
}
