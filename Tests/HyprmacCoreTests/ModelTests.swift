import Testing
@testable import HyprmacCore

@Suite struct ModelTests {
    func model(monitors: Int = 1, layout: String = "dwindle") -> Model {
        var c = Config()
        c.gapsIn = Insets(all: 0)
        c.gapsOut = Insets(all: 0)
        c.layout = layout
        let m = Model(config: c)
        m.setMonitors((0..<monitors).map { i in
            (id: "m\(i)", name: "Display \(i)", frame: Rect(x: Double(i) * 1000, y: 0, w: 1000, h: 600))
        })
        return m
    }

    @Test func monitorsGetWorkspaces() {
        let m = model(monitors: 2)
        #expect(m.monitors.map(\.workspace) == [1, 2])
        // Unplug and replug keeps monitor 0's workspace.
        _ = try? m.dispatch("workspace", "5")
        m.setMonitors([(id: "m0", name: "a", frame: Rect(x: 0, y: 0, w: 1000, h: 600))])
        #expect(m.monitors.map(\.workspace) == [5])
    }

    @Test func tilingAndWorkspaceSwitch() throws {
        let m = model()
        m.addWindow(1, floating: false)
        m.setFocused(1)
        m.addWindow(2, floating: false)
        m.setFocused(2)
        #expect(m.frames().count == 2)

        let fx = try m.dispatch("workspace", "2")
        #expect(fx == [.focusDesktop])
        #expect(m.currentWorkspace == 2)
        #expect(m.frames().isEmpty)
        #expect(!m.isVisible(1))

        let back = try m.dispatch("workspace", "previous")
        #expect(back == [.focus(2)])
        #expect(m.isVisible(1))
    }

    @Test func moveToWorkspaceFollowsAndSilentStays() throws {
        let m = model()
        m.addWindow(1, floating: false); m.setFocused(1)
        m.addWindow(2, floating: false); m.setFocused(2)

        #expect(try m.dispatch("movetoworkspacesilent", "3") == [.focus(1)])
        #expect(m.windowWorkspace[2] == 3)
        #expect(m.currentWorkspace == 1)

        #expect(try m.dispatch("movetoworkspace", "3") == [.focus(1)])
        #expect(m.currentWorkspace == 3)
        #expect(m.frames()[1]?.w == 500)
    }

    @Test func focusOnHiddenWorkspaceSwitchesToIt() throws {
        let m = model()
        m.addWindow(1, floating: false)
        _ = try m.dispatch("workspace", "2")
        #expect(m.setFocused(1))  // Cmd-Tab to a window on workspace 1
        #expect(m.currentWorkspace == 1)
    }

    @Test func closingFocusedPicksNext() {
        let m = model()
        m.addWindow(1, floating: false); m.setFocused(1)
        m.addWindow(2, floating: false); m.setFocused(2)
        #expect(m.removeWindow(2) == [.focus(1)])
        #expect(m.removeWindow(1) == [.focusDesktop])
        #expect(m.focused == nil)
    }

    @Test func directionalFocusAndMove() throws {
        let m = model()
        m.addWindow(1, floating: false); m.setFocused(1)
        m.addWindow(2, floating: false); m.setFocused(2)
        #expect(try m.dispatch("movefocus", "l") == [.focus(1)])
        #expect(try m.dispatch("movefocus", "l") == [])
        _ = try m.dispatch("movewindow", "r")
        #expect(m.frames()[1]?.x == 500)
        #expect(m.focused == 1)
    }

    @Test func movefocusCrossesMonitors() throws {
        let m = model(monitors: 2)
        m.addWindow(1, floating: false, monitor: 0); m.setFocused(1)
        m.addWindow(2, floating: false, monitor: 1)
        #expect(try m.dispatch("movefocus", "r") == [.focus(2)])
        #expect(m.focusedMonitor == 1)
        #expect(try m.dispatch("workspace", "1") == [.focus(1)])
        #expect(m.focusedMonitor == 0)
    }

    @Test func movewindowToOtherMonitor() throws {
        let m = model(monitors: 2)
        m.addWindow(1, floating: false, monitor: 0); m.setFocused(1)
        #expect(try m.dispatch("movewindow", "r") == [.focus(1)])
        #expect(m.windowWorkspace[1] == 2)
        #expect(m.frames()[1]?.x == 1000)
    }

    @Test func floatingAndFullscreen() throws {
        let m = model()
        m.addWindow(1, floating: false); m.setFocused(1)
        m.addWindow(2, floating: false); m.setFocused(2)
        #expect(try m.dispatch("togglefloating", "") == [.center(2)])
        #expect(m.frames()[1] == Rect(x: 0, y: 0, w: 1000, h: 600))
        #expect(m.frames()[2] == nil)
        _ = try m.dispatch("togglefloating", "")
        #expect(m.frames().count == 2)
        _ = try m.dispatch("fullscreen", "")
        #expect(m.frames()[2] == Rect(x: 0, y: 0, w: 1000, h: 600))
    }

    @Test func masterLayoutMessages() throws {
        let m = model(layout: "master")
        for i in 1...3 { m.addWindow(WindowID(i), floating: false); m.setFocused(WindowID(i)) }
        #expect(m.frames()[1]?.x == 0)
        _ = try m.dispatch("layoutmsg", "swapwithmaster")
        #expect(m.frames()[3]?.x == 0)
        _ = try m.dispatch("layoutmsg", "mfact exact 0.7")
        #expect(m.frames()[3]?.w == 700)
        _ = try m.dispatch("splitratio", "-0.2")
        #expect(m.frames()[3]?.w == 600)
    }

    @Test func workspaceArgs() throws {
        let m = model()
        #expect(try m.resolveWorkspace("4") == 4)
        #expect(try m.resolveWorkspace("+1") == 2)
        #expect(try m.resolveWorkspace("-1") == 1)
        m.addWindow(1, floating: false, workspace: 6)
        #expect(try m.resolveWorkspace("e+1") == 6)
        #expect(try m.resolveWorkspace("empty") == 2)
        #expect(throws: DispatchError.self) { try m.resolveWorkspace("name:web") }
        #expect(throws: DispatchError.self) { try m.dispatch("frob", "") }
    }

    @Test func cycleNext() throws {
        let m = model()
        for i in 1...3 { m.addWindow(WindowID(i), floating: false) }
        m.setFocused(3)
        #expect(try m.dispatch("cyclenext", "") == [.focus(1)])
        #expect(try m.dispatch("cyclenext", "prev") == [.focus(3)])
    }
}
