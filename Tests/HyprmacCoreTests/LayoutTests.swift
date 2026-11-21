import Testing
@testable import HyprmacCore

@Suite struct LayoutTests {
    let area = Rect(x: 0, y: 0, w: 1000, h: 600)
    let s = DwindleSettings()

    @Test func dwindleSplitsLikeHyprland() {
        let t = DwindleTree()
        t.insert(1, splitting: nil, area: area, settings: s)
        #expect(t.boxes(in: area, settings: s)[1] == area)

        t.insert(2, splitting: 1, area: area, settings: s)  // wide box: side by side
        var b = t.boxes(in: area, settings: s)
        #expect(b[1] == Rect(x: 0, y: 0, w: 500, h: 600))
        #expect(b[2] == Rect(x: 500, y: 0, w: 500, h: 600))

        t.insert(3, splitting: 2, area: area, settings: s)  // 500x600 is tall: stacked
        b = t.boxes(in: area, settings: s)
        #expect(b[2] == Rect(x: 500, y: 0, w: 500, h: 300))
        #expect(b[3] == Rect(x: 500, y: 300, w: 500, h: 300))
        #expect(t.windows == [1, 2, 3])
    }

    @Test func dwindleRemoveCollapses() {
        let t = DwindleTree()
        for i in 1...3 { t.insert(WindowID(i), splitting: WindowID(max(1, i - 1)), area: area, settings: s) }
        t.remove(2)
        let b = t.boxes(in: area, settings: s)
        #expect(b[3] == Rect(x: 500, y: 0, w: 500, h: 600))
        t.remove(1)
        #expect(t.boxes(in: area, settings: s)[3] == area)
        t.remove(3)
        #expect(t.isEmpty)
    }

    @Test func forceSplitPutsNewFirst() {
        let t = DwindleTree()
        let f = DwindleSettings(forceSplit: 1)
        t.insert(1, splitting: nil, area: area, settings: f)
        t.insert(2, splitting: 1, area: area, settings: f)
        #expect(t.boxes(in: area, settings: f)[2]?.x == 0)
    }

    @Test func toggleSplitAndRatio() {
        let t = DwindleTree()
        t.insert(1, splitting: nil, area: area, settings: s)
        t.insert(2, splitting: 1, area: area, settings: s)
        t.toggleSplit(2, area: area, settings: s)
        var b = t.boxes(in: area, settings: s)
        #expect(b[1] == Rect(x: 0, y: 0, w: 1000, h: 300))
        t.changeRatio(1, delta: 0.2)
        b = t.boxes(in: area, settings: s)
        #expect(b[1]?.h == 360)
        t.changeRatio(1, exact: 5)
        #expect(t.ratio(of: 1) == 1.9)
    }

    @Test func swapLeaves() {
        let t = DwindleTree()
        t.insert(1, splitting: nil, area: area, settings: s)
        t.insert(2, splitting: 1, area: area, settings: s)
        t.swap(1, 2)
        #expect(t.boxes(in: area, settings: s)[2]?.x == 0)
    }

    @Test func masterLayout() {
        let b = MasterLayout.boxes(order: [1, 2, 3], area: area, mfact: 0.6, orientation: "left")
        #expect(b[1] == Rect(x: 0, y: 0, w: 600, h: 600))
        #expect(b[2] == Rect(x: 600, y: 0, w: 400, h: 300))
        #expect(b[3] == Rect(x: 600, y: 300, w: 400, h: 300))
        let r = MasterLayout.boxes(order: [1, 2], area: area, mfact: 0.5, orientation: "right")
        #expect(r[1]?.x == 500)
        #expect(MasterLayout.boxes(order: [9], area: area, mfact: 0.5, orientation: "left")[9] == area)
    }

    @Test func innerGapsOnlyBetweenTiles() {
        let boxes: [WindowID: Rect] = [1: Rect(x: 0, y: 0, w: 500, h: 600), 2: Rect(x: 500, y: 0, w: 500, h: 600)]
        let g = applyInnerGaps(boxes, area: area, gapsIn: Insets(all: 5))
        #expect(g[1] == Rect(x: 0, y: 0, w: 495, h: 600))
        #expect(g[2] == Rect(x: 505, y: 0, w: 495, h: 600))
    }

    @Test func neighborSearch() {
        let r: [Int: Rect] = [
            1: Rect(x: 0, y: 0, w: 500, h: 600),
            2: Rect(x: 500, y: 0, w: 500, h: 300),
            3: Rect(x: 500, y: 300, w: 500, h: 300),
        ]
        #expect(neighbor(of: r[1]!, direction: .right, among: [2: r[2]!, 3: r[3]!]) != nil)
        #expect(neighbor(of: r[3]!, direction: .up, among: [1: r[1]!, 2: r[2]!]) == 2)
        #expect(neighbor(of: r[3]!, direction: .left, among: [1: r[1]!, 2: r[2]!]) == 1)
        #expect(neighbor(of: r[1]!, direction: .left, among: [2: r[2]!, 3: r[3]!]) == nil)
    }

    @Test func insetsCSS() {
        #expect(Insets(css: "5") == Insets(all: 5))
        #expect(Insets(css: "1,2,3,4") == Insets(top: 1, right: 2, bottom: 3, left: 4))
        #expect(Insets(css: "a") == nil)
    }
}
