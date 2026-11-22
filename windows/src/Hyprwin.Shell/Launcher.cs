using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Hyprwin.Shell;

/// <summary>Installed apps (Win32 and Store), from the shell's AppsFolder.</summary>
sealed record AppEntry(string Name, string ParsingName);

static class AppIndex
{
    static List<AppEntry>? cache;
    static DateTime loaded;
    static readonly Dictionary<string, ImageSource?> icons = [];

    public static List<AppEntry> All()
    {
        if (cache is not null && DateTime.UtcNow - loaded < TimeSpan.FromMinutes(2)) return cache;
        var list = new List<AppEntry>();
        try
        {
            var t = Type.GetTypeFromProgID("Shell.Application");
            if (t is not null)
            {
                dynamic shell = Activator.CreateInstance(t)!;
                dynamic folder = shell.NameSpace("shell:AppsFolder");
                foreach (dynamic item in folder.Items())
                {
                    string name = item.Name;
                    string path = item.Path;
                    if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(path)) continue;
                    if (name.Contains("uninstall", StringComparison.OrdinalIgnoreCase)) continue;
                    list.Add(new AppEntry(name, path));
                }
            }
        }
        catch (Exception) { }
        cache = list.GroupBy(a => a.Name, StringComparer.OrdinalIgnoreCase).Select(g => g.First()).OrderBy(a => a.Name).ToList();
        loaded = DateTime.UtcNow;
        return cache;
    }

    public static void Launch(AppEntry app) =>
        Process.Start(new ProcessStartInfo("explorer.exe", "shell:AppsFolder\\" + app.ParsingName) { UseShellExecute = false })?.Dispose();

    /// <summary>Lower is better; null = no match. Prefix beats word start beats substring beats subsequence.</summary>
    public static int? Score(string name, string query)
    {
        if (query.Length == 0) return 1000;
        var n = name.ToLowerInvariant();
        var q = query.ToLowerInvariant();
        if (n.StartsWith(q)) return n.Length - q.Length;
        int word = n.IndexOf(" " + q, StringComparison.Ordinal);
        if (word >= 0) return 100 + word;
        int sub = n.IndexOf(q, StringComparison.Ordinal);
        if (sub >= 0) return 200 + sub;
        int i = 0, gaps = 0;
        foreach (var ch in n)
        {
            if (i < q.Length && ch == q[i]) i++;
            else if (i > 0) gaps++;
        }
        return i == q.Length ? 400 + gaps : null;
    }

    public static ImageSource? Icon(AppEntry app)
    {
        if (icons.TryGetValue(app.ParsingName, out var cached)) return cached;
        ImageSource? img = null;
        try
        {
            var iid = typeof(IShellItemImageFactory).GUID;
            if (SHCreateItemFromParsingName("shell:AppsFolder\\" + app.ParsingName, IntPtr.Zero, ref iid, out var factory) == 0)
            {
                if (factory.GetImage(new SIZE { cx = 48, cy = 48 }, 0x0, out var hbitmap) == 0 && hbitmap != IntPtr.Zero)
                {
                    try
                    {
                        img = Imaging.CreateBitmapSourceFromHBitmap(hbitmap, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                        img.Freeze();
                    }
                    finally { DeleteObject(hbitmap); }
                }
                Marshal.ReleaseComObject(factory);
            }
        }
        catch (Exception) { }
        icons[app.ParsingName] = img;
        return img;
    }

    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }

    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory
    {
        [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr phbm);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    static extern int SHCreateItemFromParsingName(string path, IntPtr pbc, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);

    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
}

/// <summary>App launcher that grows out of the bottom frame edge. Type to search;
/// "=" evaluates math, ">" runs a command. Enter launches, arrows move, Esc closes.</summary>
sealed class Launcher : EdgePanel
{
    public Launcher(ShellHost host) : base(host, Edge.Bottom) { }

    readonly TextBox query = new();
    readonly StackPanel results = new();
    readonly List<(Border Row, Action Run)> rows = [];
    int selected;
    List<AppEntry> apps = [];

