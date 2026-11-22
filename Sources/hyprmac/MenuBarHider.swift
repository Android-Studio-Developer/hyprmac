import AppKit
import HyprmacCore

/// Turns on "Automatically hide and show the menu bar" while the shell runs and puts the
/// user's setting back afterwards. The original value is kept in a file so a crash or kill
/// still restores it on the next start or `hyprmac --restore-menubar`.
enum MenuBarHider {
    private static let key = "_HIHideMenuBar" as CFString
    static var stateFile: String { ConfigParser.home + "/.local/state/hyprmac/menubar-before" }

    private static func current() -> Bool? {
        CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool
    }

    private static func write(_ value: Bool?) {
        let v: CFPropertyList? = value.map { $0 ? kCFBooleanTrue : kCFBooleanFalse }
        CFPreferencesSetValue(key, v, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        DistributedNotificationCenter.default().postNotificationName(
            .init("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    static func hide() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: stateFile) {
            try? fm.createDirectory(atPath: (stateFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let before = current().map { $0 ? "1" : "0" } ?? "unset"
            try? before.write(toFile: stateFile, atomically: true, encoding: .utf8)
        }
        if current() != true { write(true) }
    }

    /// Restores the setting saved by `hide()`. Does nothing when nothing was saved.
    static func restore() {
        guard let before = try? String(contentsOfFile: stateFile, encoding: .utf8) else { return }
        let value: Bool? = before.hasPrefix("1") ? true : before.hasPrefix("0") ? false : nil
        if current() != value { write(value) }
        try? FileManager.default.removeItem(atPath: stateFile)
    }
}
