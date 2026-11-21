import Foundation

/// Window identifier. On macOS this is the CGWindowID.
public typealias WindowID = UInt32

/// Rectangle in screen coordinates with the origin at the top-left of the
/// primary display and y growing downwards (the Accessibility API convention).
public struct Rect: Equatable, Hashable, CustomStringConvertible, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var midX: Double { x + w / 2 }
    public var midY: Double { y + h / 2 }

    public func inset(_ i: Insets) -> Rect {
        Rect(x: x + i.left, y: y + i.top, w: max(1, w - i.left - i.right), h: max(1, h - i.top - i.bottom))
    }

    public func inset(by d: Double) -> Rect { inset(Insets(all: d)) }

    public func rounded() -> Rect {
        Rect(x: x.rounded(), y: y.rounded(), w: w.rounded(), h: h.rounded())
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }

    /// True when every edge is within `tolerance` of the other rect.
    public func isClose(to o: Rect, tolerance: Double = 2) -> Bool {
        abs(x - o.x) <= tolerance && abs(y - o.y) <= tolerance
            && abs(w - o.w) <= tolerance && abs(h - o.h) <= tolerance
    }

    public var description: String { "\(Int(x)),\(Int(y)) \(Int(w))x\(Int(h))" }
}

public struct Insets: Equatable, Sendable {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public init(all v: Double) { self.init(top: v, right: v, bottom: v, left: v) }

    /// Hyprland/CSS style: "5", "5 10", "5 10 15", "5 10 15 20" (commas allowed).
    public init?(css: String) {
        let parts = css.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        let raw = css.split(whereSeparator: { $0 == " " || $0 == "," })
        guard !parts.isEmpty, parts.count == raw.count else { return nil }
        switch parts.count {
        case 1: self.init(all: parts[0])
        case 2: self.init(top: parts[0], right: parts[1], bottom: parts[0], left: parts[1])
        case 3: self.init(top: parts[0], right: parts[1], bottom: parts[2], left: parts[1])
        default: self.init(top: parts[0], right: parts[1], bottom: parts[2], left: parts[3])
        }
    }
}

public enum Direction: String, CaseIterable, Sendable {
    case left = "l", right = "r", up = "u", down = "d"

    public init?(arg: String) {
        switch arg.trimmingCharacters(in: .whitespaces).lowercased() {
        case "l", "left": self = .left
        case "r", "right": self = .right
        case "u", "up", "t", "top": self = .up
        case "d", "down", "b", "bottom": self = .down
        default: return nil
        }
    }
}

/// Finds the rect nearest to `from` in `direction`. Prefers rects that overlap
/// on the perpendicular axis; falls back to the nearest center in that half-plane.
public func neighbor<K: Hashable>(of from: Rect, direction: Direction, among candidates: [K: Rect]) -> K? {
    let eps = 2.0
    func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
        max(0, min(a1, b1) - max(a0, b0))
    }

    var best: (key: K, dist: Double, ov: Double)?
    for (k, r) in candidates {
        let dist: Double
        let ov: Double
        switch direction {
        case .left:
            guard r.maxX <= from.x + eps else { continue }
            dist = from.x - r.maxX
            ov = overlap(from.y, from.maxY, r.y, r.maxY)
        case .right:
            guard r.x >= from.maxX - eps else { continue }
            dist = r.x - from.maxX
            ov = overlap(from.y, from.maxY, r.y, r.maxY)
        case .up:
            guard r.maxY <= from.y + eps else { continue }
            dist = from.y - r.maxY
            ov = overlap(from.x, from.maxX, r.x, r.maxX)
        case .down:
            guard r.y >= from.maxY - eps else { continue }
            dist = r.y - from.maxY
            ov = overlap(from.x, from.maxX, r.x, r.maxX)
        }
        guard ov > 0 else { continue }
        if let b = best {
            if dist < b.dist - eps || (abs(dist - b.dist) <= eps && ov > b.ov) {
                best = (k, dist, ov)
            }
        } else {
            best = (k, dist, ov)
        }
    }
    if let b = best { return b.key }

    // No overlapping candidate: nearest center strictly in that direction.
    var fallback: (key: K, d: Double)?
    for (k, r) in candidates {
        let dx = r.midX - from.midX
        let dy = r.midY - from.midY
        let inDir: Bool
        switch direction {
        case .left: inDir = dx < -eps
        case .right: inDir = dx > eps
        case .up: inDir = dy < -eps
        case .down: inDir = dy > eps
        }
        guard inDir else { continue }
        let d = dx * dx + dy * dy
        if fallback == nil || d < fallback!.d { fallback = (k, d) }
    }
    return fallback?.key
}
