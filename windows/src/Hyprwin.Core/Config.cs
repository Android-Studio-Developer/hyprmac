using System.Globalization;
using System.Text.RegularExpressions;

namespace Hyprwin.Core;

public sealed record KeyBind(Mods Mods, string Key, string Dispatcher, string Arg)
{
    public string Combo => string.Join("+", Mods.Names().Append(Key));
}

public sealed record WindowRule(string Effect, string? ClassPattern = null, string? TitlePattern = null)
{
    /// <summary>Class candidates (process name, window class) are tried in turn. Regexes must match
    /// the whole string, like Hyprland, but case-insensitively.</summary>
    public bool Matches(IEnumerable<string> appClasses, string title)
    {
        if (ClassPattern is { } p && !appClasses.Any(c => FullMatch(p, c))) return false;
        if (TitlePattern is { } t && !FullMatch(t, title)) return false;
        return ClassPattern is not null || TitlePattern is not null;
    }

    internal static bool FullMatch(string pattern, string text)
    {
        try { return Regex.IsMatch(text, "^(?:" + pattern + ")$", RegexOptions.IgnoreCase, TimeSpan.FromMilliseconds(200)); }
        catch (ArgumentException) { return false; }
    }

    public string EffectName => Effect.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
    public string[] EffectArgs => Effect.Split(' ', StringSplitOptions.RemoveEmptyEntries).Skip(1).ToArray();
}

public sealed class Config
{
    // general
    public Insets GapsIn = Insets.All(5);
    public Insets GapsOut = Insets.All(20);
    public double BorderSize = 2;
    public BorderColor ActiveBorder = new([Rgba.FromHex("33ccffee")!.Value, Rgba.FromHex("00ff99ee")!.Value], 45);
    public BorderColor InactiveBorder = new([Rgba.FromHex("595959aa")!.Value]);
    public string Layout = "dwindle";
    // decoration
    public double Rounding = 10;
    // dwindle
    public bool PreserveSplit;
    public int ForceSplit;
    public double SplitWidthMultiplier = 1;
    public double DefaultSplitRatio = 1;
    // master
    public double Mfact = 0.55;
    public string NewStatus = "slave";
    public bool NewOnTop;
    public string Orientation = "left";
    // hyprmac/hyprwin-only
    public bool StatusBar = true;
    /// <summary>Physical modifiers SUPER binds use. Default the Windows key. Rices bind SUPER+C/V/L...,
    /// several of which Windows reserves, so `hyprwin rice use` sets ALT.</summary>
    public Mods SuperMapsTo = Mods.Super;

    public List<KeyBind> Binds = [];
    public List<string> ExecOnce = [];
    public List<string> Exec = [];
    public List<WindowRule> Rules = [];

    /// <summary>Real problems (bad values, unknown dispatchers).</summary>
    public List<string> Errors = [];
    /// <summary>Valid Hyprland options that hyprwin ignores.</summary>
    public List<string> Ignored = [];
    /// <summary>Files read (source =, Lua require/dofile). Watched for hot reload.</summary>
    public List<string> Files = [];

    public DwindleSettings Dwindle => new(PreserveSplit, ForceSplit, SplitWidthMultiplier, DefaultSplitRatio);

    public const string DefaultPath = "~/.config/hyprwin/hyprland.conf";
}

public static class Dispatchers
{
    public static readonly HashSet<string> Known =
    [
        "exec", "killactive", "closewindow", "workspace", "movetoworkspace", "movetoworkspacesilent",
        "movefocus", "movewindow", "swapwindow", "togglefloating", "setfloating", "settiled",
        "fullscreen", "togglesplit", "splitratio", "layoutmsg", "exit", "focusmonitor",
        "cyclenext", "centerwindow", "pseudo", "pin", "moveactive", "resizeactive",
        "lua", // internal: run a function or multi-line command from a Lua config
    ];

    public static readonly HashSet<string> Unsupported = ["pseudo", "pin"];
}

public sealed record LuaLoadResult(string Text, IReadOnlyList<string> Files, string? Error);

