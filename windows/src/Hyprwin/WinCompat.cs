using System.Diagnostics;
using Hyprwin.Core;
using Microsoft.Win32;

namespace Hyprwin;

/// <summary>PATH, Linux-tool stand-ins (.cmd shims) and "is this program available" checks.</summary>
static class WinCompat
{
    public static string ShimDir => Path.Combine(HyprwinInfo.DataDir, "shims");

    public static string PathString
    {
        get
        {
            var inherited = Environment.GetEnvironmentVariable("PATH") ?? "";
            return ShimDir + ";" + inherited;
        }
    }

    static readonly Dictionary<string, bool> cache = new(StringComparer.OrdinalIgnoreCase);
    static HashSet<string> shimNames = new(StringComparer.OrdinalIgnoreCase);
    static readonly string[] Exts = (Environment.GetEnvironmentVariable("PATHEXT") ?? ".COM;.EXE;.BAT;.CMD").Split(';', StringSplitOptions.RemoveEmptyEntries);

    /// <summary>On PATH (any PATHEXT), registered in App Paths (what `start` uses), or shimmed.</summary>
    public static bool IsAvailable(string program)
    {
        if (shimNames.Contains(program)) return true;
        if (cache.TryGetValue(program, out var c)) return c;
        bool ok;
        if (program.Contains('/') || program.Contains('\\'))
        {
            ok = File.Exists(ConfigParser.Expand(program));
        }
        else
        {
            ok = OnPath(program, skipShims: true) || InAppPaths(program);
        }
        cache[program] = ok;
        return ok;
    }

    static bool OnPath(string name, bool skipShims)
    {
        foreach (var dir in PathString.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            if (skipShims && string.Equals(dir, ShimDir, StringComparison.OrdinalIgnoreCase)) continue;
            try
            {
                if (Path.HasExtension(name) && File.Exists(Path.Combine(dir, name))) return true;
                if (Exts.Any(e => File.Exists(Path.Combine(dir, name + e)))) return true;
            }
            catch (ArgumentException) { }
        }
        return false;
    }

    static bool InAppPaths(string name)
    {
        var exe = name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name : name + ".exe";
        const string key = @"Software\Microsoft\Windows\CurrentVersion\App Paths\";
        using var cu = Registry.CurrentUser.OpenSubKey(key + exe);
        if (cu is not null) return true;
        using var lm = Registry.LocalMachine.OpenSubKey(key + exe);
        return lm is not null;
    }

    public static string CtlPath => Path.Combine(AppContext.BaseDirectory, "hyprwinctl.exe");

    /// <summary>Writes .cmd shims for missing Linux tools (or only computes them, for --check-config).</summary>
    public static List<string> InstallShims(bool write = true)
    {
        if (write)
        {
            try { if (Directory.Exists(ShimDir)) Directory.Delete(ShimDir, true); } catch (IOException) { }
            Directory.CreateDirectory(ShimDir);
        }
        shimNames = new(StringComparer.OrdinalIgnoreCase);
        cache.Clear();
        var installed = new List<string>();
        bool Exists(string exe) => OnPath(exe, skipShims: true) || InAppPaths(exe);
        foreach (var (name, script) in LinuxCompat.WindowsShims(CtlPath, Exists).OrderBy(p => p.Key, StringComparer.Ordinal))
        {
            if (OnPath(name, skipShims: true)) continue; // the real program wins
            if (write)
            {
                try { File.WriteAllText(Path.Combine(ShimDir, name + ".cmd"), script); }
                catch (IOException) { continue; }
            }
            installed.Add(name);
        }
        shimNames = new HashSet<string>(installed, StringComparer.OrdinalIgnoreCase);
        cache.Clear();
        return installed;
    }

    /// <summary>Missing programs for a command, including inside a script file it runs directly.</summary>
    public static List<string> Missing(string command)
    {
        var o = LinuxCompat.Missing(command, IsAvailable);
        var words = command.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(3);
        foreach (var w in words.Select(x => x.Trim('"')).Where(x => x.Contains('/') || x.Contains('\\')))
        {
            var p = ConfigParser.Expand(w);
            try
            {
                var fi = new FileInfo(p);
                if (!fi.Exists || fi.Length > 256 * 1024) continue;
                foreach (var prog in LinuxCompat.Programs(File.ReadAllText(p)))
                    if (!IsAvailable(prog) && !o.Contains(prog)) o.Add(prog);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { }
        }
        return o;
    }

    /// <summary>Runs a command with cmd.exe (hidden console), shims on PATH.</summary>
    public static void Spawn(string command, Action<string> log)
    {
        var missing = Missing(command);
        if (missing.Count > 0)
        {
            log($"skipped (needs {string.Join(", ", missing)}): {command[..Math.Min(80, command.Length)]}");
            return;
        }
        try
        {
            var psi = new ProcessStartInfo("cmd.exe")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = ConfigParser.Home,
            };
            psi.ArgumentList.Add("/d");
            psi.ArgumentList.Add("/s");
            psi.ArgumentList.Add("/c");
            psi.ArgumentList.Add(command);
            psi.Environment["PATH"] = PathString;
            psi.Environment["HOME"] = ConfigParser.Home;
            Process.Start(psi)?.Dispose();
        }
        catch (Exception e)
        {
            log($"exec failed: {command}: {e.Message}");
        }
    }
}
