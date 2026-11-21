import Foundation

public struct DwindleSettings: Equatable, Sendable {
    public var preserveSplit = false
    /// 0 = follow focus side (treated as 2 on macOS), 1 = new window left/top, 2 = right/bottom.
    public var forceSplit = 0
    public var splitWidthMultiplier = 1.0
    public var defaultSplitRatio = 1.0

    public init(preserveSplit: Bool = false, forceSplit: Int = 0, splitWidthMultiplier: Double = 1.0, defaultSplitRatio: Double = 1.0) {
        self.preserveSplit = preserveSplit
        self.forceSplit = forceSplit
        self.splitWidthMultiplier = splitWidthMultiplier
        self.defaultSplitRatio = defaultSplitRatio
    }
}

/// Hyprland's dwindle layout: a binary tree. Each new window splits the focused leaf.
public final class DwindleTree {
    final class Node {
        weak var parent: Node?
        var window: WindowID?
        var first: Node?
        var second: Node?
        /// true = children stacked top/bottom, false = side by side.
        var stacked = false
        /// Set by togglesplit; the split no longer follows the box shape.
        var manual = false
        /// Hyprland split ratio: 1.0 = even, range 0.1...1.9. First child gets ratio/2.
        var ratio = 1.0

        init(window: WindowID?) { self.window = window }
        var isLeaf: Bool { window != nil }
    }

    var root: Node?

    public init() {}

    public var windows: [WindowID] {
        var out: [WindowID] = []
        func walk(_ n: Node?) {
            guard let n else { return }
            if let w = n.window { out.append(w) } else { walk(n.first); walk(n.second) }
        }
        walk(root)
        return out
    }

    public var isEmpty: Bool { root == nil }

    public func contains(_ id: WindowID) -> Bool { leaf(id) != nil }

    func leaf(_ id: WindowID) -> Node? {
        func find(_ n: Node?) -> Node? {
            guard let n else { return nil }
            if n.window == id { return n }
            return find(n.first) ?? find(n.second)
        }
        return find(root)
    }

    /// Inserts `id`, splitting the leaf of `target` (or the last leaf when nil/missing).
    public func insert(_ id: WindowID, splitting target: WindowID?, area: Rect, settings: DwindleSettings) {
        guard !contains(id) else { return }
        let newLeaf = Node(window: id)
        guard root != nil else {
            self.root = newLeaf
            return
        }
        let targetLeaf = target.flatMap { leaf($0) } ?? leaf(windows.last!)!
        let box = boxes(in: area, settings: settings)[targetLeaf.window!] ?? area

        let split = Node(window: nil)
        split.stacked = !(box.w > box.h * settings.splitWidthMultiplier)
        split.ratio = settings.defaultSplitRatio
        split.parent = targetLeaf.parent
        if let parent = targetLeaf.parent {
            if parent.first === targetLeaf { parent.first = split } else { parent.second = split }
        } else {
            self.root = split
        }
        targetLeaf.parent = split
        newLeaf.parent = split
        if settings.forceSplit == 1 {
            split.first = newLeaf
            split.second = targetLeaf
        } else {
            split.first = targetLeaf
            split.second = newLeaf
        }
    }

    public func remove(_ id: WindowID) {
        guard let node = leaf(id) else { return }
        guard let parent = node.parent else {
            root = nil
            return
        }
        let sibling = parent.first === node ? parent.second! : parent.first!
        sibling.parent = parent.parent
        if let gp = parent.parent {
            if gp.first === parent { gp.first = sibling } else { gp.second = sibling }
        } else {
            root = sibling
        }
    }

    public func swap(_ a: WindowID, _ b: WindowID) {
        guard let na = leaf(a), let nb = leaf(b) else { return }
        na.window = b
        nb.window = a
    }

    public func toggleSplit(_ id: WindowID, area: Rect, settings: DwindleSettings) {
        guard let parent = leaf(id)?.parent else { return }
        // Lock in the current orientation before flipping it.
        if !parent.manual && !settings.preserveSplit {
            parent.stacked = currentStacked(parent, area: area, settings: settings)
        }
        parent.stacked.toggle()
        parent.manual = true
    }

    /// Changes the ratio of the split that holds `id`. `delta` is added; `exact` replaces.
    public func changeRatio(_ id: WindowID, delta: Double? = nil, exact: Double? = nil) {
        guard let parent = leaf(id)?.parent else { return }
        var r = exact ?? parent.ratio + (delta ?? 0)
        r = min(1.9, max(0.1, r))
        parent.ratio = r
    }

    public func ratio(of id: WindowID) -> Double? { leaf(id)?.parent?.ratio }

