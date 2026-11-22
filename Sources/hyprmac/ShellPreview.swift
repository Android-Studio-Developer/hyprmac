import AppKit
import HyprmacCore
import SwiftUI

/// Shell with sample data and no window management (needs no permission).
/// `--render-shell OUT.png [--open dashboard|session] [--size 1600x1000]` draws it offscreen
/// over the wallpaper; `--preview-shell [seconds] [--open ...]` shows it on screen for a while.
enum ShellPreview {
    final class Actions: ShellActions {
        weak var shell: Shell?
        func shellDispatch(_ dispatcher: String, _ arg: String) {
            guard dispatcher == "workspace", let n = Int(arg), let shell else { return }
            let id = shell.model.focusedScreen
            shell.update(workspaces: [id: n], focusedScreen: id, occupied: [1, 2, 4], app: shell.model.app,
                         title: shell.model.title, pid: shell.model.pid)
        }
        func shellMenu() -> NSMenu {
            let m = NSMenu()
            m.addItem(withTitle: "hyprmac \(HyprmacInfo.version) (preview)", action: nil, keyEquivalent: "")
            return m
        }
        func shellQuit() {
            shell?.dispose()
            exit(0)
        }
    }

    static func main(args: [String], config: Config) -> Never {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let actions = Actions()
        let shell = Shell(actions: actions)
        actions.shell = shell
        let screen = NSScreen.main.map(Shell.screenID) ?? "main"
        let finder = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
        shell.update(workspaces: [screen: 2], focusedScreen: screen, occupied: [1, 2, 4], app: "Finder",
                     title: "Downloads", pid: finder?.processIdentifier)

        if let out = value("--render-shell") {
            shell.setScheme(config.scheme)
            let size = value("--size").flatMap { s -> CGSize? in
                let p = s.split(separator: "x").compactMap { Double($0) }
                return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
            } ?? CGSize(width: 1600, height: 1000)
            let ok = render(shell: shell, screenID: screen, size: size, open: value("--open"), to: out)
            print(ok ? "wrote \(out)" : "render failed")
            exit(ok ? 0 : 1)
        }

        let seconds = value("--preview-shell").flatMap(Double.init) ?? 10
        shell.configure(hideMenuBar: config.hideTaskbar, scheme: config.scheme)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { shell.layout() }
        if let what = value("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { shell.toggle(what) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            shell.dispose()
            exit(0)
        }
        for sig in [SIGINT, SIGTERM] {
            signal(sig) { _ in
                MenuBarHider.restore()
                exit(0)
            }
        }
        NSApp.run()
        exit(0)
    }

    /// Wallpaper, frame, bar and (optionally) a popup, composed like on a screen of `size` points.
    static func render(shell: Shell, screenID: String, size: CGSize, open: String?, to path: String) -> Bool {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let full = CGRect(origin: .zero, size: size)

        // Wallpaper, aspect-filled.
        if let url = NSScreen.main.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0) }), let img = NSImage(contentsOf: url) {
            let k = max(size.width / img.size.width, size.height / img.size.height)
            let w = img.size.width * k, h = img.size.height * k
            img.draw(in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        } else {
            NSColor.darkGray.setFill()
            full.fill()
        }

        // Frame around a rounded hole, bar on top.
        let t = Shell.frameThickness, bh = Shell.barHeight
        let hole = CGRect(x: t, y: t, width: size.width - 2 * t, height: size.height - bh - t)
        let s = shell.model.scheme
        let ring = NSBezierPath(rect: full)
        ring.append(NSBezierPath(roundedRect: hole, xRadius: Shell.innerRadius, yRadius: Shell.innerRadius))
        ring.windingRule = .evenOdd
        s.surface.ns.setFill()
        ring.fill()

        // A sample tiled window so the frame reads as a frame.
        let g = 10.0
        let win = NSBezierPath(roundedRect: hole.insetBy(dx: g, dy: g).divided(atDistance: hole.width / 2, from: .minXEdge).slice.insetBy(dx: 0, dy: 0),
                               xRadius: 12, yRadius: 12)
        s.surfaceContainerLow.ns.withAlphaComponent(0.92).setFill()
        win.fill()
        s.primary.ns.setStroke()
        win.lineWidth = 2
        win.stroke()

        draw(AnyView(BarView(model: shell.model, shell: shell, screenID: screenID)),
             in: CGRect(x: 0, y: size.height - bh, width: size.width, height: bh))

        if let open {
            let kind: Popup.Kind? = ["dashboard", "dash"].contains(open) ? .dashboard : ["session", "power"].contains(open) ? .session : nil
            if let kind {
                shell.model.popup = kind
                draw(AnyView(BarView(model: shell.model, shell: shell, screenID: screenID)),
                     in: CGRect(x: 0, y: size.height - bh, width: size.width, height: bh))
                let content = kind == .dashboard ? AnyView(DashboardView(model: shell.model))
                    : AnyView(SessionView(model: shell.model, shell: shell))
                let view = AnyView(DrawerContainer(scheme: s, content: content, shown: true))
                let fit = NSHostingView(rootView: view).fittingSize
                let x = kind == .dashboard ? (size.width - fit.width) / 2 : size.width - t - fit.width + DrawerShape.ear
                draw(view, in: CGRect(x: x, y: size.height - bh - fit.height, width: fit.width, height: fit.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Renders a SwiftUI view offscreen into the current graphics context.
    private static func draw(_ view: AnyView, in rect: CGRect) {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: rect.size), styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: rect.size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        bitmap.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
