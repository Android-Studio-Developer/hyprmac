using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace Hyprwin.Shell;

/// <summary>Owns the shell windows and the color scheme. Create on the UI thread.</summary>
public sealed class ShellHost : IDisposable
{
    public IShellBackend Backend { get; }
    public ShellOptions Options { get; private set; }
    public Scheme Scheme { get; private set; } = Scheme.Default;
    /// <summary>Raised when the scheme changes (the window manager recolors borders).</summary>
    public event Action? SchemeChanged;

    internal Desktop.RECT WorkArea { get; private set; }

    readonly Bar bar;
    readonly Frame frame;
    readonly Launcher launcher;
    readonly Dashboard dashboard;
    readonly Session session;
    bool started, disposed;

    public ShellHost(IShellBackend backend, ShellOptions options)
    {
        Backend = backend;
        Options = options;
        LoadScheme();
        bar = new Bar(this);
        frame = new Frame(this);
        launcher = new Launcher(this);
        dashboard = new Dashboard(this);
        session = new Session(this);
        backend.Changed += () => bar.UpdateState();
        SystemEvents.UserPreferenceChanged += OnPreferenceChanged;
    }

    public void Start()
    {
        if (started) return;
        started = true;
        if (Options.HideTaskbar) Desktop.AutoHideTaskbar();
        bar.Show();
        Layout();
        // The taskbar slides away over a moment; fit the frame again once the work area settles.
        var settle = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1500) };
        settle.Tick += (_, _) => { settle.Stop(); Layout(); };
        settle.Start();
    }

    /// <summary>Reserves the bar's edge (when needed) and fits the frame to the work area.</summary>
    public void Layout(bool force = false)
    {
        if (!started || disposed) return;
        int barPx = (int)Math.Round(Options.BarWidth * Ui.Scale(bar));
        bar.Attach(barPx, force);
        var work = Desktop.WorkArea();
        if (force || !work.Equals(WorkArea)) frame.Attach(work);
        WorkArea = work;
    }

    public void Toggle(string action)
    {
        EdgePanel? p = action switch
        {
            "launcher" or "drawers" or "apps" => launcher,
            "dashboard" or "dash" => dashboard,
            "session" or "power" => session,
            _ => null,
        };
        if (p is null) return;
        foreach (var other in new EdgePanel[] { launcher, dashboard, session })
            if (other != p) other.Close2();
        p.Toggle();
    }

    public void Configure(ShellOptions options)
    {
        bool schemeChanged = options.Scheme != Options.Scheme;
        Options = options;
        if (options.HideTaskbar) Desktop.AutoHideTaskbar(); else Desktop.RestoreTaskbar();
        if (schemeChanged) Recolor(); else Layout();
    }

    void OnPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        // Wallpaper and work area changes arrive as Desktop / General.
        if (e.Category is UserPreferenceCategory.Desktop or UserPreferenceCategory.General)
            bar.Dispatcher.BeginInvoke(() =>
            {
                if (Options.Scheme == "auto") Recolor();
                Layout();
            });
    }

    void Recolor()
    {
        var before = Scheme;
        LoadScheme();
        if (Scheme == before) return;
        bar.Rebuild();
        frame.Redraw();
        foreach (var p in new EdgePanel[] { launcher, dashboard, session }) p.Close2();
        Layout();
        SchemeChanged?.Invoke();
    }

    void LoadScheme() => Scheme = Scheme.Resolve(Options.Scheme, Wallpaper());

    public static string? Wallpaper()
    {
        var sb = new StringBuilder(520);
        return SystemParametersInfoW(0x0073, (uint)sb.Capacity, sb, 0) && sb.Length > 0 ? sb.ToString() : null;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool SystemParametersInfoW(uint action, uint param, StringBuilder value, uint winIni);

    /// <summary>Border colors from the scheme as COLORREF (0x00BBGGRR): active, inactive.</summary>
    public (uint Active, uint Inactive) BorderColors()
    {
        static uint Ref(System.Windows.Media.Color c) => c.R | ((uint)c.G << 8) | ((uint)c.B << 16);
        return (Ref(Scheme.Primary), Ref(Scheme.SurfaceContainerHighest));
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        SystemEvents.UserPreferenceChanged -= OnPreferenceChanged;
        bar.Detach();
        foreach (var w in new System.Windows.Window[] { launcher, dashboard, session, frame, bar }) w.Close();
        Desktop.RestoreTaskbar();
    }
}
