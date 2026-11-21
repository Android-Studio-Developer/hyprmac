import Foundation

/// Running Linux rices on another OS: which programs a command needs, and small stand-in
/// scripts ("shims") for common Linux tools. Shims are only installed when the real program
/// is missing, so they never shadow something the user installed.
public enum LinuxCompat {
    /// Linux desktop programs with no stand-in. A bind or autostart command that needs one of
    /// these (and doesn't have it) is skipped instead of grabbing a key for nothing.
    public static let linuxOnly: Set<String> = [
        "grim", "slurp", "cliphist", "qs", "quickshell", "hyprpicker", "hyprpaper", "hypridle",
        "hyprsunset", "hyprpolkitagent", "brightnessctl", "gpu-screen-recorder", "wf-recorder",
        "nm-applet", "nm-connection-editor", "blueman-manager", "blueman-applet", "systemctl",
        "loginctl", "pactl", "wpctl", "pamixer", "pavucontrol", "playerctl", "swww", "swww-daemon",
        "awww", "awww-daemon", "waybar", "eww", "ags", "dunst", "dunstctl", "mako", "makoctl",
        "swaync", "swaync-client", "wlogout", "nwg-look", "nwg-dock", "gsettings", "xdg-user-dir",
        "dbus-update-activation-environment", "pkexec", "wtype", "ydotool", "hyprshot", "swappy",
        "satty", "matugen", "wal", "zenity", "kdialog", "xdotool", "xrandr", "wlr-randr",
    ]

    /// Tools that get a macOS stand-in when missing.
    public static let shimmable: Set<String> = [
        "hyprctl", "wl-copy", "wl-paste", "xdg-open", "notify-send", "hyprlock", "swaylock",
        "thunar", "nautilus", "dolphin", "nemo", "pcmanfm", "brave", "brave-browser", "firefox",
        "chromium", "google-chrome", "google-chrome-stable", "rofi", "wofi", "fuzzel", "tofi",
        "kitty", "alacritty", "wezterm", "ghostty", "foot",
    ]

    /// Known program names that appear in `command` as words.
    public static func programs(in command: String) -> [String] {
        let names = linuxOnly.union(shimmable)
        var found: [String] = []
        // Split on shell punctuation; keep '-', '.', '_' inside names.
        let words = command.split(whereSeparator: { c in
            !(c.isLetter || c.isNumber || c == "-" || c == "_" || c == ".")
        })
        for w in words {
            let s = String(w)
            if names.contains(s), !found.contains(s) { found.append(s) }
        }
        return found
    }

    /// Programs `command` needs that are not available. `available` checks PATH (shims included).
    public static func missing(in command: String, available: (String) -> Bool) -> [String] {
        var out = programs(in: command).filter { !available($0) }
        // The command's own program, e.g. `thunar` or `/usr/bin/foo`.
        let first = command.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let isEnvAssignment = first.contains("=")
        if !first.isEmpty, !isEnvAssignment, !first.hasPrefix("~"), !first.hasPrefix("$"),
           !shellBuiltins.contains(first), !available(first), !out.contains(first) {
            out.insert(first, at: 0)
        }
        return out
    }

    static let shellBuiltins: Set<String> = [
        "cd", "echo", "exec", "export", "if", "for", "while", "test", "[", "true", "false", "eval",
        "source", ".", "printf", "read", "set", "unset", "kill", "sleep", "{", "(",
    ]

