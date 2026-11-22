import Foundation

public final class Workspace {
    public let id: Int
    public let tree = DwindleTree()
    /// Tiled windows in master-layout order (index 0 = master).
    public internal(set) var order: [WindowID] = []
    public internal(set) var floating: [WindowID] = []
    public internal(set) var fullscreen: WindowID?
    public internal(set) var lastFocused: WindowID?
    /// Monitor index this workspace was last shown on.
    public internal(set) var lastMonitor: Int?

    init(id: Int) { self.id = id }

    public var all: [WindowID] { order + floating }
    public var isEmpty: Bool { order.isEmpty && floating.isEmpty }
    public func isFloating(_ id: WindowID) -> Bool { floating.contains(id) }
}

public struct Monitor: Equatable, Sendable {
    public var id: String
    public var name: String
    /// Usable area (menu bar and Dock excluded), top-left origin coordinates.
    public var frame: Rect
    public var workspace: Int

    public init(id: String, name: String, frame: Rect, workspace: Int) {
        self.id = id
        self.name = name
        self.frame = frame
        self.workspace = workspace
    }
}

/// Side effects the platform layer must perform after a dispatch.
public enum Effect: Equatable, Sendable {
    case exec(String)
    case close(WindowID)
    case focus(WindowID)
    /// Nothing to focus on the new workspace: focus the desktop so keys don't go to a hidden window.
    case focusDesktop
    case center(WindowID)
    /// Move/resize a floating window: by (x, y), or to (x, y) when `exact`.
    case moveWindow(WindowID, x: Double, y: Double, exact: Bool)
    case resizeWindow(WindowID, x: Double, y: Double, exact: Bool)
    case reload
    case quit
}

public struct DispatchError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Platform-independent window manager state: workspaces, monitors, layout and focus.
/// The macOS (and later Windows) layer feeds it window events and applies its frames.
public final class Model {
    public var config: Config
    public private(set) var monitors: [Monitor] = []
    public private(set) var workspaces: [Int: Workspace] = [:]
    public private(set) var windowWorkspace: [WindowID: Int] = [:]
    public private(set) var focused: WindowID?
    public private(set) var focusedMonitor = 0
    public private(set) var previousWorkspace: Int?

    public init(config: Config) {
        self.config = config
    }

    // MARK: Monitors and workspaces

    /// Replaces the monitor list. Monitors keep their workspace when their id is unchanged.
    public func setMonitors(_ list: [(id: String, name: String, frame: Rect)]) {
        let old = monitors
        // Pass 1: monitors that already existed keep their workspace.
        var assigned: [Int?] = list.map { m in old.first(where: { $0.id == m.id })?.workspace }
        var used = Set(assigned.compactMap { $0 })
        // Pass 2: new monitors get workspace i+1, or the next free one.
        for i in assigned.indices where assigned[i] == nil {
            var ws = i + 1
            while used.contains(ws) { ws += 1 }
            assigned[i] = ws
            used.insert(ws)
        }
        monitors = list.enumerated().map { i, m in
            Monitor(id: m.id, name: m.name, frame: m.frame, workspace: assigned[i]!)
        }
        for (i, m) in monitors.enumerated() { workspace(m.workspace).lastMonitor = i }
        if focusedMonitor >= monitors.count { focusedMonitor = 0 }
    }

    @discardableResult
    public func workspace(_ id: Int) -> Workspace {
        if let ws = workspaces[id] { return ws }
        let ws = Workspace(id: id)
        workspaces[id] = ws
        return ws
    }

    public var currentWorkspace: Int { monitors.isEmpty ? 1 : monitors[focusedMonitor].workspace }

    public func monitorIndex(showing ws: Int) -> Int? { monitors.firstIndex { $0.workspace == ws } }

    public func isVisible(_ id: WindowID) -> Bool {
        guard let ws = windowWorkspace[id] else { return false }
        return monitorIndex(showing: ws) != nil
    }

    public func isFloating(_ id: WindowID) -> Bool {
        guard let ws = windowWorkspace[id] else { return false }
        return workspaces[ws]?.isFloating(id) ?? false
    }

    public func tileArea(monitor m: Int) -> Rect { monitors[m].frame.inset(config.gapsOut) }