public static class ConfigParser
{
    /// <summary>Loads a Hyprland Lua config and returns equivalent hyprlang text. Installed by LuaConfig.</summary>
    public static Func<string, LuaLoadResult>? LuaLoader;

    public static Config Load(string path)
    {
        var expanded = Expand(path);
        if (expanded.EndsWith(".lua", StringComparison.OrdinalIgnoreCase))
        {
            var c = Parse($"source = {expanded}\n", "<lua>");
            c.Files.Remove("<lua>");
            return c;
        }
        string text;
        try { text = File.ReadAllText(expanded); }
        catch (Exception)
        {
            var c = new Config();
            c.Errors.Add($"cannot read {expanded}");
            return c;
        }
        return Parse(text, expanded);
    }

    public static Config Parse(string text, string file = "hyprland.conf", Func<string, string?>? readFile = null)
    {
        var p = new Parser(readFile ?? (f => { try { return File.ReadAllText(f); } catch { return null; } }));
        p.Config.Files.Add(file);
        p.Run(text, file, 0);
        if (p.Sections.Count > 0) p.Config.Errors.Add($"{file}: missing closing }}");
        return p.Config;
    }

    /// <summary>$HOME (or the user profile on Windows), with forward slashes so Lua configs that do
    /// os.getenv("HOME") .. "/.config/..." build sane paths.</summary>
    public static string Home
    {
        get
        {
            var h = Environment.GetEnvironmentVariable("HOME");
            if (string.IsNullOrEmpty(h)) h = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return h.Replace('\\', '/');
        }
    }

    public static string Expand(string path)
    {
        if (path == "~" || path.StartsWith("~/") || path.StartsWith("~\\")) return Home + path[1..];
        return path;
    }

    sealed class Parser(Func<string, string?> readFile)
    {
        public readonly Config Config = new();
        public readonly List<string> Sections = [];
        readonly Dictionary<string, string> vars = [];

        static readonly string[] IgnoredPrefixes =
        [
            "monitor", "env", "workspace", "animation", "bezier", "animations", "input", "device",
            "gestures", "gesture", "misc", "cursor", "xwayland", "opengl", "render", "debug", "ecosystem",
            "experimental", "binds", "group", "decoration", "general", "dwindle", "master", "plugin",
            "layerrule", "permission", "exec-shutdown", "execr", "execr-once", "submap", "windowrule",
            "hyprmac",
        ];

        public void Run(string text, string file, int depth)
        {
            int lineNo = 0;
            foreach (var rawLine in text.Split('\n'))
            {
                lineNo++;
                var where = $"{Path.GetFileName(file)}:{lineNo}";
                var line = StripComment(rawLine.TrimEnd('\r')).Trim();
                if (line.Length == 0) continue;

                while (line.StartsWith('}'))
                {
                    if (Sections.Count == 0) Config.Errors.Add($"{where}: unexpected }}");
                    else Sections.RemoveAt(Sections.Count - 1);
                    line = line[1..].Trim();
                }
                if (line.Length == 0) continue;

                if (line.EndsWith('{'))
                {
                    var name = line[..^1].Trim();
                    Sections.Add(name.Split('[')[0]);
                    continue;
                }

                int eq = line.IndexOf('=');
                if (eq < 0)
                {
                    Config.Errors.Add($"{where}: expected key = value");
                    continue;
                }
                var key = line[..eq].Trim();
                var value = Substitute(line[(eq + 1)..].Trim());
                if (key.StartsWith('$'))
                {
                    vars[key[1..]] = value;
                    continue;
                }
                var full = string.Join(":", Sections.Append(key));
                // hyprwin { } is the Windows spelling of hyprmac { }.
                if (full.StartsWith("hyprwin:")) full = "hyprmac:" + full["hyprwin:".Length..];
                Handle(full, value, where, file, depth);
            }
        }

        static string StripComment(string s)
        {
            var sb = new System.Text.StringBuilder();
            for (int i = 0; i < s.Length; i++)
            {
                if (s[i] == '#')
                {
                    if (i + 1 < s.Length && s[i + 1] == '#') { sb.Append('#'); i++; continue; }
                    break;
                }
                sb.Append(s[i]);
            }
            return sb.ToString();
        }

