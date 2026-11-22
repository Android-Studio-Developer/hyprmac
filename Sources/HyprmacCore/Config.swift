import Foundation

public struct KeyBind: Equatable, Sendable {
    public var mods: Modifiers
    public var key: String
    public var dispatcher: String
    public var arg: String

    public init(mods: Modifiers, key: String, dispatcher: String, arg: String) {
        self.mods = mods
        self.key = key
        self.dispatcher = dispatcher
        self.arg = arg
    }
}

public struct WindowRule: Equatable, Sendable {
    /// The effect, e.g. "float", "tile", "center", "fullscreen", "workspace 3 silent", "size 800 600".
    public var effect: String
    public var classPattern: String?
    public var titlePattern: String?

    public init(effect: String, classPattern: String? = nil, titlePattern: String? = nil) {
        self.effect = effect
        self.classPattern = classPattern
        self.titlePattern = titlePattern
    }

    /// `appClass` candidates are matched in turn (app name, bundle id). Regexes must match the
    /// whole string, like Hyprland, but case-insensitively.
    public func matches(appClasses: [String], title: String) -> Bool {
        if let p = classPattern, !appClasses.contains(where: { WindowRule.fullMatch(p, $0) }) { return false }
        if let p = titlePattern, !WindowRule.fullMatch(p, title) { return false }
        return classPattern != nil || titlePattern != nil
    }

    static func fullMatch(_ pattern: String, _ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$", options: [.caseInsensitive]) else {
            return false
        }
        return re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    public var effectName: String { String(effect.split(separator: " ").first ?? "") }
    public var effectArgs: [String] { effect.split(separator: " ").dropFirst().map(String.init) }
}

public struct Config: Sendable {
    // general
    public var gapsIn = Insets(all: 5)
    public var gapsOut = Insets(all: 20)
    public var borderSize = 2.0
    public var activeBorder = BorderColor(colors: [RGBA(hex: "33ccffee")!, RGBA(hex: "00ff99ee")!], angle: 45)
    public var inactiveBorder = BorderColor(colors: [RGBA(hex: "595959aa")!])
    public var layout = "dwindle"
    // decoration
    public var rounding = 10.0
    // dwindle
    public var preserveSplit = false
    public var forceSplit = 0
    public var splitWidthMultiplier = 1.0
    public var defaultSplitRatio = 1.0
    // master
    public var mfact = 0.55
    public var newStatus = "slave"
    public var newOnTop = false
    public var orientation = "left"
    // hyprmac-only
    public var statusBar = true
    /// Physical modifier(s) that SUPER binds use. Default Command. Rices made for Linux bind
    /// SUPER+C/V/Q..., which would break copy/paste on a Mac, so `hyprmac rice use` sets ALT.
    public var superMapsTo: Modifiers = [.superKey]
    /// Desktop shell: Caelestia-style top bar and screen frame (Windows: bar, launcher, dashboard).
    public var shell = true
    /// Hide the taskbar (Windows) / auto-hide the menu bar (macOS) while the shell runs.
    public var hideTaskbar = true
    /// "auto" = colors from the wallpaper, or a color like rgb(89b4fa) to seed the scheme.
    public var scheme = "auto"
    /// The config set col.active_border / col.inactive_border itself (the shell scheme won't override).
    public var bordersExplicit = false

    public var binds: [KeyBind] = []
    public var execOnce: [String] = []
    public var exec: [String] = []
    public var rules: [WindowRule] = []

    /// Real problems (bad values, unknown dispatchers). Shown by `hyprmacctl configerrors`.
    public var errors: [String] = []
    /// Valid Hyprland options that hyprmac ignores on macOS.
    public var ignored: [String] = []
    /// Files read, including `source =` files. Watched for hot reload.
    public var files: [String] = []

    public init() {}

    public var dwindle: DwindleSettings {
        DwindleSettings(preserveSplit: preserveSplit, forceSplit: forceSplit,
                        splitWidthMultiplier: splitWidthMultiplier, defaultSplitRatio: defaultSplitRatio)
    }

