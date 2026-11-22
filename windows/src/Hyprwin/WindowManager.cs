using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Hyprwin.Core;
using Microsoft.Win32;
using Rect = Hyprwin.Core.Rect;

namespace Hyprwin;

sealed class ManagedWindow(IntPtr hwnd, uint pid, string process, string className, string title)
{
    public IntPtr Hwnd { get; } = hwnd;
    public long Id => Hwnd.ToInt64();
    public uint Pid { get; } = pid;
    public string Process { get; } = process;
    public string ClassName { get; } = className;
    public string Title { get; set; } = title;
    public uint? BorderColor;
    public bool CornerSet;
}

/// <summary>Drives real Windows windows from the platform-free <see cref="Model"/>. Mirrors the macOS
/// WindowManager: tile, park windows of hidden workspaces off screen, color borders via DWM.</summary>
sealed class WindowManager
{
    public string ConfigPath { get; }
    public Model Model { get; } = new(new Config());
    public RiceManager Rices { get; }

    readonly Dictionary<long, ManagedWindow> windows = [];
    readonly HashSet<long> hidden = [];
    readonly HashSet<long> unmovable = [];
    readonly Dictionary<long, Rect> savedFloating = [];
    readonly Dictionary<long, (Rect Rect, DateTime At)> lastSet = [];
    readonly List<IntPtr> hooks = [];
    readonly Native.WinEventProc winEventProc;
    readonly uint ownPid = (uint)Environment.ProcessId;
    Hotkeys? hotkeys;
    Tray? tray;
    EventServer? events;
    readonly List<System.Windows.Forms.Timer> timers = [];
    Dictionary<string, DateTime?> configStamps = [];
    List<string> hotkeyErrors = [];
    public List<string> SkippedBinds { get; private set; } = [];
    DateTime suppressFocusUntil = DateTime.MinValue;
    bool relayoutScheduled;
    (int Ws, long? Win, int Mon) lastEvent = (0, null, -1);
    Dictionary<long, int> lastWindowWorkspace = [];

    static readonly HashSet<string> IgnoredClasses =
    [
        "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Windows.UI.Core.CoreWindow",
        "XamlExplorerHostIslandWindow", "ApplicationManager_ImmersiveShellWindow", "Xaml_WindowedPopupClass",
        "MultitaskingViewFrame", "ForegroundStaging", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland",
        "Windows.Internal.Shell.TabProxyWindow", "LauncherTipWnd", "SysShadow", "tooltips_class32",
    ];

    public WindowManager(string configPath)
    {
        ConfigPath = configPath;
        winEventProc = OnWinEvent;
        Rices = new RiceManager(new WinRicePlatform(), HyprwinInfo.DataDir, configPath, Console.Out) { OnChanged = Reload };
    }

    public int WindowCount => windows.Count;
    public List<string> ConfigErrors => [.. Model.Config.Errors, .. hotkeyErrors];

    // ---- Lifecycle

    public void Start()
    {
        var shims = WinCompat.InstallShims();
        if (shims.Count > 0) Program.Log($"Linux stand-ins: {string.Join(" ", shims)}");
        LuaConfig.Host = LuaHost;
        Model.Config = LoadConfig();
        UpdateMonitors();
        hotkeys = new Hotkeys(b => Run(b.Dispatcher, b.Arg));
        RegisterHotkeys();

        foreach (var (min, max) in new[] {
            (Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND),
            (Native.EVENT_SYSTEM_MOVESIZEEND, Native.EVENT_SYSTEM_MOVESIZEEND),
            (Native.EVENT_SYSTEM_MINIMIZESTART, Native.EVENT_SYSTEM_MINIMIZEEND),
            (Native.EVENT_OBJECT_DESTROY, Native.EVENT_OBJECT_HIDE),
            (Native.EVENT_OBJECT_NAMECHANGE, Native.EVENT_OBJECT_NAMECHANGE),
            (Native.EVENT_OBJECT_CLOAKED, Native.EVENT_OBJECT_UNCLOAKED) })
        {
            var h = Native.SetWinEventHook(min, max, IntPtr.Zero, winEventProc, 0, 0, Native.WINEVENT_OUTOFCONTEXT | Native.WINEVENT_SKIPOWNPROCESS);
            if (h != IntPtr.Zero) hooks.Add(h);
        }
        SystemEvents.DisplaySettingsChanged += (_, _) => { UpdateMonitors(); Apply(); };

        ScanAll(initial: true);
        RefreshFocus(Native.GetForegroundWindow());
        Apply();

        var ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        new IpcServer(HyprwinInfo.PipeName, HandleRequest, ui).Start();
        events = new EventServer(HyprwinInfo.EventPipeName);
        events.Start();
        if (Model.Config.StatusBar) tray = new Tray(this);

        AddTimer(1000, CheckConfigChanged);
        AddTimer(3000, () => { ScanAll(initial: false); Apply(); });

        foreach (var cmd in Model.Config.ExecOnce.Concat(Model.Config.Exec)) WinCompat.Spawn(cmd, Program.Log);
        LuaConfig.Emit("hyprland.start");
        UpdateUi();
        Program.Log($"hyprwin {HyprwinInfo.Version} running: {windows.Count} windows, {Model.Monitors.Count} monitor(s)");
    }

