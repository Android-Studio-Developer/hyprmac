import AppKit
import ApplicationServices

/// Focusing a specific window of another app. macOS 14+ "cooperative activation" often ignores
/// NSRunningApplication.activate from a background agent, so this uses the same private
/// SkyLight calls as yabai and AeroSpace, loaded at runtime. Falls back to public API.
enum WindowFocus {
    private typealias SetFront = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias PostEvent = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    /// RTLD_DEFAULT: search every loaded image (GetProcessForPID lives in HIServices).
    private static let anyImage = UnsafeMutableRawPointer(bitPattern: -2)

    private static let setFront: SetFront? = sym(skylight, "_SLPSSetFrontProcessWithOptions")
    private static let postEvent: PostEvent? = sym(skylight, "SLPSPostEventRecordTo")
    private static let getPSN: GetPSN? = sym(anyImage, "GetProcessForPID")

    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static func focus(pid: pid_t, windowID: UInt32, element: AXUIElement) {
        var done = false
        if let setFront, let postEvent, let getPSN {
            // ProcessSerialNumber is two UInt32s.
            var psn: (UInt32, UInt32) = (0, 0)
            if withUnsafeMutablePointer(to: &psn, { getPSN(pid, UnsafeMutableRawPointer($0)) }) == 0 {
                let kCPSUserGenerated: UInt32 = 0x200
                _ = withUnsafeMutablePointer(to: &psn) { setFront(UnsafeMutableRawPointer($0), windowID, kCPSUserGenerated) }
                // Make it the key window (byte layout from yabai's window_manager_make_key_window).
                var bytes = [UInt8](repeating: 0, count: 0xf8)
                bytes[0x04] = 0xf8
                bytes[0x3a] = 0x10
                withUnsafeBytes(of: windowID.littleEndian) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
                for i in 0x20..<0x30 { bytes[i] = 0xff }
                bytes[0x08] = 0x01
                _ = withUnsafeMutablePointer(to: &psn) { p in bytes.withUnsafeMutableBufferPointer { postEvent(UnsafeMutableRawPointer(p), $0.baseAddress!) } }
                bytes[0x08] = 0x02
                _ = withUnsafeMutablePointer(to: &psn) { p in bytes.withUnsafeMutableBufferPointer { postEvent(UnsafeMutableRawPointer(p), $0.baseAddress!) } }
                done = true
            }
        }
        element.set(kAXMainAttribute, kCFBooleanTrue)
        element.perform(kAXRaiseAction)
        if !done {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    /// Nothing to focus (empty workspace): make hyprmac itself active. It has no windows, so
    /// keystrokes go nowhere instead of into a window parked on a hidden workspace. (Activating
    /// Finder would focus a Finder window that may live on another workspace.)
    static func focusDesktop() {
        NSApp.activate()
    }
}
