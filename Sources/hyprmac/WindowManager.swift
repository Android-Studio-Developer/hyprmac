import AppKit
import ApplicationServices
import HyprLua
import HyprmacCore

final class ManagedWindow {
    let id: WindowID
    let pid: pid_t
    let element: AXUIElement
    let appElement: AXUIElement
    let appName: String
    let bundleID: String
    var title: String

    init(id: WindowID, pid: pid_t, element: AXUIElement, appElement: AXUIElement, appName: String, bundleID: String, title: String) {
        self.id = id
        self.pid = pid
        self.element = element
        self.appElement = appElement
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
    }
}

/// One AXObserver per app process.
final class AppWatcher {
    let pid: pid_t
    let app: AXUIElement
    private var observer: AXObserver?
    private let refcon: UnsafeMutableRawPointer

    init?(pid: pid_t, manager: WindowManager) {
        self.pid = pid
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        refcon = Unmanaged.passUnretained(manager).toOpaque()
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return nil }
        observer = obs
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    func watch(_ window: AXUIElement) {
        guard let observer else { return }
        for n in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowMovedNotification,
                  kAXWindowResizedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(observer, window, n as CFString, refcon)
        }
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
}

private func axCallback(_: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue().handleAX(element, notification as String)
}

final class WindowManager {
    let configPath: String
    private(set) var model: Model
    private var windows: [WindowID: ManagedWindow] = [:]
    private var watchers: [pid_t: AppWatcher] = [:]
    /// Last frame we set and when, to tell our own moves from the user's.
    private var lastSet: [WindowID: (rect: Rect, at: Date)] = [:]
    private var hidden: Set<WindowID> = []
    private var savedFloating: [WindowID: Rect] = [:]
    private let borders = Borders()
    private var hotkeys: Hotkeys!
    private var ipc: IPCServer?
    private var events: EventServer?
    private var statusBar: StatusBar?
    private var configStamps: [String: Date] = [:]
    private var hotkeyErrors: [String] = []
    /// Binds not registered because they need Linux-only programs (e.g. grim, rofi -dmenu).
    private(set) var skippedBinds: [String] = []
    private var suppressFocusUntil = Date.distantPast
    private var relayoutScheduled = false
    private var timers: [Timer] = []
    private var children: Set<Process> = []
    private var initialScan = true
    private var lastEvent = (workspace: 0, window: WindowID?.none, monitor: -1)
    private var lastWindowWorkspace: [WindowID: Int] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(configPath: String) {
        self.configPath = configPath
        model = Model(config: Config())
    }

    // MARK: Lifecycle

