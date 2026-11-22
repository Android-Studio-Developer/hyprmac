using Hyprwin.Core;

namespace Hyprwin.Core.Tests;

// Same cases as Tests/HyprmacCoreTests (Swift): both cores must behave the same.

public class ConfigTests
{
    [Fact]
    public void DefaultConfigParsesClean()
    {
        var c = ConfigParser.Parse(DefaultConfig.Text);
        Assert.Empty(c.Errors);
        Assert.True(c.Binds.Count > 30);
        Assert.Equal(Insets.All(18), c.GapsOut);
        Assert.True(c.Shell);
        Assert.False(c.BordersExplicit);
        Assert.Contains(c.Binds, b => b.Dispatcher == "global" && b.Arg == "shell:launcher");
        Assert.True(c.PreserveSplit);
        Assert.Equal(2, c.Rules.Count);
    }

    [Fact]
    public void SectionsVariablesAndColonKeys()
    {
        var c = ConfigParser.Parse("""
        $mod = SUPER
        $gap = 7
        general {
            gaps_in = $gap
            gaps_out = 10 20
            border_size = 3
            layout = master
        }
        master:mfact = 0.6
        decoration {
            rounding = 4
            blur {
                enabled = true
            }
        }
        bind = $mod SHIFT, Q, killactive,
        bind = $mod, Return, exec, start "" "kitty", --args # comment
        """);
        Assert.Empty(c.Errors);
        Assert.Equal(Insets.All(7), c.GapsIn);
        Assert.Equal(new Insets(10, 20, 10, 20), c.GapsOut);
        Assert.Equal(3, c.BorderSize);
        Assert.Equal("master", c.Layout);
        Assert.Equal(0.6, c.Mfact);
        Assert.Equal(4, c.Rounding);
        Assert.Equal(new KeyBind(Mods.Super | Mods.Shift, "q", "killactive", ""), c.Binds[0]);
        Assert.Equal("start \"\" \"kitty\", --args", c.Binds[1].Arg);
        Assert.Contains("decoration:blur:enabled", c.Ignored);
    }

    [Fact]
    public void DoubleHashIsLiteral() =>
        Assert.Equal("echo #1", ConfigParser.Parse("bind = ALT, 1, exec, echo ##1 # real comment").Binds[0].Arg);

    [Fact]
    public void ErrorsAreReported()
    {
        var c = ConfigParser.Parse("""
        bind = HYPER, Q, killactive,
        bind = ALT, notakey, killactive,
        bind = ALT, Q, frobnicate,
        general:gaps_in = lots
        nonsense
        foo:bar = 1
        }
        """);
        Assert.Equal(7, c.Errors.Count);
    }

    [Fact]
    public void LinuxOnlyOptionsAreIgnored()
    {
        var c = ConfigParser.Parse("""
        monitor = ,preferred,auto,1
        env = XCURSOR_SIZE,24
        input {
            kb_layout = us
            touchpad {
                natural_scroll = true
            }
        }
        animations {
            enabled = yes
            bezier = myBezier, 0.05, 0.9, 0.1, 1.05
            animation = windows, 1, 7, myBezier
        }
        bindm = SUPER, mouse:272, movewindow
        """);
        Assert.Empty(c.Errors);
        Assert.Equal(8, c.Ignored.Count);
    }

    [Fact]
    public void SourceIncludesRelativeFile()
    {
        // Separators differ per OS ("/cfg\extra.conf" on Windows), so match loosely.
        const string extra = "bind = ALT, T, exec, kitty\ngeneral:border_size = 5";
        var c = ConfigParser.Parse("source = extra.conf\n", "/cfg/hyprland.conf",
            f => f.Replace('\\', '/').EndsWith("/cfg/extra.conf") ? extra : null);
        Assert.Empty(c.Errors);
        Assert.Equal("t", c.Binds[0].Key);
        Assert.Equal(5, c.BorderSize);
    }

