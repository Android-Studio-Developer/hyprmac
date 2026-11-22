using System.Globalization;

namespace Hyprwin.Core;

public sealed class Workspace(int id)
{
    public int Id { get; } = id;
    public DwindleTree Tree { get; } = new();
    /// <summary>Tiled windows in master order (index 0 = master).</summary>
    public List<long> Order { get; } = [];
    public List<long> Floating { get; } = [];
    public long? Fullscreen { get; internal set; }
    public long? LastFocused { get; internal set; }
    public int? LastMonitor { get; internal set; }

    public List<long> All => [.. Order, .. Floating];
    public bool IsEmpty => Order.Count == 0 && Floating.Count == 0;
    public bool IsFloating(long id) => Floating.Contains(id);
}

public sealed record Monitor(string Id, string Name, Rect Frame, int Workspace);

/// <summary>Side effects the platform layer performs after a dispatch.</summary>
public abstract record Effect
{
    public sealed record Exec(string Command) : Effect;
    public sealed record Close(long Window) : Effect;
    public sealed record Focus(long Window) : Effect;
    /// <summary>Empty workspace: focus the desktop so keys don't go to a hidden window.</summary>
    public sealed record FocusDesktop : Effect;
    public sealed record Center(long Window) : Effect;
    public sealed record MoveWindow(long Window, double X, double Y, bool Exact) : Effect;
    public sealed record ResizeWindow(long Window, double X, double Y, bool Exact) : Effect;
    /// <summary>Shell action, e.g. "launcher", "dashboard", "session" (from `global, shell:launcher`).</summary>
    public sealed record Global(string Action) : Effect;
    public sealed record Reload : Effect;
    public sealed record Quit : Effect;
}

public sealed class DispatchException(string message) : Exception(message);

/// <summary>Platform-independent window manager state. Port of Model.swift.</summary>
public sealed class Model(Config config)
{
    public Config Config { get; set; } = config;
    public List<Monitor> Monitors { get; private set; } = [];
    public Dictionary<int, Workspace> Workspaces { get; } = [];
    public Dictionary<long, int> WindowWorkspace { get; } = [];
    public long? Focused { get; private set; }
    public int FocusedMonitor { get; private set; }
    public int? PreviousWorkspace { get; private set; }

    // ---- Monitors and workspaces

    public void SetMonitors(IReadOnlyList<(string Id, string Name, Rect Frame)> list)
    {
        var old = Monitors;
        var assigned = list.Select(m => old.FirstOrDefault(o => o.Id == m.Id)?.Workspace).ToList();
        var used = assigned.Where(a => a is not null).Select(a => a!.Value).ToHashSet();
        for (int i = 0; i < assigned.Count; i++)
        {
            if (assigned[i] is not null) continue;
            int ws = i + 1;
            while (used.Contains(ws)) ws++;
            assigned[i] = ws;
            used.Add(ws);
        }
        Monitors = list.Select((m, i) => new Monitor(m.Id, m.Name, m.Frame, assigned[i]!.Value)).ToList();
        for (int i = 0; i < Monitors.Count; i++) Workspace(Monitors[i].Workspace).LastMonitor = i;
        if (FocusedMonitor >= Monitors.Count) FocusedMonitor = 0;
    }

    public Workspace Workspace(int id)
    {
        if (!Workspaces.TryGetValue(id, out var ws)) Workspaces[id] = ws = new Workspace(id);
        return ws;
    }

    public int CurrentWorkspace => Monitors.Count == 0 ? 1 : Monitors[FocusedMonitor].Workspace;

    public int? MonitorIndex(int ws)
    {
        int i = Monitors.FindIndex(m => m.Workspace == ws);
        return i < 0 ? null : i;
    }

    public bool IsVisible(long id) => WindowWorkspace.TryGetValue(id, out var ws) && MonitorIndex(ws) is not null;

    public bool IsFloating(long id) =>
        WindowWorkspace.TryGetValue(id, out var ws) && Workspaces.TryGetValue(ws, out var w) && w.IsFloating(id);

    public Rect TileArea(int m) => Monitors[m].Frame.Inset(Config.GapsOut);

    int? ValidMonitor(int? m) => m is { } v && v < Monitors.Count ? v : null;

