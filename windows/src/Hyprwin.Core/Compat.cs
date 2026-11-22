namespace Hyprwin.Core;

/// <summary>Running Linux rices on Windows: which programs a command needs, and .cmd stand-ins for
/// common Linux tools (installed only when the real program is missing). Port of LinuxCompat.swift.</summary>
public static class LinuxCompat
{
    public static readonly HashSet<string> LinuxOnly =
    [
        "grim", "slurp", "cliphist", "qs", "quickshell", "hyprpicker", "hyprpaper", "hypridle",
        "hyprsunset", "hyprpolkitagent", "brightnessctl", "gpu-screen-recorder", "wf-recorder",
        "nm-applet", "nm-connection-editor", "blueman-manager", "blueman-applet", "systemctl",
        "loginctl", "pactl", "wpctl", "pamixer", "pavucontrol", "playerctl", "swww", "swww-daemon",
        "awww", "awww-daemon", "waybar", "eww", "ags", "dunst", "dunstctl", "mako", "makoctl",
        "swaync", "swaync-client", "wlogout", "nwg-look", "nwg-dock", "gsettings", "xdg-user-dir",
        "dbus-update-activation-environment", "pkexec", "wtype", "ydotool", "hyprshot", "swappy",
        "satty", "matugen", "wal", "zenity", "kdialog", "xdotool", "xrandr", "wlr-randr",
        "pgrep", "pkill", "killall", "notify-send-sh",
    ];

    public static readonly HashSet<string> Shimmable =
    [
        "hyprctl", "wl-copy", "wl-paste", "xdg-open", "notify-send", "hyprlock", "swaylock",
        "thunar", "nautilus", "dolphin", "nemo", "pcmanfm", "brave", "brave-browser", "firefox",
        "chromium", "google-chrome", "google-chrome-stable", "rofi", "wofi", "fuzzel", "tofi",
        "kitty", "alacritty", "wezterm", "ghostty", "foot",
    ];

    /// <summary>Known program names appearing in a command as words.</summary>
    public static List<string> Programs(string command)
    {
        var found = new List<string>();
        var words = System.Text.RegularExpressions.Regex.Split(command, @"[^\p{L}\p{N}\-_.]+");
        foreach (var w in words)
            if ((LinuxOnly.Contains(w) || Shimmable.Contains(w)) && !found.Contains(w)) found.Add(w);
        return found;
    }

    static readonly HashSet<string> ShellBuiltins =
    [
        "cd", "echo", "exec", "export", "if", "for", "while", "test", "[", "true", "false", "eval",
        "source", ".", "printf", "read", "set", "unset", "kill", "sleep", "{", "(",
        // cmd.exe
        "start", "call", "dir", "copy", "del", "move", "mkdir", "rmdir", "type", "cls", "exit",
    ];

    /// <summary>Programs a command needs that aren't available (PATH + shims).</summary>
    public static List<string> Missing(string command, Func<string, bool> available)
    {
        var o = Programs(command).Where(p => !available(p)).ToList();
        var first = command.Trim().Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
        first = first.Trim('"');
        if (first.Length > 0 && !first.Contains('=') && !first.StartsWith('~') && !first.StartsWith('$') && !first.StartsWith('%')
            && !ShellBuiltins.Contains(first.ToLowerInvariant()) && !available(first) && !o.Contains(first))
            o.Insert(0, first);
        return o;
    }

    /// <summary>.cmd stand-ins for missing Linux tools. <paramref name="exists"/> says whether a Windows
    /// program (e.g. "brave.exe", "wt.exe") can be started.</summary>
    public static Dictionary<string, string> WindowsShims(string ctlPath, Func<string, bool> exists)
    {
        const string h = "@echo off\r\nrem hyprwin stand-in for a Linux tool. Delete to disable.\r\n";
        var s = new Dictionary<string, string>
        {
            ["hyprctl"] = h + $"\"{ctlPath}\" %*\r\n",
            ["wl-copy"] = h + "if \"%~1\"==\"\" (clip) else (echo|set /p=%*| clip)\r\n",
            ["wl-paste"] = h + "powershell -NoProfile -Command Get-Clipboard\r\n",
            ["xdg-open"] = h + "start \"\" %*\r\n",
            ["notify-send"] = h +
                "powershell -NoProfile -WindowStyle Hidden -Command \"Add-Type -AssemblyName System.Windows.Forms; " +
                "$n = New-Object System.Windows.Forms.NotifyIcon; $n.Icon = [System.Drawing.SystemIcons]::Information; " +
                "$n.Visible = $true; $n.ShowBalloonTip(5000, $args[0], [string]$args[1], 'Info'); Start-Sleep 6; $n.Dispose()\" %*\r\n",
        };
        foreach (var l in new[] { "hyprlock", "swaylock" }) s[l] = h + "rundll32.exe user32.dll,LockWorkStation\r\n";
        foreach (var fm in new[] { "thunar", "nautilus", "dolphin", "nemo", "pcmanfm" })
            s[fm] = h + "if \"%~1\"==\"\" (start \"\" explorer \"%USERPROFILE%\") else (start \"\" explorer %*)\r\n";
        (string cmd, string exe)[] browsers =
        [
            ("brave", "brave.exe"), ("brave-browser", "brave.exe"), ("firefox", "firefox.exe"),
            ("chromium", "chrome.exe"), ("google-chrome", "chrome.exe"), ("google-chrome-stable", "chrome.exe"),
        ];
        foreach (var (cmd, exe) in browsers)
            if (exists(exe)) s[cmd] = h + $"start \"\" {exe} %*\r\n";
        // Launchers: open the Start menu search (Ctrl+Esc). dmenu mode can't be faked.
        foreach (var l in new[] { "rofi", "wofi", "fuzzel", "tofi" })
            s[l] = h + "echo %* | findstr /i /c:\"-dmenu\" >nul && exit /b 1\r\n" +
                   "powershell -NoProfile -WindowStyle Hidden -Command \"(New-Object -ComObject WScript.Shell).SendKeys('^{ESC}')\"\r\n";
        // Terminals: the real one if installed, else Windows Terminal, else a console.
        string fallbackTerm = exists("wt.exe") ? "start \"\" wt.exe\r\n" : "start \"\" cmd.exe\r\n";
        foreach (var (cmd, exe) in new[] { ("kitty", ""), ("alacritty", "alacritty.exe"), ("wezterm", "wezterm-gui.exe"), ("ghostty", ""), ("foot", "") })
            s[cmd] = h + (exe.Length > 0 && exists(exe) ? $"start \"\" {exe} %*\r\n" : fallbackTerm);
        return s;
    }
}

