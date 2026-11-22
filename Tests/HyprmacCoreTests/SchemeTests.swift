import Testing
@testable import HyprmacCore

/// Same cases as the Windows shell's scheme (Scheme.cs): both must give the same colors.
@Suite struct SchemeTests {
    @Test func hslRoundTrip() {
        for (h, s, l) in [(0.0, 1.0, 0.5), (120, 0.5, 0.4), (215, 0.75, 0.8), (300, 0.3, 0.2)] {
            let (h2, s2, l2) = Scheme.toHSL(Scheme.hsl(h, s, l))
            #expect(abs(h2 - h) < 1.5 && abs(s2 - s) < 0.02 && abs(l2 - l) < 0.01)
        }
    }

    @Test func seedPicksDominantHue() {
        // 90% saturated blue, 10% red: blue wins, and it is colorful.
        var px: [UInt8] = []
        for i in 0..<100 { px += i < 90 ? [40, 90, 220, 255] : [220, 40, 40, 255] }
        let seed = Scheme.seed(rgba: px)!
        #expect(abs(seed.hue - 222) < 6)
        #expect(seed.chroma > 0.5)
    }

    @Test func greyImageGivesLowChroma() {
        let px = [UInt8](repeating: 128, count: 4 * 64)
        #expect(Scheme.seed(rgba: px)! == (215, 0.12))
    }

    @Test func resolve() {
        #expect(Scheme.resolve("auto", wallpaperSeed: nil) == .default)
        let purple = Scheme.resolve("rgb(cba6f7)", wallpaperSeed: nil)
        let (h, _, l) = Scheme.toHSL(purple.primary)
        #expect(abs(h - 267) < 3 && abs(l - 0.8) < 0.01)
        // Dark theme: surfaces are dark, text is light.
        #expect(Scheme.toHSL(purple.surface).l < 0.1 && Scheme.toHSL(purple.onSurface).l > 0.85)
        #expect(Scheme.resolve("auto", wallpaperSeed: (120, 1)).primary == Scheme.fromSeed(hue: 120).primary)
    }
}