    func start() {
        let shims = MacCompat.installShims()
        if !shims.isEmpty { log("Linux stand-ins: \(shims.joined(separator: " "))") }
        LuaConfig.host = { [weak self] op, arg in self?.luaHost(op, arg) }
        Rice.onApplied = { [weak self] in self?.reload() }
        model.config = loadConfig()
        updateMonitors()
        hotkeys = Hotkeys { [weak self] bind in self?.run(bind.dispatcher, bind.arg) }
        registerHotkeys()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.track(app)
            for delay in [0.3, 1.0, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.scanApp(app.processIdentifier) }
            }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.forget(pid: app.processIdentifier)
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshFocus()
        }
        ws.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.removeWindows(pid: app.processIdentifier)
        }
        ws.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.scanApp(app.processIdentifier)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateMonitors()
            self?.apply()
        }

        scanAll()
        initialScan = false
        refreshFocus()
        apply()

        let uid = getuid()
        mkdir(HyprmacInfo.runtimeDir(uid: uid), 0o700)
        ipc = IPCServer(path: HyprmacInfo.socketPath(uid: uid)) { [weak self] req in self?.handleRequest(req) ?? "not running" }
        if ipc?.start() != true { log("cannot open control socket \(HyprmacInfo.socketPath(uid: uid))") }
        events = EventServer(path: HyprmacInfo.eventSocketPath(uid: uid))
        if events?.start() != true { log("cannot open event socket") }

        if model.config.statusBar {
            statusBar = StatusBar(manager: self)
        }

        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkConfigChanged() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.scanAll()
            self?.apply()
        })

        for cmd in model.config.execOnce + model.config.exec { spawn(cmd) }
        LuaConfig.emit("hyprland.start")
        updateUI()
        log("hyprmac \(HyprmacInfo.version) running: \(windows.count) windows, \(model.monitors.count) monitor(s)")
    }

    /// Put every window back on screen and exit.
    func shutdown() {
        for t in timers { t.invalidate() }
        for id in hidden {
            guard let w = windows[id], let wsID = model.windowWorkspace[id] else { continue }
            if let saved = savedFloating[id] {
                w.element.setFrame(saved)
            } else {
                let m = model.workspaces[wsID]?.lastMonitor.flatMap { $0 < model.monitors.count ? $0 : nil } ?? 0
                if let r = model.frames(workspace: wsID, monitor: m)[id] {
                    w.element.setFrame(r.inset(by: model.config.borderSize))
                }
            }
        }
        borders.removeAll()
        ipc?.stop()
        events?.stop()
        exit(0)
    }

    // MARK: Config

    private func loadConfig() -> Config {
        LuaConfig.reset()
        let c = ConfigParser.load(path: configPath)
        configStamps = [:]
        for f in c.files { configStamps[f] = mtime(f) }
        for e in c.errors { log("config: \(e)") }
        return c
    }

    private func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func checkConfigChanged() {
        if configStamps.contains(where: { mtime($0.key) != $0.value }) { reload() }
    }

    func reload() {
        MacCompat.installShims()  // programs may have been installed since start
        let c = loadConfig()
        model.config = c
        registerHotkeys()
        lastSet.removeAll()
        if c.statusBar, statusBar == nil { statusBar = StatusBar(manager: self) }
        if !c.statusBar { statusBar?.remove(); statusBar = nil }
        for cmd in c.exec { spawn(cmd) }
        apply()
        LuaConfig.emit("config.reloaded")
        events?.emit("configreloaded", "")
        log("config reloaded (\(c.errors.count) error(s))")
    }

    private func registerHotkeys() {
        let (usable, skipped) = WindowManager.splitBinds(model.config.binds)
        skippedBinds = skipped
        hotkeyErrors = hotkeys.register(usable, superMapsTo: model.config.superMapsTo)
        for e in hotkeyErrors { log(e) }
        if !skipped.isEmpty { log("\(skipped.count) bind(s) skipped: they need Linux-only programs") }
    }

    /// Exec binds whose programs are missing are left unregistered, so a rice's
    /// `bind = , Delete, exec, grim ...` doesn't steal the Delete key on a Mac.
    static func splitBinds(_ binds: [KeyBind]) -> (usable: [KeyBind], skipped: [String]) {
        var usable: [KeyBind] = []
        var skipped: [String] = []
        for b in binds {
            let command = b.dispatcher == "exec" ? b.arg : b.dispatcher == "lua" ? LuaConfig.storedCommand(b.arg) : nil
            if let command {
                let missing = MacCompat.missing(in: command)
                if !missing.isEmpty {
                    let combo = (b.mods.names + [b.key]).joined(separator: "+")
                    skipped.append("\(combo): needs \(missing.joined(separator: ", "))")
                    continue
                }
            }
            usable.append(b)
        }
        return (usable, skipped)
    }

    var configErrors: [String] { model.config.errors + hotkeyErrors }

    /// Calls from Lua configs (hl.dispatch, hl.exec_cmd, hl.get_active_window, ...).
    private func luaHost(_ op: String, _ arg: String) -> String? {
        switch op {
        case "exec":
            spawn(arg)
            return nil
        case "dispatch":
            let parts = arg.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return run(parts[0], parts.count > 1 ? parts[1] : "")
        case "activewindow":
            guard let id = model.focused, let w = windows[id] else { return nil }
            let f = w.element.frame ?? Rect(x: 0, y: 0, w: 0, h: 0)
            return LuaConfig.table(["address": hex(id), "class": w.appName, "title": w.title,
                                    "floating": model.isFloating(id), "workspace": model.windowWorkspace[id] ?? 0,
                                    "x": Int(f.x), "y": Int(f.y), "width": Int(f.w), "height": Int(f.h)])
        case "activemonitor":
            guard model.focusedMonitor < model.monitors.count else { return nil }
            let m = model.monitors[model.focusedMonitor]
            return LuaConfig.table(["name": m.name, "id": model.focusedMonitor, "x": Int(m.frame.x), "y": Int(m.frame.y),
                                    "width": Int(m.frame.w), "height": Int(m.frame.h), "workspace": m.workspace])
        case "activeworkspace":
            return LuaConfig.table(["id": model.currentWorkspace, "name": String(model.currentWorkspace)])
        case "log":
            log("lua: \(arg)")
            return nil
        default:
            return nil
        }
    }

    // MARK: Discovery

    private func updateMonitors() {
        let list = NSScreen.screens.map { s -> (id: String, name: String, frame: Rect) in
            let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? s.localizedName
            return (id: num, name: s.localizedName, frame: Coords.ax(s.visibleFrame))
        }
        model.setMonitors(list)
    }

    private func track(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ownPID, app.activationPolicy == .regular, watchers[pid] == nil else { return }
        watchers[pid] = AppWatcher(pid: pid, manager: self)
    }

    func scanAll() {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
        let pids = Set(running.map(\.processIdentifier))
        for pid in watchers.keys where !pids.contains(pid) { forget(pid: pid) }
        for app in running {
            track(app)
            scanApp(app.processIdentifier)
        }
    }

    func scanApp(_ pid: pid_t) {
        guard let watcher = watchers[pid] else {
            if let app = NSRunningApplication(processIdentifier: pid) { track(app) }
            if watchers[pid] != nil { scanApp(pid) }
            return
        }
        if NSRunningApplication(processIdentifier: pid)?.isHidden == true {
            removeWindows(pid: pid)
            return
        }
        let elements = watcher.app.elements(kAXWindowsAttribute)
        var seen = Set<WindowID>()
        for el in elements {
            if let id = considerWindow(el, pid: pid) { seen.insert(id) }
        }
        // Windows that vanished, got minimized or went native-fullscreen.
        for (id, w) in windows where w.pid == pid && !seen.contains(id) { removeWindow(id) }
    }

    /// Adds `el` if it is a manageable window. Returns its id when managed (new or known).
    @discardableResult
    private func considerWindow(_ el: AXUIElement, pid: pid_t) -> WindowID? {
        guard let id = el.windowID else { return nil }
        let minimized = el.bool(kAXMinimizedAttribute) ?? false
        let nativeFullscreen = el.bool("AXFullScreen") ?? false
        if windows[id] != nil { return minimized || nativeFullscreen ? nil : id }
        guard !minimized, !nativeFullscreen,
              el.string(kAXRoleAttribute) == kAXWindowRole,
              el.string(kAXSubroleAttribute) == kAXStandardWindowSubrole,
              let watcher = watchers[pid] else { return nil }

        let app = NSRunningApplication(processIdentifier: pid)
        let w = ManagedWindow(id: id, pid: pid, element: el, appElement: watcher.app,
                              appName: app?.localizedName ?? "", bundleID: app?.bundleIdentifier ?? "",
                              title: el.string(kAXTitleAttribute) ?? "")

        var floating = !el.isSettable(kAXSizeAttribute)
        var ruleWorkspace: Int?
        var silent = false
        var size: (Double, Double, Bool)?
        var center = false
        var fullscreen = false
        for r in model.config.rules where r.matches(appClasses: [w.appName, w.bundleID], title: w.title) {
            let args = r.effectArgs
            switch r.effectName {
            case "float": floating = true
            case "tile": floating = false
            case "center": center = true
            case "fullscreen", "maximize": fullscreen = true
            case "workspace":
                if let n = args.first.flatMap(Int.init) { ruleWorkspace = n }
                silent = args.contains("silent")
            case "size":
                if args.count == 2 {
                    let pct = args[0].hasSuffix("%")
                    if let a = Double(args[0].replacingOccurrences(of: "%", with: "")),
                       let b = Double(args[1].replacingOccurrences(of: "%", with: "")) {
                        size = (a, b, pct)
                        floating = true
                    }
                }
            default: break
            }
        }

        var monitorHint: Int?
        if initialScan, let f = el.frame {
            monitorHint = model.monitors.firstIndex { $0.frame.contains(x: f.midX, y: f.midY) }
        }
        windows[id] = w
        watcher.watch(el)
        model.addWindow(id, floating: floating, workspace: ruleWorkspace, monitor: monitorHint)
        events?.emit("openwindow", "\(hex(id)),\(model.windowWorkspace[id] ?? 0),\(w.appName),\(w.title)")

        if let (a, b, pct) = size, let mon = monitorFor(id) {
            let mf = model.monitors[mon].frame
            let sw = pct ? mf.w * a / 100 : a
            let sh = pct ? mf.h * b / 100 : b
            el.setSize(CGSize(width: sw, height: sh))
            center = true
        }
        if center { centerWindow(id) }
        if !initialScan, let n = ruleWorkspace, !silent {
            _ = try? model.dispatch("workspace", String(n))
        }
        if fullscreen {
            model.setFocused(id)
            _ = try? model.dispatch("fullscreen", "")
        }
        if !initialScan { scheduleRelayout(after: 0) }
        return id
    }

    private func forget(pid: pid_t) {
        removeWindows(pid: pid)
        watchers[pid] = nil
    }

    private func removeWindows(pid: pid_t) {
        for (id, w) in windows where w.pid == pid { removeWindow(id) }
        apply()
    }

    private func removeWindow(_ id: WindowID) {
        guard windows[id] != nil else { return }
        windows[id] = nil
        lastSet[id] = nil
        hidden.remove(id)
        savedFloating[id] = nil
        let fx = model.removeWindow(id)
        events?.emit("closewindow", hex(id))
        handle(fx)
        scheduleRelayout(after: 0)
    }

    // MARK: AX events

    func handleAX(_ el: AXUIElement, _ notification: String) {
        switch notification {
        case kAXWindowCreatedNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            considerWindow(el, pid: pid)
            // Some apps finish setting up the window (title, subrole) a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.scanApp(pid) }

        case kAXFocusedWindowChangedNotification:
            refreshFocus()

        case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
            if let id = windows.first(where: { CFEqual($0.value.element, el) })?.key {
                removeWindow(id)
            }

        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            guard let id = el.windowID, windows[id] != nil else { return }
            if let last = lastSet[id], Date().timeIntervalSince(last.at) < 0.6 { return }  // our own move
            if model.isFloating(id) && !hidden.contains(id) {
                updateBorders()
                return
            }
            // User dragged a tiled (or hidden) window: snap it back once the mouse is up.
            lastSet[id] = nil
            scheduleRelayout(after: 0.15)

        case kAXTitleChangedNotification:
            guard let id = el.windowID, let w = windows[id] else { return }
            w.title = el.string(kAXTitleAttribute) ?? w.title
            if id == model.focused { events?.emit("activewindow", "\(w.appName),\(w.title)") }

        default:
            break
        }
    }

    private func scheduleRelayout(after delay: Double) {
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.relayoutScheduled = false
            if NSEvent.pressedMouseButtons != 0 {
                self.scheduleRelayout(after: 0.15)
                return
            }
            self.apply()
        }
    }

    func refreshFocus() {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID else { return }
        let pid = front.processIdentifier
        let appEl = watchers[pid]?.app ?? AXUIElementCreateApplication(pid)
        guard let el = appEl.element(kAXFocusedWindowAttribute), let id = el.windowID else { return }
        if windows[id] == nil { scanApp(pid) }
        guard windows[id] != nil else { return }
        if Date() < suppressFocusUntil, id != model.focused, !model.isVisible(id) {
            // macOS handed focus to a window on a hidden workspace right after we switched. Undo.
            if let f = model.focused { focusWindow(f) } else { WindowFocus.focusDesktop() }
            return
        }
        guard id != model.focused || !model.isVisible(id) else { return }
        model.setFocused(id)
        apply()
    }

    // MARK: Dispatch

    /// Runs a dispatcher. Returns an error message or nil.
    @discardableResult
    func run(_ dispatcher: String, _ arg: String) -> String? {
        if dispatcher == "lua" {
            LuaConfig.call(arg)
            return nil
        }
        var floatingFrames: [WindowID: Rect] = [:]
        for (id, w) in windows where model.isFloating(id) && model.isVisible(id) {
            if let f = w.element.frame { floatingFrames[id] = f }
        }
        do {
            let fx = try model.dispatch(dispatcher, arg, floatingFrames: floatingFrames)
            apply()
            handle(fx)
            return nil
        } catch {
            log("\(dispatcher) \(arg): \(error)")
            return "\(error)"
        }
    }

    private func handle(_ effects: [Effect]) {
        for e in effects {
            switch e {
            case .exec(let cmd): spawn(cmd)
            case .close(let id):
                guard let w = windows[id] else { break }
                if let button = w.element.element(kAXCloseButtonAttribute) {
                    button.perform(kAXPressAction)
                }
            case .focus(let id): focusWindow(id)
            case .focusDesktop:
                suppressFocusUntil = Date().addingTimeInterval(0.5)
                WindowFocus.focusDesktop()
            case .center(let id): centerWindow(id)
            case let .moveWindow(id, x, y, exact):
                guard let w = windows[id], let f = w.element.frame else { break }
                let r = Rect(x: exact ? x : f.x + x, y: exact ? y : f.y + y, w: f.w, h: f.h).rounded()
                withoutEnhancedUI(w.appElement) { w.element.setPosition(CGPoint(x: r.x, y: r.y)) }
                lastSet[id] = (r, Date())
            case let .resizeWindow(id, x, y, exact):
                guard let w = windows[id], let f = w.element.frame else { break }
                let r = Rect(x: f.x, y: f.y, w: max(50, exact ? x : f.w + x), h: max(50, exact ? y : f.h + y)).rounded()
                withoutEnhancedUI(w.appElement) { w.element.setSize(CGSize(width: r.w, height: r.h)) }
                lastSet[id] = (r, Date())
            case .reload: reload()
            case .quit: shutdown()
            }
        }
        updateUI()
    }

    private func focusWindow(_ id: WindowID) {
        guard let w = windows[id] else { return }
        suppressFocusUntil = Date().addingTimeInterval(0.5)
        WindowFocus.focus(pid: w.pid, windowID: id, element: w.element)
    }

    private func monitorFor(_ id: WindowID) -> Int? {
        guard let ws = model.windowWorkspace[id] else { return nil }
        return model.monitorIndex(showing: ws) ?? model.workspaces[ws]?.lastMonitor
    }

    private func centerWindow(_ id: WindowID) {
        guard let w = windows[id], let m = monitorFor(id), m < model.monitors.count else { return }
        let mf = model.monitors[m].frame
        var f = w.element.frame ?? Rect(x: 0, y: 0, w: mf.w * 0.6, h: mf.h * 0.7)
        // A window that was tiled full-size gets a sensible floating size.
        if f.w >= mf.w * 0.9 || f.h >= mf.h * 0.9 { f.w = mf.w * 0.6; f.h = mf.h * 0.7 }
        let r = Rect(x: mf.midX - f.w / 2, y: mf.midY - f.h / 2, w: f.w, h: f.h).rounded()
        withoutEnhancedUI(w.appElement) { w.element.setFrame(r) }
        lastSet[id] = (r, Date())
    }

    private func spawn(_ cmd: String) {
        let missing = MacCompat.missing(in: cmd)
        guard missing.isEmpty else {
            log("skipped (needs \(missing.joined(separator: ", "))): \(cmd.prefix(80))")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = MacCompat.path
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.children.remove(proc) }
        }
        do {
            try p.run()
            children.insert(p)
        } catch {
            log("exec failed: \(cmd): \(error)")
        }
    }

    // MARK: Apply layout

    /// Pushes the model's state to the screen: tiles, hides and shows windows, draws borders.
    func apply() {
        let frames = model.frames()
        let bs = model.config.borderSize
        for (id, w) in windows {
            if model.isVisible(id) {
                if hidden.remove(id) != nil, let saved = savedFloating.removeValue(forKey: id) {
                    setFrame(w, saved)
                }
                if let tile = frames[id] {
                    let ws = model.windowWorkspace[id].flatMap { model.workspaces[$0] }
                    setFrame(w, ws?.fullscreen == id ? tile : tile.inset(by: bs))
                }
            } else {
                if !hidden.contains(id) {
                    if model.isFloating(id), let f = w.element.frame { savedFloating[id] = f }
                    hidden.insert(id)
                }
                hide(w)
            }
        }
        updateBorders(frames: frames)
        updateUI()
    }

    private func setFrame(_ w: ManagedWindow, _ r: Rect) {
        let r = r.rounded()
        if let last = lastSet[w.id], last.rect == r { return }
        withoutEnhancedUI(w.appElement) { w.element.setFrame(r) }
        lastSet[w.id] = (r, Date())
    }

    /// Parks a window in a screen corner with 1px visible (macOS will not let windows go fully
    /// off screen). Same approach as AeroSpace.
    private func hide(_ w: ManagedWindow) {
        guard let wsID = model.windowWorkspace[w.id], !model.monitors.isEmpty else { return }
        let m = model.workspaces[wsID]?.lastMonitor.flatMap { $0 < model.monitors.count ? $0 : nil } ?? 0
        let mf = model.monitors[m].frame
        let size = w.element.size ?? CGSize(width: 800, height: 600)
        let rightBlocked = model.monitors.enumerated().contains { i, o in
            i != m && o.frame.x >= mf.maxX - 1 && o.frame.y < mf.maxY && o.frame.maxY > mf.y
        }
        let x = rightBlocked ? mf.x - size.width + 1 : mf.maxX - 1
        let target = Rect(x: x, y: mf.maxY - 1, w: size.width, h: size.height).rounded()
        if let last = lastSet[w.id], last.rect == target { return }
        withoutEnhancedUI(w.appElement) { w.element.setPosition(CGPoint(x: target.x, y: target.y)) }
        lastSet[w.id] = (target, Date())
    }

    private func updateBorders(frames: [WindowID: Rect]? = nil) {
        let frames = frames ?? model.frames()
        let bs = model.config.borderSize
        var items: [WindowID: Borders.Item] = [:]
        for (id, w) in windows where model.isVisible(id) {
            guard let ws = model.windowWorkspace[id].flatMap({ model.workspaces[$0] }), ws.fullscreen == nil else { continue }
            let active = id == model.focused
            if let tile = frames[id] {
                items[id] = .init(outer: tile, active: active)
            } else if model.isFloating(id), let f = w.element.frame {
                items[id] = .init(outer: Rect(x: f.x - bs, y: f.y - bs, w: f.w + 2 * bs, h: f.h + 2 * bs), active: active)
            }
        }
        borders.update(items, config: model.config)
    }

    private func updateUI() {
        statusBar?.update()
        emitEvents()
    }

    private func emitEvents() {
        guard let events else { return }
        let ws = model.currentWorkspace
        if ws != lastEvent.workspace {
            events.emit("workspace", String(ws))
            events.emit("workspacev2", "\(ws),\(ws)")
        }
        if model.focusedMonitor != lastEvent.monitor, model.focusedMonitor < model.monitors.count {
            events.emit("focusedmon", "\(model.monitors[model.focusedMonitor].name),\(ws)")
        }
        if model.focused != lastEvent.window {
            if let id = model.focused, let w = windows[id] {
                events.emit("activewindow", "\(w.appName),\(w.title)")
                events.emit("activewindowv2", hex(id))
            } else {
                events.emit("activewindow", ",")
                events.emit("activewindowv2", "")
            }
        }
        for (id, wsID) in model.windowWorkspace where lastWindowWorkspace[id] != nil && lastWindowWorkspace[id] != wsID {
            events.emit("movewindow", "\(hex(id)),\(wsID)")
        }
        lastWindowWorkspace = model.windowWorkspace
        lastEvent = (ws, model.focused, model.focusedMonitor)
    }

    // MARK: IPC

    func handleRequest(_ raw: String) -> String {
        var req = raw
        var json = false
        if req.hasPrefix("j/") {
            json = true
            req.removeFirst(2)
        }
        let parts = req.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return "empty request" }
        let rest = parts.count > 1 ? parts[1] : ""

        switch cmd {
        case "dispatch":
            let d = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard let name = d.first else { return "dispatch needs a dispatcher" }
            return run(name, d.count > 1 ? d[1] : "") ?? "ok"
        case "reload":
            reload()
            return "ok"
        case "version":
            return json ? toJSON(["version": HyprmacInfo.version, "platform": "macOS"]) : "hyprmac \(HyprmacInfo.version)"
        case "configerrors":
            return json ? toJSON(configErrors) : (configErrors.isEmpty ? "no errors" : configErrors.joined(separator: "\n"))
        case "skippedbinds":
            return json ? toJSON(skippedBinds) : (skippedBinds.isEmpty ? "none" : skippedBinds.joined(separator: "\n"))
        case "monitors":
            let list = model.monitors.enumerated().map { i, m -> [String: Any] in
                ["id": i, "name": m.name, "x": m.frame.x, "y": m.frame.y, "width": m.frame.w, "height": m.frame.h,
                 "activeWorkspace": ["id": m.workspace, "name": String(m.workspace)], "focused": i == model.focusedMonitor]
            }
            return json ? toJSON(list) : list.map(describe).joined(separator: "\n\n")
        case "workspaces":
            let ids = model.workspaces.values.filter { !$0.isEmpty || model.monitorIndex(showing: $0.id) != nil }.map(\.id).sorted()
            let list = ids.map(workspaceInfo)
            return json ? toJSON(list) : list.map(describe).joined(separator: "\n\n")
        case "activeworkspace":
            let info = workspaceInfo(model.currentWorkspace)
            return json ? toJSON(info) : describe(info)
        case "clients":
            let list = windows.keys.sorted().map(clientInfo)
            return json ? toJSON(list) : list.map(describe).joined(separator: "\n\n")
        case "activewindow":
            guard let id = model.focused, windows[id] != nil else { return json ? "{}" : "Invalid" }
            let info = clientInfo(id)
            return json ? toJSON(info) : describe(info)
        case "binds":
            let list = model.config.binds.map { b -> [String: Any] in
                ["modmask": b.mods.names.joined(separator: " "), "key": b.key, "dispatcher": b.dispatcher, "arg": b.arg]
            }
            return json ? toJSON(list) : list.map(describe).joined(separator: "\n\n")
        default:
            return "unknown request: \(cmd)"
        }
    }

    private func workspaceInfo(_ id: Int) -> [String: Any] {
        let ws = model.workspace(id)
        let mon = model.monitorIndex(showing: id)
        return ["id": id, "name": String(id), "monitor": mon.map { model.monitors[$0].name } ?? "",
                "monitorID": mon ?? -1, "windows": ws.all.count, "hasfullscreen": ws.fullscreen != nil,
                "lastwindow": ws.lastFocused.map(hex) ?? "", "lastwindowtitle": ws.lastFocused.flatMap { windows[$0]?.title } ?? ""]
    }

    private func clientInfo(_ id: WindowID) -> [String: Any] {
        guard let w = windows[id] else { return [:] }
        let f = w.element.frame ?? Rect(x: 0, y: 0, w: 0, h: 0)
        let wsID = model.windowWorkspace[id] ?? 0
        return ["address": hex(id), "class": w.appName, "bundleID": w.bundleID, "title": w.title, "pid": w.pid,
                "workspace": ["id": wsID, "name": String(wsID)], "floating": model.isFloating(id),
                "fullscreen": model.workspaces[wsID]?.fullscreen == id, "hidden": hidden.contains(id),
                "at": [Int(f.x), Int(f.y)], "size": [Int(f.w), Int(f.h)], "focused": id == model.focused]
    }

    private func describe(_ d: [String: Any]) -> String {
        d.keys.sorted().map { k in
            let v = d[k]!
            if let sub = v as? [String: Any] { return "\t\(k): \(sub["id"] ?? "") (\(sub["name"] ?? ""))" }
            if let arr = v as? [Any] { return "\t\(k): " + arr.map { "\($0)" }.joined(separator: ",") }
            return "\t\(k): \(v)"
        }.joined(separator: "\n")
    }

    private func toJSON(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: For the status bar and --list

    var windowCount: Int { windows.count }

    func windowSummary() -> [(ws: Int, app: String, title: String, floating: Bool)] {
        windows.values.map { w in
            (model.windowWorkspace[w.id] ?? 0, w.appName, w.title, model.isFloating(w.id))
        }.sorted { ($0.ws, $0.app) < ($1.ws, $1.app) }
    }
}

func hex(_ id: WindowID) -> String { "0x" + String(id, radix: 16) }

/// stderr plus ~/Library/Logs/hyprmac.log (the app has no terminal when started with `open`).
func log(_ s: String) {
    FileHandle.standardError.write(Data("[hyprmac] \(s)\n".utf8))
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = Data("\(stamp) \(s)\n".utf8)
    let path = ConfigParser.home + "/Library/Logs/hyprmac.log"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(line)
        try? h.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: line)
    }
}
