import AppKit
import HyprmacCore
import IOKit.ps
import Network
import SwiftUI

/// What the shell asks of the window manager.
protocol ShellActions: AnyObject {
    func shellDispatch(_ dispatcher: String, _ arg: String)
    /// The hyprmac menu (rice, reload, edit config, quit), shown from the bar's logo.
    func shellMenu() -> NSMenu
    func shellQuit()
}

/// Caelestia-style desktop shell for macOS: a bar across the top of every screen that flows
/// into a thin frame around it (tiled windows sit inside), a dashboard and a session menu
/// that grow out of the bar, all colored from the wallpaper. The real menu bar auto-hides.
final class Shell {
    static let barHeight: CGFloat = 38
    static let frameThickness: CGFloat = 8
    static let innerRadius: CGFloat = 18
    /// Above normal and floating windows, below the Dock (20) and the menu bar (24).
    static let frameLevel = NSWindow.Level(rawValue: 18)
    static let barLevel = NSWindow.Level(rawValue: 19)

    let model = ShellModel()
    /// 24-hour clock, like Caelestia.
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private weak var actions: ShellActions?
    private var screens: [String: ScreenShell] = [:]
    private var popup: Popup?
    private var hideMenuBar = true
    private var schemeSetting = "auto"
    private var wallpaperStamp = ""
    private var clock: Timer?
    private let pathMonitor = NWPathMonitor()
    private var disposed = false
    /// Called when the colors change (the window manager recolors borders).
    var onSchemeChange: (() -> Void)?

    init(actions: ShellActions) {
        self.actions = actions
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.model.network = NetState(path) }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        model.battery = Battery.read()
    }

    func configure(hideMenuBar: Bool, scheme: String) {
        self.hideMenuBar = hideMenuBar
        if hideMenuBar { MenuBarHider.hide() } else { MenuBarHider.restore() }
        if scheme != schemeSetting {
            schemeSetting = scheme
            wallpaperStamp = ""
        }
        checkWallpaper()
        layout()
    }

    // MARK: Geometry

    static func screenID(_ s: NSScreen) -> String {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? s.localizedName
    }

    /// Height of the bar on `screen`: taller on a notched screen when the bar reaches the top.
    static func barHeight(_ screen: NSScreen) -> CGFloat {
        let reachesTop = screen.visibleFrame.maxY >= screen.frame.maxY - 1
        return reachesTop ? max(barHeight, screen.safeAreaInsets.top) : barHeight
    }

    /// Area left for windows on `screen` (Cocoa coordinates): below the bar, inside the frame.
    static func usableFrame(_ screen: NSScreen) -> CGRect {
        let v = screen.visibleFrame, t = frameThickness
        return CGRect(x: v.minX + t, y: v.minY + t, width: v.width - 2 * t, height: v.height - barHeight(screen) - t)
    }

    /// Places the bar and frame on every screen (creates and removes as screens come and go).
    func layout() {
        guard !disposed else { return }
        var seen = Set<String>()
        for screen in NSScreen.screens {
            let id = Shell.screenID(screen)
            seen.insert(id)
            let s = screens[id] ?? ScreenShell(id: id, shell: self)
            screens[id] = s
            s.place(on: screen)
        }
        for (id, s) in screens where !seen.contains(id) {
            s.close()
            screens[id] = nil
        }
    }

    // MARK: State

    func update(workspaces: [String: Int], focusedScreen: String, occupied: Set<Int>, app: String, title: String, pid: pid_t?) {
        if model.workspaces != workspaces { model.workspaces = workspaces }
        if model.focusedScreen != focusedScreen { model.focusedScreen = focusedScreen }
        if model.occupied != occupied { model.occupied = occupied }
        if model.app != app { model.app = app }
        if model.title != title { model.title = title }
        if model.pid != pid {
            model.pid = pid
            model.icon = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon }
        }
    }

    private func tick() {
        let now = Date()
        if Calendar.current.component(.minute, from: now) != Calendar.current.component(.minute, from: model.now)
            || now.timeIntervalSince(model.now) > 60 {
            model.now = now
        }
        if Int(now.timeIntervalSince1970) % 30 == 0 {
            let b = Battery.read()
            if b != model.battery { model.battery = b }
        }
    }

    /// Sets the color setting and computes the scheme without touching the screen (previews).
    func setScheme(_ setting: String) {
        schemeSetting = setting
        wallpaperStamp = ""
        checkWallpaper()
    }

    /// Re-reads the wallpaper when it changed and recolors everything.
    func checkWallpaper() {
        guard !disposed else { return }
        let url = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        let mtime = url.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        let stamp = "\(schemeSetting)|\(url?.path ?? "")|\(mtime?.timeIntervalSince1970 ?? 0)"
        guard stamp != wallpaperStamp else { return }
        wallpaperStamp = stamp
        let seed = schemeSetting == "auto" ? url.flatMap(Wallpaper.seed) : nil
        let scheme = Scheme.resolve(schemeSetting, wallpaperSeed: seed)
        guard scheme != model.scheme else { return }
        model.scheme = scheme
        for s in screens.values { s.recolor() }
        onSchemeChange?()
    }

    // MARK: Actions

    func dispatch(_ d: String, _ arg: String) { actions?.shellDispatch(d, arg) }

    func showMenu(from screenID: String) {
        guard let menu = actions?.shellMenu(), let s = screens[screenID] else { return }
        closePopup()
        menu.appearance = NSAppearance(named: .darkAqua)
        let at = NSPoint(x: NSEvent.mouseLocation.x - 12, y: s.barBottom - 4)
        menu.popUp(positioning: nil, at: at, in: nil)
    }

    /// shell:launcher, shell:dashboard, shell:session (also caelestia:...).
    func toggle(_ action: String) {
        switch action {
        case "launcher", "drawers", "apps":
            closePopup()
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Apps.app"))
        case "dashboard", "dash", "calendar":
            togglePopup(.dashboard)
        case "session", "power":
            togglePopup(.session)
        default:
            break
        }
    }

    func togglePopup(_ kind: Popup.Kind) {
        if let p = popup, p.kind == kind {
            closePopup()
            return
        }
        closePopup()
        let screen = NSScreen.screens.first { Shell.screenID($0) == model.focusedScreen } ?? NSScreen.main ?? NSScreen.screens[0]
        let p = Popup(kind: kind, shell: self, screen: screen)
        popup = p
        model.popup = kind
        p.show()
    }

    func closePopup() {
        popup?.close()
        popup = nil
        model.popup = nil
    }

    func quit() { actions?.shellQuit() }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        clock?.invalidate()
        pathMonitor.cancel()
        closePopup()
        for s in screens.values { s.close() }
        screens.removeAll()
        MenuBarHider.restore()
    }
}