    void AddTimer(int ms, Action a)
    {
        var t = new System.Windows.Forms.Timer { Interval = ms };
        t.Tick += (_, _) => a();
        t.Start();
        timers.Add(t);
    }

    /// <summary>Put every window back on screen, reset border colors, exit.</summary>
    public void Shutdown()
    {
        foreach (var t in timers) t.Stop();
        foreach (var id in hidden.ToList())
        {
            if (!windows.TryGetValue(id, out var w) || !Model.WindowWorkspace.TryGetValue(id, out var wsId)) continue;
            if (savedFloating.TryGetValue(id, out var saved)) { lastSet.Remove(id); SetFrame(w, saved); continue; }
            var m = Model.Workspaces.GetValueOrDefault(wsId)?.LastMonitor is { } lm && lm < Model.Monitors.Count ? lm : 0;
            if (Model.Frames(wsId, m).TryGetValue(id, out var r)) { lastSet.Remove(id); SetFrame(w, r); }
        }
        foreach (var w in windows.Values) ResetDecorations(w);
        foreach (var h in hooks) Native.UnhookWinEvent(h);
        hotkeys?.Dispose();
        tray?.Dispose();
        Application.Exit();
    }

    // ---- Config

    Config LoadConfig()
    {
        LuaConfig.Reset();
        var c = ConfigParser.Load(ConfigPath);
        configStamps = c.Files.ToDictionary(f => f, Stamp);
        foreach (var e in c.Errors) Program.Log($"config: {e}");
        return c;
    }

    static DateTime? Stamp(string f) => File.Exists(f) ? File.GetLastWriteTimeUtc(f) : null;

    void CheckConfigChanged()
    {
        if (configStamps.Any(p => Stamp(p.Key) != p.Value)) Reload();
    }

    public void Reload()
    {
        WinCompat.InstallShims();
        var c = LoadConfig();
        Model.Config = c;
        RegisterHotkeys();
        lastSet.Clear();
        foreach (var w in windows.Values) { w.BorderColor = null; w.CornerSet = false; }
        if (c.StatusBar && tray is null) tray = new Tray(this);
        if (!c.StatusBar && tray is not null) { tray.Dispose(); tray = null; }
        foreach (var cmd in c.Exec) WinCompat.Spawn(cmd, Program.Log);
        Apply();
        LuaConfig.Emit("config.reloaded");
        events?.Emit("configreloaded", "");
        Program.Log($"config reloaded ({c.Errors.Count} error(s))");
    }

    void RegisterHotkeys()
    {
        var (usable, skipped) = SplitBinds(Model.Config.Binds);
        SkippedBinds = skipped;
        hotkeyErrors = hotkeys!.Register(usable, Model.Config.SuperMapsTo);
        foreach (var e in hotkeyErrors) Program.Log(e);
        if (skipped.Count > 0) Program.Log($"{skipped.Count} bind(s) skipped: they need Linux-only programs");
    }

    /// <summary>Exec binds whose programs are missing stay unregistered, so a rice's
    /// `bind = , Delete, exec, grim ...` doesn't steal Delete.</summary>
    public static (List<KeyBind> Usable, List<string> Skipped) SplitBinds(IEnumerable<KeyBind> binds)
    {
        var usable = new List<KeyBind>();
        var skipped = new List<string>();
        foreach (var b in binds)
        {
            var command = b.Dispatcher == "exec" ? b.Arg : b.Dispatcher == "lua" ? LuaConfig.StoredCommand(b.Arg) : null;
            if (command is not null && WinCompat.Missing(command) is { Count: > 0 } missing)
            {
                skipped.Add($"{b.Combo}: needs {string.Join(", ", missing)}");
                continue;
            }
            usable.Add(b);
        }
        return (usable, skipped);
    }