    private func currentStacked(_ node: Node, area: Rect, settings: DwindleSettings) -> Bool {
        var result = node.stacked
        walkBoxes(in: area, settings: settings) { n, box in
            if n === node { result = !(box.w > box.h * settings.splitWidthMultiplier) }
        }
        return result
    }

    /// Tile boxes without gaps.
    public func boxes(in area: Rect, settings: DwindleSettings) -> [WindowID: Rect] {
        var out: [WindowID: Rect] = [:]
        walkBoxes(in: area, settings: settings) { n, box in
            if let w = n.window { out[w] = box }
        }
        return out
    }

    private func walkBoxes(in area: Rect, settings: DwindleSettings, visit: (Node, Rect) -> Void) {
        func walk(_ n: Node?, _ box: Rect) {
            guard let n else { return }
            visit(n, box)
            guard !n.isLeaf else { return }
            let stacked = (n.manual || settings.preserveSplit) ? n.stacked : !(box.w > box.h * settings.splitWidthMultiplier)
            if !n.manual && !settings.preserveSplit { n.stacked = stacked }
            let share = n.ratio / 2
            if stacked {
                let h1 = (box.h * share).rounded()
                walk(n.first, Rect(x: box.x, y: box.y, w: box.w, h: h1))
                walk(n.second, Rect(x: box.x, y: box.y + h1, w: box.w, h: box.h - h1))
            } else {
                let w1 = (box.w * share).rounded()
                walk(n.first, Rect(x: box.x, y: box.y, w: w1, h: box.h))
                walk(n.second, Rect(x: box.x + w1, y: box.y, w: box.w - w1, h: box.h))
            }
        }
        walk(root, area)
    }
}

/// Hyprland's master layout: first window is the master, the rest share the stack.
public enum MasterLayout {
    public static func boxes(order: [WindowID], area: Rect, mfact: Double, orientation: String) -> [WindowID: Rect] {
        var out: [WindowID: Rect] = [:]
        guard let master = order.first else { return out }
        let stack = Array(order.dropFirst())
        if stack.isEmpty {
            out[master] = area
            return out
        }
        let horizontal = orientation == "left" || orientation == "right"
        let masterSize = ((horizontal ? area.w : area.h) * mfact).rounded()
        let masterBox: Rect
        let stackBox: Rect
        switch orientation {
        case "right":
            masterBox = Rect(x: area.maxX - masterSize, y: area.y, w: masterSize, h: area.h)
            stackBox = Rect(x: area.x, y: area.y, w: area.w - masterSize, h: area.h)
        case "top":
            masterBox = Rect(x: area.x, y: area.y, w: area.w, h: masterSize)
            stackBox = Rect(x: area.x, y: area.y + masterSize, w: area.w, h: area.h - masterSize)
        case "bottom":
            masterBox = Rect(x: area.x, y: area.maxY - masterSize, w: area.w, h: masterSize)
            stackBox = Rect(x: area.x, y: area.y, w: area.w, h: area.h - masterSize)
        default:
            masterBox = Rect(x: area.x, y: area.y, w: masterSize, h: area.h)
            stackBox = Rect(x: area.x + masterSize, y: area.y, w: area.w - masterSize, h: area.h)
        }
        out[master] = masterBox
        let n = Double(stack.count)
        for (i, id) in stack.enumerated() {
            let fi = Double(i)
            if horizontal {
                let y0 = (stackBox.y + stackBox.h * fi / n).rounded()
                let y1 = (stackBox.y + stackBox.h * (fi + 1) / n).rounded()
                out[id] = Rect(x: stackBox.x, y: y0, w: stackBox.w, h: y1 - y0)
            } else {
                let x0 = (stackBox.x + stackBox.w * fi / n).rounded()
                let x1 = (stackBox.x + stackBox.w * (fi + 1) / n).rounded()
                out[id] = Rect(x: x0, y: stackBox.y, w: x1 - x0, h: stackBox.h)
            }
        }
        return out
    }
}

/// Applies gaps_in to the sides of each tile that face another tile (not the area edge).
public func applyInnerGaps(_ boxes: [WindowID: Rect], area: Rect, gapsIn: Insets) -> [WindowID: Rect] {
    let eps = 1.0
    return boxes.mapValues { b in
        let top = abs(b.y - area.y) <= eps ? 0 : gapsIn.top
        let left = abs(b.x - area.x) <= eps ? 0 : gapsIn.left
        let bottom = abs(b.maxY - area.maxY) <= eps ? 0 : gapsIn.bottom
        let right = abs(b.maxX - area.maxX) <= eps ? 0 : gapsIn.right
        return b.inset(Insets(top: top, right: right, bottom: bottom, left: left))
    }
}