// MARK: - State for the views

enum NetState: Equatable {
    case offline, wifi, wired, other
    init(_ path: NWPath) {
        if path.status != .satisfied { self = .offline }
        else if path.usesInterfaceType(.wifi) { self = .wifi }
        else if path.usesInterfaceType(.wiredEthernet) { self = .wired }
        else { self = .other }
    }

    var symbol: String {
        switch self {
        case .offline: "wifi.slash"
        case .wifi: "wifi"
        case .wired: "cable.connector.horizontal"
        case .other: "network"
        }
    }

    var label: String {
        switch self {
        case .offline: "Offline"
        case .wifi: "Wi-Fi"
        case .wired: "Ethernet"
        case .other: "Connected"
        }
    }
}

struct Battery: Equatable {
    var percent: Int
    var charging: Bool

    static func read() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? (d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
            return Battery(percent: cur * 100 / max, charging: charging)
        }
        return nil
    }

    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

final class ShellModel: ObservableObject {
    @Published var scheme = Scheme.default
    /// Screen id -> workspace shown there.
    @Published var workspaces: [String: Int] = [:]
    @Published var focusedScreen = ""
    @Published var occupied: Set<Int> = []
    @Published var app = ""
    @Published var title = ""
    @Published var icon: NSImage?
    var pid: pid_t?
    @Published var now = Date()
    @Published var network = NetState.wifi
    @Published var battery: Battery?
    @Published var popup: Popup.Kind?
}

enum Wallpaper {
    /// Dominant hue and colorfulness of an image file, from a 96 px thumbnail.
    static func seed(_ url: URL) -> (hue: Double, chroma: Double)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceThumbnailMaxPixelSize: 96,
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
              ] as CFDictionary) else { return nil }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Scheme.seed(rgba: px) : nil
    }
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

// MARK: - Windows

/// Bar + frame for one screen.
final class ScreenShell {
    let id: String
    private unowned let shell: Shell
    private let frame = FrameWindow()
    private let bar: NSPanel
    private(set) var barBottom: CGFloat = 0

    init(id: String, shell: Shell) {
        self.id = id
        self.shell = shell
        bar = ShellPanel(level: Shell.barLevel)
        bar.contentView = ClickThroughHost(rootView: AnyView(BarView(model: shell.model, shell: shell, screenID: id)))
    }

