import AppKit
import ApplicationServices
import HyprmacCore

/// Private but stable for 10+ years; used by yabai, AeroSpace, Amethyst, Rectangle.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func value(_ attr: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attr as CFString, &out) == .success else { return nil }
        return out
    }

    func string(_ attr: String) -> String? { value(attr) as? String }
    func bool(_ attr: String) -> Bool? { (value(attr) as? NSNumber)?.boolValue }

    func element(_ attr: String) -> AXUIElement? {
        guard let v = value(attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func elements(_ attr: String) -> [AXUIElement] {
        (value(attr) as? [AnyObject])?.compactMap { obj in
            CFGetTypeID(obj) == AXUIElementGetTypeID() ? (obj as! AXUIElement) : nil
        } ?? []
    }

    @discardableResult
    func set(_ attr: String, _ v: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, attr as CFString, v) == .success
    }

    func isSettable(_ attr: String) -> Bool {
        var ok: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, attr as CFString, &ok) == .success && ok.boolValue
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var position: CGPoint? {
        guard let v = value(kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    var size: CGSize? {
        guard let v = value(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Frame in Accessibility coordinates (top-left origin, y down).
    var frame: Rect? {
        guard let p = position, let s = size else { return nil }
        return Rect(x: p.x, y: p.y, w: s.width, h: s.height)
    }

    func setPosition(_ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { set(kAXPositionAttribute, v) }
    }

    func setSize(_ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { set(kAXSizeAttribute, v) }
    }

    /// Size, then position, then size again: the first size can be clamped when the old
    /// position would push the window off screen. Same trick as AeroSpace and yabai.
    func setFrame(_ r: Rect) {
        let size = CGSize(width: r.w, height: r.h)
        setSize(size)
        setPosition(CGPoint(x: r.x, y: r.y))
        setSize(size)
    }

    func perform(_ action: String) {
        AXUIElementPerformAction(self, action as CFString)
    }
}

/// Runs `body` with AXEnhancedUserInterface off. When on (set by VoiceOver or some apps),
/// frame changes animate slowly and can land in the wrong place.
func withoutEnhancedUI(_ app: AXUIElement, _ body: () -> Void) {
    let key = "AXEnhancedUserInterface"
    let was = app.bool(key) ?? false
    if was { app.set(key, kCFBooleanFalse) }
    body()
    if was { app.set(key, kCFBooleanTrue) }
}

/// Converts between Cocoa screen coordinates (bottom-left origin) and AX coordinates.
enum Coords {
    static var primaryHeight: Double { Double(NSScreen.screens.first?.frame.height ?? 0) }

    static func ax(_ r: CGRect) -> Rect {
        Rect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height, w: r.width, h: r.height)
    }

    static func cocoa(_ r: Rect) -> CGRect {
        CGRect(x: r.x, y: primaryHeight - r.y - r.h, width: r.w, height: r.h)
    }
}
