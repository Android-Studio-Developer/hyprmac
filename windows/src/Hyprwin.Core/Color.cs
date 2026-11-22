using System.Globalization;
using System.Text.RegularExpressions;

namespace Hyprwin.Core;

public readonly record struct Rgba(double R, double G, double B, double A = 1)
{
    /// <summary>Parses "RRGGBB" or "RRGGBBAA".</summary>
    public static Rgba? FromHex(string hex)
    {
        var s = hex.StartsWith('#') ? hex[1..] : hex;
        if ((s.Length != 6 && s.Length != 8) || !ulong.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v)) return null;
        return s.Length == 6
            ? new Rgba(((v >> 16) & 0xff) / 255.0, ((v >> 8) & 0xff) / 255.0, (v & 0xff) / 255.0)
            : new Rgba(((v >> 24) & 0xff) / 255.0, ((v >> 16) & 0xff) / 255.0, ((v >> 8) & 0xff) / 255.0, (v & 0xff) / 255.0);
    }

    public string Hex
    {
        get
        {
            static string C(double v) => ((int)Math.Round(v * 255)).ToString("x2");
            return C(R) + C(G) + C(B) + C(A);
        }
    }

    /// <summary>Win32 COLORREF (0x00BBGGRR).</summary>
    public uint ColorRef => (uint)Math.Round(R * 255) | ((uint)Math.Round(G * 255) << 8) | ((uint)Math.Round(B * 255) << 16);
}

/// <summary>A Hyprland border color: one or more colors plus a gradient angle in degrees.</summary>
public sealed record BorderColor(IReadOnlyList<Rgba> Colors, double Angle = 0)
{
    static readonly Regex Token = new(@"rgba?\([^)]*\)|0x[0-9a-fA-F]{8}|-?\d+(?:\.\d+)?deg", RegexOptions.Compiled);

    public bool Equals(BorderColor? o) => o is not null && Angle == o.Angle && Colors.SequenceEqual(o.Colors);
    public override int GetHashCode() => HashCode.Combine(Angle, Colors.Count);

    /// <summary>Parses rgba(33ccffee), rgba(51, 204, 255, 0.93), rgb(ff0000), 0xee33ccff (ARGB),
    /// and gradients like "rgba(33ccffee) rgba(00ff99ee) 45deg".</summary>
    public static BorderColor? Parse(string text)
    {
        var matches = Token.Matches(text);
        int nonSpace = text.Count(c => !char.IsWhiteSpace(c));
        int tokenNonSpace = matches.Sum(m => m.Value.Count(c => !char.IsWhiteSpace(c)));
        if (matches.Count == 0 || tokenNonSpace != nonSpace) return null;

        var colors = new List<Rgba>();
        double angle = 0;
        foreach (Match m in matches)
        {
            var tok = m.Value;
            if (tok.EndsWith("deg"))
            {
                if (!double.TryParse(tok[..^3], NumberStyles.Float, CultureInfo.InvariantCulture, out angle)) return null;
            }
            else if (tok.StartsWith("0x"))
            {
                var v = ulong.Parse(tok[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture);
                colors.Add(new Rgba(((v >> 16) & 0xff) / 255.0, ((v >> 8) & 0xff) / 255.0, (v & 0xff) / 255.0, ((v >> 24) & 0xff) / 255.0));
            }
            else
            {
                var c = ParseFunc(tok);
                if (c is null) return null;
                colors.Add(c.Value);
            }
        }
        return colors.Count == 0 ? null : new BorderColor(colors, angle);
    }

    static Rgba? ParseFunc(string tok)
    {
        bool isRgba = tok.StartsWith("rgba(");
        var body = tok[(tok.IndexOf('(') + 1)..^1].Trim();
        if (!body.Contains(','))
        {
            if (body.Length != (isRgba ? 8 : 6)) return null;
            return Rgba.FromHex(body);
        }
        var parts = body.Split(',').Select(p => p.Trim()).ToArray();
        if (parts.Length != (isRgba ? 4 : 3)) return null;
        var nums = new double[parts.Length];
        for (int i = 0; i < parts.Length; i++)
            if (!double.TryParse(parts[i], NumberStyles.Float, CultureInfo.InvariantCulture, out nums[i])) return null;
        return new Rgba(nums[0] / 255, nums[1] / 255, nums[2] / 255, isRgba ? nums[3] : 1);
    }
}
