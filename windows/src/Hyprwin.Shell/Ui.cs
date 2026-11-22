using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Hyprwin.Shell;

/// <summary>Small helpers for building the shell UI in code.</summary>
static class Ui
{
    public static readonly FontFamily Text = new("Segoe UI Variable Text, Segoe UI");
    public static readonly FontFamily Display = new("Segoe UI Variable Display, Segoe UI");
    /// <summary>Icon font: Segoe Fluent Icons on Windows 11, MDL2 Assets on Windows 10 (same code points).</summary>
    public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");

    public static class Glyph
    {
        public const string Search = "", Power = "", Lock = "", Sleep = "", SignOut = "",
            Restart = "", Volume = "", Wifi = "", Ethernet = "", NoNetwork = "",
            Play = "", Pause = "", Next = "", Previous = "", Apps = "",
            Calendar = "", Calculator = "", Terminal = "", Music = "", Close = "",
            Settings = "", Dashboard = "";

        /// <summary>Battery glyph for a level 0..100 (MDL2 Battery0..Battery10, charging variants).</summary>
        public static string Battery(int percent, bool charging)
        {
            int step = Math.Clamp((int)Math.Round(percent / 10.0), 0, 10);
            return char.ConvertFromUtf32((charging ? 0xEBAB : 0xEBA0) + step);
        }
    }

    public static SolidColorBrush Brush(Color c, double alpha = 1)
    {
        var b = new SolidColorBrush(Color.FromArgb((byte)Math.Round(alpha * 255), c.R, c.G, c.B));
        b.Freeze();
        return b;
    }

    public static TextBlock Label(string text, Color color, double size = 13, FontWeight? weight = null, FontFamily? font = null) => new()
    {
        Text = text,
        Foreground = Brush(color),
        FontSize = size,
        FontWeight = weight ?? FontWeights.Normal,
        FontFamily = font ?? Text,
        TextTrimming = TextTrimming.CharacterEllipsis,
    };

    public static TextBlock Icon(string glyph, Color color, double size = 16) => new()
    {
        Text = glyph,
        Foreground = Brush(color),
        FontSize = size,
        FontFamily = Icons,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>Rounded clickable surface with a hover tint (no WPF button chrome).</summary>
    public static Border Clickable(UIElement child, Action onClick, Color hover, double radius = 12, Thickness? padding = null)
    {
        var b = new Border
        {
            Child = child,
            CornerRadius = new CornerRadius(radius),
            Padding = padding ?? new Thickness(8),
            Background = Brushes.Transparent,
            Cursor = Cursors.Hand,
        };
        b.MouseEnter += (_, _) => b.Background = Brush(hover);
        b.MouseLeave += (_, _) => b.Background = Brushes.Transparent;
        b.MouseLeftButtonUp += (_, e) => { e.Handled = true; onClick(); };
        return b;
    }

    public static void Animate(DependencyObject target, DependencyProperty prop, double to, double ms, double? from = null, Action? done = null)
    {
        var a = new DoubleAnimation
        {
            To = to,
            Duration = TimeSpan.FromMilliseconds(ms),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };
        if (from is { } f) a.From = f;
        if (done is not null) a.Completed += (_, _) => done();
        if (target is IAnimatable an) an.BeginAnimation(prop, a);
    }

    // ---- Window placement in physical pixels (the work area and AppBar use pixels, WPF uses DIPs).

    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetWindowLongPtrW(IntPtr h, int i);
    [DllImport("user32.dll")] static extern IntPtr SetWindowLongPtrW(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);

    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_TOOLWINDOW = 0x80, WS_EX_TRANSPARENT = 0x20, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000;
    const uint SWP_NOACTIVATE = 0x10, SWP_NOZORDER = 0x4, SWP_SHOWWINDOW = 0x40;
    public static readonly IntPtr HWND_TOPMOST = new(-1), HWND_BOTTOM = new(1);

    public static IntPtr Handle(Window w) => new WindowInteropHelper(w).EnsureHandle();

    public static void AddExStyle(Window w, long flags)
    {
        var h = Handle(w);
        SetWindowLongPtrW(h, GWL_EXSTYLE, new IntPtr(GetWindowLongPtrW(h, GWL_EXSTYLE).ToInt64() | flags));
    }

    public static double Scale(Window w) => GetDpiForWindow(Handle(w)) / 96.0 is var s && s > 0 ? s : 1;

    /// <summary>Places a window at a pixel rectangle.</summary>
    public static void Place(Window w, int x, int y, int cx, int cy, IntPtr? after = null) =>
        SetWindowPos(Handle(w), after ?? IntPtr.Zero, x, y, cx, cy, SWP_NOACTIVATE | SWP_SHOWWINDOW | (after is null ? SWP_NOZORDER : 0));
}