    private func show(_ wsID: Int, on m: Int) {
        guard m < monitors.count else { return }
        if monitors[m].workspace != wsID {
            previousWorkspace = monitors[m].workspace
            monitors[m].workspace = wsID
        }
        workspace(wsID).lastMonitor = m
        focusedMonitor = m
    }

    private func focusTarget(_ ws: Workspace) -> WindowID? {
        if let f = ws.lastFocused, ws.all.contains(f) { return f }
        return ws.fullscreen ?? ws.order.first ?? ws.floating.first
    }

    /// Focus the best window on the focused monitor's workspace.
    private func focusCurrent() -> [Effect] {
        let ws = workspace(currentWorkspace)
        if let t = focusTarget(ws) {
            focused = t
            ws.lastFocused = t
            return [.focus(t)]
        }
        focused = nil
        return [.focusDesktop]
    }

    // MARK: Windows

    /// Adds a window. `workspace` wins over `monitor`; otherwise the focused monitor's workspace.
    public func addWindow(_ id: WindowID, floating: Bool, workspace wsID: Int? = nil, monitor: Int? = nil) {
        guard windowWorkspace[id] == nil else { return }
        let target = wsID ?? monitor.flatMap { $0 < monitors.count ? monitors[$0].workspace : nil } ?? currentWorkspace
        let ws = workspace(target)
        windowWorkspace[id] = target
        if floating { ws.floating.append(id) } else { tile(id, in: ws) }
    }

    /// Removes a window. Returns effects to keep focus on the current workspace.
    @discardableResult
    public func removeWindow(_ id: WindowID) -> [Effect] {
        guard let wsID = windowWorkspace[id], let ws = workspaces[wsID] else { return [] }
        detach(id, from: ws)
        windowWorkspace[id] = nil
        guard focused == id else { return [] }
        focused = nil
        if monitorIndex(showing: wsID) != nil, let t = focusTarget(ws) {
            focused = t
            ws.lastFocused = t
            return [.focus(t)]
        }
        return monitorIndex(showing: wsID) != nil ? [.focusDesktop] : []
    }

    /// Called when the OS reports a focus change. Returns true when this switched workspace
    /// (the user activated a window that lives on a hidden workspace, e.g. with Cmd-Tab).
    @discardableResult
    public func setFocused(_ id: WindowID?) -> Bool {
        guard let id, let wsID = windowWorkspace[id], let ws = workspaces[wsID] else { return false }
        focused = id
        ws.lastFocused = id
        if let m = monitorIndex(showing: wsID) {
            focusedMonitor = m
            return false
        }
        let m = ws.lastMonitor.flatMap { $0 < monitors.count ? $0 : nil } ?? focusedMonitor
        show(wsID, on: m)
        return true
    }

    private func tile(_ id: WindowID, in ws: Workspace) {
        let m = monitorIndex(showing: ws.id) ?? ws.lastMonitor.flatMap { $0 < monitors.count ? $0 : nil } ?? focusedMonitor
        let area = monitors.isEmpty ? Rect(x: 0, y: 0, w: 1600, h: 1000) : tileArea(monitor: m)
        let target = ws.lastFocused.flatMap { ws.order.contains($0) ? $0 : nil }
        ws.tree.insert(id, splitting: target, area: area, settings: config.dwindle)
        switch config.newStatus {
        case "master": ws.order.insert(id, at: 0)
        default:
            if config.newOnTop, !ws.order.isEmpty { ws.order.insert(id, at: 1) } else { ws.order.append(id) }
        }
    }

    private func detach(_ id: WindowID, from ws: Workspace) {
        ws.tree.remove(id)
        ws.order.removeAll { $0 == id }
        ws.floating.removeAll { $0 == id }
        if ws.fullscreen == id { ws.fullscreen = nil }
        if ws.lastFocused == id { ws.lastFocused = nil }
    }

    private func moveWindow(_ id: WindowID, to target: Int) {
        guard let from = windowWorkspace[id], from != target, let old = workspaces[from] else { return }
        let wasFloating = old.isFloating(id)
        detach(id, from: old)
        let ws = workspace(target)
        windowWorkspace[id] = target
        if wasFloating { ws.floating.append(id) } else { tile(id, in: ws) }
        ws.lastFocused = id
    }

