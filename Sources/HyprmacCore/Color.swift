import Foundation

public struct RGBA: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Parses "RRGGBB" or "RRGGBBAA" hex.
    public init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(r: Double((v >> 16) & 0xff) / 255, g: Double((v >> 8) & 0xff) / 255, b: Double(v & 0xff) / 255)
        } else {
            self.init(r: Double((v >> 24) & 0xff) / 255, g: Double((v >> 16) & 0xff) / 255,
                      b: Double((v >> 8) & 0xff) / 255, a: Double(v & 0xff) / 255)
        }
    }

    public var hex: String {
        func c(_ v: Double) -> String { String(format: "%02x", Int((v * 255).rounded())) }
        return c(r) + c(g) + c(b) + c(a)
    }
}

/// A Hyprland border color: one or more colors plus a gradient angle in degrees.
public struct BorderColor: Equatable, Sendable {
    public var colors: [RGBA]
    public var angle: Double

    public init(colors: [RGBA], angle: Double = 0) {
        self.colors = colors
        self.angle = angle
    }

    /// Parses Hyprland color syntax:
    /// `rgba(33ccffee)`, `rgba(51, 204, 255, 0.93)`, `rgb(ff0000)`, `rgb(255,0,0)`,
    /// `0xee33ccff` (ARGB), and gradients like `rgba(33ccffee) rgba(00ff99ee) 45deg`.
    public static func parse(_ text: String) -> BorderColor? {
        let pattern = #"rgba?\([^)]*\)|0x[0-9a-fA-F]{8}|-?\d+(?:\.\d+)?deg"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // Everything except whitespace must be covered by a token.
        let covered = matches.reduce(0) { $0 + $1.range.length }
        let nonSpace = text.filter { !$0.isWhitespace }.count
        let tokenNonSpace = matches.reduce(0) { $0 + ns.substring(with: $1.range).filter { !$0.isWhitespace }.count }
        guard !matches.isEmpty, tokenNonSpace == nonSpace, covered > 0 else { return nil }

        var colors: [RGBA] = []
        var angle = 0.0
        for m in matches {
            let tok = ns.substring(with: m.range)
            if tok.hasSuffix("deg") {
                guard let a = Double(tok.dropLast(3)) else { return nil }
                angle = a
            } else if tok.hasPrefix("0x") {
                guard let v = UInt64(tok.dropFirst(2), radix: 16) else { return nil }
                colors.append(RGBA(r: Double((v >> 16) & 0xff) / 255, g: Double((v >> 8) & 0xff) / 255,
                                   b: Double(v & 0xff) / 255, a: Double((v >> 24) & 0xff) / 255))
            } else {
                guard let c = parseFunc(tok) else { return nil }
                colors.append(c)
            }
        }
        guard !colors.isEmpty else { return nil }
        return BorderColor(colors: colors, angle: angle)
    }

    private static func parseFunc(_ tok: String) -> RGBA? {
        let isRGBA = tok.hasPrefix("rgba(")
        let inner = tok.drop(while: { $0 != "(" }).dropFirst().dropLast()
        let body = inner.trimmingCharacters(in: .whitespaces)
        if !body.contains(",") {
            let c = RGBA(hex: body)
            if isRGBA, body.count != 8 { return nil }
            if !isRGBA, body.count != 6 { return nil }
            return c
        }
        let parts = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == (isRGBA ? 4 : 3) else { return nil }
        guard let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else { return nil }
        let a = isRGBA ? Double(parts[3]) : 1
        guard let alpha = a else { return nil }
        return RGBA(r: r / 255, g: g / 255, b: b / 255, a: alpha)
    }
}