    func place(on screen: NSScreen) {
        let v = screen.visibleFrame
        let h = Shell.barHeight(screen)
        barBottom = v.maxY - h
        frame.show(outer: v, inner: Shell.usableFrame(screen), color: shell.model.scheme.surface.ns)
        let barRect = CGRect(x: v.minX, y: v.maxY - h, width: v.width, height: h)
        if bar.frame != barRect { bar.setFrame(barRect, display: true) }
        bar.orderFrontRegardless()
    }

    func recolor() { frame.recolor(shell.model.scheme.surface.ns) }

    func close() {
        frame.orderOut(nil)
        bar.orderOut(nil)
    }
}

/// Borderless panel that never activates hyprmac and shows on every Space.
class ShellPanel: NSPanel {
    init(level: NSWindow.Level) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }
}

/// Hosting view that takes the first click (the bar is never the key window).
final class ClickThroughHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The frame: fills the visible area except a rounded hole where windows tile. Click-through.
final class FrameWindow: NSWindow {
    private let view = FrameView()

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = Shell.frameLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = view
    }

    func show(outer: CGRect, inner: CGRect, color: NSColor) {
        let hole = inner.offsetBy(dx: -outer.minX, dy: -outer.minY)
        if frame != outer || view.hole != hole || view.color != color {
            setFrame(outer, display: false)
            view.hole = hole
            view.color = color
            view.needsDisplay = true
        }
        orderFrontRegardless()
    }

    func recolor(_ color: NSColor) {
        view.color = color
        view.needsDisplay = true
    }
}

final class FrameView: NSView {
    var hole = CGRect.zero
    var color = NSColor.black

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(roundedRect: hole, xRadius: Shell.innerRadius, yRadius: Shell.innerRadius))
        path.windingRule = .evenOdd
        color.setFill()
        path.fill()
    }
}

// MARK: - Bar

private extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Rounded "chip" on the bar; lighter when hovered or when its popup is open.
struct Chip<Content: View>: View {
    let scheme: Scheme
    var active = false
    var help = ""
    var action: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        content()
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill((active ? scheme.surfaceContainerHighest : hover && action != nil ? scheme.surfaceContainerHigh : scheme.surfaceContainer).color)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { action?() }
            .help(help)
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct BarView: View {
    @ObservedObject var model: ShellModel
    let shell: Shell
    let screenID: String

    private var s: Scheme { model.scheme }

    var body: some View {
        HStack(spacing: 8) {
            Chip(scheme: s, help: "hyprmac", action: { shell.showMenu(from: screenID) }) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(s.primary.color)
            }
            workspaces
            if !model.title.isEmpty || !model.app.isEmpty { activeWindow }
            Spacer(minLength: 16)
            status
            Chip(scheme: s, active: model.popup == .dashboard, help: "Dashboard",
                 action: { shell.togglePopup(.dashboard) }) {
                HStack(spacing: 7) {
                    Image(systemName: "calendar").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(s.onSurfaceVariant.color)
                    Text(model.now.formatted(.dateTime.weekday(.abbreviated).day()))
                        .font(.rounded(12.5, .medium)).foregroundStyle(s.onSurfaceVariant.color)
                    Text(Shell.clock.string(from: model.now))
                        .font(.rounded(13.5, .semibold)).monospacedDigit().foregroundStyle(s.secondary.color)
                }
            }
            Chip(scheme: s, active: model.popup == .session, help: "Session",
                 action: { shell.togglePopup(.session) }) {
                Image(systemName: "power").font(.system(size: 13, weight: .bold)).foregroundStyle(s.error.color)
            }
        }
        .padding(.leading, Shell.frameThickness + 2)
        .padding(.trailing, Shell.frameThickness + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaces: some View {
        let current = model.workspaces[screenID] ?? 1
        let shownElsewhere = Set(model.workspaces.filter { $0.key != screenID }.values)
        let count = max(5, current, model.occupied.max() ?? 0)
        return HStack(spacing: 6) {
            ForEach(1...count, id: \.self) { i in
                let active = i == current
                let fill = active ? s.primary : shownElsewhere.contains(i) ? s.tertiary
                    : model.occupied.contains(i) ? s.onSurfaceVariant : s.surfaceContainerHighest
                Capsule()
                    .fill(fill.color)
                    .frame(width: active ? 28 : 9, height: 9)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture { shell.dispatch("workspace", String(i)) }
                    .help("Workspace \(i)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(s.surfaceContainer.color))
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: current)
        .animation(.easeOut(duration: 0.2), value: model.occupied)
    }

    private var activeWindow: some View {
        HStack(spacing: 7) {
            if let icon = model.icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18)
            }
            Text(model.title.isEmpty ? model.app : model.title)
                .font(.rounded(12.5, .medium))
                .foregroundStyle(s.onSurfaceVariant.color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.leading, 4)
        .help(model.app.isEmpty ? model.title : "\(model.app): \(model.title)")
    }

    private var status: some View {
        Chip(scheme: s, help: model.network.label, action: {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
        }) {
            HStack(spacing: 10) {
                Image(systemName: model.network.symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle((model.network == .offline ? s.error : s.onSurfaceVariant).color)
                if let b = model.battery {
                    HStack(spacing: 4) {
                        Image(systemName: b.symbol).font(.system(size: 13))
                        Text("\(b.percent)%").font(.rounded(12, .medium)).monospacedDigit()
                    }
                    .foregroundStyle((b.percent <= 15 && !b.charging ? s.error : s.onSurfaceVariant).color)
                }
            }
        }
    }
}

// MARK: - Popups (dashboard, session)

/// Panel that grows out of the bottom of the bar, Caelestia-style: square top joined to the
/// bar with curved "ears", rounded bottom.
final class Popup {
    enum Kind { case dashboard, session }
    let kind: Kind
    private let panel: KeyPanel
    private var monitors: [Any] = []
    private unowned let shell: Shell
    private let screen: NSScreen

    init(kind: Kind, shell: Shell, screen: NSScreen) {
        self.kind = kind
        self.shell = shell
        self.screen = screen
        panel = KeyPanel(level: Shell.barLevel)
        let content: AnyView
        switch kind {
        case .dashboard: content = AnyView(DashboardView(model: shell.model))
        case .session: content = AnyView(SessionView(model: shell.model, shell: shell))
        }
        let host = ClickThroughHost(rootView: AnyView(DrawerContainer(scheme: shell.model.scheme, content: content)))
        panel.contentView = host
        let size = host.fittingSize
        let top = screen.visibleFrame.maxY - Shell.barHeight(screen)
        let x: CGFloat
        switch kind {
        case .dashboard: x = screen.visibleFrame.midX - size.width / 2
        case .session: x = screen.visibleFrame.maxX - Shell.frameThickness - size.width + DrawerShape.ear
        }
        panel.setFrame(CGRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    func show() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        // Click elsewhere or Escape closes it.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.shell.closePopup()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 { self?.shell.closePopup(); return nil }
            return e
        }) { monitors.append(m) }
    }

    func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        let p = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }
}

final class KeyPanel: ShellPanel {
    override var canBecomeKey: Bool { true }
}

struct DrawerShape: Shape {
    static let ear: CGFloat = 16
    var radius: CGFloat = 22

    func path(in r: CGRect) -> Path {
        let e = DrawerShape.ear, w = r.width, h = r.height, rad = min(radius, (h - e) / 2)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addQuadCurve(to: CGPoint(x: w - e, y: e), control: CGPoint(x: w - e, y: 0))
        p.addLine(to: CGPoint(x: w - e, y: h - rad))
        p.addQuadCurve(to: CGPoint(x: w - e - rad, y: h), control: CGPoint(x: w - e, y: h))
        p.addLine(to: CGPoint(x: e + rad, y: h))
        p.addQuadCurve(to: CGPoint(x: e, y: h - rad), control: CGPoint(x: e, y: h))
        p.addLine(to: CGPoint(x: e, y: e))
        p.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: e, y: 0))
        p.closeSubpath()
        return p
    }
}

struct DrawerContainer: View {
    let scheme: Scheme
    let content: AnyView
    @State var shown = false

    var body: some View {
        content
            .padding(.horizontal, DrawerShape.ear + 18)
            .padding(.top, 14)
            .padding(.bottom, 20)
            .background(DrawerShape().fill(scheme.surface.color))
            .scaleEffect(x: 1, y: shown ? 1 : 0.85, anchor: .top)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { shown = true } }
            .fixedSize()
    }
}

struct DashboardView: View {
    @ObservedObject var model: ShellModel
    @State private var monthOffset = 0

