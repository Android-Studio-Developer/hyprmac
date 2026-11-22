namespace Hyprwin.Core;

/// <summary>Modifier keys in a bind. SUPER is the Windows key (unless remapped with hyprmac:super).</summary>
[Flags]
public enum Mods
{
    None = 0,
    Super = 1,
    Shift = 2,
    Alt = 4,
    Ctrl = 8,
}

public static class ModsParser
{
    /// <summary>Parses "SUPER SHIFT", "SUPER_SHIFT", "CTRL+ALT", "" (none). Null on unknown names.</summary>
    public static Mods? Parse(string text)
    {
        var m = Mods.None;
        foreach (var p in text.ToUpperInvariant().Split([' ', '_', '+'], StringSplitOptions.RemoveEmptyEntries))
        {
            switch (p)
            {
                case "SUPER" or "WIN" or "LOGO" or "MOD4" or "META" or "CMD" or "COMMAND": m |= Mods.Super; break;
                case "SHIFT": m |= Mods.Shift; break;
                case "ALT" or "MOD1" or "OPT" or "OPTION": m |= Mods.Alt; break;
                case "CTRL" or "CONTROL": m |= Mods.Ctrl; break;
                default: return null;
            }
        }
        return m;
    }

    public static List<string> Names(this Mods m)
    {
        var o = new List<string>();
        if (m.HasFlag(Mods.Super)) o.Add("SUPER");
        if (m.HasFlag(Mods.Ctrl)) o.Add("CTRL");
        if (m.HasFlag(Mods.Alt)) o.Add("ALT");
        if (m.HasFlag(Mods.Shift)) o.Add("SHIFT");
        return o;
    }
}

/// <summary>Key names (xkb style, as in hyprland.conf) mapped to Windows virtual-key codes.</summary>
public static class WinKeyCodes
{
    public static readonly IReadOnlyDictionary<string, uint> Table = Build();

    static Dictionary<string, uint> Build()
    {
        var t = new Dictionary<string, uint>();
        for (char c = 'a'; c <= 'z'; c++) t[c.ToString()] = (uint)char.ToUpperInvariant(c);
        for (char c = '0'; c <= '9'; c++) t[c.ToString()] = c;
        for (uint i = 1; i <= 24; i++) t[$"f{i}"] = 0x70 + i - 1;
        t["return"] = 0x0D; t["space"] = 0x20; t["tab"] = 0x09; t["escape"] = 0x1B; t["backspace"] = 0x08;
        t["delete"] = 0x2E; t["insert"] = 0x2D; t["print"] = 0x2C;
        t["minus"] = 0xBD; t["equal"] = 0xBB; t["bracketleft"] = 0xDB; t["bracketright"] = 0xDD;
        t["semicolon"] = 0xBA; t["apostrophe"] = 0xDE; t["grave"] = 0xC0; t["backslash"] = 0xDC;
        t["comma"] = 0xBC; t["period"] = 0xBE; t["slash"] = 0xBF;
        t["left"] = 0x25; t["up"] = 0x26; t["right"] = 0x27; t["down"] = 0x28;
        t["home"] = 0x24; t["end"] = 0x23; t["prior"] = 0x21; t["next"] = 0x22;
        // Aliases.
        t["enter"] = t["return"]; t["esc"] = t["escape"]; t["page_up"] = t["prior"]; t["pageup"] = t["prior"];
        t["page_down"] = t["next"]; t["pagedown"] = t["next"]; t["equals"] = t["equal"]; t["quoteleft"] = t["grave"];
        t["quote"] = t["apostrophe"]; t["dot"] = t["period"];
        return t;
    }

    public static string Normalize(string key) => key.Trim().ToLowerInvariant();

    public static uint? Code(string key) => Table.TryGetValue(Normalize(key), out var v) ? v : null;
}
