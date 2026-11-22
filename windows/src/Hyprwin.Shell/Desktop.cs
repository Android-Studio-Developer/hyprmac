using System.Runtime.InteropServices;

namespace Hyprwin.Shell;

/// <summary>AppBar registration (reserves a screen edge like the taskbar does) and taskbar auto-hide.</summary>
static class Desktop
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct APPBARDATA
    {
        public int cbSize;
        public IntPtr hWnd;
        public uint uCallbackMessage;
        public uint uEdge;
        public RECT rc;
        public IntPtr lParam;
    }

    [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowW(string cls, string? name);
    [DllImport("user32.dll")] static extern bool SystemParametersInfoW(uint action, uint param, ref RECT value, uint winIni);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);

    const uint ABM_NEW = 0, ABM_REMOVE = 1, ABM_QUERYPOS = 2, ABM_SETPOS = 3, ABM_GETSTATE = 4, ABM_SETSTATE = 10;
    const uint ABE_LEFT = 0;
    const int ABS_AUTOHIDE = 1, ABS_ALWAYSONTOP = 2;
    const uint SPI_GETWORKAREA = 0x30;

    /// <summary>Reserves <paramref name="width"/> pixels on the left of the primary monitor.
    /// Returns the rectangle the bar may use.</summary>
    public static RECT RegisterLeft(IntPtr hwnd, int width, uint callbackMessage)
    {
        var d = new APPBARDATA { cbSize = Marshal.SizeOf<APPBARDATA>(), hWnd = hwnd, uCallbackMessage = callbackMessage };
        SHAppBarMessage(ABM_NEW, ref d);
        return SetLeft(hwnd, width);
    }

    public static RECT SetLeft(IntPtr hwnd, int width)
    {
        var screen = PrimaryBounds();
        var d = new APPBARDATA { cbSize = Marshal.SizeOf<APPBARDATA>(), hWnd = hwnd, uEdge = ABE_LEFT, rc = screen };
        d.rc.Right = d.rc.Left + width;
        SHAppBarMessage(ABM_QUERYPOS, ref d);
        d.rc.Right = d.rc.Left + width;
        SHAppBarMessage(ABM_SETPOS, ref d);
        return d.rc;
    }

    public static void Unregister(IntPtr hwnd)
    {
        var d = new APPBARDATA { cbSize = Marshal.SizeOf<APPBARDATA>(), hWnd = hwnd };
        SHAppBarMessage(ABM_REMOVE, ref d);
    }

    public static RECT PrimaryBounds()
    {
        // The primary monitor always starts at 0,0.
        return new RECT { Left = 0, Top = 0, Right = GetSystemMetrics(0), Bottom = GetSystemMetrics(1) };
    }

    /// <summary>Primary monitor work area in pixels (screen minus taskbar and app bars).</summary>
    public static RECT WorkArea()
    {
        var r = new RECT();
        SystemParametersInfoW(SPI_GETWORKAREA, 0, ref r, 0);
        return r;
    }

    // ---- Taskbar

    static int? savedTaskbarState;

    /// <summary>Sets the taskbar to auto-hide (Explorer remembers it, so a crash leaves it auto-hidden,
    /// never gone). <see cref="RestoreTaskbar"/> puts the old setting back.</summary>
    public static void AutoHideTaskbar()
    {
        var tray = FindWindowW("Shell_TrayWnd", null);
        if (tray == IntPtr.Zero) return;
        var d = new APPBARDATA { cbSize = Marshal.SizeOf<APPBARDATA>(), hWnd = tray };
        int state = (int)SHAppBarMessage(ABM_GETSTATE, ref d).ToUInt32();
        savedTaskbarState ??= state;
        d.lParam = new IntPtr(state | ABS_AUTOHIDE);
        SHAppBarMessage(ABM_SETSTATE, ref d);
    }

    public static void RestoreTaskbar()
    {
        if (savedTaskbarState is not { } state) return;
        var tray = FindWindowW("Shell_TrayWnd", null);
        if (tray == IntPtr.Zero) return;
        var d = new APPBARDATA { cbSize = Marshal.SizeOf<APPBARDATA>(), hWnd = tray, lParam = new IntPtr(state & (ABS_AUTOHIDE | ABS_ALWAYSONTOP)) };
        SHAppBarMessage(ABM_SETSTATE, ref d);
        savedTaskbarState = null;
    }
}
