using Hyprwin.Core;

namespace Hyprwin;

public static class Program
{
    const string Usage = """
    hyprwin: Hyprland-style tiling for Windows

    usage: hyprwin [--config PATH]        run the window manager (tray icon)
           hyprwin rice ...               install and apply dotfiles rices (hyprwin rice help)
           hyprwin --check-config [PATH]  parse the config and print problems
           hyprwin --print-default-config
           hyprwin --list                 show windows hyprwin would manage (moves nothing)
           hyprwin --version

    Config: ~/.config/hyprwin/hyprland.conf (created on first run). Control: hyprwinctl.
    """;

    static readonly string LogPath = Path.Combine(HyprwinInfo.DataDir, "hyprwin.log");

    public static void Log(string s)
    {
        var line = $"[{DateTime.Now:HH:mm:ss}] {s}";
        try { Console.Error.WriteLine("[hyprwin] " + s); } catch (Exception) { }
        try
        {
            Directory.CreateDirectory(HyprwinInfo.DataDir);
            File.AppendAllText(LogPath, line + Environment.NewLine);
        }
        catch (Exception) { }
    }

    [STAThread]
    static int Main(string[] args)
    {
        LuaConfig.Install();
        var configPath = Environment.GetEnvironmentVariable("HYPRWIN_CONFIG") ?? Config.DefaultPath;
        string? Value(string flag) => Array.IndexOf(args, flag) is var i && i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        if (Value("--config") is { } c) configPath = c;

        bool cli = args.Length > 0 && (args[0] == "rice" || args.Any(a => a is "--check-config" or "--version" or "-v" or "--help" or "-h"
            or "--list" or "--print-default-config"));
        if (cli)
        {
            // WinExe has no console of its own: write to the terminal that started us.
            Native.AttachConsole(Native.ATTACH_PARENT_PROCESS);
            Console.SetOut(new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true });
            Console.SetError(new StreamWriter(Console.OpenStandardError()) { AutoFlush = true });
            Console.WriteLine();
            return RunCli(args, configPath);
        }

        using var mutex = new Mutex(true, $@"Local\hyprwin-{Environment.UserName}", out bool first);
        if (!first)
        {
            MessageBox.Show("hyprwin is already running (see the tray icon).", "hyprwin");
            return 1;
        }

        EnsureConfig(configPath);
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        Application.ThreadException += (_, e) => Log($"error: {e.Exception}");

        var wm = new WindowManager(configPath);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => { Log($"crash: {e.ExceptionObject}"); wm.EmergencyCleanup(); };
        AppDomain.CurrentDomain.ProcessExit += (_, _) => wm.EmergencyCleanup();
        wm.Start();
        Application.ApplicationExit += (_, _) => Log("exit");
        Application.Run(new ApplicationContext());
        return 0;
    }

    /// <summary>Terminal commands (also reachable through hyprwinctl, which has a real console).</summary>
    public static int RunCli(string[] args, string configPath)
    {
        if (args[0] == "rice")
        {
            var rm = new RiceManager(new WinRicePlatform(), HyprwinInfo.DataDir, configPath, Console.Out)
            {
                OnChanged = () =>
                {
                    try { PipeClient.Send("reload", HyprwinInfo.PipeName); } catch (Exception) { }
                },
            };
            return rm.Main(args[1..]);
        }
        if (args.Contains("--help") || args.Contains("-h")) { Console.WriteLine(Usage); return 0; }
        if (args.Contains("--version") || args.Contains("-v")) { Console.WriteLine($"hyprwin {HyprwinInfo.Version}"); return 0; }
        if (args.Contains("--print-default-config")) { Console.Write(DefaultConfig.Text); return 0; }

        if (args.Contains("--check-config"))
        {
            int i = Array.IndexOf(args, "--check-config");
            var path = i + 1 < args.Length && !args[i + 1].StartsWith("--") ? args[i + 1] : configPath;
            var c = ConfigParser.Load(path);
            WinCompat.InstallShims(write: false);
            var (usable, skipped) = WindowManager.SplitBinds(c.Binds);
            static string Gaps(Insets g) => g.Top == g.Right && g.Right == g.Bottom && g.Bottom == g.Left ? $"{g.Top}" : $"{g.Top} {g.Right} {g.Bottom} {g.Left}";
            Console.WriteLine($"{ConfigParser.Expand(path)}: {usable.Count} binds, {c.Rules.Count} window rules, layout {c.Layout}");
            Console.WriteLine($"look: gaps_in {Gaps(c.GapsIn)}, gaps_out {Gaps(c.GapsOut)}, border {c.BorderSize}, rounding {c.Rounding}, " +
                $"active {c.ActiveBorder.Colors[0].Hex}, inactive {c.InactiveBorder.Colors[0].Hex}, SUPER = {string.Join("+", c.SuperMapsTo.Names()).Replace("SUPER", "Win")}");
            Console.WriteLine($"files: {string.Join(", ", c.Files)}");
            if (c.Ignored.Count > 0) Console.WriteLine($"ignored on Windows ({c.Ignored.Count}): {string.Join(", ", c.Ignored.Distinct().Order())}");
            foreach (var s in skipped) Console.WriteLine($"skipped bind: {s}");
            foreach (var b in usable) Console.WriteLine($"bind: {b.Combo} -> {b.Dispatcher} {b.Arg[..Math.Min(70, b.Arg.Length)]}");
            foreach (var e in c.Errors) Console.WriteLine($"error: {e}");
            return c.Errors.Count == 0 ? 0 : 1;
        }

        if (args.Contains("--list"))
        {
            var wm = new WindowManager(configPath);
            wm.ScanOnly();
            foreach (var m in wm.Model.Monitors) Console.WriteLine($"monitor {m.Name}: {m.Frame} -> workspace {m.Workspace}");
            foreach (var (ws, app, title, floating) in wm.Summary())
                Console.WriteLine($"ws {ws}  {(floating ? "float" : "tile ")}  {app}  -  {title}");
            return 0;
        }
        Console.WriteLine(Usage);
        return 1;
    }

    static void EnsureConfig(string configPath)
    {
        var path = ConfigParser.Expand(configPath);
        if (File.Exists(path) || configPath != Config.DefaultPath) return;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, DefaultConfig.Text);
        Log($"wrote default config to {path}");
    }
}