    [Fact]
    public void LaterBindReplacesAndUnbindRemoves()
    {
        var c = ConfigParser.Parse("bind = ALT, Q, exec, a\nbind = ALT, Q, exec, b\nbind = ALT, W, exec, c\nunbind = ALT, W\n");
        Assert.Single(c.Binds);
        Assert.Equal("b", c.Binds[0].Arg);
    }

    [Fact]
    public void WindowRules()
    {
        var c = ConfigParser.Parse("""
        windowrulev2 = float, class:^(kitty)$
        windowrulev2 = workspace 3 silent, class:Safari, title:.*YouTube.*
        windowrule = size 800 600, ^(Calculator)$
        """);
        Assert.Empty(c.Errors);
        Assert.True(c.Rules[0].Matches(["Kitty", "kitty.exe"], "zsh"));
        Assert.False(c.Rules[0].Matches(["kitty2"], ""));
        Assert.True(c.Rules[1].Matches(["Safari"], "Cats - YouTube"));
        Assert.False(c.Rules[1].Matches(["Safari"], "News"));
        Assert.Equal("workspace", c.Rules[1].EffectName);
        Assert.Equal(["3", "silent"], c.Rules[1].EffectArgs);
        Assert.Equal("^(Calculator)$", c.Rules[2].ClassPattern);
    }

    [Fact]
    public void Colors()
    {
        var g = BorderColor.Parse("rgba(33ccffee) rgba(00ff99ee) 45deg")!;
        Assert.Equal(2, g.Colors.Count);
        Assert.Equal(45, g.Angle);
        Assert.Equal("33ccffee", g.Colors[0].Hex);
        Assert.Equal(new Rgba(1, 0, 0, 1), BorderColor.Parse("rgb(ff0000)")!.Colors[0]);
        Assert.Equal(new Rgba(0, 1, 0, 1), BorderColor.Parse("0xff00ff00")!.Colors[0]);
        Assert.Equal(new Rgba(1, 0, 0, 0.5), BorderColor.Parse("rgba(255, 0, 0, 0.5)")!.Colors[0]);
        Assert.Null(BorderColor.Parse("red"));
        Assert.Null(BorderColor.Parse("rgba(33ccffee) junk"));
        Assert.Equal(0x00FF0000u, new Rgba(0, 0, 1).ColorRef); // COLORREF is 0x00BBGGRR
    }

    [Fact]
    public void Modifiers()
    {
        Assert.Equal(Mods.Super | Mods.Shift, ModsParser.Parse("SUPER_SHIFT"));
        Assert.Equal(Mods.Ctrl | Mods.Alt, ModsParser.Parse("CTRL ALT"));
        Assert.Equal(Mods.None, ModsParser.Parse(""));
        Assert.Null(ModsParser.Parse("HYPER"));
        Assert.Equal(Mods.Alt, ConfigParser.Parse("hyprwin {\n super = alt\n}\n").SuperMapsTo);
    }
}

public class LayoutTests
{
    static readonly Rect Area = new(0, 0, 1000, 600);
    static readonly DwindleSettings S = new();

    [Fact]
    public void DwindleSplitsLikeHyprland()
    {
        var t = new DwindleTree();
        t.Insert(1, null, Area, S);
        Assert.Equal(Area, t.Boxes(Area, S)[1]);
        t.Insert(2, 1, Area, S);
        var b = t.Boxes(Area, S);
        Assert.Equal(new Rect(0, 0, 500, 600), b[1]);
        Assert.Equal(new Rect(500, 0, 500, 600), b[2]);
        t.Insert(3, 2, Area, S);
        b = t.Boxes(Area, S);
        Assert.Equal(new Rect(500, 0, 500, 300), b[2]);
        Assert.Equal(new Rect(500, 300, 500, 300), b[3]);
        Assert.Equal([1L, 2, 3], t.Windows);
    }

    [Fact]
    public void DwindleRemoveCollapses()
    {
        var t = new DwindleTree();
        for (long i = 1; i <= 3; i++) t.Insert(i, Math.Max(1, i - 1), Area, S);
        t.Remove(2);
        Assert.Equal(new Rect(500, 0, 500, 600), t.Boxes(Area, S)[3]);
        t.Remove(1);
        Assert.Equal(Area, t.Boxes(Area, S)[3]);
        t.Remove(3);
        Assert.True(t.IsEmpty);
    }

