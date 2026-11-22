using System.Runtime.InteropServices;
using System.Text;

namespace Hyprwin;

/// <summary>Win32 / DWM calls used by hyprwin.</summary>
static class Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);
    public delegate void WinEventProc(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);

    // Styles
    public const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
    public const long WS_CAPTION = 0x00C00000, WS_THICKFRAME = 0x00040000, WS_CHILD = 0x40000000, WS_POPUP = 0x80000000;
    public const long WS_EX_TOOLWINDOW = 0x00000080, WS_EX_NOACTIVATE = 0x08000000, WS_EX_APPWINDOW = 0x00040000;
    public const uint GW_OWNER = 4;

    // ShowWindow
    public const int SW_RESTORE = 9;

    // SetWindowPos
    public const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010,
        SWP_FRAMECHANGED = 0x0020, SWP_NOOWNERZORDER = 0x0200, SWP_ASYNCWINDOWPOS = 0x4000;

    // WinEvents
    public const uint EVENT_SYSTEM_FOREGROUND = 0x0003, EVENT_SYSTEM_MOVESIZEEND = 0x000B,
        EVENT_SYSTEM_MINIMIZESTART = 0x0016, EVENT_SYSTEM_MINIMIZEEND = 0x0017,
        EVENT_OBJECT_DESTROY = 0x8001, EVENT_OBJECT_SHOW = 0x8002, EVENT_OBJECT_HIDE = 0x8003,
        EVENT_OBJECT_NAMECHANGE = 0x800C, EVENT_OBJECT_CLOAKED = 0x8017, EVENT_OBJECT_UNCLOAKED = 0x8018;
    public const uint WINEVENT_OUTOFCONTEXT = 0x0000, WINEVENT_SKIPOWNPROCESS = 0x0002;
    public const int OBJID_WINDOW = 0;

    // Messages / hotkeys
    public const int WM_HOTKEY = 0x0312, WM_CLOSE = 0x0010;
    public const uint MOD_ALT = 0x1, MOD_CONTROL = 0x2, MOD_SHIFT = 0x4, MOD_WIN = 0x8, MOD_NOREPEAT = 0x4000;

    // DWM
    public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9, DWMWA_CLOAKED = 14, DWMWA_WINDOW_CORNER_PREFERENCE = 33,
        DWMWA_BORDER_COLOR = 34;
    public const uint DWMWA_COLOR_DEFAULT = 0xFFFFFFFF;
    public const int DWMWCP_DEFAULT = 0, DWMWCP_DONOTROUND = 1, DWMWCP_ROUND = 2;

    // Keyboard
    public const byte VK_MENU = 0x12;
    public const uint KEYEVENTF_KEYUP = 0x0002;

    // Wallpaper
    public const uint SPI_GETDESKWALLPAPER = 0x0073, SPI_SETDESKWALLPAPER = 0x0014, SPIF_UPDATEINIFILE = 0x01, SPIF_SENDCHANGE = 0x02;

    // Console
    public const int ATTACH_PARENT_PROCESS = -1;

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hwnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern int GetWindowTextLengthW(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr hwnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr hMonitor, ref MONITORINFOEX info);
    [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc cb, uint pid, uint thread, uint flags);
    [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool RegisterHotKey(IntPtr hwnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool SystemParametersInfoW(uint action, uint param, StringBuilder? value, uint winIni);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SystemParametersInfoW")]
    public static extern bool SystemParametersInfoSet(uint action, uint param, string value, uint winIni);

    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT value, int size);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref uint value, int size);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    [DllImport("kernel32.dll")] public static extern bool AttachConsole(int pid);

    public static string Title(IntPtr h)
    {
        int n = GetWindowTextLengthW(h);
        if (n <= 0) return "";
        var sb = new StringBuilder(n + 1);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string ClassName(IntPtr h)
    {
        var sb = new StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static long Style(IntPtr h) => GetWindowLongPtr(h, GWL_STYLE).ToInt64();
    public static long ExStyle(IntPtr h) => GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64();

    public static bool IsCloaked(IntPtr h) =>
        DwmGetWindowAttribute(h, DWMWA_CLOAKED, out int c, sizeof(int)) == 0 && c != 0;

    /// <summary>Visible frame (without the invisible resize border Windows 10/11 adds).</summary>
    public static Core.Rect? VisibleFrame(IntPtr h)
    {
        if (DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT r, Marshal.SizeOf<RECT>()) != 0 && !GetWindowRect(h, out r))
            return null;
        return new Core.Rect(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
    }
}
