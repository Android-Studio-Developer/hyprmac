namespace Hyprwin.Core;

/// <summary>Rectangle in virtual-screen pixels, origin top-left, y down.</summary>
public readonly record struct Rect(double X, double Y, double W, double H)
{
    public double MaxX => X + W;
    public double MaxY => Y + H;
    public double MidX => X + W / 2;
    public double MidY => Y + H / 2;

    public Rect Inset(Insets i) =>
        new(X + i.Left, Y + i.Top, Math.Max(1, W - i.Left - i.Right), Math.Max(1, H - i.Top - i.Bottom));

    public Rect Inset(double d) => Inset(Insets.All(d));

    public Rect Rounded() => new(Math.Round(X), Math.Round(Y), Math.Round(W), Math.Round(H));

    public bool Contains(double px, double py) => px >= X && px < MaxX && py >= Y && py < MaxY;

    public override string ToString() => $"{(int)X},{(int)Y} {(int)W}x{(int)H}";
}

public readonly record struct Insets(double Top, double Right, double Bottom, double Left)
{
    public static Insets All(double v) => new(v, v, v, v);

    /// <summary>Hyprland/CSS style: "5", "5 10", "5 10 15", "5 10 15 20" (commas allowed).</summary>
    public static Insets? ParseCss(string css)
    {
        var raw = css.Split([' ', ','], StringSplitOptions.RemoveEmptyEntries);
        var parts = new List<double>();
        foreach (var r in raw)
        {
            if (!double.TryParse(r, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v)) return null;
            parts.Add(v);
        }
        return parts.Count switch
        {
            0 => null,
            1 => All(parts[0]),
            2 => new Insets(parts[0], parts[1], parts[0], parts[1]),
            3 => new Insets(parts[0], parts[1], parts[2], parts[1]),
            _ => new Insets(parts[0], parts[1], parts[2], parts[3]),
        };
    }
}

public enum Direction { Left, Right, Up, Down }

public static class Geometry
{
    public static Direction? ParseDirection(string arg) => arg.Trim().ToLowerInvariant() switch
    {
        "l" or "left" => Direction.Left,
        "r" or "right" => Direction.Right,
        "u" or "up" or "t" or "top" => Direction.Up,
        "d" or "down" or "b" or "bottom" => Direction.Down,
        _ => null,
    };

    /// <summary>Nearest rect from <paramref name="from"/> in a direction. Prefers rects that overlap on
    /// the perpendicular axis; falls back to the nearest center in that half-plane.</summary>
    public static bool TryNeighbor<TKey>(Rect from, Direction direction, IReadOnlyDictionary<TKey, Rect> candidates, out TKey found)
        where TKey : notnull
    {
        const double eps = 2.0;
        static double Overlap(double a0, double a1, double b0, double b1) => Math.Max(0, Math.Min(a1, b1) - Math.Max(a0, b0));

        bool have = false;
        TKey bestKey = default!;
        double bestDist = 0, bestOv = 0;
        foreach (var (k, r) in candidates.OrderBy(p => p.Key.ToString(), StringComparer.Ordinal))
        {
            double dist, ov;
            switch (direction)
            {
                case Direction.Left:
                    if (r.MaxX > from.X + eps) continue;
                    dist = from.X - r.MaxX; ov = Overlap(from.Y, from.MaxY, r.Y, r.MaxY); break;
                case Direction.Right:
                    if (r.X < from.MaxX - eps) continue;
                    dist = r.X - from.MaxX; ov = Overlap(from.Y, from.MaxY, r.Y, r.MaxY); break;
                case Direction.Up:
                    if (r.MaxY > from.Y + eps) continue;
                    dist = from.Y - r.MaxY; ov = Overlap(from.X, from.MaxX, r.X, r.MaxX); break;
                default:
                    if (r.Y < from.MaxY - eps) continue;
                    dist = r.Y - from.MaxY; ov = Overlap(from.X, from.MaxX, r.X, r.MaxX); break;
            }
            if (ov <= 0) continue;
            if (!have || dist < bestDist - eps || (Math.Abs(dist - bestDist) <= eps && ov > bestOv))
            {
                have = true; bestKey = k; bestDist = dist; bestOv = ov;
            }
        }
        if (have) { found = bestKey; return true; }

        double fd = double.MaxValue;
        foreach (var (k, r) in candidates)
        {
            double dx = r.MidX - from.MidX, dy = r.MidY - from.MidY;
            bool inDir = direction switch
            {
                Direction.Left => dx < -eps,
                Direction.Right => dx > eps,
                Direction.Up => dy < -eps,
                _ => dy > eps,
            };
            if (!inDir) continue;
            double d = dx * dx + dy * dy;
            if (d < fd) { fd = d; bestKey = k; have = true; }
        }
        found = bestKey;
        return have;
    }
}