    [Fact]
    public void ToggleSplitAndRatio()
    {
        var t = new DwindleTree();
        t.Insert(1, null, Area, S);
        t.Insert(2, 1, Area, S);
        t.ToggleSplit(2, Area, S);
        Assert.Equal(new Rect(0, 0, 1000, 300), t.Boxes(Area, S)[1]);
        t.ChangeRatio(1, delta: 0.2);
        Assert.Equal(360, t.Boxes(Area, S)[1].H);
        t.ChangeRatio(1, exact: 5);
        Assert.Equal(1.9, t.RatioOf(1));
    }

    [Fact]
    public void MasterLayoutBoxes()
    {
        var b = MasterLayout.Boxes([1, 2, 3], Area, 0.6, "left");
        Assert.Equal(new Rect(0, 0, 600, 600), b[1]);
        Assert.Equal(new Rect(600, 0, 400, 300), b[2]);
        Assert.Equal(new Rect(600, 300, 400, 300), b[3]);
        Assert.Equal(500, MasterLayout.Boxes([1, 2], Area, 0.5, "right")[1].X);
    }

    [Fact]
    public void InnerGapsOnlyBetweenTiles()
    {
        var g = MasterLayout.ApplyInnerGaps(new() { [1] = new(0, 0, 500, 600), [2] = new(500, 0, 500, 600) }, Area, Insets.All(5));
        Assert.Equal(new Rect(0, 0, 495, 600), g[1]);
        Assert.Equal(new Rect(505, 0, 495, 600), g[2]);
    }

    [Fact]
    public void Neighbors()
    {
        var r = new Dictionary<int, Rect> { [1] = new(0, 0, 500, 600), [2] = new(500, 0, 500, 300), [3] = new(500, 300, 500, 300) };
        Assert.True(Geometry.TryNeighbor(r[3], Direction.Up, new Dictionary<int, Rect> { [1] = r[1], [2] = r[2] }, out var up));
        Assert.Equal(2, up);
        Assert.True(Geometry.TryNeighbor(r[3], Direction.Left, new Dictionary<int, Rect> { [1] = r[1], [2] = r[2] }, out var left));
        Assert.Equal(1, left);
        Assert.False(Geometry.TryNeighbor(r[1], Direction.Left, new Dictionary<int, Rect> { [2] = r[2], [3] = r[3] }, out _));
    }
}

public class ModelTests
{
    static Model Make(int monitors = 1, string layout = "dwindle")
    {
        var c = new Config { GapsIn = Insets.All(0), GapsOut = Insets.All(0), Layout = layout };
        var m = new Model(c);
        m.SetMonitors(Enumerable.Range(0, monitors).Select(i => ($"m{i}", $"Display {i}", new Rect(i * 1000, 0, 1000, 600))).ToList());
        return m;
    }

    [Fact]
    public void TilingAndWorkspaceSwitch()
    {
        var m = Make();
        m.AddWindow(1, false); m.SetFocused(1);
        m.AddWindow(2, false); m.SetFocused(2);
        Assert.Equal(2, m.Frames().Count);
        Assert.Equal([new Effect.FocusDesktop()], m.Dispatch("workspace", "2"));
        Assert.Equal(2, m.CurrentWorkspace);
        Assert.False(m.IsVisible(1));
        Assert.Equal([new Effect.Focus(2)], m.Dispatch("workspace", "previous"));
        Assert.True(m.IsVisible(1));
    }

    [Fact]
    public void MoveToWorkspaceFollowsAndSilentStays()
    {
        var m = Make();
        m.AddWindow(1, false); m.SetFocused(1);
        m.AddWindow(2, false); m.SetFocused(2);
        Assert.Equal([new Effect.Focus(1)], m.Dispatch("movetoworkspacesilent", "3"));
        Assert.Equal(3, m.WindowWorkspace[2]);
        Assert.Equal([new Effect.Focus(1)], m.Dispatch("movetoworkspace", "3"));
        Assert.Equal(3, m.CurrentWorkspace);
        Assert.Equal(500, m.Frames()[1].W);
    }