    /// macOS shim scripts for missing tools. `ctlPath` is the hyprmacctl binary.
    /// `appExists` checks /Applications for an app bundle name.
    public static func macShims(ctlPath: String, appExists: (String) -> Bool) -> [String: String] {
        let sh = "#!/bin/sh\n# hyprmac stand-in for a Linux tool. Delete to disable.\n"
        var s: [String: String] = [:]
        s["hyprctl"] = sh + "exec \(shellQuote(ctlPath)) \"$@\"\n"
        s["wl-copy"] = sh + """
        text=""
        for a in "$@"; do case "$a" in -*) ;; *) text="$a" ;; esac; done
        if [ -n "$text" ]; then printf '%s' "$text" | pbcopy; else pbcopy; fi

        """
        s["wl-paste"] = sh + "exec pbpaste\n"
        s["xdg-open"] = sh + "exec open \"$@\"\n"
        s["notify-send"] = sh + """
        title=""; body=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -a|-i|-t|-u|-c|-h|-r|-e|--app-name|--icon|--expire-time|--urgency|--category|--hint|--replace-id) shift 2 ;;
            -*) shift ;;
            *) if [ -z "$title" ]; then title="$1"; else body="$1"; fi; shift ;;
          esac
        done
        exec osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$title" "$body"

        """
        for lock in ["hyprlock", "swaylock"] {
            s[lock] = sh + "exec pmset displaysleepnow\n"
        }
        for fm in ["thunar", "nautilus", "dolphin", "nemo", "pcmanfm"] {
            s[fm] = sh + "exec open \"${1:-$HOME}\"\n"
        }
        let browsers: [(String, String)] = [
            ("brave", "Brave Browser"), ("brave-browser", "Brave Browser"), ("firefox", "Firefox"),
            ("chromium", "Chromium"), ("google-chrome", "Google Chrome"), ("google-chrome-stable", "Google Chrome"),
        ]
        for (cmd, app) in browsers where appExists(app) {
            s[cmd] = sh + "exec open -a \(shellQuote(app)) \"$@\"\n"
        }
        // Launchers: open Raycast/Alfred, or press Cmd+Space for Spotlight. dmenu mode can't be faked.
        let launcher: String
        if appExists("Raycast") {
            launcher = "exec open -a Raycast\n"
        } else if appExists("Alfred 5") {
            launcher = "exec open -a 'Alfred 5'\n"
        } else {
            launcher = "exec osascript -e 'tell application \"System Events\" to keystroke space using command down'\n"
        }
        for l in ["rofi", "wofi", "fuzzel", "tofi"] {
            s[l] = sh + "for a in \"$@\"; do case \"$a\" in -dmenu|--dmenu|-d) exit 1 ;; esac; done\n" + launcher
        }
        // Terminals: the real app if installed, else Terminal.app.
        let terms: [(String, String)] = [("kitty", "kitty"), ("alacritty", "Alacritty"), ("wezterm", "WezTerm"),
                                         ("ghostty", "Ghostty"), ("foot", "")]
        for (cmd, app) in terms {
            if !app.isEmpty, appExists(app) {
                s[cmd] = sh + "exec open -na \(shellQuote(app)) --args \"$@\"\n"
            } else {
                s[cmd] = sh + "exec open -na Terminal\n"
            }
        }
        return s
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// How `hyprmac rice` treats each entry of a rice's `.config` folder.
public enum RiceCatalog {
    public enum Kind: Equatable {
        /// Works on macOS: linked into ~/.config.
        case link
        /// Linux desktop component with no macOS counterpart.
        case linuxOnly
        /// Shell startup files: only linked with --with-shell (they often contain Linux-only aliases).
        case shell
        /// Not known: only linked with --all.
        case unknown
    }

    public static let portable: Set<String> = [
        "hypr", "hyprmac", "kitty", "alacritty", "wezterm", "ghostty", "btop", "htop", "cava",
        "fastfetch", "neofetch", "nvim", "vim", "helix", "tmux", "zellij", "yazi", "lf", "ranger",
        "lazygit", "lazydocker", "spicetify", "sketchybar", "borders", "aerospace", "skhd", "yabai",
        "karabiner", "starship.toml", "bat", "eza", "glow", "k9s", "mpv", "git", "gh", "ncspot",
        "spotify-player", "cmus", "newsboat", "zed", "Code", "micro", "nano", "wallust", "pywal",
        "tealdeer", "atuin", "fzf", "ripgrep", "posting", "superfile", "onefetch", "pfetch",
    ]

    public static let linuxOnly: Set<String> = [
        "quickshell", "waybar", "rofi", "wofi", "fuzzel", "tofi", "gtk-2.0", "gtk-3.0", "gtk-4.0",
        "dunst", "mako", "swaync", "wlogout", "nwg-look", "nwg-dock-hyprland", "nwg-drawer", "hyprpanel",
        "ags", "eww", "Kvantum", "qt5ct", "qt6ct", "xsettingsd", "swaylock", "foot", "picom", "i3",
        "sway", "polybar", "xfce4", "Thunar", "pipewire", "wireplumber", "systemd", "environment.d",
        "mimeapps.list", "user-dirs.dirs", "user-dirs.locale", "autostart", "fontconfig", "hyprpaper",
        "hypridle", "hyprlock", "wal", "matugen", "uwsm", "xdg-desktop-portal", "nwg-displays",
        "pavucontrol.ini", "kdeglobals", "dolphinrc", "gammastep", "wlsunset",
    ]

    public static let shell: Set<String> = [
        ".zshrc", ".bashrc", ".zshenv", ".zprofile", ".profile", ".bash_profile", "zsh", "fish", "bash",
        "nushell", "starship",
    ]

    public static func classify(_ name: String) -> Kind {
        if portable.contains(name) { return .link }
        if linuxOnly.contains(name) { return .linuxOnly }
        if shell.contains(name) { return .shell }
        return .unknown
    }

    /// Images that are likely wallpapers (not screenshots/banners), best first.
    public static func wallpaperCandidates(_ relativePaths: [String]) -> [String] {
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "webp"]
        let badWords = ["screenshot", "banner", "preview", "desktop", "demo", "logo", "icon", "pfp", "avatar", "showcase"]
        let badDirs = ["assets", "docs", "screenshots", "preview", "previews", ".github", "icons", "imgs", "fonts"]
        func score(_ p: String) -> Int? {
            let lower = p.lowercased()
            guard exts.contains((lower as NSString).pathExtension) else { return nil }
            let comps = lower.split(separator: "/").map(String.init)
            let file = comps.last ?? ""
            if badWords.contains(where: { file.contains($0) }) { return nil }
            if comps.dropLast().contains(where: { badDirs.contains($0) }) { return nil }
            if comps.dropLast().contains(where: { $0.contains("wall") }) { return 0 }
            if file.contains("wall") { return 1 }
            if comps.count == 1 { return 2 }
            return nil
        }
        return relativePaths.compactMap { p in score(p).map { (p, $0) } }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            .map(\.0)
    }
}
