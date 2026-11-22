using Hyprwin.Core;

namespace Hyprwin.Core.Tests;

static class Temp
{
    public static string Dir(Dictionary<string, string>? files = null)
    {
        var d = Path.Combine(Path.GetTempPath(), "hyprwin-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(d);
        foreach (var (name, text) in files ?? [])
        {
            var p = Path.Combine(d, name);
            Directory.CreateDirectory(Path.GetDirectoryName(p)!);
            File.WriteAllText(p, text);
        }
        return d;
    }
}

// Lua state is static (LuaConfig), so these run one at a time.
[Collection("lua")]
public class LuaTests
{
    [Fact]
    public void HyprlandLuaConfigBecomesConfig()
    {
        LuaConfig.Install();
        var dir = Temp.Dir(new()
        {
            ["hyprland.lua"] = """
            mainMod = "SUPER"
            hl.config({
                general = {
                    gaps_in = 4,
                    gaps_out = { top = 5, right = 8, bottom = 8, left = 8 },
                    border_size = 1,
                    col = { active_border = "rgba(89b4faff)", inactive_border = "rgba(45475aaa)" },
                    layout = "master",
                },
                decoration = { rounding = 8, blur = { enabled = true } },
                master = { new_status = "master" },
            })
            hl.env("QT_QPA_PLATFORM", "wayland")
            hl.on("hyprland.start", function() hl.exec_cmd("echo started") end)
            hl.exec_cmd("echo top-level")
            local f = os.getenv("HOME") .. "/.config/hypr/colors.lua"
            require("keys")
            hl.window_rule({ name = "x", match = { class = "^(kitty)$" }, float = true, size = "900 600" })
            hl.window_rule({ match = { class = ".*", fullscreen = true }, opacity = "1.0 override" })
            """,
            ["keys.lua"] = """
            hl.bind(mainMod .. " + T", hl.dsp.exec_cmd("kitty"))
            hl.bind(mainMod .. " + SHIFT + Q", hl.dsp.window.close())
            hl.bind(mainMod .. " + H", hl.dsp.focus({ direction = "left" }))
            hl.bind(mainMod .. " + SHIFT + 3", hl.dsp.window.move({ workspace = 3 }))
            hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
            hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute"))
            hl.bind("Delete", hl.dsp.exec_cmd([==[sh -c '
            grim /tmp/x.png
            ']==]))
            hl.bind(mainMod .. " + Space", function()
                hl.dispatch(hl.dsp.window.float({ action = "toggle" }))
                local w = hl.get_active_window()
                if w and w.floating then
                    hl.dispatch(hl.dsp.window.resize({ x = 100, y = 50, relative = false }))
                end
            end)
            """,
        });
        var c = ConfigParser.Load(Path.Combine(dir, "hyprland.lua"));
        Assert.Empty(c.Errors);
        Assert.Equal(Insets.All(4), c.GapsIn);
        Assert.Equal(new Insets(5, 8, 8, 8), c.GapsOut);
        Assert.Equal(1, c.BorderSize);
        Assert.Equal(8, c.Rounding);
        Assert.Equal("master", c.Layout);
        Assert.Equal("89b4faff", c.ActiveBorder.Colors[0].Hex);
        Assert.Contains(c.Files, f => f.EndsWith("keys.lua"));

        KeyBind? Bind(string key, Mods mods = Mods.Super) => c.Binds.FirstOrDefault(b => b.Key == key && b.Mods == mods);
        Assert.Equal("kitty", Bind("t")!.Arg);
        Assert.Equal("killactive", Bind("q", Mods.Super | Mods.Shift)!.Dispatcher);
        Assert.Equal("l", Bind("h")!.Arg);
        Assert.Equal("movetoworkspace", Bind("3", Mods.Super | Mods.Shift)!.Dispatcher);
        Assert.Equal("lua", Bind("delete", Mods.None)!.Dispatcher);
        Assert.Contains("grim", LuaConfig.StoredCommand(Bind("delete", Mods.None)!.Arg));
        Assert.Contains(c.Ignored, i => i.Contains("XF86AudioMute"));
        Assert.Contains("bindm", c.Ignored);
        Assert.Contains("windowrule:match_fullscreen", c.Ignored);
        Assert.Equal(["float", "size 900 600"], c.Rules.Select(r => r.Effect).Order());

        var calls = new List<string>();
        LuaConfig.Host = (op, arg) =>
        {
            calls.Add(op + " " + arg);
            return op == "activewindow" ? LuaConfig.Table(new Dictionary<string, object?> { ["floating"] = true }) : null;
        };
        LuaConfig.Call(Bind("space")!.Arg);
        Assert.Equal(["dispatch togglefloating\t", "activewindow ", "dispatch resizeactive\texact 100 50"], calls);
        calls.Clear();
        LuaConfig.Emit("hyprland.start");
        Assert.Equal(["exec echo top-level", "exec echo started"], calls);
        LuaConfig.Host = null;
    }