        string Substitute(string s)
        {
            if (!s.Contains('$') || vars.Count == 0) return s;
            foreach (var name in vars.Keys.OrderByDescending(k => k.Length))
                s = s.Replace("$" + name, vars[name]);
            return s;
        }

        static bool? Bool(string v) => v.ToLowerInvariant() switch
        {
            "1" or "true" or "yes" or "on" => true,
            "0" or "false" or "no" or "off" => false,
            _ => null,
        };

        static double? Num(string v) =>
            double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : null;

        void Handle(string key, string value, string where, string file, int depth)
        {
            void Bad() => Config.Errors.Add($"{where}: invalid value for {key}: {value}");

            switch (key)
            {
                case "source":
                {
                    if (depth >= 8) { Config.Errors.Add($"{where}: source nested too deep"); return; }
                    var path = Expand(value);
                    if (!Path.IsPathRooted(path) && !path.StartsWith('/'))
                        path = Path.Combine(Path.GetDirectoryName(file) ?? "", path);
                    if (path.EndsWith(".lua", StringComparison.OrdinalIgnoreCase))
                    {
                        if (LuaLoader is null) { Config.Errors.Add($"{where}: Lua configs need Lua support"); return; }
                        var r = LuaLoader(path);
                        Config.Files.Add(path);
                        foreach (var f in r.Files) if (!Config.Files.Contains(f)) Config.Files.Add(f);
                        if (r.Error is not null) Config.Errors.Add($"{Path.GetFileName(path)}: {r.Error}");
                        var savedLua = Sections.ToList();
                        Sections.Clear();
                        Run(r.Text, path + " (lua)", depth + 1);
                        Sections.AddRange(savedLua);
                        return;
                    }
                    var text = readFile(path);
                    if (text is null) { Config.Errors.Add($"{where}: cannot read source {path}"); return; }
                    Config.Files.Add(path);
                    var saved = Sections.ToList();
                    Sections.Clear();
                    Run(text, path, depth + 1);
                    Sections.AddRange(saved);
                    return;
                }
                case "exec-once": Config.ExecOnce.Add(value); return;
                case "exec": Config.Exec.Add(value); return;
                case "windowrule" or "windowrulev2":
                    if (ParseRule(value, key == "windowrulev2") is { } rule) Config.Rules.Add(rule); else Bad();
                    return;
                case "unbind":
                {
                    var parts = value.Split(',', 2).Select(p => p.Trim()).ToArray();
                    if (parts.Length != 2 || ModsParser.Parse(parts[0]) is not { } mods) { Bad(); return; }
                    var k = WinKeyCodes.Normalize(parts[1]);
                    Config.Binds.RemoveAll(b => b.Mods == mods && b.Key == k);
                    return;
                }
                case "general:gaps_in": if (Insets.ParseCss(value) is { } gi) Config.GapsIn = gi; else Bad(); return;
                case "general:gaps_out": if (Insets.ParseCss(value) is { } go) Config.GapsOut = go; else Bad(); return;
                case "general:border_size": if (Num(value) is { } bs && bs >= 0) Config.BorderSize = bs; else Bad(); return;
                case "general:col.active_border": if (BorderColor.Parse(value) is { } ab) Config.ActiveBorder = ab; else Bad(); return;
                case "general:col.inactive_border": if (BorderColor.Parse(value) is { } ib) Config.InactiveBorder = ib; else Bad(); return;
                case "general:layout": if (value is "dwindle" or "master") Config.Layout = value; else Bad(); return;
                case "decoration:rounding": if (Num(value) is { } ro && ro >= 0) Config.Rounding = ro; else Bad(); return;
                case "dwindle:preserve_split": if (Bool(value) is { } ps) Config.PreserveSplit = ps; else Bad(); return;
                case "dwindle:force_split":
                    if (int.TryParse(value, out var fs) && fs is >= 0 and <= 2) Config.ForceSplit = fs; else Bad(); return;
                case "dwindle:split_width_multiplier": if (Num(value) is { } sw && sw > 0) Config.SplitWidthMultiplier = sw; else Bad(); return;
                case "dwindle:default_split_ratio":
                    if (Num(value) is { } dr && dr >= 0.1 && dr <= 1.9) Config.DefaultSplitRatio = dr; else Bad(); return;
                case "master:mfact": if (Num(value) is { } mf && mf > 0 && mf < 1) Config.Mfact = mf; else Bad(); return;
                case "master:new_status": if (value is "master" or "slave" or "inherit") Config.NewStatus = value; else Bad(); return;
                case "master:new_on_top": if (Bool(value) is { } nt) Config.NewOnTop = nt; else Bad(); return;
                case "master:orientation":
                    if (value is "left" or "right" or "top" or "bottom") Config.Orientation = value; else Bad(); return;
                case "hyprmac:status_bar": if (Bool(value) is { } sb) Config.StatusBar = sb; else Bad(); return;
                case "hyprmac:super":
                    if (ModsParser.Parse(value) is { } sm && sm != Mods.None) Config.SuperMapsTo = sm; else Bad(); return;
            }

            if (key.StartsWith("bind")) ParseBind(key, value, where);
            else if (IgnoredPrefixes.Any(p => key == p || key.StartsWith(p + ":"))) Config.Ignored.Add(key);
            else Config.Errors.Add($"{where}: unknown option {key}");
        }