    public static let defaultPath = "~/.config/hyprmac/hyprland.conf"
}

public enum Dispatchers {
    public static let known: Set<String> = [
        "exec", "killactive", "closewindow", "workspace", "movetoworkspace", "movetoworkspacesilent",
        "movefocus", "movewindow", "swapwindow", "togglefloating", "setfloating", "settiled",
        "fullscreen", "togglesplit", "splitratio", "layoutmsg", "exit", "focusmonitor",
        "cyclenext", "centerwindow", "pseudo", "pin", "moveactive", "resizeactive",
        "lua",  // internal: run a function or multi-line command from a Lua config
        "global",  // shell actions: global, shell:launcher (also accepts caelestia:launcher)
    ]
    /// Known Hyprland dispatchers that have no macOS meaning yet.
    public static let unsupported: Set<String> = ["pseudo", "pin"]
}

public enum ConfigParser {
    /// Loads a Hyprland Lua config and returns equivalent hyprlang text, the files it read and an
    /// error (if the Lua code failed). Installed by the HyprLua module.
    public static var luaLoader: ((String) -> (text: String, files: [String], error: String?))?

    public static func load(path: String) -> Config {
        let expanded = expand(path)
        if expanded.hasSuffix(".lua") {
            var c = parse("source = \(expanded)\n", file: "<lua>")
            c.files.removeAll { $0 == "<lua>" }
            return c
        }
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            var c = Config()
            c.errors.append("cannot read \(expanded)")
            return c
        }
        return parse(text, file: expanded)
    }

    public static func parse(_ text: String, file: String = "hyprland.conf",
                             readFile: @escaping (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Config {
        var p = Parser(readFile: readFile)
        p.config.files.append(file)
        p.run(text, file: file, depth: 0)
        if !p.sections.isEmpty { p.config.errors.append("\(file): missing closing }") }
        return p.config
    }

    /// Expands `~` using $HOME (like Hyprland and Lua's os.getenv("HOME")).
    public static func expand(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home + path.dropFirst()
    }

    public static var home: String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }
}

private struct Parser {
    var config = Config()
    var vars: [String: String] = [:]
    var sections: [String] = []
    let readFile: (String) -> String?

    init(readFile: @escaping (String) -> String?) { self.readFile = readFile }

    mutating func run(_ text: String, file: String, depth: Int) {
        var lineNo = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNo += 1
            let where_ = "\((file as NSString).lastPathComponent):\(lineNo)"
            var line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Allow "}" plus trailing content like "} # end" (comment already stripped).
            while line.hasPrefix("}") {
                if sections.isEmpty { config.errors.append("\(where_): unexpected }") } else { sections.removeLast() }
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if line.isEmpty { continue }

            if line.hasSuffix("{") {
                let name = line.dropLast().trimmingCharacters(in: .whitespaces)
                // device[name] { ... } or device { ... }
                sections.append(name.split(separator: "[").first.map(String.init) ?? name)
                continue
            }

            guard let eq = line.firstIndex(of: "=") else {
                config.errors.append("\(where_): expected key = value")
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = substitute(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))

            if key.hasPrefix("$") {
                vars[String(key.dropFirst())] = value
                continue
            }
            let full = (sections + [key]).joined(separator: ":")
            handle(full, value, where_: where_, file: file, depth: depth)
        }
    }

    /// "#" starts a comment; "##" is a literal "#".
    func stripComment(_ s: String) -> String {
        var out = ""
        let it = Array(s)
        var i = 0
        while i < it.count {
            if it[i] == "#" {
                if i + 1 < it.count, it[i + 1] == "#" {
                    out.append("#")
                    i += 2
                    continue
                }
                break
            }
            out.append(it[i])
            i += 1
        }
        return out
    }