    [Fact]
    public void LuaErrorsAreReportedNotFatal()
    {
        LuaConfig.Install();
        var dir = Temp.Dir(new() { ["hyprland.lua"] = "hl.config({ general = { gaps_in = 2 } })\nhl.bind('SUPER + T', hl.dsp.exec_cmd('kitty'))\nerror('boom')\n" });
        var c = ConfigParser.Load(Path.Combine(dir, "hyprland.lua"));
        Assert.Single(c.Errors);
        Assert.Contains("boom", c.Errors[0]);
        Assert.Equal(Insets.All(2), c.GapsIn);
        Assert.Single(c.Binds);
    }

    [Fact]
    public void Quoting() => Assert.Equal("\"a\\\"b\\\\c\\0101\"", LuaRuntime.Quote("a\"b\\c\n1"));

    [Fact]
    public void PreludeIsTheSharedFile()
    {
        // The Swift build embeds a generated copy; this guards the Windows side reads the same file.
        var shared = Path.Combine(AppContext.BaseDirectory, "../../../../../../shared/hl-prelude.lua");
        using var s = typeof(LuaRuntime).Assembly.GetManifestResourceStream("hl-prelude.lua")!;
        Assert.Equal(File.ReadAllText(shared), new StreamReader(s).ReadToEnd());
    }
}

public class CompatTests
{
    [Fact]
    public void FindsProgramsInCommands()
    {
        Assert.Equal(["pgrep", "rofi", "pkill"], LinuxCompat.Programs("pgrep -x rofi >/dev/null && pkill -x rofi || rofi -show drun"));
        Assert.Equal(["grim", "slurp", "wl-copy"], LinuxCompat.Programs("grim -g \"$(slurp)\" - | wl-copy"));
        Assert.Empty(LinuxCompat.Programs("echo kitty.conf"));
    }

    [Fact]
    public void MissingIncludesFirstWord()
    {
        HashSet<string> have = ["kitty"];
        Assert.Equal(["thunar"], LinuxCompat.Missing("thunar ~", have.Contains));
        Assert.Empty(LinuxCompat.Missing("kitty -e btop", have.Contains));
        Assert.Empty(LinuxCompat.Missing("start \"\" msedge.exe", _ => false));
        Assert.Equal(["sh", "grim"], LinuxCompat.Missing("sh -c 'grim x'", have.Contains));
    }

    [Fact]
    public void ShimsCoverCommonTools()
    {
        var s = LinuxCompat.WindowsShims(@"C:\hyprwin\hyprwinctl.exe", exe => exe is "wt.exe" or "brave.exe");
        Assert.Contains("hyprwinctl.exe", s["hyprctl"]);
        Assert.Contains("wt.exe", s["kitty"]);
        Assert.Contains("brave.exe", s["brave"]);
        Assert.False(s.ContainsKey("firefox"));
        Assert.Contains("explorer", s["thunar"]);
        Assert.Contains("LockWorkStation", s["hyprlock"]);
    }