    protected override UIElement Build()
    {
        apps = AppIndex.All();
        var root = new StackPanel { Width = 560 };
        root.Children.Add(results);

        var icon = Ui.Icon(Ui.Glyph.Search, S.OnSurfaceVariant, 16);
        icon.Margin = new Thickness(4, 0, 12, 0);
        query.Background = Brushes.Transparent;
        query.BorderThickness = new Thickness(0);
        query.Foreground = Ui.Brush(S.OnSurface);
        query.CaretBrush = Ui.Brush(S.Primary);
        query.FontFamily = Ui.Text;
        query.FontSize = 16;
        query.VerticalContentAlignment = VerticalAlignment.Center;
        query.Text = "";
        query.TextChanged -= OnQuery;
        query.TextChanged += OnQuery;
        query.PreviewKeyDown -= OnKey;
        query.PreviewKeyDown += OnKey;
        var hint = Ui.Label("Search apps  ·  = math  ·  > command", S.Outline, 12);
        hint.HorizontalAlignment = HorizontalAlignment.Right;
        hint.VerticalAlignment = VerticalAlignment.Center;
        var bar = new DockPanel();
        DockPanel.SetDock(icon, Dock.Left);
        DockPanel.SetDock(hint, Dock.Right);
        bar.Children.Add(icon);
        bar.Children.Add(hint);
        bar.Children.Add(query);
        var field = new Border
        {
            Background = Ui.Brush(S.SurfaceContainer),
            CornerRadius = new CornerRadius(22),
            Padding = new Thickness(14, 10, 14, 10),
            Margin = new Thickness(0, 10, 0, 0),
            Child = bar,
        };
        root.Children.Add(field);
        Refresh();
        return root;
    }

    protected override void OnOpened()
    {
        query.Focus();
        Keyboard.Focus(query);
    }

    void OnQuery(object? sender, TextChangedEventArgs e) => Refresh();

    void Refresh()
    {
        results.Children.Clear();
        rows.Clear();
        selected = 0;
        var q = query.Text.Trim();

        if (q.StartsWith('='))
        {
            var expr = q[1..].Trim();
            string answer;
            try { answer = expr.Length == 0 ? "" : Convert.ToString(new System.Data.DataTable().Compute(expr, null), System.Globalization.CultureInfo.InvariantCulture) ?? ""; }
            catch (Exception) { answer = "…"; }
            AddRow(Ui.Glyph.Calculator, null, answer.Length > 0 ? answer : "Type a calculation", "Enter copies the result",
                () => { if (answer is not ("" or "…")) Clipboard.SetText(answer); });
        }
        else if (q.StartsWith('>'))
        {
            var cmd = q[1..].Trim();
            AddRow(Ui.Glyph.Terminal, null, cmd.Length > 0 ? cmd : "Type a command", "Runs with cmd.exe",
                () => { if (cmd.Length > 0) Host.Backend.Exec(cmd); });
        }
        else
        {
            var matches = apps.Select(a => (a, s: AppIndex.Score(a.Name, q))).Where(x => x.s is not null)
                .OrderBy(x => x.s).ThenBy(x => x.a.Name).Take(q.Length == 0 ? 7 : 8).Select(x => x.a).ToList();
            foreach (var app in matches)
                AddRow(null, AppIndex.Icon(app), app.Name, null, () => AppIndex.Launch(app));
            if (matches.Count == 0) AddRow(Ui.Glyph.Search, null, "No apps found", "Try = for math or > for a command", () => { });
        }
        Highlight();
    }

    void AddRow(string? glyph, ImageSource? image, string title, string? subtitle, Action run)
    {
        var icon = image is not null
            ? (UIElement)new Image { Source = image, Width = 32, Height = 32 }
            : new Border
            {
                Width = 32, Height = 32, CornerRadius = new CornerRadius(10),
                Background = Ui.Brush(S.SecondaryContainer),
                Child = Ui.Icon(glyph ?? Ui.Glyph.Apps, S.OnSecondaryContainer, 15),
            };
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(14, 0, 0, 0) };
        text.Children.Add(Ui.Label(title, S.OnSurface, 14.5, FontWeights.Medium));
        if (subtitle is not null) text.Children.Add(Ui.Label(subtitle, S.OnSurfaceVariant, 12));
        var line = new DockPanel();
        DockPanel.SetDock(icon, Dock.Left);
        line.Children.Add(icon);
        line.Children.Add(text);
        var row = new Border { CornerRadius = new CornerRadius(16), Padding = new Thickness(10, 7, 10, 7), Child = line, Cursor = Cursors.Hand };
        int index = rows.Count;
        row.MouseEnter += (_, _) => { selected = index; Highlight(); };
        row.MouseLeftButtonUp += (_, _) => Run(index);
        rows.Add((row, run));
        results.Children.Add(row);
    }

    void Highlight()
    {
        for (int i = 0; i < rows.Count; i++)
            rows[i].Row.Background = i == selected ? Ui.Brush(S.SurfaceContainerHigh) : Brushes.Transparent;
    }

    void Run(int i)
    {
        if (i < 0 || i >= rows.Count) return;
        var run = rows[i].Run;
        Close2();
        try { run(); } catch (Exception) { }
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Down: selected = Math.Min(rows.Count - 1, selected + 1); Highlight(); e.Handled = true; break;
            case Key.Up: selected = Math.Max(0, selected - 1); Highlight(); e.Handled = true; break;
            case Key.Enter: Run(selected); e.Handled = true; break;
        }
    }
}