    func substitute(_ s: String) -> String {
        guard s.contains("$"), !vars.isEmpty else { return s }
        var out = s
        for name in vars.keys.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: "$" + name, with: vars[name]!)
        }
        return out
    }

    mutating func handle(_ key: String, _ value: String, where_: String, file: String, depth: Int) {
        func bool(_ v: String) -> Bool? {
            switch v.lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return nil
            }
        }
        func number(_ v: String) -> Double? { Double(v) }
        func bad() { config.errors.append("\(where_): invalid value for \(key): \(value)") }

        switch key {
        case "source":
            guard depth < 8 else { config.errors.append("\(where_): source nested too deep"); return }
            var path = ConfigParser.expand(value)
            if !path.hasPrefix("/") {
                path = ((file as NSString).deletingLastPathComponent as NSString).appendingPathComponent(path)
            }
            if path.hasSuffix(".lua") {
                guard let loader = ConfigParser.luaLoader else {
                    config.errors.append("\(where_): Lua configs need hyprmac's Lua support")
                    return
                }
                let r = loader(path)
                config.files.append(path)
                for f in r.files where !config.files.contains(f) { config.files.append(f) }
                if let e = r.error { config.errors.append("\((path as NSString).lastPathComponent): \(e)") }
                let saved = sections
                sections = []
                run(r.text, file: path + " (lua)", depth: depth + 1)
                sections = saved
                return
            }
            guard let text = readFile(path) else {
                config.errors.append("\(where_): cannot read source \(path)")
                return
            }
            config.files.append(path)
            let saved = sections
            sections = []
            run(text, file: path, depth: depth + 1)
            sections = saved

        case "exec-once": config.execOnce.append(value)
        case "exec": config.exec.append(value)

        case "windowrule", "windowrulev2":
            if let r = parseRule(value, v2: key == "windowrulev2") { config.rules.append(r) } else { bad() }

        case "unbind":
            let parts = value.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let mods = Modifiers.parse(parts[0]) else { bad(); return }
            let k = MacKeyCodes.normalize(parts[1])
            config.binds.removeAll { $0.mods == mods && $0.key == k }

        case "general:gaps_in": if let v = Insets(css: value) { config.gapsIn = v } else { bad() }
        case "general:gaps_out": if let v = Insets(css: value) { config.gapsOut = v } else { bad() }
        case "general:border_size": if let v = number(value), v >= 0 { config.borderSize = v } else { bad() }
        case "general:col.active_border":
            if let v = BorderColor.parse(value) { config.activeBorder = v; config.bordersExplicit = true } else { bad() }
        case "general:col.inactive_border":
            if let v = BorderColor.parse(value) { config.inactiveBorder = v; config.bordersExplicit = true } else { bad() }
        case "general:layout":
            if value == "dwindle" || value == "master" { config.layout = value } else { bad() }

        case "decoration:rounding": if let v = number(value), v >= 0 { config.rounding = v } else { bad() }

        case "dwindle:preserve_split": if let v = bool(value) { config.preserveSplit = v } else { bad() }
        case "dwindle:force_split": if let v = Int(value), (0...2).contains(v) { config.forceSplit = v } else { bad() }
        case "dwindle:split_width_multiplier": if let v = number(value), v > 0 { config.splitWidthMultiplier = v } else { bad() }
        case "dwindle:default_split_ratio":
            if let v = number(value), v >= 0.1, v <= 1.9 { config.defaultSplitRatio = v } else { bad() }

        case "master:mfact": if let v = number(value), v > 0, v < 1 { config.mfact = v } else { bad() }
        case "master:new_status":
            if ["master", "slave", "inherit"].contains(value) { config.newStatus = value } else { bad() }
        case "master:new_on_top": if let v = bool(value) { config.newOnTop = v } else { bad() }
        case "master:orientation":
            if ["left", "right", "top", "bottom"].contains(value) { config.orientation = value } else { bad() }

        case "hyprmac:status_bar": if let v = bool(value) { config.statusBar = v } else { bad() }
        case "hyprmac:shell": if let v = bool(value) { config.shell = v } else { bad() }
        case "hyprmac:hide_taskbar", "hyprmac:hide_menubar": if let v = bool(value) { config.hideTaskbar = v } else { bad() }
        case "hyprmac:scheme":
            if value == "auto" || BorderColor.parse(value) != nil { config.scheme = value } else { bad() }
        case "hyprmac:super":
            if let m = Modifiers.parse(value), !m.isEmpty { config.superMapsTo = m } else { bad() }

        default:
            if key.hasPrefix("bind") {
                parseBind(kind: key, value, where_: where_)
            } else if Parser.ignoredPrefixes.contains(where: { key == $0 || key.hasPrefix($0 + ":") }) {
                config.ignored.append(key)
            } else {
                config.errors.append("\(where_): unknown option \(key)")
            }
        }
    }

    /// Real Hyprland options that have no effect on macOS (yet). Accepted silently so a Linux
    /// hyprland.conf can be reused.
    static let ignoredPrefixes = [
        "monitor", "env", "workspace", "animation", "bezier", "animations", "input", "device",
        "gestures", "gesture", "misc", "cursor", "xwayland", "opengl", "render", "debug", "ecosystem",
        "experimental", "binds", "group", "decoration", "general", "dwindle", "master", "plugin",
        "layerrule", "permission", "exec-shutdown", "execr", "execr-once", "submap", "windowrule",
        "hyprmac",
    ]

    mutating func parseBind(kind: String, _ value: String, where_: String) {
        let flags = Set(kind.dropFirst(4))
        if flags.contains("m") {
            config.ignored.append(kind)  // mouse binds: not supported yet
            return
        }
        guard flags.isSubset(of: Set("lrenitsdpo")) else {
            config.errors.append("\(where_): unknown bind kind \(kind)")
            return
        }
        // MODS, key, dispatcher, args (args may contain commas)
        let parts = value.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else {
            config.errors.append("\(where_): bind needs MODS, key, dispatcher")
            return
        }
        guard let mods = Modifiers.parse(parts[0]) else {
            config.errors.append("\(where_): unknown modifier in \(parts[0])")
            return
        }
        let key = MacKeyCodes.normalize(parts[1])
        // Mouse buttons/wheel, media keys and raw keycodes: no macOS hotkey equivalent yet.
        if key.hasPrefix("mouse") || key.hasPrefix("xf86") || key.hasPrefix("code:") {
            config.ignored.append("\(kind) \(parts[0]) \(parts[1])")
            return
        }
        guard MacKeyCodes.code(for: key) != nil else {
            config.errors.append("\(where_): unknown key \(parts[1])")
            return
        }
        let dispatcher = parts[2].lowercased()
        if dispatcher == "unsupported" || dispatcher == "mouse" {
            config.ignored.append("\(kind) \(parts[0]) \(parts[1]): \(parts.count > 3 ? parts[3] : dispatcher)")
            return
        }
        guard Dispatchers.known.contains(dispatcher) else {
            config.errors.append("\(where_): unknown dispatcher \(parts[2])")
            return
        }
        let arg = parts.count > 3 ? parts[3] : ""
        config.binds.removeAll { $0.mods == mods && $0.key == key }
        config.binds.append(KeyBind(mods: mods, key: key, dispatcher: dispatcher, arg: arg))
    }

    func parseRule(_ value: String, v2: Bool) -> WindowRule? {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        var rule = WindowRule(effect: parts[0].split(separator: " ").joined(separator: " "))
        for m in parts.dropFirst() {
            if let r = m.range(of: ":"), ["class", "initialclass", "title", "initialtitle"].contains(m[..<r.lowerBound].lowercased()) {
                let prop = m[..<r.lowerBound].lowercased()
                let pat = String(m[r.upperBound...])
                if prop.hasSuffix("class") { rule.classPattern = pat } else { rule.titlePattern = pat }
            } else if !v2 {
                rule.classPattern = m  // v1: plain regex means class
            } else if m.contains(":") {
                continue  // other v2 matchers (floating:, xwayland:, ...) ignored
            } else {
                return nil
            }
        }
        guard rule.classPattern != nil || rule.titlePattern != nil else { return nil }
        return rule
    }
}