    string? LuaHost(string op, string arg)
    {
        switch (op)
        {
            case "exec": WinCompat.Spawn(arg, Program.Log); return null;
            case "dispatch":
            {
                var parts = arg.Split('\t', 2);
                return Run(parts[0], parts.Length > 1 ? parts[1] : "");
            }
            case "activewindow":
            {
                if (Model.Focused is not { } id || !windows.TryGetValue(id, out var w)) return null;
                var f = Native.VisibleFrame(w.Hwnd) ?? default;
                return LuaConfig.Table(new Dictionary<string, object?>
                {
                    ["address"] = Hex(id), ["class"] = w.Process, ["title"] = w.Title, ["floating"] = Model.IsFloating(id),
                    ["workspace"] = Model.WindowWorkspace.GetValueOrDefault(id), ["x"] = (int)f.X, ["y"] = (int)f.Y,
                    ["width"] = (int)f.W, ["height"] = (int)f.H,
                });
            }
            case "activemonitor":
            {
                if (Model.FocusedMonitor >= Model.Monitors.Count) return null;
                var m = Model.Monitors[Model.FocusedMonitor];
                return LuaConfig.Table(new Dictionary<string, object?>
                {
                    ["name"] = m.Name, ["id"] = Model.FocusedMonitor, ["x"] = (int)m.Frame.X, ["y"] = (int)m.Frame.Y,
                    ["width"] = (int)m.Frame.W, ["height"] = (int)m.Frame.H, ["workspace"] = m.Workspace,
                });
            }
            case "activeworkspace":
                return LuaConfig.Table(new Dictionary<string, object?> { ["id"] = Model.CurrentWorkspace, ["name"] = Model.CurrentWorkspace.ToString() });
            case "log": Program.Log("lua: " + arg); return null;
            default: return null;
        }
    }

    // ---- Discovery

