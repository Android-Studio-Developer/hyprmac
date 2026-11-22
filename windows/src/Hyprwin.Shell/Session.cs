using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace Hyprwin.Shell;

/// <summary>Grows out of the right frame edge: lock, sleep, sign out, restart, shut down, quit.
/// Restart and shut down ask for a second click.</summary>
sealed class Session : EdgePanel
{
    string? armed;
    readonly DispatcherTimer disarm = new() { Interval = TimeSpan.FromSeconds(3) };

    public Session(ShellHost host) : base(host, Edge.Right)
    {
        disarm.Tick += Disarm;
        IsVisibleChanged += (_, _) => { if (!IsVisible) { armed = null; disarm.Stop(); } };
    }

    protected override UIElement Build()
    {
        var stack = new StackPanel();
        Add(stack, "lock", Ui.Glyph.Lock, "Lock", () => LockWorkStation());
        Add(stack, "sleep", Ui.Glyph.Sleep, "Sleep", () => SetSuspendState(false, false, false));
        Add(stack, "signout", Ui.Glyph.SignOut, "Sign out", () => Run("shutdown.exe", "/l"));
        Add(stack, "restart", Ui.Glyph.Restart, "Restart", () => Run("shutdown.exe", "/r /t 0"), confirm: true);
        Add(stack, "shutdown", Ui.Glyph.Power, "Shut down", () => Run("shutdown.exe", "/s /t 0"), confirm: true);
        Add(stack, "quit", Ui.Glyph.Close, "Quit hyprwin", () => Host.Backend.Quit());
        return stack;
    }

    void Disarm(object? s, EventArgs e)
    {
        disarm.Stop();
        armed = null;
        Body.Child = Build();
    }

    void Add(StackPanel stack, string key, string glyph, string label, Action action, bool confirm = false)
    {
        bool isArmed = armed == key;
        var icon = new Border
        {
            Width = 44, Height = 44, CornerRadius = new CornerRadius(14),
            Background = Ui.Brush(isArmed ? S.Error : key is "restart" or "shutdown" ? S.SecondaryContainer : S.SurfaceContainerHigh),
            Child = Ui.Icon(glyph, isArmed ? S.Surface : key == "shutdown" ? S.Error : S.OnSurface, 18),
        };
        var text = Ui.Label(isArmed ? $"Click again to {label.ToLowerInvariant()}" : label, isArmed ? S.Error : S.OnSurface, 13.5, FontWeights.Medium);
        text.VerticalAlignment = VerticalAlignment.Center;
        text.Margin = new Thickness(12, 0, 6, 0);
        text.Width = 150;
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(icon);
        row.Children.Add(text);
        var button = Ui.Clickable(row, () =>
        {
            if (confirm && armed != key)
            {
                armed = key;
                Body.Child = Build();
                disarm.Stop();
                disarm.Start();
                return;
            }
            Close2();
            action();
        }, S.SurfaceContainer, 18, new Thickness(6));
        button.Margin = new Thickness(0, 2, 0, 2);
        stack.Children.Add(button);
    }

    static void Run(string exe, string args)
    {
        try { Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true })?.Dispose(); }
        catch (Exception) { }
    }

    [DllImport("user32.dll")] static extern bool LockWorkStation();
    [DllImport("powrprof.dll")] static extern bool SetSuspendState(bool hibernate, bool force, bool disableWake);
}
