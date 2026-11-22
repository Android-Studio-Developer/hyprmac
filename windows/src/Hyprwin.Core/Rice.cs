using System.Text.Json;
using System.Text.Json.Serialization;

namespace Hyprwin.Core;

/// <summary>OS-specific pieces of applying a rice.</summary>
public interface IRicePlatform
{
    /// <summary>Classify a rice .config entry; <c>target</c> is where to link it.</summary>
    RiceKind Classify(string name, out string? target);
    /// <summary>Directory link (a junction on Windows: no admin or Developer Mode needed).</summary>
    void LinkDirectory(string link, string target);
    /// <summary>File link; may fall back to a copy. Returns true when it copied.</summary>
    bool LinkFile(string link, string target);
    string? GetWallpaper();
    void SetWallpaper(string path);
    void Git(params string[] args);
}

public sealed class RiceManifest
{
    public sealed class Link
    {
        public string Target { get; set; } = "";
        public string Source { get; set; } = "";
        public string? Backup { get; set; }
        public bool Copied { get; set; }
    }

    public string Rice { get; set; } = "";
    public DateTime AppliedAt { get; set; }
    public List<Link> Links { get; set; } = [];
    public string? ConfigWritten { get; set; }
    public string? ConfigBackup { get; set; }
    public string? Wallpaper { get; set; }
}

public sealed record RicePlan(string Name, string Dir, string ConfigRoot,
    IReadOnlyList<(string Name, RiceKind Kind, string? Target)> Items, string? HyprConfig, string? Wallpaper);

public sealed class RiceException(string message) : Exception(message);

/// <summary>`hyprwin rice ...`: install a dotfiles repo and apply the parts that work here.
/// Same behavior as Rice.swift on macOS.</summary>
public sealed class RiceManager(IRicePlatform platform, string dataDir, string configPath, TextWriter output)
{
    public string Root => Path.Combine(dataDir, "rices");
    public string ManifestPath => Path.Combine(dataDir, "active-rice.json");
    string BackupRoot => Path.Combine(dataDir, "backups");

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    public const string Usage = """
    usage: hyprwin rice install <git-url | folder> [--name NAME]
           hyprwin rice show <name>                 what `use` would do
           hyprwin rice use <name> [--dry-run] [--no-wallpaper] [--with-shell] [--all]
           hyprwin rice off                         undo the active rice, restore backups
           hyprwin rice list
           hyprwin rice update <name>               git pull
           hyprwin rice remove <name>

    Rices live in %LOCALAPPDATA%\hyprwin\rices. Replaced configs are backed up to
    %LOCALAPPDATA%\hyprwin\backups. A rice's own install script is never run, but its
    Lua config and keybinds do run commands, so only use rices you trust.
    """;

    /// <summary>Called after a rice is applied or removed (e.g. reload the running window manager).</summary>
    public Action? OnChanged { get; set; }