public enum RiceKind { Link, NotHere, Shell, Unknown }

/// <summary>Where each .config entry of a rice goes on Windows.</summary>
public static class RiceCatalog
{
    /// <summary>Classify an entry. <paramref name="target"/> is the path to link for <see cref="RiceKind.Link"/>.</summary>
    public static RiceKind ClassifyWindows(string name, string profile, string appData, string localAppData, out string? target)
    {
        string cfg = Path.Combine(profile, ".config", name);
        target = name switch
        {
            // Read from ~/.config on Windows too.
            "hypr" or "hyprwin" or "hyprmac" or "wezterm" or "fastfetch" or "starship.toml" or "git" or "neofetch"
                or "onefetch" or "glow" or "atuin" or "posting" => cfg,
            "nvim" => Path.Combine(localAppData, "nvim"),
            "lazygit" => Path.Combine(localAppData, "lazygit"),
            "alacritty" => Path.Combine(appData, "alacritty"),
            "helix" => Path.Combine(appData, "helix"),
            "spicetify" => Path.Combine(appData, "spicetify"),
            "yazi" => Path.Combine(appData, "yazi", "config"),
            "mpv" => Path.Combine(appData, "mpv"),
            "bat" => Path.Combine(appData, "bat"),
            "zed" => Path.Combine(appData, "Zed"),
            "gh" => Path.Combine(appData, "GitHub CLI"),
            "Code" => Path.Combine(appData, "Code"),
            "btop" => Path.Combine(profile, ".config", "btop"),
            _ => null,
        };
        if (target is not null) return RiceKind.Link;
        if (Shell.Contains(name)) return RiceKind.Shell;
        if (NotOnWindows.Contains(name)) return RiceKind.NotHere;
        return RiceKind.Unknown;
    }

    /// <summary>Linux desktop parts and apps that don't exist on Windows.</summary>
    public static readonly HashSet<string> NotOnWindows =
    [
        "quickshell", "waybar", "rofi", "wofi", "fuzzel", "tofi", "gtk-2.0", "gtk-3.0", "gtk-4.0",
        "dunst", "mako", "swaync", "wlogout", "nwg-look", "nwg-dock-hyprland", "nwg-drawer", "hyprpanel",
        "ags", "eww", "Kvantum", "qt5ct", "qt6ct", "xsettingsd", "swaylock", "foot", "picom", "i3",
        "sway", "polybar", "xfce4", "Thunar", "pipewire", "wireplumber", "systemd", "environment.d",
        "mimeapps.list", "user-dirs.dirs", "user-dirs.locale", "autostart", "fontconfig", "hyprpaper",
        "hypridle", "hyprlock", "wal", "matugen", "uwsm", "xdg-desktop-portal", "nwg-displays",
        "pavucontrol.ini", "kdeglobals", "dolphinrc", "gammastep", "wlsunset",
        // macOS/Linux-only apps
        "kitty", "ghostty", "cava", "sketchybar", "borders", "aerospace", "skhd", "yabai", "karabiner",
    ];

    public static readonly HashSet<string> Shell =
    [
        ".zshrc", ".bashrc", ".zshenv", ".zprofile", ".profile", ".bash_profile", "zsh", "fish", "bash",
        "nushell", "starship",
    ];

    /// <summary>Images that are likely wallpapers (not screenshots/banners), best first.</summary>
    public static List<string> WallpaperCandidates(IEnumerable<string> relativePaths)
    {
        string[] exts = ["jpg", "jpeg", "png", "bmp", "webp"];
        string[] badWords = ["screenshot", "banner", "preview", "desktop", "demo", "logo", "icon", "pfp", "avatar", "showcase"];
        string[] badDirs = ["assets", "docs", "screenshots", "preview", "previews", ".github", "icons", "imgs", "fonts"];
        int? Score(string p)
        {
            var lower = p.Replace('\\', '/').ToLowerInvariant();
            if (!exts.Contains(Path.GetExtension(lower).TrimStart('.'))) return null;
            var comps = lower.Split('/');
            var file = comps[^1];
            var dirs = comps[..^1];
            if (badWords.Any(file.Contains)) return null;
            if (dirs.Any(badDirs.Contains)) return null;
            if (dirs.Any(d => d.Contains("wall"))) return 0;
            if (file.Contains("wall")) return 1;
            return comps.Length == 1 ? 2 : null;
        }
        return relativePaths.Select(p => (p, s: Score(p))).Where(x => x.s is not null)
            .OrderBy(x => x.s).ThenBy(x => x.p, StringComparer.Ordinal).Select(x => x.p).ToList();
    }
}