    void UpdateMonitors()
    {
        var list = new List<(string, string, Rect)>();
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hMon, IntPtr _, ref Native.RECT _, IntPtr _) =>
        {
            var info = new Native.MONITORINFOEX { cbSize = Marshal.SizeOf<Native.MONITORINFOEX>(), szDevice = "" };
            if (Native.GetMonitorInfoW(hMon, ref info))
            {
                var r = info.rcWork;
                list.Add((info.szDevice, info.szDevice.Replace(@"\\.\", ""), new Rect(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top)));
            }
            return true;
        }, IntPtr.Zero);
        // Primary (the one at 0,0) first, then left to right.
        list = list.OrderBy(m => m.Item3.X == 0 && m.Item3.Y >= 0 && m.Item3.Y < 100 ? 0 : 1).ThenBy(m => m.Item3.X).ThenBy(m => m.Item3.Y).ToList();
        Model.SetMonitors(list);
    }

    void ScanAll(bool initial)
    {
        var seen = new HashSet<long>();
        Native.EnumWindows((h, _) =>
        {
            if (Consider(h, initial) is { } id) seen.Add(id);
            return true;
        }, IntPtr.Zero);
        foreach (var id in windows.Keys.Where(k => !seen.Contains(k)).ToList()) RemoveWindow(id);
    }

    bool Manageable(IntPtr h, out string className)
    {
        className = "";
        if (!Native.IsWindowVisible(h) || Native.IsIconic(h) || Native.IsCloaked(h)) return false;
        if (Native.GetWindow(h, Native.GW_OWNER) != IntPtr.Zero) return false;
        long style = Native.Style(h), ex = Native.ExStyle(h);
        if ((ex & Native.WS_EX_TOOLWINDOW) != 0 || (ex & Native.WS_EX_NOACTIVATE) != 0 || (style & Native.WS_CHILD) != 0) return false;
        if ((style & Native.WS_CAPTION) != Native.WS_CAPTION && (style & Native.WS_THICKFRAME) == 0) return false;
        if (Native.Title(h).Length == 0) return false;
        className = Native.ClassName(h);
        if (IgnoredClasses.Contains(className)) return false;
        Native.GetWindowThreadProcessId(h, out var pid);
        return pid != ownPid;
    }

    /// <summary>Adds a manageable window. Returns its id when managed (new or known).</summary>
    long? Consider(IntPtr h, bool initial)
    {
        long id = h.ToInt64();
        if (unmovable.Contains(id)) return null;
        if (windows.ContainsKey(id)) return Native.IsIconic(h) || Native.IsCloaked(h) || !Native.IsWindowVisible(h) ? null : id;
        if (!Manageable(h, out var cls)) return null;

        Native.GetWindowThreadProcessId(h, out var pid);
        string proc = "";
        try { using var p = Process.GetProcessById((int)pid); proc = p.ProcessName; } catch (Exception) { }
        var w = new ManagedWindow(h, pid, proc, cls, Native.Title(h));

        bool floating = (Native.Style(h) & Native.WS_THICKFRAME) == 0 || cls == "#32770";
        int? ruleWs = null;
        bool silent = false, center = false, fullscreen = false;
        (double, double, bool)? size = null;
        foreach (var r in Model.Config.Rules.Where(r => r.Matches([w.Process, w.ClassName], w.Title)))
        {
            var a = r.EffectArgs;
            switch (r.EffectName)
            {
                case "float": floating = true; break;
                case "tile": floating = false; break;
                case "center": center = true; break;
                case "fullscreen" or "maximize": fullscreen = true; break;
                case "workspace":
                    if (a.Length > 0 && int.TryParse(a[0], out var n)) ruleWs = n;
                    silent = a.Contains("silent");
                    break;
                case "size" when a.Length == 2:
                    bool pct = a[0].EndsWith('%');
                    if (double.TryParse(a[0].TrimEnd('%'), System.Globalization.CultureInfo.InvariantCulture, out var sw)
                        && double.TryParse(a[1].TrimEnd('%'), System.Globalization.CultureInfo.InvariantCulture, out var sh))
                    { size = (sw, sh, pct); floating = true; }
                    break;
            }
        }

        int? monitorHint = null;
        if (initial && Native.VisibleFrame(h) is { } f)
        {
            int i = Model.Monitors.FindIndex(m => m.Frame.Contains(f.MidX, f.MidY));
            monitorHint = i >= 0 ? i : null;
        }
        windows[id] = w;
        Model.AddWindow(id, floating, ruleWs, monitorHint);
        events?.Emit("openwindow", $"{Hex(id)},{Model.WindowWorkspace.GetValueOrDefault(id)},{w.Process},{w.Title}");

        if (size is var (a0, a1, isPct) && MonitorFor(id) is { } mon)
        {
            var mf = Model.Monitors[mon].Frame;
            var cur = Native.VisibleFrame(h) ?? mf;
            SetFrame(w, new Rect(cur.X, cur.Y, isPct ? mf.W * a0 / 100 : a0, isPct ? mf.H * a1 / 100 : a1));
            center = true;
        }
        if (center) CenterWindow(id);
        if (!initial && ruleWs is { } rw && !silent) TryDispatch("workspace", rw.ToString());
        if (fullscreen) { Model.SetFocused(id); TryDispatch("fullscreen", ""); }
        if (!initial) ScheduleRelayout(0);
        return id;
    }

    void TryDispatch(string d, string a)
    {
        try { Model.Dispatch(d, a); } catch (DispatchException) { }
    }

    void RemoveWindow(long id)
    {
        if (!windows.Remove(id, out var w)) return;
        lastSet.Remove(id);
        hidden.Remove(id);
        savedFloating.Remove(id);
        if (Native.IsWindow(w.Hwnd)) ResetDecorations(w);
        var fx = Model.RemoveWindow(id);
        events?.Emit("closewindow", Hex(id));
        Handle(fx);
        ScheduleRelayout(0);
    }

    // ---- Events

    void OnWinEvent(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (idObject != Native.OBJID_WINDOW || idChild != 0 || hwnd == IntPtr.Zero) return;
        long id = hwnd.ToInt64();
        switch (evt)
        {
            case Native.EVENT_OBJECT_SHOW or Native.EVENT_OBJECT_UNCLOAKED or Native.EVENT_SYSTEM_MINIMIZEEND:
                if (!windows.ContainsKey(id)) Consider(hwnd, initial: false);
                break;
            case Native.EVENT_OBJECT_DESTROY or Native.EVENT_OBJECT_HIDE or Native.EVENT_OBJECT_CLOAKED or Native.EVENT_SYSTEM_MINIMIZESTART:
                if (windows.ContainsKey(id)) RemoveWindow(id);
                break;
            case Native.EVENT_SYSTEM_FOREGROUND:
                RefreshFocus(hwnd);
                break;
            case Native.EVENT_SYSTEM_MOVESIZEEND:
                // User dragged/resized a tiled window: snap it back.
                if (windows.ContainsKey(id) && !Model.IsFloating(id)) { lastSet.Remove(id); ScheduleRelayout(0.05); }
                break;
            case Native.EVENT_OBJECT_NAMECHANGE:
                if (windows.TryGetValue(id, out var w))
                {
                    w.Title = Native.Title(hwnd);
                    if (Model.Focused == id) events?.Emit("activewindow", $"{w.Process},{w.Title}");
                }
                break;
        }
    }

    void ScheduleRelayout(double seconds)
    {
        if (relayoutScheduled) return;
        relayoutScheduled = true;
        var t = new System.Windows.Forms.Timer { Interval = Math.Max(1, (int)(seconds * 1000)) };
        t.Tick += (_, _) =>
        {
            t.Stop();
            t.Dispose();
            relayoutScheduled = false;
            if (Control.MouseButtons != MouseButtons.None) { ScheduleRelayout(0.15); return; }
            Apply();
        };
        t.Start();
    }

    void RefreshFocus(IntPtr h)
    {
        long id = h.ToInt64();
        if (!windows.ContainsKey(id)) Consider(h, initial: false);
        if (!windows.ContainsKey(id)) return;
        if (DateTime.UtcNow < suppressFocusUntil && id != Model.Focused && !Model.IsVisible(id))
        {
            // Windows handed focus to a window on a hidden workspace right after we switched. Undo.
            if (Model.Focused is { } f) FocusWindow(f); else FocusDesktop();
            return;
        }
        if (id == Model.Focused && Model.IsVisible(id)) return;
        Model.SetFocused(id);
        Apply();
    }

    // ---- Dispatch

    /// <summary>Runs a dispatcher; returns an error message or null.</summary>
    public string? Run(string dispatcher, string arg)
    {
        if (dispatcher == "lua") { LuaConfig.Call(arg); return null; }
        var floating = new Dictionary<long, Rect>();
        foreach (var (id, w) in windows)
            if (Model.IsFloating(id) && Model.IsVisible(id) && Native.VisibleFrame(w.Hwnd) is { } f) floating[id] = f;
        try
        {
            var fx = Model.Dispatch(dispatcher, arg, floating);
            Apply();
            Handle(fx);
            return null;
        }
        catch (DispatchException e)
        {
            Program.Log($"{dispatcher} {arg}: {e.Message}");
            return e.Message;
        }
    }

    void Handle(List<Effect> effects)
    {
        foreach (var e in effects)
        {
            switch (e)
            {
                case Effect.Exec x: WinCompat.Spawn(x.Command, Program.Log); break;
                case Effect.Close c:
                    if (windows.TryGetValue(c.Window, out var cw)) Native.PostMessage(cw.Hwnd, Native.WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                    break;
                case Effect.Focus f: FocusWindow(f.Window); break;
                case Effect.FocusDesktop: FocusDesktop(); break;
                case Effect.Center c: CenterWindow(c.Window); break;
                case Effect.MoveWindow mv:
                    if (windows.TryGetValue(mv.Window, out var mw) && Native.VisibleFrame(mw.Hwnd) is { } mf)
                        SetFrame(mw, mf with { X = mv.Exact ? mv.X : mf.X + mv.X, Y = mv.Exact ? mv.Y : mf.Y + mv.Y });
                    break;
                case Effect.ResizeWindow rs:
                    if (windows.TryGetValue(rs.Window, out var rw) && Native.VisibleFrame(rw.Hwnd) is { } rf)
                        SetFrame(rw, rf with { W = Math.Max(50, rs.Exact ? rs.X : rf.W + rs.X), H = Math.Max(50, rs.Exact ? rs.Y : rf.H + rs.Y) });
                    break;
                case Effect.Reload: Reload(); break;
                case Effect.Quit: Shutdown(); break;
            }
        }
        UpdateUi();
    }

    void FocusWindow(long id)
    {
        if (!windows.TryGetValue(id, out var w)) return;
        suppressFocusUntil = DateTime.UtcNow.AddMilliseconds(500);
        if (Native.IsIconic(w.Hwnd)) Native.ShowWindow(w.Hwnd, Native.SW_RESTORE);
        if (Native.SetForegroundWindow(w.Hwnd) && Native.GetForegroundWindow() == w.Hwnd) return;
        // Foreground lock: a synthetic Alt press lets this process take the foreground.
        Native.keybd_event(Native.VK_MENU, 0, 0, UIntPtr.Zero);
        Native.SetForegroundWindow(w.Hwnd);
        Native.keybd_event(Native.VK_MENU, 0, Native.KEYEVENTF_KEYUP, UIntPtr.Zero);
        Native.BringWindowToTop(w.Hwnd);
    }

    void FocusDesktop()
    {
        suppressFocusUntil = DateTime.UtcNow.AddMilliseconds(500);
        Native.SetForegroundWindow(Native.GetShellWindow());
    }

    int? MonitorFor(long id)
    {
        if (!Model.WindowWorkspace.TryGetValue(id, out var ws)) return null;
        return Model.MonitorIndex(ws) ?? Model.Workspaces.GetValueOrDefault(ws)?.LastMonitor;
    }

    void CenterWindow(long id)
    {
        if (!windows.TryGetValue(id, out var w) || MonitorFor(id) is not { } m || m >= Model.Monitors.Count) return;
        var mf = Model.Monitors[m].Frame;
        var f = Native.VisibleFrame(w.Hwnd) ?? new Rect(0, 0, mf.W * 0.6, mf.H * 0.7);
        if (f.W >= mf.W * 0.9 || f.H >= mf.H * 0.9) f = f with { W = mf.W * 0.6, H = mf.H * 0.7 };
        SetFrame(w, new Rect(mf.MidX - f.W / 2, mf.MidY - f.H / 2, f.W, f.H));
    }

    // ---- Apply

    public void Apply()
    {
        var frames = Model.Frames();
        foreach (var (id, w) in windows.ToList())
        {
            if (Model.IsVisible(id))
            {
                if (hidden.Remove(id) && savedFloating.Remove(id, out var saved)) { lastSet.Remove(id); SetFrame(w, saved); }
                if (frames.TryGetValue(id, out var tile)) SetFrame(w, tile);
            }
            else
            {
                if (!hidden.Contains(id))
                {
                    if (Model.IsFloating(id) && Native.VisibleFrame(w.Hwnd) is { } f) savedFloating[id] = f;
                    hidden.Add(id);
                }
                Hide(w);
            }
        }
        UpdateBorders();
        UpdateUi();
    }

    /// <summary>Moves a window so its visible frame (not the invisible resize border) lands on <paramref name="r"/>.</summary>
    void SetFrame(ManagedWindow w, Rect r)
    {
        r = r.Rounded();
        if (lastSet.TryGetValue(w.Id, out var last) && last.Rect == r) return;
        var h = w.Hwnd;
        if (Native.IsZoomed(h)) Native.ShowWindow(h, Native.SW_RESTORE);
        double l = 0, t = 0, rr = 0, b = 0;
        if (Native.GetWindowRect(h, out var wr) && Native.VisibleFrame(h) is { } vf)
        {
            l = vf.X - wr.Left; t = vf.Y - wr.Top; rr = wr.Right - vf.MaxX; b = wr.Bottom - vf.MaxY;
        }
        bool ok = Native.SetWindowPos(h, IntPtr.Zero, (int)(r.X - l), (int)(r.Y - t), (int)(r.W + l + rr), (int)(r.H + t + b),
            Native.SWP_NOZORDER | Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER | Native.SWP_ASYNCWINDOWPOS);
        if (!ok && Marshal.GetLastWin32Error() == 5)
        {
            // Elevated (admin) window: can't be moved from a normal process. Leave it alone.
            Program.Log($"cannot move {w.Process} (\"{w.Title}\"): it runs as administrator");
            unmovable.Add(w.Id);
            RemoveWindow(w.Id);
            return;
        }
        lastSet[w.Id] = (r, DateTime.UtcNow);
    }

    /// <summary>Parks a window beyond every monitor. It stays in the taskbar and Alt-Tab; activating it
    /// switches to its workspace.</summary>
    void Hide(ManagedWindow w)
    {
        var vs = SystemInformation.VirtualScreen;
        var cur = Native.VisibleFrame(w.Hwnd) ?? new Rect(0, 0, 800, 600);
        var target = new Rect(vs.Right + 2000, vs.Top + 100, cur.W, cur.H);
        if (lastSet.TryGetValue(w.Id, out var last) && last.Rect == target.Rounded()) return;
        Native.SetWindowPos(w.Hwnd, IntPtr.Zero, (int)target.X, (int)target.Y, 0, 0,
            Native.SWP_NOSIZE | Native.SWP_NOZORDER | Native.SWP_NOACTIVATE | Native.SWP_NOOWNERZORDER | Native.SWP_ASYNCWINDOWPOS);
        lastSet[w.Id] = (target.Rounded(), DateTime.UtcNow);
    }

    /// <summary>Windows 11 colors window borders natively (DWMWA_BORDER_COLOR); first gradient color is used.</summary>
    void UpdateBorders()
    {
        var c = Model.Config;
        uint active = c.ActiveBorder.Colors[0].ColorRef, inactive = c.InactiveBorder.Colors[0].ColorRef;
        foreach (var (id, w) in windows)
        {
            uint want = c.BorderSize <= 0 ? Native.DWMWA_COLOR_DEFAULT : id == Model.Focused ? active : inactive;
            if (w.BorderColor != want)
            {
                Native.DwmSetWindowAttribute(w.Hwnd, Native.DWMWA_BORDER_COLOR, ref want, sizeof(uint));
                w.BorderColor = want;
            }
            if (!w.CornerSet)
            {
                int pref = c.Rounding > 0 ? Native.DWMWCP_ROUND : Native.DWMWCP_DONOTROUND;
                Native.DwmSetWindowAttribute(w.Hwnd, Native.DWMWA_WINDOW_CORNER_PREFERENCE, ref pref, sizeof(int));
                w.CornerSet = true;
            }
        }
    }

    static void ResetDecorations(ManagedWindow w)
    {
        uint color = Native.DWMWA_COLOR_DEFAULT;
        int pref = Native.DWMWCP_DEFAULT;
        Native.DwmSetWindowAttribute(w.Hwnd, Native.DWMWA_BORDER_COLOR, ref color, sizeof(uint));
        Native.DwmSetWindowAttribute(w.Hwnd, Native.DWMWA_WINDOW_CORNER_PREFERENCE, ref pref, sizeof(int));
    }

    void UpdateUi()
    {
        tray?.Update();
        EmitEvents();
    }

    void EmitEvents()
    {
        if (events is null) return;
        int ws = Model.CurrentWorkspace;
        if (ws != lastEvent.Ws) { events.Emit("workspace", ws.ToString()); events.Emit("workspacev2", $"{ws},{ws}"); }
        if (Model.FocusedMonitor != lastEvent.Mon && Model.FocusedMonitor < Model.Monitors.Count)
            events.Emit("focusedmon", $"{Model.Monitors[Model.FocusedMonitor].Name},{ws}");
        if (Model.Focused != lastEvent.Win)
        {
            if (Model.Focused is { } id && windows.TryGetValue(id, out var w))
            {
                events.Emit("activewindow", $"{w.Process},{w.Title}");
                events.Emit("activewindowv2", Hex(id));
            }
            else { events.Emit("activewindow", ","); events.Emit("activewindowv2", ""); }
        }
        foreach (var (id, wsId) in Model.WindowWorkspace)
            if (lastWindowWorkspace.TryGetValue(id, out var before) && before != wsId) events.Emit("movewindow", $"{Hex(id)},{wsId}");
        lastWindowWorkspace = new(Model.WindowWorkspace);
        lastEvent = (ws, Model.Focused, Model.FocusedMonitor);
    }

    // ---- IPC

    static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = true };

    string HandleRequest(string raw)
    {
        bool json = raw.StartsWith("j/");
        var req = json ? raw[2..] : raw;
        var parts = req.Split(' ', 2);
        var cmd = parts[0];
        var rest = parts.Length > 1 ? parts[1] : "";
        string Out(object o) => json ? JsonSerializer.Serialize(o, JsonOpts) : Describe(o);

        switch (cmd)
        {
            case "dispatch":
            {
                var d = rest.Split(' ', 2);
                if (d[0].Length == 0) return "dispatch needs a dispatcher";
                return Run(d[0], d.Length > 1 ? d[1] : "") ?? "ok";
            }
            case "reload": Reload(); return "ok";
            case "version": return json ? Out(new Dictionary<string, object?> { ["version"] = HyprwinInfo.Version, ["platform"] = "Windows" }) : $"hyprwin {HyprwinInfo.Version}";
            case "configerrors": return json ? Out(ConfigErrors) : ConfigErrors.Count == 0 ? "no errors" : string.Join("\n", ConfigErrors);
            case "skippedbinds": return json ? Out(SkippedBinds) : SkippedBinds.Count == 0 ? "none" : string.Join("\n", SkippedBinds);
            case "monitors":
                return Out(Model.Monitors.Select((m, i) => (object)new Dictionary<string, object?>
                {
                    ["id"] = i, ["name"] = m.Name, ["x"] = m.Frame.X, ["y"] = m.Frame.Y, ["width"] = m.Frame.W, ["height"] = m.Frame.H,
                    ["activeWorkspace"] = new Dictionary<string, object?> { ["id"] = m.Workspace, ["name"] = m.Workspace.ToString() },
                    ["focused"] = i == Model.FocusedMonitor,
                }).ToList());
            case "workspaces":
                return Out(Model.Workspaces.Values.Where(w => !w.IsEmpty || Model.MonitorIndex(w.Id) is not null)
                    .Select(w => w.Id).Order().Select(id => (object)WorkspaceInfo(id)).ToList());
            case "activeworkspace": return Out(WorkspaceInfo(Model.CurrentWorkspace));
            case "clients": return Out(windows.Keys.Order().Select(id => (object)ClientInfo(id)).ToList());
            case "activewindow":
                return Model.Focused is { } fid && windows.ContainsKey(fid) ? Out(ClientInfo(fid)) : json ? "{}" : "Invalid";
            case "binds":
                return Out(Model.Config.Binds.Select(b => (object)new Dictionary<string, object?>
                {
                    ["modmask"] = string.Join(" ", b.Mods.Names()), ["key"] = b.Key, ["dispatcher"] = b.Dispatcher, ["arg"] = b.Arg,
                }).ToList());
            default: return $"unknown request: {cmd}";
        }
    }

    Dictionary<string, object?> WorkspaceInfo(int id)
    {
        var ws = Model.Workspace(id);
        var mon = Model.MonitorIndex(id);
        return new()
        {
            ["id"] = id, ["name"] = id.ToString(), ["monitor"] = mon is { } m ? Model.Monitors[m].Name : "", ["monitorID"] = mon ?? -1,
            ["windows"] = ws.All.Count, ["hasfullscreen"] = ws.Fullscreen is not null,
            ["lastwindow"] = ws.LastFocused is { } lf ? Hex(lf) : "",
            ["lastwindowtitle"] = ws.LastFocused is { } lt && windows.TryGetValue(lt, out var w) ? w.Title : "",
        };
    }

    Dictionary<string, object?> ClientInfo(long id)
    {
        var w = windows[id];
        var f = Native.VisibleFrame(w.Hwnd) ?? default;
        int wsId = Model.WindowWorkspace.GetValueOrDefault(id);
        return new()
        {
            ["address"] = Hex(id), ["class"] = w.Process, ["windowClass"] = w.ClassName, ["title"] = w.Title, ["pid"] = w.Pid,
            ["workspace"] = new Dictionary<string, object?> { ["id"] = wsId, ["name"] = wsId.ToString() },
            ["floating"] = Model.IsFloating(id), ["fullscreen"] = Model.Workspaces.GetValueOrDefault(wsId)?.Fullscreen == id,
            ["hidden"] = hidden.Contains(id), ["at"] = new[] { (int)f.X, (int)f.Y }, ["size"] = new[] { (int)f.W, (int)f.H },
            ["focused"] = id == Model.Focused,
        };
    }

    static string Describe(object o) => o switch
    {
        Dictionary<string, object?> d => string.Join("\n", d.Keys.Order(StringComparer.Ordinal).Select(k => d[k] switch
        {
            Dictionary<string, object?> sub => $"\t{k}: {sub.GetValueOrDefault("id")} ({sub.GetValueOrDefault("name")})",
            int[] arr => $"\t{k}: {string.Join(",", arr)}",
            var v => $"\t{k}: {v}",
        })),
        IEnumerable<object> list => string.Join("\n\n", list.Select(Describe)),
        _ => o.ToString() ?? "",
    };

    public List<(int Ws, string App, string Title, bool Floating)> Summary() =>
        windows.Values.Select(w => (Model.WindowWorkspace.GetValueOrDefault(w.Id), w.Process, w.Title, Model.IsFloating(w.Id)))
            .OrderBy(x => x.Item1).ThenBy(x => x.Process).ToList();

    /// <summary>For --list: discover windows without touching them.</summary>
    public void ScanOnly()
    {
        Model.Config = ConfigParser.Load(ConfigPath);
        UpdateMonitors();
        ScanAll(initial: true);
    }

    static string Hex(long id) => "0x" + id.ToString("x");
}
