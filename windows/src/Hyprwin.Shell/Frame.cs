using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Hyprwin.Shell;

/// <summary>Click-through border around the work area, the same color as the bar, with rounded
/// inner corners. Tiled windows sit inside it (gaps_out is larger than the frame).</summary>
sealed class Frame : Window
{
    readonly ShellHost host;
    readonly System.Windows.Shapes.Path path = new();

    public Frame(ShellHost host)
    {
        this.host = host;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Focusable = false;
        IsHitTestVisible = false;
        Title = "hyprwin frame";
        Content = path;
        SourceInitialized += (_, _) =>
            Ui.AddExStyle(this, Ui.WS_EX_TOOLWINDOW | Ui.WS_EX_NOACTIVATE | Ui.WS_EX_TRANSPARENT | Ui.WS_EX_LAYERED);
        SizeChanged += (_, _) => Redraw();
    }

    public void Attach(Desktop.RECT work)
    {
        if (!IsVisible) Show();
        Ui.Place(this, work.Left, work.Top, work.Right - work.Left, work.Bottom - work.Top);
        Redraw();
    }

    public void Redraw()
    {
        double w = ActualWidth, h = ActualHeight, t = host.Options.FrameThickness, r = 18;
        if (w <= 2 * t || h <= 2 * t) return;
        // No frame on the left: the bar is there.
        var outer = new RectangleGeometry(new Rect(0, 0, w, h));
        var inner = new RectangleGeometry(new Rect(0, t, w - t, h - 2 * t), r, r);
        path.Data = new CombinedGeometry(GeometryCombineMode.Exclude, outer, inner);
        path.Fill = Ui.Brush(host.Scheme.Surface);
    }
}

/// <summary>A panel that grows out of a frame edge (launcher: bottom, dashboard: top, session: right).
/// Same color as the frame, rounded only on its inner side, scales open from the edge.</summary>
abstract class EdgePanel : Window
{
    public enum Edge { Top, Bottom, Right }

    protected readonly ShellHost Host;
    protected readonly Border Body = new();
    readonly ScaleTransform scale = new(1, 1);
    readonly Edge edge;
    bool closing;

    protected EdgePanel(ShellHost host, Edge edge)
    {
        Host = host;
        this.edge = edge;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        SizeToContent = SizeToContent.WidthAndHeight;
        Title = "hyprwin " + GetType().Name.ToLowerInvariant();
        Body.RenderTransform = scale;
        Body.RenderTransformOrigin = edge switch
        {
            Edge.Top => new Point(0.5, 0),
            Edge.Bottom => new Point(0.5, 1),
            _ => new Point(1, 0.5),
        };
        Content = Body;
        SourceInitialized += (_, _) => Ui.AddExStyle(this, Ui.WS_EX_TOOLWINDOW);
        Deactivated += (_, _) => Close2();
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { e.Handled = true; Close2(); } };
        SizeChanged += (_, _) => { if (IsVisible) Position(); };
    }

    protected Scheme S => Host.Scheme;

    /// <summary>Rebuild the content (on open and when the scheme changes).</summary>
    protected abstract UIElement Build();

    protected virtual void OnOpened() { }

    public bool IsOpen => IsVisible && !closing;

    public void Open()
    {
        closing = false;
        Body.Background = Ui.Brush(S.Surface);
        Body.CornerRadius = edge switch
        {
            Edge.Top => new CornerRadius(0, 0, 24, 24),
            Edge.Bottom => new CornerRadius(24, 24, 0, 0),
            _ => new CornerRadius(24, 0, 0, 24),
        };
        Body.Padding = new Thickness(18);
        Body.Child = Build();
        Show();
        Position();
        Activate();
        Ui.SetForegroundWindow(Ui.Handle(this));
        var prop = edge == Edge.Right ? ScaleTransform.ScaleXProperty : ScaleTransform.ScaleYProperty;
        scale.ScaleX = 1;
        scale.ScaleY = 1;
        Ui.Animate(scale, prop, 1, 260, from: 0.05);
        Ui.Animate(Body, OpacityProperty, 1, 180, from: 0);
        OnOpened();
    }

    public void Close2()
    {
        if (!IsVisible || closing) return;
        closing = true;
        var prop = edge == Edge.Right ? ScaleTransform.ScaleXProperty : ScaleTransform.ScaleYProperty;
        Ui.Animate(Body, OpacityProperty, 0, 140);
        Ui.Animate(scale, prop, 0.05, 160, done: () =>
        {
            if (closing) Hide();
            closing = false;
        });
    }

    public void Toggle()
    {
        if (IsOpen) Close2(); else Open();
    }

    /// <summary>Sticks the panel to its frame edge, centered along it (pixel math).</summary>
    void Position()
    {
        var work = Host.WorkArea;
        double scaleF = Ui.Scale(this);
        int w = (int)Math.Ceiling(ActualWidth * scaleF), h = (int)Math.Ceiling(ActualHeight * scaleF);
        int t = (int)Math.Round(Host.Options.FrameThickness * scaleF);
        int x, y;
        switch (edge)
        {
            case Edge.Top:
                x = (work.Left + work.Right - w) / 2; y = work.Top + t; break;
            case Edge.Bottom:
                x = (work.Left + work.Right - w) / 2; y = work.Bottom - t - h; break;
            default:
                x = work.Right - t - w; y = (work.Top + work.Bottom - h) / 2; break;
        }
        Ui.Place(this, x, y, w, h, Ui.HWND_TOPMOST);
    }

    /// <summary>Card inside a panel.</summary>
    protected Border Card(UIElement child, double padding = 14) => new()
    {
        Background = Ui.Brush(S.SurfaceContainer),
        CornerRadius = new CornerRadius(18),
        Padding = new Thickness(padding),
        Child = child,
    };
}