    // MARK: Layout

    /// Target frames for tiled windows on visible workspaces (gaps applied, borders not).
    public func frames() -> [WindowID: Rect] {
        var out: [WindowID: Rect] = [:]
        for (i, _) in monitors.enumerated() {
            out.merge(frames(workspace: monitors[i].workspace, monitor: i)) { a, _ in a }
        }
        return out
    }

    /// Frames for one workspace as if shown on monitor `m`.
    public func frames(workspace wsID: Int, monitor m: Int) -> [WindowID: Rect] {
        guard m < monitors.count, let ws = workspaces[wsID] else { return [:] }
        let area = tileArea(monitor: m)
        let boxes = config.layout == "master"
            ? MasterLayout.boxes(order: ws.order, area: area, mfact: config.mfact, orientation: config.orientation)
            : ws.tree.boxes(in: area, settings: config.dwindle)
        var out = applyInnerGaps(boxes, area: area, gapsIn: config.gapsIn)
        if let fs = ws.fullscreen { out[fs] = monitors[m].frame }
        return out
    }

    // MARK: Dispatchers

    /// Runs a Hyprland dispatcher. `floatingFrames` gives current frames of floating windows
    /// (owned by the platform layer) so directional focus can reach them.
    public func dispatch(_ name: String, _ arg: String, floatingFrames: [WindowID: Rect] = [:]) throws -> [Effect] {
        let arg = arg.trimmingCharacters(in: .whitespaces)
        switch name.lowercased() {
        case "exec":
            guard !arg.isEmpty else { throw DispatchError("exec needs a command") }
            return [.exec(arg)]

        case "exit":
            return [.quit]

        case "killactive", "closewindow":
            guard let f = focused else { return [] }
            return [.close(f)]

        case "workspace":
            if arg == "previous" && previousWorkspace == nil { return [] }
            let n = try resolveWorkspace(arg)
            if n == currentWorkspace { return [] }
            if let m = monitorIndex(showing: n) { focusedMonitor = m } else { show(n, on: focusedMonitor) }
            return focusCurrent()

        case "movetoworkspace", "movetoworkspacesilent":
            let wsArg = String(arg.split(separator: ",").first ?? "")
            let n = try resolveWorkspace(wsArg)
            guard let id = focused else { return [] }
            moveWindow(id, to: n)
            if name.lowercased() == "movetoworkspacesilent" {
                return focusCurrent()
            }
            if let m = monitorIndex(showing: n) { focusedMonitor = m } else { show(n, on: focusedMonitor) }
            focused = id
            return [.focus(id)]

        case "togglefloating", "setfloating", "settiled":
            guard let id = focused, let ws = windowWorkspace[id].flatMap({ workspaces[$0] }) else { return [] }
            let floating = ws.isFloating(id)
            let wantFloating = name == "setfloating" ? true : name == "settiled" ? false : !floating
            guard wantFloating != floating else { return [] }
            detach(id, from: ws)
            if wantFloating { ws.floating.append(id) } else { tile(id, in: ws) }
            ws.lastFocused = id
            return wantFloating ? [.center(id)] : []

        case "fullscreen":
            guard let id = focused, let ws = windowWorkspace[id].flatMap({ workspaces[$0] }) else { return [] }
            ws.fullscreen = ws.fullscreen == id ? nil : id
            return []

        case "movefocus":
            guard let dir = Direction(arg: arg) else { throw DispatchError("movefocus needs l, r, u or d") }
            return moveFocus(dir, floatingFrames: floatingFrames)

        case "movewindow", "swapwindow":
            guard let dir = Direction(arg: arg) else { throw DispatchError("\(name) needs l, r, u or d") }
            return moveFocused(dir, allowMonitor: name == "movewindow")

        case "togglesplit":
            toggleSplit()
            return []

        case "splitratio":
            try splitRatio(arg)
            return []

        case "layoutmsg":
            return try layoutMsg(arg)

        case "focusmonitor":
            guard !monitors.isEmpty else { return [] }
            let m: Int?
            if let dir = Direction(arg: arg) {
                var frames: [Int: Rect] = [:]
                for (i, mon) in monitors.enumerated() where i != focusedMonitor { frames[i] = mon.frame }
                m = neighbor(of: monitors[focusedMonitor].frame, direction: dir, among: frames)
            } else if arg.hasPrefix("+") || arg.hasPrefix("-"), let d = Int(arg) {
                m = ((focusedMonitor + d) % monitors.count + monitors.count) % monitors.count
            } else if let i = Int(arg), i >= 0, i < monitors.count {
                m = i
            } else if let i = monitors.firstIndex(where: { $0.name == arg || $0.id == arg }) {
                m = i
            } else {
                throw DispatchError("unknown monitor \(arg)")
            }
            guard let m, m != focusedMonitor else { return [] }
            focusedMonitor = m
            return focusCurrent()

        case "cyclenext":
            let ws = workspace(currentWorkspace)
            let list = ws.all
            guard !list.isEmpty else { return [] }
            let back = arg.lowercased().contains("prev")
            let idx = focused.flatMap { list.firstIndex(of: $0) } ?? (back ? 0 : list.count - 1)
            let next = list[((idx + (back ? -1 : 1)) % list.count + list.count) % list.count]
            focused = next
            ws.lastFocused = next
            return [.focus(next)]

        case "centerwindow":
            guard let id = focused, isFloating(id) else { return [] }
            return [.center(id)]

        case "moveactive", "resizeactive":
            // Hyprland: "[exact] X Y". Only floating windows; tiled ones keep their tile.
            var parts = arg.split(separator: " ").map(String.init)
            let exact = parts.first == "exact"
            if exact { parts.removeFirst() }
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                throw DispatchError("\(name) needs [exact] X Y")
            }
            guard let id = focused, isFloating(id) else { return [] }
            return name == "moveactive"
                ? [.moveWindow(id, x: x, y: y, exact: exact)]
                : [.resizeWindow(id, x: x, y: y, exact: exact)]

        default:
            if Dispatchers.unsupported.contains(name) { throw DispatchError("\(name) is not supported on macOS yet") }
            throw DispatchError("unknown dispatcher \(name)")
        }
    }

    func resolveWorkspace(_ arg: String) throws -> Int {
        let a = arg.trimmingCharacters(in: .whitespaces)
        if let n = Int(a), n > 0, !a.hasPrefix("+") { return n }
        if a == "previous" {
            guard let p = previousWorkspace else { throw DispatchError("no previous workspace") }
            return p
        }
        if a == "empty" {
            var n = 1
            while !(workspaces[n]?.isEmpty ?? true) || monitorIndex(showing: n) != nil { n += 1 }
            return n
        }
        var rel = a
        var existingOnly = false
        if rel.hasPrefix("e") || rel.hasPrefix("m") {
            existingOnly = true
            rel.removeFirst()
        } else if rel.hasPrefix("r") {
            rel.removeFirst()
        }
        if rel.hasPrefix("+") || rel.hasPrefix("-"), let d = Int(rel) {
            if existingOnly {
                var ids = workspaces.values.filter { !$0.isEmpty }.map(\.id)
                if !ids.contains(currentWorkspace) { ids.append(currentWorkspace) }
                ids.sort()
                let i = ids.firstIndex(of: currentWorkspace)!
                return ids[((i + d) % ids.count + ids.count) % ids.count]
            }
            return max(1, currentWorkspace + d)
        }
        throw DispatchError("bad workspace \(arg)")
    }

    private func visibleFrames(floatingFrames: [WindowID: Rect]) -> [WindowID: Rect] {
        var out = frames()
        for (id, r) in floatingFrames where isVisible(id) { out[id] = r }
        return out
    }

    private func moveFocus(_ dir: Direction, floatingFrames: [WindowID: Rect]) -> [Effect] {
        let all = visibleFrames(floatingFrames: floatingFrames)
        guard let f = focused, let from = all[f] else { return focusCurrent() }
        let mon = focusedMonitor
        var candidates = all.filter { $0.key != f && windowWorkspace[$0.key] == monitors[mon].workspace }
        if let fs = workspaces[monitors[mon].workspace]?.fullscreen, fs != f { candidates = [:] }
        if let n = neighbor(of: from, direction: dir, among: candidates) {
            focused = n
            workspace(monitors[mon].workspace).lastFocused = n
            return [.focus(n)]
        }
        var monFrames: [Int: Rect] = [:]
        for (i, m) in monitors.enumerated() where i != mon { monFrames[i] = m.frame }
        guard let m = neighbor(of: monitors[mon].frame, direction: dir, among: monFrames) else { return [] }
        focusedMonitor = m
        return focusCurrent()
    }

    private func moveFocused(_ dir: Direction, allowMonitor: Bool) -> [Effect] {
        guard let id = focused, let wsID = windowWorkspace[id], let ws = workspaces[wsID],
              !ws.isFloating(id), let mon = monitorIndex(showing: wsID) else { return [] }
        let tiled = frames(workspace: wsID, monitor: mon)
        if let from = tiled[id],
           let other = neighbor(of: from, direction: dir, among: tiled.filter { $0.key != id }) {
            ws.tree.swap(id, other)
            if let i = ws.order.firstIndex(of: id), let j = ws.order.firstIndex(of: other) {
                ws.order.swapAt(i, j)
            }
            return []
        }
        guard allowMonitor else { return [] }
        var monFrames: [Int: Rect] = [:]
        for (i, m) in monitors.enumerated() where i != mon { monFrames[i] = m.frame }
        guard let m = neighbor(of: monitors[mon].frame, direction: dir, among: monFrames) else { return [] }
        moveWindow(id, to: monitors[m].workspace)
        focusedMonitor = m
        focused = id
        return [.focus(id)]
    }

    private func toggleSplit() {
        guard let id = focused, let wsID = windowWorkspace[id], let ws = workspaces[wsID] else { return }
        let m = monitorIndex(showing: wsID) ?? focusedMonitor
        guard m < monitors.count else { return }
        ws.tree.toggleSplit(id, area: tileArea(monitor: m), settings: config.dwindle)
    }

    private func splitRatio(_ arg: String) throws {
        let parts = arg.split(separator: " ").map(String.init)
        var exact: Double?
        var delta: Double?
        if parts.first == "exact", parts.count == 2, let v = Double(parts[1]) {
            exact = v
        } else if parts.count == 1, let v = Double(parts[0]) {
            delta = v
        } else {
            throw DispatchError("splitratio needs a number or 'exact N'")
        }
        if config.layout == "master" {
            let v = exact.map { $0 / 2 } ?? config.mfact + (delta ?? 0) / 2
            config.mfact = min(0.95, max(0.05, v))
            return
        }
        guard let id = focused, let ws = windowWorkspace[id].flatMap({ workspaces[$0] }) else { return }
        ws.tree.changeRatio(id, delta: delta, exact: exact)
    }

    private func layoutMsg(_ arg: String) throws -> [Effect] {
        let parts = arg.split(separator: " ").map(String.init)
        guard let cmd = parts.first?.lowercased() else { throw DispatchError("layoutmsg needs a message") }
        switch cmd {
        case "togglesplit":
            toggleSplit()
        case "swapwithmaster":
            guard let id = focused, let ws = windowWorkspace[id].flatMap({ workspaces[$0] }),
                  let i = ws.order.firstIndex(of: id), i != 0 || ws.order.count > 1 else { return [] }
            let j = i == 0 ? 1 : 0
            let other = ws.order[j]
            ws.order.swapAt(i, j)
            ws.tree.swap(id, other)
        case "orientationleft", "orientationright", "orientationtop", "orientationbottom":
            config.orientation = String(cmd.dropFirst("orientation".count))
        case "mfact":
            let rest = parts.dropFirst().joined(separator: " ")
            let sub = rest.split(separator: " ").map(String.init)
            if sub.first == "exact", sub.count == 2, let v = Double(sub[1]) {
                config.mfact = min(0.95, max(0.05, v))
            } else if sub.count == 1, let v = Double(sub[0]) {
                config.mfact = min(0.95, max(0.05, config.mfact + v))
            } else {
                throw DispatchError("mfact needs a number or 'exact N'")
            }
        default:
            throw DispatchError("unknown layoutmsg \(cmd)")
        }
        return []
    }
}
