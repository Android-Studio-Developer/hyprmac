import Foundation

/// Dark color scheme in Material 3 roles, generated from one seed hue (taken from the
/// wallpaper, or given). Same math as the Windows shell (windows/src/Hyprwin.Shell/Scheme.cs).
public struct Scheme: Equatable, Sendable {
    public var primary, onPrimary, primaryContainer, onPrimaryContainer: RGBA
    public var secondary, secondaryContainer, onSecondaryContainer, tertiary: RGBA
    public var surface, surfaceContainerLow, surfaceContainer, surfaceContainerHigh, surfaceContainerHighest: RGBA
    public var onSurface, onSurfaceVariant, outline, error: RGBA

    /// chroma: 0 = grey wallpaper, 1 = colorful. Scales every saturation.
    public static func fromSeed(hue: Double, chroma: Double = 1) -> Scheme {
        func c(_ h: Double, _ s: Double, _ l: Double) -> RGBA {
            hsl((h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360),
                min(max(s * chroma, 0), 1), l)
        }
        return Scheme(
            primary: c(hue, 0.75, 0.80), onPrimary: c(hue, 0.70, 0.18),
            primaryContainer: c(hue, 0.55, 0.28), onPrimaryContainer: c(hue, 0.85, 0.90),
            secondary: c(hue, 0.30, 0.78), secondaryContainer: c(hue, 0.22, 0.27),
            onSecondaryContainer: c(hue, 0.35, 0.88), tertiary: c(hue + 60, 0.50, 0.78),
            surface: c(hue, 0.16, 0.065), surfaceContainerLow: c(hue, 0.14, 0.09),
            surfaceContainer: c(hue, 0.13, 0.115), surfaceContainerHigh: c(hue, 0.12, 0.155),
            surfaceContainerHighest: c(hue, 0.11, 0.20),
            onSurface: c(hue, 0.20, 0.90), onSurfaceVariant: c(hue, 0.12, 0.78),
            outline: c(hue, 0.08, 0.55), error: hsl(0, 0.90 * max(0.6, chroma), 0.78))
    }

    public static let `default` = fromSeed(hue: 215)

    /// `setting` is "auto" (use `wallpaperSeed`) or a Hyprland color like rgb(89b4fa).
    public static func resolve(_ setting: String, wallpaperSeed: (hue: Double, chroma: Double)?) -> Scheme {
        if setting != "auto", let bc = BorderColor.parse(setting), let c = bc.colors.first {
            let (h, s, _) = toHSL(c)
            return fromSeed(hue: h, chroma: min(max(s * 1.4, 0.15), 1))
        }
        if let seed = wallpaperSeed { return fromSeed(hue: seed.hue, chroma: seed.chroma) }
        return .default
    }

    /// Dominant hue of an image given as RGBA bytes (any size; a ~96 px thumbnail is plenty),
    /// weighted by saturation and brightness.
    public static func seed(rgba px: [UInt8]) -> (hue: Double, chroma: Double)? {
        var bins = [Double](repeating: 0, count: 36)
        var sinSum = bins, cosSum = bins
        var colorful = 0.0, total = 0.0
        var i = 0
        while i + 3 < px.count {
            let (hue, sat, light) = toHSL(RGBA(r: Double(px[i]) / 255, g: Double(px[i + 1]) / 255, b: Double(px[i + 2]) / 255))
            i += 4
            total += 1
            if light < 0.12 || light > 0.92 || sat < 0.18 { continue }
            let weight = sat * (1 - abs(light - 0.5) * 1.4)
            if weight <= 0 { continue }
            colorful += weight
            let b = Int(hue / 10) % 36
            bins[b] += weight
            sinSum[b] += sin(hue * .pi / 180) * weight
            cosSum[b] += cos(hue * .pi / 180) * weight
        }
        guard total > 0 else { return nil }
        // Smooth over neighbours so a hue split across two bins still wins.
        var best = 0
        var bestScore = -1.0
        for b in 0..<36 {
            let score = bins[b] + 0.5 * (bins[(b + 35) % 36] + bins[(b + 1) % 36])
            if score > bestScore { bestScore = score; best = b }
        }
        let chroma = min(max(colorful / total * 3, 0.12), 1)
        if bins[best] <= 0 { return (215, 0.12) }
        let hue = atan2(sinSum[best], cosSum[best]) * 180 / .pi
        return ((hue + 360).truncatingRemainder(dividingBy: 360), chroma)
    }

    public static func hsl(_ h: Double, _ s: Double, _ l: Double) -> RGBA {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h.truncatingRemainder(dividingBy: 360) {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        func q(_ v: Double) -> Double { (min(max(v, 0), 1) * 255).rounded() / 255 }
        return RGBA(r: q(r + m), g: q(g + m), b: q(b + m))
    }

    public static func toHSL(_ c: RGBA) -> (h: Double, s: Double, l: Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        let l = (mx + mn) / 2, d = mx - mn
        if d < 1e-6 { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if mx == c.r { h = 60 * ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == c.g { h = 60 * ((c.b - c.r) / d + 2) }
        else { h = 60 * ((c.r - c.g) / d + 4) }
        h = (h + 360).truncatingRemainder(dividingBy: 360)
        return (h, s, l)
    }
}
