import AppKit
import HyprmacCore

/// Hyprland-style borders: one click-through overlay window per visible managed window,
/// drawn in the ring between the tile and the (shrunk) window.
final class Borders {
    private var windows: [WindowID: BorderWindow] = [:]

    struct Item {
        /// Outer edge of the border, AX coordinates.
        var outer: Rect
        var active: Bool
    }

    func update(_ items: [WindowID: Item], config: Config) {
        for (id, w) in windows where items[id] == nil {
            w.orderOut(nil)
            windows[id] = nil
        }
        guard config.borderSize > 0 else {
            for w in windows.values { w.orderOut(nil) }
            windows.removeAll()
            return
        }
        for (id, item) in items {
            let w = windows[id] ?? BorderWindow()
            windows[id] = w
            w.show(frame: Coords.cocoa(item.outer), width: config.borderSize, radius: config.rounding + config.borderSize,
                   color: item.active ? config.activeBorder : config.inactiveBorder, above: id)
        }
    }

    func removeAll() {
        for w in windows.values { w.orderOut(nil) }
        windows.removeAll()
    }
}

private final class BorderWindow: NSWindow {
    private let gradient = CAGradientLayer()
    private let mask = CAShapeLayer()
    private var last: (CGRect, Double, Double, BorderColor)?

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(gradient)
        gradient.mask = mask
        mask.fillRule = .evenOdd
        contentView = view
    }

    func show(frame: CGRect, width: Double, radius: Double, color: BorderColor, above windowID: WindowID) {
        let changed = last.map { $0.0 != frame || $0.1 != width || $0.2 != radius || $0.3 != color } ?? true
        if changed {
            last = (frame, width, radius, color)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            setFrame(frame, display: false)
            let bounds = CGRect(origin: .zero, size: frame.size)
            gradient.frame = bounds
            mask.frame = bounds
            let colors = color.colors.map { CGColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: $0.a) }
            gradient.colors = colors.count == 1 ? [colors[0], colors[0]] : colors
            // Hyprland angle: 0deg = left to right, growing clockwise.
            let a = color.angle * .pi / 180
            let dx = cos(a) / 2, dy = sin(a) / 2
            gradient.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 + dy)
            gradient.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 - dy)
            let path = CGMutablePath()
            let r = min(radius, min(bounds.width, bounds.height) / 2)
            path.addRoundedRect(in: bounds, cornerWidth: r, cornerHeight: r)
            let inner = bounds.insetBy(dx: width, dy: width)
            if inner.width > 0, inner.height > 0 {
                let ir = max(0, r - width)
                path.addRoundedRect(in: inner, cornerWidth: ir, cornerHeight: ir)
            }
            mask.path = path
            CATransaction.commit()
        }
        order(.above, relativeTo: Int(windowID))
    }
}
