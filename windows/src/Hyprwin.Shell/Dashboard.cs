using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Windows.Media.Control;

namespace Hyprwin.Shell;

/// <summary>Grows out of the top frame edge: clock and date, month calendar, media controls,
/// CPU / memory / disk rings.</summary>
sealed class Dashboard : EdgePanel
{
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    TextBlock? time, date;
    readonly Dictionary<string, (Path Arc, TextBlock Value)> rings = [];
    readonly Cpu cpu = new();
    Border? media;

    public Dashboard(ShellHost host) : base(host, Edge.Top)
    {
        timer.Tick += (_, _) => Tick();
        IsVisibleChanged += (_, _) => { if (IsVisible) timer.Start(); else timer.Stop(); };
    }

    protected override UIElement Build()
    {
        rings.Clear();
        var grid = new Grid { Width = 760 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.05, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        // Clock + calendar.
        var left = new StackPanel();
        time = Ui.Label("", S.Primary, 46, FontWeights.SemiBold, Ui.Display);
        date = Ui.Label("", S.OnSurfaceVariant, 14);
        left.Children.Add(time);
        left.Children.Add(date);
        left.Children.Add(Calendar());
        grid.Children.Add(Card(left, 18));

        // Media.
        var idle = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        idle.Children.Add(new Border
        {
            Width = 120, Height = 120, CornerRadius = new CornerRadius(16), Background = Ui.Brush(S.SurfaceContainerHigh),
            Child = Ui.Icon(Ui.Glyph.Music, S.Outline, 34),
        });
        var none = Ui.Label("Nothing playing", S.OnSurfaceVariant, 13);
        none.HorizontalAlignment = HorizontalAlignment.Center;
        none.Margin = new Thickness(0, 12, 0, 0);
        idle.Children.Add(none);
        media = Card(idle);
        Grid.SetColumn(media, 2);
        grid.Children.Add(media);
        _ = LoadMediaAsync();

        // Performance rings.
        var perf = new StackPanel();
        foreach (var (key, label) in new[] { ("cpu", "CPU"), ("mem", "Memory"), ("disk", "Disk") })
        {
            var ring = Ring(key, label);
            ring.Margin = new Thickness(0, 0, 0, key == "disk" ? 0 : 10);
            perf.Children.Add(ring);
        }
        var perfCard = Card(perf, 12);
        Grid.SetColumn(perfCard, 4);
        grid.Children.Add(perfCard);

        Tick();
        return grid;
    }

    UIElement Calendar()
    {
        var today = DateTime.Today;
        var first = new DateTime(today.Year, today.Month, 1);
        var g = new UniformGrid { Columns = 7, Margin = new Thickness(0, 14, 0, 0) };
        foreach (var d in new[] { "M", "T", "W", "T", "F", "S", "S" })
        {
            var h = Ui.Label(d, S.Outline, 11.5, FontWeights.SemiBold);
            h.HorizontalAlignment = HorizontalAlignment.Center;
            g.Children.Add(h);
        }
        int offset = ((int)first.DayOfWeek + 6) % 7;
        for (int i = 0; i < offset; i++) g.Children.Add(new Border());
        for (int day = 1; day <= DateTime.DaysInMonth(today.Year, today.Month); day++)
        {
            bool isToday = day == today.Day;
            var t = Ui.Label(day.ToString(), isToday ? S.OnPrimary : S.OnSurface, 12.5, isToday ? FontWeights.Bold : FontWeights.Normal);
            t.HorizontalAlignment = HorizontalAlignment.Center;
            t.VerticalAlignment = VerticalAlignment.Center;
            g.Children.Add(new Border
            {
                Width = 28, Height = 28, CornerRadius = new CornerRadius(14), Margin = new Thickness(1),
                Background = isToday ? Ui.Brush(S.Primary) : Brushes.Transparent, Child = t,
            });
        }
        return g;
    }

    FrameworkElement Ring(string key, string label)
    {
        const double size = 64, stroke = 7;
        var canvas = new Grid { Width = size, Height = size };
        canvas.Children.Add(new Ellipse { Stroke = Ui.Brush(S.SurfaceContainerHighest), StrokeThickness = stroke });
        var arc = new Path
        {
            Stroke = Ui.Brush(key == "cpu" ? S.Primary : key == "mem" ? S.Secondary : S.Tertiary),
            StrokeThickness = stroke,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
        };
        canvas.Children.Add(arc);
        var value = Ui.Label("", S.OnSurface, 12.5, FontWeights.SemiBold);
        value.HorizontalAlignment = HorizontalAlignment.Center;
        value.VerticalAlignment = VerticalAlignment.Center;
        canvas.Children.Add(value);
        rings[key] = (arc, value);
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(canvas);
        var l = Ui.Label(label, S.OnSurfaceVariant, 11.5);
        l.HorizontalAlignment = HorizontalAlignment.Center;
        l.Margin = new Thickness(0, 4, 0, 0);
        stack.Children.Add(l);
        return stack;
    }

    static Geometry Arc(double fraction, double size, double stroke)
    {
        fraction = Math.Clamp(fraction, 0.001, 0.999);
        double r = (size - stroke) / 2, c = size / 2;
        double angle = fraction * 2 * Math.PI;
        var start = new Point(c, c - r);
        var end = new Point(c + r * Math.Sin(angle), c - r * Math.Cos(angle));
        var fig = new PathFigure { StartPoint = start, IsClosed = false };
        fig.Segments.Add(new ArcSegment(end, new Size(r, r), 0, fraction > 0.5, SweepDirection.Clockwise, true));
        return new PathGeometry([fig]);
    }

    void SetRing(string key, double fraction, string text)
    {
        if (!rings.TryGetValue(key, out var r)) return;
        r.Arc.Data = Arc(fraction, 64, 7);
        r.Value.Text = text;
    }

    void Tick()
    {
        var now = DateTime.Now;
        if (time is not null) time.Text = now.ToString("HH:mm");
        if (date is not null) date.Text = now.ToString("dddd, d MMMM");

        double c = cpu.Sample();
        SetRing("cpu", c, $"{c * 100:0}%");
        var mem = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        if (GlobalMemoryStatusEx(ref mem))
        {
            double used = 1 - (double)mem.ullAvailPhys / mem.ullTotalPhys;
            SetRing("mem", used, $"{used * 100:0}%");
        }
        try
        {
            var drive = new System.IO.DriveInfo(System.IO.Path.GetPathRoot(Environment.SystemDirectory) ?? "C:\\");
            double used = 1 - (double)drive.AvailableFreeSpace / drive.TotalSize;
            SetRing("disk", used, $"{used * 100:0}%");
        }
        catch (Exception) { }
    }

    // ---- Media (Windows' "now playing" sessions: Spotify, browsers, Media Player...)

    GlobalSystemMediaTransportControlsSessionManager? manager;

    async Task LoadMediaAsync()
    {
        try
        {
            manager ??= await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            var session = manager.GetCurrentSession();
            if (session is null || media is null) return;
            var props = await session.TryGetMediaPropertiesAsync();
            var playing = session.GetPlaybackInfo().PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;

            ImageSource? art = null;
            if (props.Thumbnail is not null)
            {
                using var stream = System.IO.WindowsRuntimeStreamExtensions.AsStreamForRead(await props.Thumbnail.OpenReadAsync());
                var ms = new System.IO.MemoryStream();
                await stream.CopyToAsync(ms);
                ms.Position = 0;
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.StreamSource = ms;
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.DecodePixelWidth = 160;
                bmp.EndInit();
                bmp.Freeze();
                art = bmp;
            }

            var stack = new StackPanel();
            var cover = new Border
            {
                Width = 120, Height = 120, CornerRadius = new CornerRadius(16), HorizontalAlignment = HorizontalAlignment.Center,
                Background = art is null ? Ui.Brush(S.SecondaryContainer) : new ImageBrush(art) { Stretch = Stretch.UniformToFill },
                Child = art is null ? Ui.Icon(Ui.Glyph.Music, S.OnSecondaryContainer, 32) : null,
            };
            stack.Children.Add(cover);
            var title = Ui.Label(props.Title ?? "", S.OnSurface, 14.5, FontWeights.SemiBold);
            title.Margin = new Thickness(0, 12, 0, 0);
            title.HorizontalAlignment = HorizontalAlignment.Center;
            stack.Children.Add(title);
            var artist = Ui.Label(props.Artist ?? "", S.OnSurfaceVariant, 12.5);
            artist.HorizontalAlignment = HorizontalAlignment.Center;
            stack.Children.Add(artist);

            var controls = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 0) };
            controls.Children.Add(Ui.Clickable(Ui.Icon(Ui.Glyph.Previous, S.OnSurface, 16), () => _ = Act(s => s.TrySkipPreviousAsync()), S.SurfaceContainerHigh, 14));
            var play = new Border
            {
                CornerRadius = new CornerRadius(16), Background = Ui.Brush(S.Primary), Margin = new Thickness(8, 0, 8, 0),
                Child = Ui.Clickable(Ui.Icon(playing ? Ui.Glyph.Pause : Ui.Glyph.Play, S.OnPrimary, 16), () => _ = Act(s => s.TryTogglePlayPauseAsync()), S.PrimaryContainer, 16, new Thickness(12, 8, 12, 8)),
            };
            controls.Children.Add(play);
            controls.Children.Add(Ui.Clickable(Ui.Icon(Ui.Glyph.Next, S.OnSurface, 16), () => _ = Act(s => s.TrySkipNextAsync()), S.SurfaceContainerHigh, 14));
            stack.Children.Add(controls);
            media.Child = stack;
        }
        catch (Exception) { }
    }

    async Task Act(Func<GlobalSystemMediaTransportControlsSession, Windows.Foundation.IAsyncOperation<bool>> action)
    {
        try
        {
            if (manager?.GetCurrentSession() is { } s) await action(s);
            await Task.Delay(300);
            await LoadMediaAsync();
        }
        catch (Exception) { }
    }

    // ---- System stats

    sealed class Cpu
    {
        ulong idle, total;

        public double Sample()
        {
            if (!GetSystemTimes(out var i, out var k, out var u)) return 0;
            ulong idleNow = i, totalNow = k + u; // kernel time includes idle
            double busy = 0;
            if (total != 0 && totalNow > total)
                busy = 1 - (double)(idleNow - idle) / (totalNow - total);
            idle = idleNow;
            total = totalNow;
            return Math.Clamp(busy, 0, 1);
        }

        [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MEMORYSTATUSEX
    {
        public uint dwLength, dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);
}