    void Show(int ws, int m)
    {
        if (m >= Monitors.Count) return;
        if (Monitors[m].Workspace != ws)
        {
            PreviousWorkspace = Monitors[m].Workspace;
            Monitors[m] = Monitors[m] with { Workspace = ws };
        }
        Workspace(ws).LastMonitor = m;
        FocusedMonitor = m;
    }

    static long? FocusTarget(Workspace ws)
    {
        if (ws.LastFocused is { } f && ws.All.Contains(f)) return f;
        if (ws.Fullscreen is { } fs) return fs;
        if (ws.Order.Count > 0) return ws.Order[0];
        return ws.Floating.Count > 0 ? ws.Floating[0] : null;
    }

    List<Effect> FocusCurrent()
    {
        var ws = Workspace(CurrentWorkspace);
        if (FocusTarget(ws) is { } t)
        {
            Focused = t;
            ws.LastFocused = t;
            return [new Effect.Focus(t)];
        }
        Focused = null;
        return [new Effect.FocusDesktop()];
    }

    // ---- Windows

    public void AddWindow(long id, bool floating, int? workspace = null, int? monitor = null)
    {
        if (WindowWorkspace.ContainsKey(id)) return;
        int target = workspace ?? (ValidMonitor(monitor) is { } m ? Monitors[m].Workspace : CurrentWorkspace);
        var ws = Workspace(target);
        WindowWorkspace[id] = target;
        if (floating) ws.Floating.Add(id); else Tile(id, ws);
    }

    public List<Effect> RemoveWindow(long id)
    {
        if (!WindowWorkspace.TryGetValue(id, out var wsId) || !Workspaces.TryGetValue(wsId, out var ws)) return [];
        Detach(id, ws);
        WindowWorkspace.Remove(id);
        if (Focused != id) return [];
        Focused = null;
        bool visible = MonitorIndex(wsId) is not null;
        if (visible && FocusTarget(ws) is { } t)
        {
            Focused = t;
            ws.LastFocused = t;
            return [new Effect.Focus(t)];
        }
        return visible ? [new Effect.FocusDesktop()] : [];
    }

    /// <summary>OS focus change. True when this switched workspace (window on a hidden workspace was
    /// activated, e.g. from the taskbar or Alt-Tab).</summary>
    public bool SetFocused(long? id)
    {
        if (id is not { } w || !WindowWorkspace.TryGetValue(w, out var wsId) || !Workspaces.TryGetValue(wsId, out var ws)) return false;
        Focused = w;
        ws.LastFocused = w;
        if (MonitorIndex(wsId) is { } m) { FocusedMonitor = m; return false; }
        Show(wsId, ValidMonitor(ws.LastMonitor) ?? FocusedMonitor);
        return true;
    }

    void Tile(long id, Workspace ws)
    {
        int m = MonitorIndex(ws.Id) ?? ValidMonitor(ws.LastMonitor) ?? FocusedMonitor;
        var area = Monitors.Count == 0 ? new Rect(0, 0, 1600, 1000) : TileArea(m);
        long? target = ws.LastFocused is { } lf && ws.Order.Contains(lf) ? lf : null;
        ws.Tree.Insert(id, target, area, Config.Dwindle);
        if (Config.NewStatus == "master") ws.Order.Insert(0, id);
        else if (Config.NewOnTop && ws.Order.Count > 0) ws.Order.Insert(1, id);
        else ws.Order.Add(id);
    }

    static void Detach(long id, Workspace ws)
    {
        ws.Tree.Remove(id);
        ws.Order.Remove(id);
        ws.Floating.Remove(id);
        if (ws.Fullscreen == id) ws.Fullscreen = null;
        if (ws.LastFocused == id) ws.LastFocused = null;
    }

    void MoveWindowTo(long id, int target)
    {
        if (!WindowWorkspace.TryGetValue(id, out var from) || from == target || !Workspaces.TryGetValue(from, out var old)) return;
        bool wasFloating = old.IsFloating(id);
        Detach(id, old);
        var ws = Workspace(target);
        WindowWorkspace[id] = target;
        if (wasFloating) ws.Floating.Add(id); else Tile(id, ws);
        ws.LastFocused = id;
    }

    // ---- Layout

    public Dictionary<long, Rect> Frames()
    {
        var o = new Dictionary<long, Rect>();
        for (int i = 0; i < Monitors.Count; i++)
            foreach (var (k, v) in Frames(Monitors[i].Workspace, i)) o.TryAdd(k, v);
        return o;
    }

