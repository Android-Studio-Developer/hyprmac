using System.Diagnostics;
using System.Drawing;
using System.Drawing.Text;
using Hyprwin.Core;

namespace Hyprwin;

/// <summary>Tray icon showing the current workspace number; menu with rices, reload, config, quit.</summary>
sealed class Tray : IDisposable
{
    readonly NotifyIcon icon = new() { Visible = true, Text = "hyprwin" };
    readonly WindowManager wm;
    int shown = -1;
    bool shownWarn;
    Icon? current;

    public Tray(WindowManager wm)
    {
        this.wm = wm;
        icon.ContextMenuStrip = new ContextMenuStrip();
        icon.ContextMenuStrip.Opening += (_, _) => BuildMenu();
        Update();
    }

    public void Update()
    {
        int ws = wm.Model.CurrentWorkspace;
        bool warn = wm.ConfigErrors.Count > 0;
        var occupied = wm.Model.Workspaces.Values.Where(w => !w.IsEmpty).Select(w => w.Id).Order();
        icon.Text = Truncate($"hyprwin: workspace {ws} (in use: {string.Join(" ", occupied)}){(warn ? " - config errors" : "")}", 127);
        if (ws == shown && warn == shownWarn) return;
        shown = ws;
        shownWarn = warn;
        var old = current;
        current = Draw(ws.ToString(), warn);
        icon.Icon = current;
        old?.Dispose();
    }

    static string Truncate(string s, int n) => s.Length <= n ? s : s[..n];

    static Icon Draw(string text, bool warn)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.Clear(Color.Transparent);
            using var bg = new SolidBrush(warn ? Color.FromArgb(220, 180, 60, 60) : Color.FromArgb(230, 30, 30, 46));
            g.FillRectangle(bg, 0, 0, 32, 32);
            using var font = new Font("Segoe UI", text.Length > 1 ? 14 : 18, FontStyle.Bold, GraphicsUnit.Pixel);
            using var fg = new SolidBrush(Color.FromArgb(255, 137, 180, 250));
            var size = g.MeasureString(text, font);
            g.DrawString(text, font, fg, (32 - size.Width) / 2, (32 - size.Height) / 2);
        }
        var h = bmp.GetHicon();
        using var tmp = Icon.FromHandle(h);
        var owned = (Icon)tmp.Clone();
        DestroyIcon(h); // FromHandle doesn't take ownership
        return owned;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr h);

    void BuildMenu()
    {
        var m = icon.ContextMenuStrip!;
        m.Items.Clear();
        m.Items.Add(new ToolStripMenuItem($"hyprwin {HyprwinInfo.Version}") { Enabled = false });
        m.Items.Add(new ToolStripMenuItem($"{wm.WindowCount} windows managed") { Enabled = false });
        m.Items.Add(new ToolStripSeparator());
        var errors = wm.ConfigErrors;
        if (errors.Count > 0)
        {
            m.Items.Add(new ToolStripMenuItem($"Config errors ({errors.Count}):") { Enabled = false });
            foreach (var e in errors.Take(10)) m.Items.Add(new ToolStripMenuItem("  " + e) { Enabled = false });
            m.Items.Add(new ToolStripSeparator());
        }

        var rice = new ToolStripMenuItem("Rice");
        var rm = wm.Rices;
        var active = rm.Active;
        foreach (var name in rm.Installed)
        {
            var n = name;
            rice.DropDownItems.Add(new ToolStripMenuItem(n, null, (_, _) => rm.Main(["use", n])) { Checked = n == active });
        }
        if (rm.Installed.Count == 0) rice.DropDownItems.Add(new ToolStripMenuItem("No rices: hyprwin rice install <git-url>") { Enabled = false });
        rice.DropDownItems.Add(new ToolStripSeparator());
        rice.DropDownItems.Add(new ToolStripMenuItem("Off (restore my configs)", null, (_, _) => rm.Main(["off"])) { Enabled = active is not null });
        m.Items.Add(rice);
        m.Items.Add(new ToolStripSeparator());

        m.Items.Add("Reload config", null, (_, _) => wm.Reload());
        m.Items.Add("Edit config", null, (_, _) => Open(ConfigParser.Expand(wm.ConfigPath)));
        m.Items.Add("Open config folder", null, (_, _) => Open(Path.GetDirectoryName(ConfigParser.Expand(wm.ConfigPath))!));
        m.Items.Add(new ToolStripSeparator());
        m.Items.Add("Quit hyprwin (restores windows)", null, (_, _) => wm.Shutdown());
    }

    static void Open(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true })?.Dispose(); }
        catch (Exception e) { Program.Log($"open {path}: {e.Message}"); }
    }

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
        current?.Dispose();
    }
}
