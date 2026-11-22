using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Hyprwin.Shell;

/// <summary>Dark color scheme in Material 3 roles, generated from one seed hue
/// (taken from the wallpaper, or given). Tones follow Material's dark-theme values.</summary>
public sealed record Scheme(
    Color Primary, Color OnPrimary, Color PrimaryContainer, Color OnPrimaryContainer,
    Color Secondary, Color SecondaryContainer, Color OnSecondaryContainer, Color Tertiary,
    Color Surface, Color SurfaceContainerLow, Color SurfaceContainer, Color SurfaceContainerHigh,
    Color SurfaceContainerHighest, Color OnSurface, Color OnSurfaceVariant, Color Outline, Color Error)
{
    public static Scheme FromSeed(double hue, double chroma = 1)
    {
        // chroma: 0 = grey wallpaper, 1 = colorful. Scales every saturation.
        Color C(double h, double s, double l) => Hsl((h % 360 + 360) % 360, Math.Clamp(s * chroma, 0, 1), l);
        return new Scheme(
            Primary: C(hue, 0.75, 0.80),
            OnPrimary: C(hue, 0.70, 0.18),
            PrimaryContainer: C(hue, 0.55, 0.28),
            OnPrimaryContainer: C(hue, 0.85, 0.90),
            Secondary: C(hue, 0.30, 0.78),
            SecondaryContainer: C(hue, 0.22, 0.27),
            OnSecondaryContainer: C(hue, 0.35, 0.88),
            Tertiary: C(hue + 60, 0.50, 0.78),
            Surface: C(hue, 0.16, 0.065),
            SurfaceContainerLow: C(hue, 0.14, 0.09),
            SurfaceContainer: C(hue, 0.13, 0.115),
            SurfaceContainerHigh: C(hue, 0.12, 0.155),
            SurfaceContainerHighest: C(hue, 0.11, 0.20),
            OnSurface: C(hue, 0.20, 0.90),
            OnSurfaceVariant: C(hue, 0.12, 0.78),
            Outline: C(hue, 0.08, 0.55),
            Error: Hsl(0, 0.90 * Math.Max(0.6, chroma), 0.78));
    }

    public static readonly Scheme Default = FromSeed(215);

    /// <summary>"auto" reads the wallpaper; a Hyprland color (rgb(...), rgba(...), 0x...) seeds it.</summary>
    public static Scheme Resolve(string setting, string? wallpaper)
    {
        if (setting != "auto" && Hyprwin.Core.BorderColor.Parse(setting) is { } bc)
        {
            var c = bc.Colors[0];
            var (h, s, _) = ToHsl(Color.FromRgb((byte)(c.R * 255), (byte)(c.G * 255), (byte)(c.B * 255)));
            return FromSeed(h, Math.Clamp(s * 1.4, 0.15, 1));
        }
        if (wallpaper is not null && SeedFromImage(wallpaper) is { } seed) return FromSeed(seed.Hue, seed.Chroma);
        return Default;
    }

    /// <summary>Dominant hue of an image, weighted by saturation and brightness.</summary>
    public static (double Hue, double Chroma)? SeedFromImage(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            var img = new BitmapImage();
            img.BeginInit();
            img.UriSource = new Uri(path);
            img.DecodePixelWidth = 96;
            img.CacheOption = BitmapCacheOption.OnLoad;
            img.EndInit();
            var bgra = new FormatConvertedBitmap(img, PixelFormats.Bgra32, null, 0);
            int w = bgra.PixelWidth, h = bgra.PixelHeight;
            var px = new byte[w * h * 4];
            bgra.CopyPixels(px, w * 4, 0);

            var bins = new double[36];
            var sinSum = new double[36];
            var cosSum = new double[36];
            double colorful = 0, total = 0;
            for (int i = 0; i < px.Length; i += 4)
            {
                var (hue, sat, light) = ToHsl(Color.FromRgb(px[i + 2], px[i + 1], px[i]));
                total++;
                if (light < 0.12 || light > 0.92 || sat < 0.18) continue;
                double weight = sat * (1 - Math.Abs(light - 0.5) * 1.4);
                if (weight <= 0) continue;
                colorful += weight;
                int b = (int)(hue / 10) % 36;
                bins[b] += weight;
                sinSum[b] += Math.Sin(hue * Math.PI / 180) * weight;
                cosSum[b] += Math.Cos(hue * Math.PI / 180) * weight;
            }
            if (total == 0) return null;
            // Smooth over neighbours so a hue split across two bins still wins.
            int best = 0;
            double bestScore = -1;
            for (int b = 0; b < 36; b++)
            {
                double score = bins[b] + 0.5 * (bins[(b + 35) % 36] + bins[(b + 1) % 36]);
                if (score > bestScore) { bestScore = score; best = b; }
            }
            double chroma = Math.Clamp(colorful / total * 3, 0.12, 1);
            if (bins[best] <= 0) return (215, 0.12);
            double hueOut = Math.Atan2(sinSum[best], cosSum[best]) * 180 / Math.PI;
            return ((hueOut + 360) % 360, chroma);
        }
        catch (Exception) { return null; }
    }

    public static Color Hsl(double h, double s, double l)
    {
        double c = (1 - Math.Abs(2 * l - 1)) * s;
        double x = c * (1 - Math.Abs(h / 60 % 2 - 1));
        double m = l - c / 2;
        (double r, double g, double b) = (h % 360) switch
        {
            < 60 => (c, x, 0.0),
            < 120 => (x, c, 0.0),
            < 180 => (0.0, c, x),
            < 240 => (0.0, x, c),
            < 300 => (x, 0.0, c),
            _ => (c, 0.0, x),
        };
        static byte B(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255);
        return Color.FromRgb(B(r + m), B(g + m), B(b + m));
    }

    public static (double H, double S, double L) ToHsl(Color c)
    {
        double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
        double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
        double l = (max + min) / 2, d = max - min;
        if (d < 1e-6) return (0, 0, l);
        double s = d / (1 - Math.Abs(2 * l - 1));
        double h = max == r ? 60 * (((g - b) / d) % 6) : max == g ? 60 * ((b - r) / d + 2) : 60 * ((r - g) / d + 4);
        return ((h + 360) % 360, s, l);
    }
}