    public Dictionary<long, Rect> Frames(int wsId, int m)
    {
        if (m >= Monitors.Count || !Workspaces.TryGetValue(wsId, out var ws)) return [];
        var area = TileArea(m);
        var boxes = Config.Layout == "master"
            ? MasterLayout.Boxes(ws.Order, area, Config.Mfact, Config.Orientation)
            : ws.Tree.Boxes(area, Config.Dwindle);
        var o = MasterLayout.ApplyInnerGaps(boxes, area, Config.GapsIn);
        if (ws.Fullscreen is { } fs) o[fs] = Monitors[m].Frame;
        return o;
    }

    // ---- Dispatchers

    public List<Effect> Dispatch(string name, string arg, IReadOnlyDictionary<long, Rect>? floatingFrames = null)
    {
        arg = arg.Trim();
        name = name.ToLowerInvariant();
        switch (name)
        {
            case "exec":
                if (arg.Length == 0) throw new DispatchException("exec needs a command");
                return [new Effect.Exec(arg)];
            case "exit":
                return [new Effect.Quit()];
            case "global":
            {
                // Hyprland's `global` names an action as app:action; accept shell:, caelestia: or none.
                var action = arg.Split(':')[^1];
                if (action.Length == 0) throw new DispatchException("global needs an action, e.g. shell:launcher");
                return [new Effect.Global(action)];
            }
            case "killactive" or "closewindow":
                return Focused is { } f ? [new Effect.Close(f)] : [];
            case "workspace":
            {
                if (arg == "previous" && PreviousWorkspace is null) return [];
                int n = ResolveWorkspace(arg);
                if (n == CurrentWorkspace) return [];
                if (MonitorIndex(n) is { } m) FocusedMonitor = m; else Show(n, FocusedMonitor);
                return FocusCurrent();
            }
            case "movetoworkspace" or "movetoworkspacesilent":
            {
                int n = ResolveWorkspace(arg.Split(',')[0]);
                if (Focused is not { } id) return [];
                MoveWindowTo(id, n);
                if (name == "movetoworkspacesilent") return FocusCurrent();
                if (MonitorIndex(n) is { } m) FocusedMonitor = m; else Show(n, FocusedMonitor);
                Focused = id;
                return [new Effect.Focus(id)];
            }
            case "togglefloating" or "setfloating" or "settiled":
            {
                if (Focused is not { } id || !WindowWorkspace.TryGetValue(id, out var wsId)) return [];
                var ws = Workspaces[wsId];
                bool floating = ws.IsFloating(id);
                bool want = name == "setfloating" || (name != "settiled" && !floating);
                if (want == floating) return [];
                Detach(id, ws);
                if (want) ws.Floating.Add(id); else Tile(id, ws);
                ws.LastFocused = id;
                return want ? [new Effect.Center(id)] : [];
            }
            case "fullscreen":
            {
                if (Focused is not { } id || !WindowWorkspace.TryGetValue(id, out var wsId)) return [];
                var ws = Workspaces[wsId];
                ws.Fullscreen = ws.Fullscreen == id ? null : id;
                return [];
            }
            case "movefocus":
                return MoveFocus(Geometry.ParseDirection(arg) ?? throw new DispatchException("movefocus needs l, r, u or d"),
                    floatingFrames ?? new Dictionary<long, Rect>());
            case "movewindow" or "swapwindow":
                return MoveFocused(Geometry.ParseDirection(arg) ?? throw new DispatchException($"{name} needs l, r, u or d"),
                    name == "movewindow");
            case "togglesplit":
                ToggleSplit();
                return [];
            case "splitratio":
                SplitRatio(arg);
                return [];
            case "layoutmsg":
                return LayoutMsg(arg);
            case "focusmonitor":
            {
                if (Monitors.Count == 0) return [];
                int? m;
                if (Geometry.ParseDirection(arg) is { } dir)
                {
                    var frames = Monitors.Select((mon, i) => (mon, i)).Where(p => p.i != FocusedMonitor).ToDictionary(p => p.i, p => p.mon.Frame);
                    m = Geometry.TryNeighbor(Monitors[FocusedMonitor].Frame, dir, frames, out var found) ? found : null;
                }
                else if ((arg.StartsWith('+') || arg.StartsWith('-')) && int.TryParse(arg, out var d))
                    m = ((FocusedMonitor + d) % Monitors.Count + Monitors.Count) % Monitors.Count;
                else if (int.TryParse(arg, out var idx) && idx >= 0 && idx < Monitors.Count)
                    m = idx;
                else if (Monitors.FindIndex(x => x.Name == arg || x.Id == arg) is var fi && fi >= 0)
                    m = fi;
                else throw new DispatchException($"unknown monitor {arg}");
                if (m is not { } mm || mm == FocusedMonitor) return [];
                FocusedMonitor = mm;
                return FocusCurrent();
            }
            case "cyclenext":
            {
                var ws = Workspace(CurrentWorkspace);
                var list = ws.All;
                if (list.Count == 0) return [];
                bool back = arg.Contains("prev", StringComparison.OrdinalIgnoreCase);
                int idx = Focused is { } cur && list.IndexOf(cur) is var i && i >= 0 ? i : (back ? 0 : list.Count - 1);
                var next = list[((idx + (back ? -1 : 1)) % list.Count + list.Count) % list.Count];
                Focused = next;
                ws.LastFocused = next;
                return [new Effect.Focus(next)];
            }
            case "centerwindow":
                return Focused is { } c && IsFloating(c) ? [new Effect.Center(c)] : [];
            case "moveactive" or "resizeactive":
            {
                var parts = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
                bool exact = parts.FirstOrDefault() == "exact";
                if (exact) parts.RemoveAt(0);
                if (parts.Count != 2 || !TryNum(parts[0], out var x) || !TryNum(parts[1], out var y))
                    throw new DispatchException($"{name} needs [exact] X Y");
                if (Focused is not { } id || !IsFloating(id)) return [];
                return name == "moveactive" ? [new Effect.MoveWindow(id, x, y, exact)] : [new Effect.ResizeWindow(id, x, y, exact)];
            }
            default:
                if (Dispatchers.Unsupported.Contains(name)) throw new DispatchException($"{name} is not supported on Windows yet");
                throw new DispatchException($"unknown dispatcher {name}");
        }
    }