    private var s: Scheme { model.scheme }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Shell.clock.string(from: model.now))
                    .font(.rounded(46, .semibold)).monospacedDigit()
                    .foregroundStyle(s.primary.color)
                Text(model.now.formatted(.dateTime.weekday(.wide)))
                    .font(.rounded(15, .semibold)).foregroundStyle(s.onSurface.color)
                Text(model.now.formatted(.dateTime.month(.wide).day().year()))
                    .font(.rounded(13)).foregroundStyle(s.onSurfaceVariant.color)
                Spacer(minLength: 10)
                if !model.app.isEmpty {
                    HStack(spacing: 6) {
                        if let icon = model.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                        Text(model.app).font(.rounded(12, .medium)).foregroundStyle(s.onSurfaceVariant.color).lineLimit(1)
                    }
                }
            }
            .frame(width: 170, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(s.surfaceContainer.color))
            calendar
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(s.surfaceContainer.color))
        }
        .frame(height: 236)
    }

    private var calendar: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: model.now)
        let month = cal.date(byAdding: .month, value: monthOffset, to: cal.date(from: cal.dateComponents([.year, .month], from: today))!)!
        let days = cal.range(of: .day, in: .month, for: month)!.count
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let header = (0..<7).map { symbols[($0 + cal.firstWeekday - 1) % 7] }
        let cells: [Int?] = Array(repeating: nil, count: lead) + (1...days).map { $0 }
        let rows = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
        return VStack(spacing: 4) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.rounded(14, .semibold)).foregroundStyle(s.secondary.color)
                Spacer()
                arrow("chevron.left") { monthOffset -= 1 }
                arrow("chevron.right") { monthOffset += 1 }
            }
            .padding(.bottom, 4)
            HStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { i in
                    Text(header[i]).font(.rounded(11, .semibold)).foregroundStyle(s.outline.color).frame(width: 30)
                }
            }
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { c in
                        let day = c < rows[r].count ? rows[r][c] : nil
                        let isToday = day != nil && cal.date(byAdding: .day, value: day! - 1, to: month) == today
                        Text(day.map(String.init) ?? "")
                            .font(.rounded(12, isToday ? .bold : .regular)).monospacedDigit()
                            .foregroundStyle((isToday ? s.onPrimary : s.onSurface).color)
                            .frame(width: 30, height: 24)
                            .background(Capsule().fill(isToday ? s.primary.color : .clear))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 226)
    }

    private func arrow(_ name: String, _ action: @escaping () -> Void) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(s.onSurfaceVariant.color)
            .frame(width: 24, height: 22)
            .background(Circle().fill(s.surfaceContainerHigh.color))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

struct SessionView: View {
    @ObservedObject var model: ShellModel
    let shell: Shell
    @State private var armed: String?

    private var s: Scheme { model.scheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("lock", "lock.fill", "Lock") { Session.lock() }
            row("sleep", "moon.zzz.fill", "Sleep") { Session.run("/usr/bin/pmset", ["sleepnow"]) }
            row("logout", "rectangle.portrait.and.arrow.right", "Log out", confirm: true) { Session.loginwindow("rlgo") }
            row("restart", "arrow.clockwise", "Restart", confirm: true) { Session.loginwindow("rrst") }
            row("shutdown", "power", "Shut down", confirm: true) { Session.loginwindow("rsdn") }
            row("quit", "xmark", "Quit hyprmac") { shell.quit() }
        }
    }

    private func row(_ key: String, _ symbol: String, _ label: String, confirm: Bool = false,
                     _ action: @escaping () -> Void) -> some View {
        let isArmed = armed == key
        return SessionRow(scheme: s, symbol: symbol, armed: isArmed, danger: key == "shutdown",
                          label: isArmed ? "Click again to \(label.lowercased())" : label) {
            if confirm && !isArmed {
                armed = key
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if armed == key { armed = nil } }
                return
            }
            shell.closePopup()
            action()
        }
    }
}

struct SessionRow: View {
    let scheme: Scheme
    let symbol: String
    let armed: Bool
    let danger: Bool
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle((armed ? scheme.surface : danger ? scheme.error : scheme.onSurface).color)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill((armed ? scheme.error : hover ? scheme.surfaceContainerHighest : scheme.surfaceContainerHigh).color))
            Text(label)
                .font(.rounded(13.5, .medium))
                .foregroundStyle((armed ? scheme.error : scheme.onSurface).color)
                .frame(width: 170, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

enum Session {
    static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    /// Log out / restart / shut down without the system's extra dialog (the menu already asked).
    static func loginwindow(_ code: String) {
        run("/usr/bin/osascript", ["-e", "tell application \"loginwindow\" to «event aevt\(code)»"])
    }

    static func lock() {
        typealias Lock = @convention(c) () -> Void
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let f = dlsym(h, "SACLockScreenImmediate") {
            unsafeBitCast(f, to: Lock.self)()
        } else {
            run("/usr/bin/pmset", ["displaysleepnow"])
        }
    }
}
