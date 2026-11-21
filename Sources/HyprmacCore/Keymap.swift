import Foundation

/// Modifier keys in a bind. SUPER maps to Command on macOS (Windows key on Windows).
public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let superKey = Modifiers(rawValue: 1)
    public static let shift = Modifiers(rawValue: 2)
    public static let alt = Modifiers(rawValue: 4)
    public static let ctrl = Modifiers(rawValue: 8)

    /// Parses "SUPER SHIFT", "SUPER_SHIFT", "CTRL+ALT", "" (no modifiers).
    public static func parse(_ text: String) -> Modifiers? {
        var m: Modifiers = []
        let parts = text.uppercased().split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "+" })
        for p in parts {
            switch p {
            case "SUPER", "WIN", "LOGO", "MOD4", "META", "CMD", "COMMAND": m.insert(.superKey)
            case "SHIFT": m.insert(.shift)
            case "ALT", "MOD1", "OPT", "OPTION": m.insert(.alt)
            case "CTRL", "CONTROL": m.insert(.ctrl)
            default: return nil
            }
        }
        return m
    }

    public var names: [String] {
        var out: [String] = []
        if contains(.superKey) { out.append("SUPER") }
        if contains(.ctrl) { out.append("CTRL") }
        if contains(.alt) { out.append("ALT") }
        if contains(.shift) { out.append("SHIFT") }
        return out
    }
}

/// Key names (xkb style, as used in hyprland.conf) mapped to macOS virtual key codes.
public enum MacKeyCodes {
    public static let table: [String: UInt32] = {
        var t: [String: UInt32] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
            "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
            "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "equal": 0x18,
            "9": 0x19, "7": 0x1A, "minus": 0x1B, "8": 0x1C, "0": 0x1D, "bracketright": 0x1E, "o": 0x1F,
            "u": 0x20, "bracketleft": 0x21, "i": 0x22, "p": 0x23, "return": 0x24, "l": 0x25, "j": 0x26,
            "apostrophe": 0x27, "k": 0x28, "semicolon": 0x29, "backslash": 0x2A, "comma": 0x2B,
            "slash": 0x2C, "n": 0x2D, "m": 0x2E, "period": 0x2F, "tab": 0x30, "space": 0x31,
            "grave": 0x32, "backspace": 0x33, "escape": 0x35,
            "home": 0x73, "prior": 0x74, "delete": 0x75, "end": 0x77, "next": 0x79,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
            "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B,
            "f15": 0x71, "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
        ]
        // Common aliases.
        t["enter"] = t["return"]
        t["esc"] = t["escape"]
        t["page_up"] = t["prior"]
        t["pageup"] = t["prior"]
        t["page_down"] = t["next"]
        t["pagedown"] = t["next"]
        t["equals"] = t["equal"]
        t["quoteleft"] = t["grave"]
        t["quote"] = t["apostrophe"]
        t["dot"] = t["period"]
        return t
    }()

    public static func code(for key: String) -> UInt32? { table[normalize(key)] }

    public static func normalize(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