    [Fact]
    public void Catalog()
    {
        Assert.Equal(RiceKind.Link, RiceCatalog.ClassifyWindows("nvim", "P", "A", "L", out var t));
        Assert.Equal(Path.Combine("L", "nvim"), t);
        Assert.Equal(RiceKind.NotHere, RiceCatalog.ClassifyWindows("kitty", "P", "A", "L", out _));
        Assert.Equal(RiceKind.NotHere, RiceCatalog.ClassifyWindows("quickshell", "P", "A", "L", out _));
        Assert.Equal(RiceKind.Shell, RiceCatalog.ClassifyWindows(".zshrc", "P", "A", "L", out _));
        Assert.Equal(RiceKind.Unknown, RiceCatalog.ClassifyWindows("mystery", "P", "A", "L", out _));
        Assert.Equal(["walls/a.png", "wallhaven-k8jvm7.jpg"], RiceCatalog.WallpaperCandidates(
            ["assets/desktop.png", "wallhaven-k8jvm7.jpg", ".config/neofetch/pfp.png", "walls/a.png", "x/screenshots/n.png"]));
    }
}

/// <summary>Fake OS layer: symlinks instead of junctions, wallpaper in memory.</summary>
sealed class FakePlatform(string home) : IRicePlatform
{
    public string? Wallpaper = "/old.jpg";
    public RiceKind Classify(string name, out string? target) =>
        RiceCatalog.ClassifyWindows(name, home, Path.Combine(home, "AppData", "Roaming"), Path.Combine(home, "AppData", "Local"), out target);
    public void LinkDirectory(string link, string target) => Directory.CreateSymbolicLink(link, target);
    public bool LinkFile(string link, string target) { File.CreateSymbolicLink(link, target); return false; }
    public string? GetWallpaper() => Wallpaper;
    public void SetWallpaper(string path) => Wallpaper = path;
    public void Git(params string[] args) => throw new InvalidOperationException("no network in tests");
}

[Collection("lua")]
public class RiceTests
{
    [Fact]
    public void UseAndOffRestoreEverything()
    {
        var home = Temp.Dir(new() { [".config/wezterm/wezterm.lua"] = "-- mine", [".config/hyprwin/hyprland.conf"] = "# my config" });
        var rice = Temp.Dir(new()
        {
            [".config/hypr/hyprland.lua"] = "hl.config({ general = { gaps_in = 3 } })",
            [".config/wezterm/wezterm.lua"] = "-- rice",
            [".config/nvim/init.lua"] = "-- nvim",
            [".config/quickshell/shell.qml"] = "",
            [".config/kitty/kitty.conf"] = "",
            [".config/starship.toml"] = "",
            ["wallhaven-1.jpg"] = "img",
            ["assets/desktop.png"] = "img",
        });
        var old = Environment.GetEnvironmentVariable("HOME");
        Environment.SetEnvironmentVariable("HOME", home);
        try
        {
            var platform = new FakePlatform(home);
            var output = new StringWriter();
            var rm = new RiceManager(platform, Path.Combine(home, "data"), Config.DefaultPath, output);
            rm.Install(rice, "test");
            var plan = rm.Plan("test");
            Assert.Equal(["hypr", "nvim", "starship.toml", "wezterm"], plan.Items.Where(i => i.Kind == RiceKind.Link).Select(i => i.Name));
            Assert.Equal(["kitty", "quickshell"], plan.Items.Where(i => i.Kind == RiceKind.NotHere).Select(i => i.Name));
            Assert.EndsWith("wallhaven-1.jpg", plan.Wallpaper);

            rm.Use("test", dryRun: false, wallpaper: true, withShell: false, all: false);
            Assert.Equal("-- rice", File.ReadAllText(Path.Combine(home, ".config/wezterm/wezterm.lua")));
            Assert.Equal("-- nvim", File.ReadAllText(Path.Combine(home, "AppData/Local/nvim/init.lua")));
            var pointer = File.ReadAllText(Path.Combine(home, ".config/hyprwin/hyprland.conf"));
            Assert.Contains("source = ~/.config/hypr/hyprland.lua", pointer);
            Assert.EndsWith("wallhaven-1.jpg", platform.Wallpaper);
            Assert.Equal("test", rm.Active);

            LuaConfig.Install();
            var cfg = ConfigParser.Load(Config.DefaultPath);
            Assert.Empty(cfg.Errors);
            Assert.Equal(Insets.All(3), cfg.GapsIn);
            Assert.Equal(Mods.Alt, cfg.SuperMapsTo);

            rm.Off();
            Assert.Equal("-- mine", File.ReadAllText(Path.Combine(home, ".config/wezterm/wezterm.lua")));
            Assert.Equal("# my config", File.ReadAllText(Path.Combine(home, ".config/hyprwin/hyprland.conf")));
            Assert.False(Directory.Exists(Path.Combine(home, "AppData/Local/nvim")));
            Assert.False(Directory.Exists(Path.Combine(home, ".config/hypr")));
            Assert.Equal("/old.jpg", platform.Wallpaper);
            Assert.Null(rm.Active);
            Assert.True(File.Exists(Path.Combine(rice, ".config/wezterm/wezterm.lua"))); // rice itself untouched
        }
        finally { Environment.SetEnvironmentVariable("HOME", old); }
    }

    [Fact]
    public void Names()
    {
        Assert.Equal("43pr", RiceManager.DefaultName("https://github.com/43PR/dotfiles"));
        Assert.Equal("hyprland-rice", RiceManager.DefaultName("https://github.com/someone/Hyprland-Rice.git"));
    }
}
