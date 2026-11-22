namespace Hyprwin.Core;

public sealed record DwindleSettings(bool PreserveSplit = false, int ForceSplit = 0,
    double SplitWidthMultiplier = 1, double DefaultSplitRatio = 1);

/// <summary>Hyprland's dwindle layout: a binary tree; each new window splits the focused leaf.</summary>
public sealed class DwindleTree
{
    sealed class Node
    {
        public Node? Parent, First, Second;
        public long? Window;
        /// <summary>true = children stacked top/bottom, false = side by side.</summary>
        public bool Stacked;
        /// <summary>Set by togglesplit; the split no longer follows the box shape.</summary>
        public bool Manual;
        /// <summary>1.0 = even; first child gets ratio/2.</summary>
        public double Ratio = 1;
        public bool IsLeaf => Window is not null;
    }

    Node? root;

    public bool IsEmpty => root is null;

    public List<long> Windows
    {
        get
        {
            var o = new List<long>();
            void Walk(Node? n)
            {
                if (n is null) return;
                if (n.Window is { } w) o.Add(w); else { Walk(n.First); Walk(n.Second); }
            }
            Walk(root);
            return o;
        }
    }

    public bool Contains(long id) => Leaf(id) is not null;

    Node? Leaf(long id)
    {
        Node? Find(Node? n) => n is null ? null : n.Window == id ? n : Find(n.First) ?? Find(n.Second);
        return Find(root);
    }

    public void Insert(long id, long? target, Rect area, DwindleSettings s)
    {
        if (Contains(id)) return;
        var leaf = new Node { Window = id };
        if (root is null) { root = leaf; return; }
        var t = (target is { } tg ? Leaf(tg) : null) ?? Leaf(Windows[^1])!;
        var box = Boxes(area, s).TryGetValue(t.Window!.Value, out var b) ? b : area;

        var split = new Node { Stacked = !(box.W > box.H * s.SplitWidthMultiplier), Ratio = s.DefaultSplitRatio, Parent = t.Parent };
        if (t.Parent is { } p) { if (p.First == t) p.First = split; else p.Second = split; }
        else root = split;
        t.Parent = split;
        leaf.Parent = split;
        if (s.ForceSplit == 1) { split.First = leaf; split.Second = t; }
        else { split.First = t; split.Second = leaf; }
    }

    public void Remove(long id)
    {
        var n = Leaf(id);
        if (n is null) return;
        if (n.Parent is not { } parent) { root = null; return; }
        var sibling = parent.First == n ? parent.Second! : parent.First!;
        sibling.Parent = parent.Parent;
        if (parent.Parent is { } gp) { if (gp.First == parent) gp.First = sibling; else gp.Second = sibling; }
        else root = sibling;
    }

    public void Swap(long a, long b)
    {
        var na = Leaf(a); var nb = Leaf(b);
        if (na is null || nb is null) return;
        na.Window = b; nb.Window = a;
    }

    public void ToggleSplit(long id, Rect area, DwindleSettings s)
    {
        if (Leaf(id)?.Parent is not { } parent) return;
        if (!parent.Manual && !s.PreserveSplit)
        {
            Walk(area, s, (n, box) => { if (n == parent) parent.Stacked = !(box.W > box.H * s.SplitWidthMultiplier); });
        }
        parent.Stacked = !parent.Stacked;
        parent.Manual = true;
    }

    public void ChangeRatio(long id, double? delta = null, double? exact = null)
    {
        if (Leaf(id)?.Parent is not { } parent) return;
        parent.Ratio = Math.Clamp(exact ?? parent.Ratio + (delta ?? 0), 0.1, 1.9);
    }

    public double? RatioOf(long id) => Leaf(id)?.Parent?.Ratio;

    public Dictionary<long, Rect> Boxes(Rect area, DwindleSettings s)
    {
        var o = new Dictionary<long, Rect>();
        Walk(area, s, (n, box) => { if (n.Window is { } w) o[w] = box; });
        return o;
    }

    void Walk(Rect area, DwindleSettings s, Action<Node, Rect> visit)
    {
        void Go(Node? n, Rect box)
        {
            if (n is null) return;
            visit(n, box);
            if (n.IsLeaf) return;
            bool stacked = (n.Manual || s.PreserveSplit) ? n.Stacked : !(box.W > box.H * s.SplitWidthMultiplier);
            if (!n.Manual && !s.PreserveSplit) n.Stacked = stacked;
            double share = n.Ratio / 2;
            if (stacked)
            {
                double h1 = Math.Round(box.H * share);
                Go(n.First, new Rect(box.X, box.Y, box.W, h1));
                Go(n.Second, new Rect(box.X, box.Y + h1, box.W, box.H - h1));
            }
            else
            {
                double w1 = Math.Round(box.W * share);
                Go(n.First, new Rect(box.X, box.Y, w1, box.H));
                Go(n.Second, new Rect(box.X + w1, box.Y, box.W - w1, box.H));
            }
        }
        Go(root, area);
    }
}

public static class MasterLayout
{
    public static Dictionary<long, Rect> Boxes(IReadOnlyList<long> order, Rect area, double mfact, string orientation)
    {
        var o = new Dictionary<long, Rect>();
        if (order.Count == 0) return o;
        var master = order[0];
        var stack = order.Skip(1).ToList();
        if (stack.Count == 0) { o[master] = area; return o; }
        bool horizontal = orientation is "left" or "right";
        double ms = Math.Round((horizontal ? area.W : area.H) * mfact);
        Rect mb, sb;
        switch (orientation)
        {
            case "right": mb = new(area.MaxX - ms, area.Y, ms, area.H); sb = new(area.X, area.Y, area.W - ms, area.H); break;
            case "top": mb = new(area.X, area.Y, area.W, ms); sb = new(area.X, area.Y + ms, area.W, area.H - ms); break;
            case "bottom": mb = new(area.X, area.MaxY - ms, area.W, ms); sb = new(area.X, area.Y, area.W, area.H - ms); break;
            default: mb = new(area.X, area.Y, ms, area.H); sb = new(area.X + ms, area.Y, area.W - ms, area.H); break;
        }
        o[master] = mb;
        double n = stack.Count;
        for (int i = 0; i < stack.Count; i++)
        {
            if (horizontal)
            {
                double y0 = Math.Round(sb.Y + sb.H * i / n), y1 = Math.Round(sb.Y + sb.H * (i + 1) / n);
                o[stack[i]] = new Rect(sb.X, y0, sb.W, y1 - y0);
            }
            else
            {
                double x0 = Math.Round(sb.X + sb.W * i / n), x1 = Math.Round(sb.X + sb.W * (i + 1) / n);
                o[stack[i]] = new Rect(x0, sb.Y, x1 - x0, sb.H);
            }
        }
        return o;
    }

    /// <summary>gaps_in on tile sides that face another tile (not the area edge).</summary>
    public static Dictionary<long, Rect> ApplyInnerGaps(Dictionary<long, Rect> boxes, Rect area, Insets gapsIn)
    {
        const double eps = 1;
        return boxes.ToDictionary(p => p.Key, p =>
        {
            var b = p.Value;
            return b.Inset(new Insets(
                Math.Abs(b.Y - area.Y) <= eps ? 0 : gapsIn.Top,
                Math.Abs(b.MaxX - area.MaxX) <= eps ? 0 : gapsIn.Right,
                Math.Abs(b.MaxY - area.MaxY) <= eps ? 0 : gapsIn.Bottom,
                Math.Abs(b.X - area.X) <= eps ? 0 : gapsIn.Left));
        });
    }
}
