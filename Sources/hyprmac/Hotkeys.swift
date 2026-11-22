import Carbon
import HyprmacCore

/// Global hotkeys through Carbon's RegisterEventHotKey. Needs no Accessibility or
/// Input Monitoring permission and swallows the key so apps don't also see it.
final class Hotkeys {
    private var refs: [EventHotKeyRef] = []
    private var binds: [UInt32: KeyBind] = [:]
    private var handlerRef: EventHandlerRef?
    private let onPress: (KeyBind) -> Void

    init(onPress: @escaping (KeyBind) -> Void) {
        self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr else { return err }
            let this = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            if let bind = this.binds[hk.id] {
                // Leave the Carbon callback before doing window work.
                DispatchQueue.main.async { this.onPress(bind) }
            }
            return noErr
        }, 1, &spec, me, &handlerRef)
    }

    /// System shortcuts a bind must never take over (after SUPER is remapped). `.superKey` = Command.
    static func reserved(_ m: Modifiers, _ key: String) -> String? {
        var base = m
        base.remove(.shift)
        switch (base, key) {
        case ([.superKey], "tab"): return "the app switcher (Cmd+Tab)"
        case ([.superKey], "space"): return "Spotlight (Cmd+Space)"
        case ([.superKey, .ctrl], "q"): return "lock screen (Ctrl+Cmd+Q)"
        case ([.superKey, .alt], "escape"): return "Force Quit (Opt+Cmd+Esc)"
        default: return nil
        }
    }

    /// Replaces all hotkeys. Returns errors for combos that could not be registered.
    func register(_ list: [KeyBind], superMapsTo: Modifiers = [.superKey]) -> [String] {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        binds.removeAll()
        var errors: [String] = []
        var nextID: UInt32 = 1
        for b in list {
            guard let code = MacKeyCodes.code(for: b.key) else { continue }
            var logical = b.mods
            if logical.contains(.superKey) {
                logical.remove(.superKey)
                logical.formUnion(superMapsTo)  // .superKey here means the physical Command key
            }
            if let why = Hotkeys.reserved(logical, b.key) {
                let combo = (b.mods.names + [b.key]).joined(separator: "+")
                errors.append("skipped \(combo): it would take over \(why)")
                continue
            }
            var mods: UInt32 = 0
            if logical.contains(.superKey) { mods |= UInt32(cmdKey) }
            if logical.contains(.shift) { mods |= UInt32(shiftKey) }
            if logical.contains(.alt) { mods |= UInt32(optionKey) }
            if logical.contains(.ctrl) { mods |= UInt32(controlKey) }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4859_504D), id: nextID)  // "HYPM"
            let err = RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref)
            if err == noErr, let ref {
                refs.append(ref)
                binds[nextID] = b
                nextID += 1
            } else {
                let combo = (b.mods.names + [b.key]).joined(separator: "+")
                errors.append("cannot register hotkey \(combo) (taken by another app or the system, error \(err))")
            }
        }
        return errors
    }
}
