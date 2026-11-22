using Hyprwin.Core;

namespace Hyprwin;

/// <summary>Global hotkeys via RegisterHotKey on a message-only window.</summary>
sealed class Hotkeys : NativeWindow, IDisposable
{
    readonly Dictionary<int, KeyBind> binds = [];
    readonly Action<KeyBind> onPress;

    public Hotkeys(Action<KeyBind> onPress)
    {
        this.onPress = onPress;
        CreateHandle(new CreateParams { Parent = new IntPtr(-3) }); // HWND_MESSAGE
    }

    /// <summary>Replaces all hotkeys. Returns combos that could not be registered.</summary>
    public List<string> Register(IEnumerable<KeyBind> list, Mods superMapsTo)
    {
        foreach (var id in binds.Keys) Native.UnregisterHotKey(Handle, id);
        binds.Clear();
        var errors = new List<string>();
        int next = 1;
        foreach (var b in list)
        {
            if (WinKeyCodes.Code(b.Key) is not { } vk) continue;
            var logical = b.Mods;
            if (logical.HasFlag(Mods.Super)) logical = (logical & ~Mods.Super) | superMapsTo; // Super here = the Windows key
            if (Reserved(logical, b.Key) is { } why)
            {
                errors.Add($"skipped {b.Combo}: it would become {string.Join("+", logical.Names()).Replace("SUPER", "WIN")}+{b.Key}, {why}");
                continue;
            }
            uint mods = Native.MOD_NOREPEAT;
            if (logical.HasFlag(Mods.Super)) mods |= Native.MOD_WIN;
            if (logical.HasFlag(Mods.Shift)) mods |= Native.MOD_SHIFT;
            if (logical.HasFlag(Mods.Alt)) mods |= Native.MOD_ALT;
            if (logical.HasFlag(Mods.Ctrl)) mods |= Native.MOD_CONTROL;
            if (Native.RegisterHotKey(Handle, next, mods, vk))
            {
                binds[next++] = b;
            }
            else
            {
                errors.Add($"cannot register hotkey {b.Combo} (taken by Windows or another app, error {System.Runtime.InteropServices.Marshal.GetLastWin32Error()})");
            }
        }
        return errors;
    }

    /// <summary>System shortcuts a bind must never take over (after SUPER is remapped).</summary>
    static string? Reserved(Mods m, string key) => (m & ~Mods.Shift, key) switch
    {
        (Mods.Alt, "tab") => "the Windows task switcher",
        (Mods.Alt, "escape") => "a Windows window shortcut",
        (Mods.Alt, "f4") when !m.HasFlag(Mods.Shift) => "close window (Alt+F4)",
        (Mods.Ctrl, "escape") => "the Start menu",
        (Mods.Super, "l") => "lock screen",
        (Mods.Ctrl | Mods.Alt, "delete") => "the security screen",
        _ => null,
    };

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == Native.WM_HOTKEY && binds.TryGetValue(m.WParam.ToInt32(), out var b))
        {
            onPress(b);
            return;
        }
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        foreach (var id in binds.Keys) Native.UnregisterHotKey(Handle, id);
        binds.Clear();
        DestroyHandle();
    }
}