    static bool TryNum(string s, out double v) => double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out v);

    internal int ResolveWorkspace(string arg)
    {
        var a = arg.Trim();
        if (int.TryParse(a, out var n) && n > 0 && !a.StartsWith('+')) return n;
        if (a == "previous") return PreviousWorkspace ?? throw new DispatchException("no previous workspace");
        if (a == "empty")
        {
            int e = 1;
            while ((Workspaces.TryGetValue(e, out var w) && !w.IsEmpty) || MonitorIndex(e) is not null) e++;
            return e;
        }
        var rel = a;
        bool existingOnly = false;
        if (rel.StartsWith('e') || rel.StartsWith('m')) { existingOnly = true; rel = rel[1..]; }
        else if (rel.StartsWith('r')) rel = rel[1..];
        if ((rel.StartsWith('+') || rel.StartsWith('-')) && int.TryParse(rel, out var d))
        {
            if (existingOnly)
            {
                var ids = Workspaces.Values.Where(w => !w.IsEmpty).Select(w => w.Id).ToList();
                if (!ids.Contains(CurrentWorkspace)) ids.Add(CurrentWorkspace);
                ids.Sort();
                int i = ids.IndexOf(CurrentWorkspace);
                return ids[((i + d) % ids.Count + ids.Count) % ids.Count];
            }
            return Math.Max(1, CurrentWorkspace + d);
        }
        throw new DispatchException($"bad workspace {arg}");
    }

    Dictionary<long, Rect> VisibleFrames(IReadOnlyDictionary<long, Rect> floating)
    {
        var o = Frames();
        foreach (var (id, r) in floating) if (IsVisible(id)) o[id] = r;
        return o;
    }

    List<Effect> MoveFocus(Direction dir, IReadOnlyDictionary<long, Rect> floating)
    {
        var all = VisibleFrames(floating);
        if (Focused is not { } f || !all.TryGetValue(f, out var from)) return FocusCurrent();
        int mon = FocusedMonitor;
        int monWs = Monitors[mon].Workspace;
        var candidates = all.Where(p => p.Key != f && WindowWorkspace.GetValueOrDefault(p.Key) == monWs).ToDictionary();
        if (Workspaces.TryGetValue(monWs, out var cw) && cw.Fullscreen is { } fs && fs != f) candidates.Clear();
        if (Geometry.TryNeighbor(from, dir, candidates, out var n))
        {
            Focused = n;
            Workspace(monWs).LastFocused = n;
            return [new Effect.Focus(n)];
        }
        var monFrames = Monitors.Select((m, i) => (m, i)).Where(p => p.i != mon).ToDictionary(p => p.i, p => p.m.Frame);
        if (!Geometry.TryNeighbor(Monitors[mon].Frame, dir, monFrames, out var other)) return [];
        FocusedMonitor = other;
        return FocusCurrent();
    }

    List<Effect> MoveFocused(Direction dir, bool allowMonitor)
    {
        if (Focused is not { } id || !WindowWorkspace.TryGetValue(id, out var wsId)) return [];
        var ws = Workspaces[wsId];
        if (ws.IsFloating(id) || MonitorIndex(wsId) is not { } mon) return [];
        var tiled = Frames(wsId, mon);
        if (tiled.TryGetValue(id, out var from) &&
            Geometry.TryNeighbor(from, dir, tiled.Where(p => p.Key != id).ToDictionary(), out var other))
        {
            ws.Tree.Swap(id, other);
            int i = ws.Order.IndexOf(id), j = ws.Order.IndexOf(other);
            if (i >= 0 && j >= 0) (ws.Order[i], ws.Order[j]) = (ws.Order[j], ws.Order[i]);
            return [];
        }
        if (!allowMonitor) return [];
        var monFrames = Monitors.Select((m, i) => (m, i)).Where(p => p.i != mon).ToDictionary(p => p.i, p => p.m.Frame);
        if (!Geometry.TryNeighbor(Monitors[mon].Frame, dir, monFrames, out var target)) return [];
        MoveWindowTo(id, Monitors[target].Workspace);
        FocusedMonitor = target;
        Focused = id;
        return [new Effect.Focus(id)];
    }

    void ToggleSplit()
    {
        if (Focused is not { } id || !WindowWorkspace.TryGetValue(id, out var wsId)) return;
        int m = MonitorIndex(wsId) ?? FocusedMonitor;
        if (m >= Monitors.Count) return;
        Workspaces[wsId].Tree.ToggleSplit(id, TileArea(m), Config.Dwindle);
    }

    void SplitRatio(string arg)
    {
        var parts = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        double? exact = null, delta = null;
        if (parts.Length == 2 && parts[0] == "exact" && TryNum(parts[1], out var e)) exact = e;
        else if (parts.Length == 1 && TryNum(parts[0], out var d)) delta = d;
        else throw new DispatchException("splitratio needs a number or 'exact N'");
        if (Config.Layout == "master")
        {
            var v = exact is { } x ? x / 2 : Config.Mfact + (delta ?? 0) / 2;
            Config.Mfact = Math.Clamp(v, 0.05, 0.95);
            return;
        }
        if (Focused is not { } id || !WindowWorkspace.TryGetValue(id, out var wsId)) return;
        Workspaces[wsId].Tree.ChangeRatio(id, delta, exact);
    }

    List<Effect> LayoutMsg(string arg)
    {
        var parts = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) throw new DispatchException("layoutmsg needs a message");
        var cmd = parts[0].ToLowerInvariant();
        switch (cmd)
        {
            case "togglesplit": ToggleSplit(); break;
            case "swapwithmaster":
            {
                if (Focused is not { } id || !WindowWorkspace.TryGetValue(id, out var wsId)) return [];
                var ws = Workspaces[wsId];
                int i = ws.Order.IndexOf(id);
                if (i < 0 || (i == 0 && ws.Order.Count < 2)) return [];
                int j = i == 0 ? 1 : 0;
                var other = ws.Order[j];
                (ws.Order[i], ws.Order[j]) = (ws.Order[j], ws.Order[i]);
                ws.Tree.Swap(id, other);
                break;
            }
            case "orientationleft" or "orientationright" or "orientationtop" or "orientationbottom":
                Config.Orientation = cmd["orientation".Length..];
                break;
            case "mfact":
            {
                var sub = parts.Skip(1).ToArray();
                if (sub.Length == 2 && sub[0] == "exact" && TryNum(sub[1], out var v)) Config.Mfact = Math.Clamp(v, 0.05, 0.95);
                else if (sub.Length == 1 && TryNum(sub[0], out var dv)) Config.Mfact = Math.Clamp(Config.Mfact + dv, 0.05, 0.95);
                else throw new DispatchException("mfact needs a number or 'exact N'");
                break;
            }
            default: throw new DispatchException($"unknown layoutmsg {cmd}");
        }
        return [];
    }
}
