using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace Hyprwin.Shell;

/// <summary>Vertical bar on the left edge: launcher button, workspace pills, active window,
/// status icons, clock, power. Registered as an AppBar so tiled windows stay clear of it.</summary>
sealed class Bar : Window
{
    readonly ShellHost host;
    readonly StackPanel workspaces = new() { HorizontalAlignment = HorizontalAlignment.Center };
    readonly TextBlock title = new();
    readonly TextBlock hours = new(), minutes = new();
    readonly TextBlock network = new(), battery = new();
    readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(5) };
    readonly Dictionary<int, Border> pills = [];
    const uint CallbackMessage = 0x8000 + 0x48; // WM_APP + n
    bool registered;

    public Bar(ShellHost host)
    {
        this.host = host;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Title = "hyprwin bar";
        SourceInitialized += (_, _) =>
        {
            Ui.AddExStyle(this, Ui.WS_EX_TOOLWINDOW | Ui.WS_EX_NOACTIVATE);
            HwndSource.FromHwnd(Ui.Handle(this))?.AddHook(WndProc);
        };
        clock.Tick += (_, _) => UpdateStatus();
        Rebuild();
    }

    Scheme S => host.Scheme;

    public void Rebuild()
    {
        Background = Ui.Brush(S.Surface);
        var root = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 10, 0, 10) };

        // Top: launcher button.
        var logo = Ui.Clickable(new TextBlock
        {
            Text = "✦",
            FontSize = 20,
            Foreground = Ui.Brush(S.Primary),
            HorizontalAlignment = HorizontalAlignment.Center,
        }, () => host.Toggle("launcher"), S.SurfaceContainerHigh, 14, new Thickness(8, 4, 8, 6));
        logo.HorizontalAlignment = HorizontalAlignment.Center;
        logo.ToolTip = "Launcher";
        DockPanel.SetDock(logo, Dock.Top);
        root.Children.Add(logo);

        // Workspaces in a pill-shaped track.
        var track = new Border
        {
            Background = Ui.Brush(S.SurfaceContainer),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(5, 7, 5, 7),
            Margin = new Thickness(0, 10, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Center,
            Child = workspaces,
        };
        DockPanel.SetDock(track, Dock.Top);
        root.Children.Add(track);

        // Bottom: status, clock, power.
        var bottom = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        DockPanel.SetDock(bottom, Dock.Bottom);
        var status = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var tb in new[] { network, battery })
        {
            tb.FontFamily = Ui.Icons;
            tb.FontSize = 15;
            tb.Foreground = Ui.Brush(S.OnSurfaceVariant);
            tb.HorizontalAlignment = HorizontalAlignment.Center;
            tb.Margin = new Thickness(0, 4, 0, 4);
        }
        var statusBox = new Border
        {
            Background = Ui.Brush(S.SurfaceContainer),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(6, 6, 6, 6),
            Child = status,
        };
        status.Children.Add(Ui.Clickable(network, () => host.Backend.Exec("start \"\" ms-availablenetworks:"), S.SurfaceContainerHigh, 10, new Thickness(4)));
        status.Children.Add(battery);
        bottom.Children.Add(statusBox);

        var clockStack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var tb in new[] { hours, minutes })
        {
            tb.FontFamily = Ui.Display;
            tb.FontSize = 15;
            tb.FontWeight = FontWeights.SemiBold;
            tb.Foreground = Ui.Brush(S.Secondary);
            tb.HorizontalAlignment = HorizontalAlignment.Center;
            tb.LineHeight = 17;
            clockStack.Children.Add(tb);
        }
        var clockButton = Ui.Clickable(clockStack, () => host.Toggle("dashboard"), S.SurfaceContainerHigh, 12, new Thickness(6, 6, 6, 6));
        clockButton.Margin = new Thickness(0, 10, 0, 6);
        clockButton.ToolTip = "Dashboard";
        bottom.Children.Add(clockButton);

        var power = Ui.Clickable(Ui.Icon(Ui.Glyph.Power, S.Error, 16), () => host.Toggle("session"), S.SurfaceContainerHigh, 12, new Thickness(8));
        power.ToolTip = "Session";
        power.HorizontalAlignment = HorizontalAlignment.Center;
        bottom.Children.Add(power);
        root.Children.Add(bottom);

        // Middle: active window title, vertical.
        title.FontFamily = Ui.Text;
        title.FontSize = 12.5;
        title.Foreground = Ui.Brush(S.OnSurfaceVariant);
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        title.LayoutTransform = new RotateTransform(90);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        title.VerticalAlignment = VerticalAlignment.Top;
        title.Margin = new Thickness(0, 14, 0, 14);
        var middle = new Grid { ClipToBounds = true };
        middle.Children.Add(title);
        middle.SizeChanged += (_, e) => title.MaxWidth = Math.Max(0, e.NewSize.Height - 28);
        root.Children.Add(middle);

        Content = root;
        pills.Clear();
        workspaces.Children.Clear();
        UpdateState();
        UpdateStatus();
    }

    Desktop.RECT? placed;

    public void Attach(int widthPx, bool force = false)
    {
        var h = Ui.Handle(this);
        // Re-reserving when nothing changed would notify the taskbar for nothing (and could ping-pong).
        if (registered && !force && placed is { } p && p.Right - p.Left == widthPx) return;
        var rc = registered ? Desktop.SetLeft(h, widthPx) : Desktop.RegisterLeft(h, widthPx, CallbackMessage);
        registered = true;
        placed = rc;
        Ui.Place(this, rc.Left, rc.Top, rc.Right - rc.Left, rc.Bottom - rc.Top, Ui.HWND_TOPMOST);
        clock.Start();
    }

    public void Detach()
    {
        clock.Stop();
        if (registered) Desktop.Unregister(Ui.Handle(this));
        registered = false;
    }

    IntPtr WndProc(IntPtr hwnd, int msg, IntPtr w, IntPtr l, ref bool handled)
    {
        // ABN_POSCHANGED: another app bar or the taskbar moved; take our place again.
        if (msg == CallbackMessage && w.ToInt32() == 1 && registered)
            Dispatcher.BeginInvoke(() => host.Layout(force: true));
        return IntPtr.Zero;
    }

    public void UpdateState()
    {
        var st = host.Backend.State;
        int max = Math.Max(5, Math.Max(st.Workspace, st.Occupied.DefaultIfEmpty(0).Max()));
        for (int i = 1; i <= max; i++)
        {
            if (!pills.TryGetValue(i, out var pill))
            {
                int n = i;
                pill = new Border
                {
                    Width = 10,
                    Height = 10,
                    CornerRadius = new CornerRadius(5),
                    Margin = new Thickness(0, 3.5, 0, 3.5),
                    Cursor = Cursors.Hand,
                    ToolTip = $"Workspace {n}",
                };
                pill.MouseLeftButtonUp += (_, _) => host.Backend.Dispatch("workspace", n.ToString());
                pills[i] = pill;
                workspaces.Children.Add(pill);
            }
            bool active = i == st.Workspace, occupied = st.Occupied.Contains(i);
            pill.Background = Ui.Brush(active ? S.Primary : occupied ? S.OnSurfaceVariant : S.SurfaceContainerHighest);
            Ui.Animate(pill, HeightProperty, active ? 26 : 10, 220);
        }
        foreach (var extra in pills.Keys.Where(k => k > max).ToList())
        {
            workspaces.Children.Remove(pills[extra]);
            pills.Remove(extra);
        }
        title.Text = st.ActiveTitle.Length > 0 ? st.ActiveTitle : "Desktop";
        title.ToolTip = st.ActiveApp.Length > 0 ? $"{st.ActiveApp}: {st.ActiveTitle}" : null;
    }

    void UpdateStatus()
    {
        var now = DateTime.Now;
        hours.Text = now.ToString("HH");
        minutes.Text = now.ToString("mm");

        bool up = NetworkInterface.GetIsNetworkAvailable();
        bool wifi = up && NetworkInterface.GetAllNetworkInterfaces().Any(n =>
            n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211);
        network.Text = !up ? Ui.Glyph.NoNetwork : wifi ? Ui.Glyph.Wifi : Ui.Glyph.Ethernet;
        network.ToolTip = !up ? "Offline" : wifi ? "Wi-Fi" : "Wired";

        if (GetSystemPowerStatus(out var p) && p.BatteryFlag != 128 && p.BatteryLifePercent <= 100)
        {
            bool charging = p.ACLineStatus == 1;
            battery.Text = Ui.Glyph.Battery(p.BatteryLifePercent, charging);
            battery.ToolTip = $"{p.BatteryLifePercent}%{(charging ? " (charging)" : "")}";
            battery.Visibility = Visibility.Visible;
        }
        else battery.Visibility = Visibility.Collapsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
        public int BatteryLifeTime, BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS s);
}