        void ParseBind(string kind, string value, string where)
        {
            var flags = kind[4..];
            if (flags.Contains('m')) { Config.Ignored.Add(kind); return; }
            if (flags.Any(c => !"lrenitsdpo".Contains(c))) { Config.Errors.Add($"{where}: unknown bind kind {kind}"); return; }
            var parts = value.Split(',', 4).Select(p => p.Trim()).ToArray();
            if (parts.Length < 3) { Config.Errors.Add($"{where}: bind needs MODS, key, dispatcher"); return; }
            if (ModsParser.Parse(parts[0]) is not { } mods) { Config.Errors.Add($"{where}: unknown modifier in {parts[0]}"); return; }
            var key = WinKeyCodes.Normalize(parts[1]);
            if (key.StartsWith("mouse") || key.StartsWith("xf86") || key.StartsWith("code:"))
            {
                Config.Ignored.Add($"{kind} {parts[0]} {parts[1]}");
                return;
            }
            if (WinKeyCodes.Code(key) is null) { Config.Errors.Add($"{where}: unknown key {parts[1]}"); return; }
            var dispatcher = parts[2].ToLowerInvariant();
            if (dispatcher is "unsupported" or "mouse")
            {
                Config.Ignored.Add($"{kind} {parts[0]} {parts[1]}: {(parts.Length > 3 ? parts[3] : dispatcher)}");
                return;
            }
            if (!Dispatchers.Known.Contains(dispatcher)) { Config.Errors.Add($"{where}: unknown dispatcher {parts[2]}"); return; }
            var arg = parts.Length > 3 ? parts[3] : "";
            Config.Binds.RemoveAll(b => b.Mods == mods && b.Key == key);
            Config.Binds.Add(new KeyBind(mods, key, dispatcher, arg));
        }

        static WindowRule? ParseRule(string value, bool v2)
        {
            var parts = value.Split(',').Select(p => p.Trim()).ToArray();
            if (parts.Length < 2 || parts[0].Length == 0) return null;
            string? cls = null, title = null;
            foreach (var m in parts.Skip(1))
            {
                int colon = m.IndexOf(':');
                var prop = colon >= 0 ? m[..colon].ToLowerInvariant() : "";
                if (prop is "class" or "initialclass" or "title" or "initialtitle")
                {
                    var pat = m[(colon + 1)..];
                    if (prop.EndsWith("class")) cls = pat; else title = pat;
                }
                else if (!v2) cls = m;
                else if (colon >= 0) continue;
                else return null;
            }
            if (cls is null && title is null) return null;
            var effect = string.Join(" ", parts[0].Split(' ', StringSplitOptions.RemoveEmptyEntries));
            return new WindowRule(effect, cls, title);
        }
    }
}