    public int Main(string[] args)
    {
        if (args.Length == 0) { output.WriteLine(Usage); return 1; }
        var rest = args.Skip(1).ToList();
        bool Flag(string f) => rest.Remove(f);
        string? Option(string f)
        {
            int i = rest.IndexOf(f);
            if (i < 0 || i + 1 >= rest.Count) return null;
            var v = rest[i + 1];
            rest.RemoveRange(i, 2);
            return v;
        }
        try
        {
            switch (args[0])
            {
                case "install":
                {
                    var name = Option("--name");
                    Install(rest.FirstOrDefault() ?? throw new RiceException("install needs a git URL or folder"), name);
                    break;
                }
                case "show": PrintPlan(Plan(rest.FirstOrDefault() ?? throw new RiceException("show needs a rice name"))); break;
                case "use" or "apply":
                {
                    bool dry = Flag("--dry-run"), noWall = Flag("--no-wallpaper"), shell = Flag("--with-shell"), all = Flag("--all");
                    Use(rest.FirstOrDefault() ?? throw new RiceException("use needs a rice name"), dry, !noWall, shell, all);
                    break;
                }
                case "off" or "restore": Off(); break;
                case "list" or "ls": List(); break;
                case "update":
                {
                    var dir = Path.Combine(Root, rest.FirstOrDefault() ?? throw new RiceException("update needs a rice name"));
                    if (!Directory.Exists(Path.Combine(dir, ".git"))) throw new RiceException("not a git clone");
                    platform.Git("-C", dir, "pull", "--ff-only");
                    break;
                }
                case "remove" or "rm": Remove(rest.FirstOrDefault() ?? throw new RiceException("remove needs a rice name")); break;
                case "help" or "-h" or "--help": output.WriteLine(Usage); break;
                default: throw new RiceException($"unknown rice command {args[0]}\n\n{Usage}");
            }
            return 0;
        }
        catch (Exception e) when (e is RiceException or IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"hyprwin rice: {e.Message}");
            return 1;
        }
    }

    public static string DefaultName(string src)
    {
        var s = src.TrimEnd('/', '\\');
        if (s.EndsWith(".git")) s = s[..^4];
        var parts = s.Split(['/', ':', '\\'], StringSplitOptions.RemoveEmptyEntries);
        var repo = parts.LastOrDefault() ?? "rice";
        var owner = parts.Length >= 2 ? parts[^2] : "";
        string[] generic = ["dotfiles", ".dotfiles", "dots", "dotfile", "config", "configs", "rice", ".config"];
        var raw = generic.Contains(repo.ToLowerInvariant()) && owner.Length > 0 ? owner : repo;
        var cleaned = new string(raw.ToLowerInvariant().Select(c => char.IsLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '-').ToArray());
        return cleaned.Trim('.', '-');
    }

    public IReadOnlyList<string> Installed =>
        Directory.Exists(Root) ? Directory.GetFileSystemEntries(Root).Select(Path.GetFileName).Where(n => n is not null && !n.StartsWith('.')).Order().ToList()! : [];

    public string? Active => LoadManifest()?.Rice;

    public void Install(string src, string? name)
    {
        name ??= DefaultName(src);
        if (name.Length == 0 || name.Contains('/') || name.Contains('\\') || name is "." or "..") throw new RiceException($"bad rice name {name}");
        var dest = Path.Combine(Root, name);
        Directory.CreateDirectory(Root);
        if (Directory.Exists(dest) || File.Exists(dest)) throw new RiceException($"{name} is already installed (update or remove it first)");
        var local = ConfigParser.Expand(src);
        if (Directory.Exists(local))
        {
            platform.LinkDirectory(dest, Path.GetFullPath(local));
            output.WriteLine($"linked local rice {Path.GetFullPath(local)} as {name}");
        }
        else
        {
            if (!(src.StartsWith("https://") || src.StartsWith("git@") || src.StartsWith("ssh://")))
                throw new RiceException($"{src} is not a folder or a git URL");
            platform.Git("clone", "--depth", "1", src, dest);
        }
        output.WriteLine();
        output.WriteLine("Only use rices you trust: their keybinds and Lua config run commands on this PC.");
        output.WriteLine();
        PrintPlan(Plan(name));
        output.WriteLine($"\nApply it with: hyprwin rice use {name}");
    }

    public void List()
    {
        var active = Active;
        if (Installed.Count == 0) output.WriteLine("no rices installed (hyprwin rice install <git-url>)");
        foreach (var n in Installed) output.WriteLine((n == active ? "* " : "  ") + n);
    }

    public void Remove(string name)
    {
        var dest = Path.Combine(Root, name);
        if (name.Length == 0 || name.Contains('/') || name.Contains('\\') || !(Directory.Exists(dest) || File.Exists(dest)))
            throw new RiceException($"no rice named {name}");
        if (Active == name) Off();
        var info = new DirectoryInfo(dest);
        if (info.LinkTarget is not null) info.Delete(); // local rice: only the link
        else DeleteTree(dest);
        output.WriteLine($"removed {name}");
    }

    /// <summary>Deletes a git clone; clears read-only flags git sets on Windows.</summary>
    static void DeleteTree(string dir)
    {
        foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
            File.SetAttributes(f, FileAttributes.Normal);
        Directory.Delete(dir, true);
    }

    public RicePlan Plan(string name)
    {
        var dir = Path.Combine(Root, name);
        if (!Directory.Exists(dir)) throw new RiceException($"no rice named {name} (hyprwin rice list)");
        var dotConfig = Path.Combine(dir, ".config");
        var configRoot = Directory.Exists(dotConfig) ? dotConfig : dir;

        var entries = Directory.GetFileSystemEntries(configRoot).Select(p => Path.GetFileName(p)!)
            .Where(n => n is not ".git" and not ".DS_Store" and not ".github").Order(StringComparer.Ordinal).ToList();
        var items = new List<(string, RiceKind, string?)>();
        string[] junk = ["README", "LICENSE", "install", "update", "assets", "docs", "packages", "screenshots"];
        foreach (var e in entries)
        {
            var kind = platform.Classify(e, out var target);
            if (configRoot == dir && kind == RiceKind.Unknown && junk.Any(e.StartsWith)) continue;
            items.Add((e, kind, target));
        }

        string? hypr = null;
        foreach (var c in new[] { "hyprwin/hyprland.lua", "hyprwin/hyprland.conf", "hypr/hyprland.lua", "hypr/hyprland.conf", "hyprland.lua", "hyprland.conf" })
        {
            var p = Path.Combine(configRoot, c);
            if (File.Exists(p)) { hypr = p; break; }
        }

        var images = new List<string>();
        void Scan(string d, int depth)
        {
            if (depth > 5) return;
            foreach (var f in Directory.EnumerateFiles(d)) images.Add(Path.GetRelativePath(dir, f).Replace('\\', '/'));
            foreach (var sub in Directory.EnumerateDirectories(d))
            {
                var n = Path.GetFileName(sub);
                if (n is ".git" or "node_modules") continue;
                if (new DirectoryInfo(sub).LinkTarget is not null) continue;
                Scan(sub, depth + 1);
            }
        }
        Scan(dir, 1);
        var wall = RiceCatalog.WallpaperCandidates(images).FirstOrDefault();
        return new RicePlan(name, dir, configRoot, items, hypr, wall is null ? null : Path.Combine(dir, wall));
    }

    public void PrintPlan(RicePlan p)
    {
        output.WriteLine($"rice {p.Name}  ({p.Dir})");
        output.WriteLine(p.HyprConfig is { } h
            ? $"  window manager config: {Path.GetRelativePath(p.Dir, h).Replace('\\', '/')}{(h.EndsWith(".lua") ? " (Hyprland Lua)" : "")}"
            : "  no hyprland.conf / hyprland.lua found: hyprwin keeps your current config");
        string Names(RiceKind k)
        {
            var n = p.Items.Where(i => i.Kind == k).Select(i => i.Name).ToList();
            return n.Count == 0 ? "-" : string.Join(", ", n);
        }
        output.WriteLine($"  link:                  {Names(RiceKind.Link)}");
        output.WriteLine($"  not on Windows:        {Names(RiceKind.NotHere)}");
        output.WriteLine($"  shell files, skipped:  {Names(RiceKind.Shell)}  (--with-shell to link)");
        output.WriteLine($"  unknown, skipped:      {Names(RiceKind.Unknown)}  (--all to link)");
        if (p.Wallpaper is { } w) output.WriteLine($"  wallpaper:             {Path.GetRelativePath(p.Dir, w).Replace('\\', '/')}");
    }

    string TargetFor((string Name, RiceKind Kind, string? Target) item) =>
        item.Target ?? (item.Name.StartsWith('.') ? Path.Combine(ConfigParser.Home, item.Name) : Path.Combine(ConfigParser.Home, ".config", item.Name));

    static bool Exists(string p) => File.Exists(p) || Directory.Exists(p) || new FileInfo(p).LinkTarget is not null;

    public void Use(string name, bool dryRun, bool wallpaper, bool withShell, bool all)
    {
        var p = Plan(name);
        var chosen = p.Items.Where(i => i.Kind switch
        {
            RiceKind.Link => true,
            RiceKind.Shell => withShell,
            RiceKind.Unknown => all,
            _ => false,
        }).ToList();
        var backupDir = Path.Combine(BackupRoot, $"{name}-{DateTime.Now:yyyyMMdd-HHmmss}");
        bool ownConfig = chosen.Any(i => i.Name is "hyprwin");

        if (dryRun)
        {
            output.WriteLine("dry run: nothing changes");
            if (Active is { } a) output.WriteLine($"would first undo the active rice {a}");
            foreach (var item in chosen)
            {
                var t = TargetFor(item);
                output.WriteLine($"  link {t} -> {Path.Combine(p.ConfigRoot, item.Name)}{(Exists(t) ? "  (existing moved to backup)" : "")}");
            }
            if (p.HyprConfig is { } h && !ownConfig)
                output.WriteLine($"  write {ConfigParser.Expand(configPath)}: source = {ConfigSource(h, p, chosen)}");
            if (wallpaper && p.Wallpaper is { } w) output.WriteLine($"  wallpaper: {w}");
            return;
        }

        if (LoadManifest() is not null) Off(quiet: true);

        var m = new RiceManifest { Rice = name, AppliedAt = DateTime.UtcNow };
        void Save()
        {
            Directory.CreateDirectory(dataDir);
            File.WriteAllText(ManifestPath, JsonSerializer.Serialize(m, Json));
        }
        Save();

        foreach (var item in chosen)
        {
            var t = TargetFor(item);
            var src = Path.Combine(p.ConfigRoot, item.Name);
            string? backup = null;
            if (Exists(t))
            {
                var existing = new FileInfo(t).LinkTarget ?? new DirectoryInfo(t).LinkTarget;
                if (existing is not null && Path.GetFullPath(existing) == Path.GetFullPath(src)) continue;
                backup = Path.Combine(backupDir, Path.GetRelativePath(ConfigParser.Home, t));
                Directory.CreateDirectory(Path.GetDirectoryName(backup)!);
                if (Directory.Exists(t) && new DirectoryInfo(t).LinkTarget is null) Directory.Move(t, backup);
                else File.Move(t, backup);
            }
            Directory.CreateDirectory(Path.GetDirectoryName(t)!);
            bool copied = false;
            if (Directory.Exists(src)) platform.LinkDirectory(t, src);
            else copied = platform.LinkFile(t, src);
            m.Links.Add(new RiceManifest.Link { Target = t, Source = src, Backup = backup, Copied = copied });
            Save();
            output.WriteLine($"linked {t}{(backup is not null ? "  (old one backed up)" : "")}");
        }

        if (p.HyprConfig is { } hc && !ownConfig)
        {
            var cfg = ConfigParser.Expand(configPath);
            Directory.CreateDirectory(Path.GetDirectoryName(cfg)!);
            if (File.Exists(cfg))
            {
                var b = Path.Combine(backupDir, ".config", "hyprwin", "hyprland.conf");
                Directory.CreateDirectory(Path.GetDirectoryName(b)!);
                File.Move(cfg, b);
                m.ConfigBackup = b;
            }
            File.WriteAllText(cfg, PointerConfig(name, ConfigSource(hc, p, chosen)));
            m.ConfigWritten = cfg;
            Save();
            output.WriteLine($"hyprwin now loads {ConfigSource(hc, p, chosen)}");
        }

        if (wallpaper && p.Wallpaper is { } wp)
        {
            m.Wallpaper = platform.GetWallpaper();
            platform.SetWallpaper(wp);
            Save();
            output.WriteLine("wallpaper set");
        }

        output.WriteLine($"\nrice {name} applied. Not on Windows, skipped: {string.Join(", ", p.Items.Where(i => i.Kind == RiceKind.NotHere).Select(i => i.Name))}");
        output.WriteLine("SUPER is mapped to Alt (edit ~/.config/hyprwin/hyprland.conf to change). Undo: hyprwin rice off");
        OnChanged?.Invoke();
    }

    /// <summary>`source =` for the rice's config: through ~/.config/hypr when that folder was linked
    /// there, because rice Lua files hard-code ~/.config/hypr/... paths.</summary>
    static string ConfigSource(string hypr, RicePlan p, IEnumerable<(string Name, RiceKind Kind, string? Target)> linked)
    {
        var rel = Path.GetRelativePath(p.ConfigRoot, hypr).Replace('\\', '/');
        var top = rel.Split('/')[0];
        if (rel.Contains('/') && linked.Any(i => i.Name == top)) return "~/.config/" + rel;
        return hypr.Replace('\\', '/');
    }

    public static string PointerConfig(string rice, string source) => $"""
    # Managed by `hyprwin rice use {rice}`.
    # `hyprwin rice off` puts back the config you had before.
    #
    # Linux rices bind SUPER + C, V, L, D... Windows reserves several Win+key combos, so SUPER
    # is mapped to Alt. Other choices: win, ctrl, "ctrl alt".
    hyprwin {"{"}
        super = alt
    {"}"}

    source = {source}

    # Your Windows tweaks go below; they apply after the rice.

    """;

    public void Off(bool quiet = false)
    {
        if (LoadManifest() is not { } m)
        {
            if (!quiet) output.WriteLine("no rice is active");
            return;
        }
        foreach (var link in Enumerable.Reverse(m.Links))
        {
            var lt = new FileInfo(link.Target).LinkTarget ?? new DirectoryInfo(link.Target).LinkTarget;
            if (lt is not null && Path.GetFullPath(lt) == Path.GetFullPath(link.Source))
            {
                if (Directory.Exists(link.Target)) Directory.Delete(link.Target); else File.Delete(link.Target);
            }
            else if (link.Copied && File.Exists(link.Target))
            {
                File.Delete(link.Target);
            }
            if (link.Backup is { } b && Exists(b) && !Exists(link.Target))
            {
                if (Directory.Exists(b) && new DirectoryInfo(b).LinkTarget is null) Directory.Move(b, link.Target);
                else File.Move(b, link.Target);
            }
        }
        if (m.ConfigWritten is { } cfg && File.Exists(cfg)) File.Delete(cfg);
        if (m.ConfigBackup is { } cb && m.ConfigWritten is { } cw && File.Exists(cb)) File.Move(cb, cw);
        else if (m.ConfigWritten is { } cw2) File.WriteAllText(cw2, DefaultConfig.Text);
        if (m.Wallpaper is { } w) platform.SetWallpaper(w);
        File.Delete(ManifestPath);
        if (!quiet) output.WriteLine($"rice {m.Rice} removed; previous configs restored");
        OnChanged?.Invoke();
    }

    public RiceManifest? LoadManifest()
    {
        try { return File.Exists(ManifestPath) ? JsonSerializer.Deserialize<RiceManifest>(File.ReadAllText(ManifestPath), Json) : null; }
        catch (JsonException) { return null; }
    }
}