    [Fact]
    public void FocusOnHiddenWorkspaceSwitchesToIt()
    {
        var m = Make();
        m.AddWindow(1, false);
        m.Dispatch("workspace", "2");
        Assert.True(m.SetFocused(1));
        Assert.Equal(1, m.CurrentWorkspace);
    }

    [Fact]
    public void ClosingFocusedPicksNext()
    {
        var m = Make();
        m.AddWindow(1, false); m.SetFocused(1);
        m.AddWindow(2, false); m.SetFocused(2);
        Assert.Equal([new Effect.Focus(1)], m.RemoveWindow(2));
        Assert.Equal([new Effect.FocusDesktop()], m.RemoveWindow(1));
    }

    [Fact]
    public void DirectionalFocusAndMoveAcrossMonitors()
    {
        var m = Make(2);
        m.AddWindow(1, false, monitor: 0); m.SetFocused(1);
        m.AddWindow(2, false, monitor: 1);
        Assert.Equal([new Effect.Focus(2)], m.Dispatch("movefocus", "r"));
        Assert.Equal(1, m.FocusedMonitor);
        Assert.Equal([new Effect.Focus(1)], m.Dispatch("workspace", "1"));
        Assert.Equal([new Effect.Focus(1)], m.Dispatch("movewindow", "r"));
        Assert.Equal(2, m.WindowWorkspace[1]);
    }

    [Fact]
    public void FloatingFullscreenAndMoveActive()
    {
        var m = Make();
        m.AddWindow(1, false); m.SetFocused(1);
        m.AddWindow(2, false); m.SetFocused(2);
        Assert.Equal([new Effect.Center(2)], m.Dispatch("togglefloating", ""));
        Assert.Equal(new Rect(0, 0, 1000, 600), m.Frames()[1]);
        Assert.Equal([new Effect.ResizeWindow(2, 100, 50, true)], m.Dispatch("resizeactive", "exact 100 50"));
        Assert.Equal([new Effect.MoveWindow(2, -40, 0, false)], m.Dispatch("moveactive", "-40 0"));
        m.Dispatch("togglefloating", "");
        m.Dispatch("fullscreen", "");
        Assert.Equal(new Rect(0, 0, 1000, 600), m.Frames()[2]);
    }

    [Fact]
    public void MasterMessages()
    {
        var m = Make(layout: "master");
        for (long i = 1; i <= 3; i++) { m.AddWindow(i, false); m.SetFocused(i); }
        m.Dispatch("layoutmsg", "swapwithmaster");
        Assert.Equal(0, m.Frames()[3].X);
        m.Dispatch("layoutmsg", "mfact exact 0.7");
        Assert.Equal(700, m.Frames()[3].W);
        m.Dispatch("splitratio", "-0.2");
        Assert.Equal(600, m.Frames()[3].W);
    }

    [Fact]
    public void GlobalActions()
    {
        var m = Make();
        Assert.Equal([new Effect.Global("launcher")], m.Dispatch("global", "shell:launcher"));
        Assert.Equal([new Effect.Global("dashboard")], m.Dispatch("global", "caelestia:dashboard"));
        Assert.Throws<DispatchException>(() => m.Dispatch("global", ""));
    }

    [Fact]
    public void WorkspaceArgs()
    {
        var m = Make();
        Assert.Equal(4, m.ResolveWorkspace("4"));
        Assert.Equal(2, m.ResolveWorkspace("+1"));
        m.AddWindow(1, false, workspace: 6);
        Assert.Equal(6, m.ResolveWorkspace("e+1"));
        Assert.Equal(2, m.ResolveWorkspace("empty"));
        Assert.Throws<DispatchException>(() => m.ResolveWorkspace("name:web"));
        Assert.Throws<DispatchException>(() => m.Dispatch("frob", ""));
    }
}
