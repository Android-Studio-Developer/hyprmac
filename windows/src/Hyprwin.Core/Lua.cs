using System.Text;
using KeraLua;
using LuaState = KeraLua.Lua;

namespace Hyprwin.Core;

/// <summary>One Lua 5.4 state running a Hyprland Lua config through the shared hl.* shim
/// (shared/hl-prelude.lua). Port of HyprLua/LuaRuntime.swift.</summary>
public sealed class LuaRuntime : IDisposable
{
    readonly LuaState L;
    readonly LuaFunction hostFn; // kept alive: Lua holds a native pointer to it

    /// <summary>Calls from Lua: exec, dispatch, activewindow, activemonitor, activeworkspace, log.</summary>
    public Func<string, string, string?>? Host { get; set; }

    static readonly string Prelude = LoadPrelude();

    static string LoadPrelude()
    {
        using var s = typeof(LuaRuntime).Assembly.GetManifestResourceStream("hl-prelude.lua")
            ?? throw new InvalidOperationException("hl-prelude.lua resource missing");
        using var r = new StreamReader(s, Encoding.UTF8);
        return r.ReadToEnd();
    }

    public LuaRuntime()
    {
        L = new LuaState(openLibs: true) { Encoding = Encoding.UTF8 };
        hostFn = HostCall;
        L.Register("__hm_host", hostFn);
        Run(Prelude, "=hl-prelude");
        // Windows has no $HOME and Lua's os.getenv can't see variables set after start-up.
        // Rices do os.getenv("HOME") .. "/.config/...", so answer HOME from here.
        Run($"local _g = os.getenv; local home = {Quote(ConfigParser.Home)}\n" +
            "os.getenv = function(k) local v = _g(k); if v == nil and k == 'HOME' then return home end; return v end",
            "=env");
    }

    int HostCall(IntPtr p)
    {
        var l = LuaState.FromIntPtr(p);
        var op = l.ToString(1, false) ?? "";
        var arg = l.ToString(2, false) ?? "";
        string? reply = null;
        try { reply = Host?.Invoke(op, arg); }
        catch (Exception e) { reply = null; Console.Error.WriteLine($"lua host {op}: {e.Message}"); }
        if (reply is null) l.PushNil(); else l.PushString(reply);
        return 1;
    }

    /// <summary>Runs code; returns its first result as a string, or null.</summary>
    public string? Run(string code, string chunk)
    {
        var status = L.LoadString(code, chunk);
        if (status == LuaStatus.OK) status = L.PCall(0, 1, 0);
        var top = L.ToString(-1, false);
        L.Pop(1);
        if (status != LuaStatus.OK) throw new LuaException(top ?? $"Lua error {status}");
        return top;
    }

    public void Dispose() => L.Dispose();

    /// <summary>Lua string literal for any string (3-digit decimal escapes for non-ASCII bytes).</summary>
    public static string Quote(string s)
    {
        var sb = new StringBuilder("\"");
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            if (b == '\\') sb.Append("\\\\");
            else if (b == '"') sb.Append("\\\"");
            else if (b >= 32 && b <= 126) sb.Append((char)b);
            else sb.Append('\\').Append(b.ToString("000"));
        }
        return sb.Append('"').ToString();
    }
}

public sealed class LuaException(string message) : Exception(message);

/// <summary>Glue between hyprwin and Lua configs. Port of LuaConfig in Swift.</summary>
public static class LuaConfig
{
    static readonly Dictionary<int, LuaRuntime> runtimes = [];
    static int nextId = 1;
    static Func<string, string, string?>? host;

    public static Func<string, string, string?>? Host
    {
        get => host;
        set { host = value; foreach (var rt in runtimes.Values) rt.Host = value; }
    }

    public static void Install() => ConfigParser.LuaLoader = Load;

    /// <summary>Drop runtimes from an earlier load (call before reloading the config).</summary>
    public static void Reset()
    {
        foreach (var rt in runtimes.Values) rt.Dispose();
        runtimes.Clear();
    }

    static LuaLoadResult Load(string path)
    {
        LuaRuntime rt;
        try { rt = new LuaRuntime(); }
        catch (Exception e) { return new LuaLoadResult("", [], e.Message); }
        int id = nextId++;
        runtimes[id] = rt;
        rt.Host = host;

        var dir = (Path.GetDirectoryName(path) ?? ".").Replace('\\', '/');
        string? error = null;
        try
        {
            rt.Run($"package.path = {LuaRuntime.Quote(dir + "/?.lua;")} .. package.path", "=setup");
            rt.Run($"__hm.loading = true; dofile({LuaRuntime.Quote(path.Replace('\\', '/'))})", "=" + Path.GetFileName(path));
        }
        catch (LuaException e) { error = e.Message; }

        string text;
        try { text = rt.Run("return __hm.export()", "=export") ?? ""; }
        catch (LuaException) { text = ""; }
        text = text.Replace(", lua, ", $", lua, {id}:");
        var files = (rt.Run("return __hm.filelist()", "=files") ?? "")
            .Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(ConfigParser.Expand).ToList();
        return new LuaLoadResult(text, files, error);
    }

    static bool TryRuntime(string arg, out LuaRuntime rt, out int n)
    {
        rt = null!; n = 0;
        var parts = arg.Split(':');
        return parts.Length == 2 && int.TryParse(parts[0], out var id) && int.TryParse(parts[1], out n)
            && runtimes.TryGetValue(id, out rt!);
    }

    /// <summary>Runs a stored bind ("runtime:n").</summary>
    public static void Call(string arg)
    {
        if (!TryRuntime(arg, out var rt, out var n)) return;
        try { rt.Run($"__hm.call({n})", "=bind"); } catch (LuaException) { }
    }

    /// <summary>Shell command behind a stored bind, if it is one (not a function).</summary>
    public static string? StoredCommand(string arg)
    {
        if (!TryRuntime(arg, out var rt, out var n)) return null;
        try { return rt.Run($"local c = __hm.callables[{n}]; if type(c) == 'string' then return c end", "=cmd"); }
        catch (LuaException) { return null; }
    }

    /// <summary>Fires hl.on handlers; "hyprland.start" also runs top-level hl.exec_cmd calls.</summary>
    public static void Emit(string evt)
    {
        foreach (var id in runtimes.Keys.Order().ToList())
        {
            try { runtimes[id].Run($"__hm.emit({LuaRuntime.Quote(evt)})", "=emit"); } catch (LuaException) { }
        }
    }

    /// <summary>"return {...}" Lua table literal for get_active_window and friends.</summary>
    public static string Table(IReadOnlyDictionary<string, object?> fields)
    {
        static string Lit(object? v) => v switch
        {
            bool b => b ? "true" : "false",
            int i => i.ToString(System.Globalization.CultureInfo.InvariantCulture),
            long l => l.ToString(System.Globalization.CultureInfo.InvariantCulture),
            double d => d.ToString(System.Globalization.CultureInfo.InvariantCulture),
            string s => LuaRuntime.Quote(s),
            _ => "nil",
        };
        var body = string.Join(",", fields.Keys.Order(StringComparer.Ordinal).Select(k => $"[{LuaRuntime.Quote(k)}]={Lit(fields[k])}"));
        return "return {" + body + "}";
    }
}
