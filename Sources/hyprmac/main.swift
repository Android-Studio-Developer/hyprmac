import AppKit
import ApplicationServices
import HyprLua
import HyprmacCore

LuaConfig.install()

let usage = """
hyprmac \(HyprmacInfo.version): Hyprland-style tiling for macOS

usage: hyprmac [--config PATH]      run the window manager
       hyprmac rice ...               install and apply dotfiles rices (hyprmac rice help)
       hyprmac --check-config [PATH] parse the config and print problems
       hyprmac --print-default-config
       hyprmac --list                 show windows hyprmac would manage (moves nothing)
       hyprmac --version

Config: \(Config.defaultPath) (created on first run). Control: hyprmacctl.
"""

var args = Array(CommandLine.arguments.dropFirst())
var configPath = ProcessInfo.processInfo.environment["HYPRMAC_CONFIG"] ?? Config.defaultPath

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.first == "rice" {
    exit(Rice.main(Array(args.dropFirst())))
}

if args.contains("--help") || args.contains("-h") {
    print(usage)
    exit(0)
}
if args.contains("--version") || args.contains("-v") {
    print("hyprmac \(HyprmacInfo.version)")
    exit(0)
}
if args.contains("--print-default-config") {
    print(DefaultConfig.text, terminator: "")
    exit(0)
}
if let p = value(after: "--config") { configPath = p }

if args.contains("--check-config") {
    let path = value(after: "--check-config") ?? configPath
    let c = ConfigParser.load(path: path)
    MacCompat.installShims(write: false)
    let (usable, skipped) = WindowManager.splitBinds(c.binds)
    print("\(ConfigParser.expand(path)): \(usable.count) binds, \(c.rules.count) window rules, layout \(c.layout)")
    func gaps(_ i: Insets) -> String { i.top == i.right && i.right == i.bottom && i.bottom == i.left ? "\(Int(i.top))" : "\(Int(i.top)) \(Int(i.right)) \(Int(i.bottom)) \(Int(i.left))" }
    print("look: gaps_in \(gaps(c.gapsIn)), gaps_out \(gaps(c.gapsOut)), border \(Int(c.borderSize)), rounding \(Int(c.rounding)), active \(c.activeBorder.colors.map(\.hex).joined(separator: " ")), inactive \(c.inactiveBorder.colors.map(\.hex).joined(separator: " ")), SUPER = \(c.superMapsTo.contains(.superKey) ? "Command" : c.superMapsTo.names.joined(separator: "+"))")
    print("files: \(c.files.map { $0.replacingOccurrences(of: ConfigParser.home, with: "~") }.joined(separator: ", "))")
    if !c.ignored.isEmpty { print("ignored on macOS (\(c.ignored.count)): \(Set(c.ignored).sorted().joined(separator: ", "))") }
    for s in skipped { print("skipped bind: \(s)") }
    for b in usable {
        print("bind: \((b.mods.names + [b.key]).joined(separator: "+")) -> \(b.dispatcher) \(b.arg.prefix(70))")
    }
    for e in c.errors { print("error: \(e)") }
    exit(c.errors.isEmpty ? 0 : 1)
}

/// Creates the default config on first run (only at the default location).
func ensureConfig() {
    let path = ConfigParser.expand(configPath)
    guard !FileManager.default.fileExists(atPath: path) else { return }
    guard configPath == Config.defaultPath else {
        log("config not found: \(path)")
        exit(1)
    }
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    do {
        try DefaultConfig.text.write(toFile: path, atomically: true, encoding: .utf8)
        log("wrote default config to \(path)")
    } catch {
        log("cannot write default config: \(error)")
    }
}

func accessibilityTrusted(prompt: Bool) -> Bool {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}

if args.contains("--list") {
    guard accessibilityTrusted(prompt: false) else {
        print("Accessibility permission missing for this process (System Settings > Privacy & Security > Accessibility).")
        exit(1)
    }
    _ = NSApplication.shared
    let wm = WindowManager(configPath: configPath)
    wm.model.config = ConfigParser.load(path: configPath)
    wm.model.setMonitors(NSScreen.screens.map { s in
        (id: s.localizedName, name: s.localizedName, frame: Coords.ax(s.visibleFrame))
    })
    wm.scanAll()
    for m in wm.model.monitors { print("monitor \(m.name): \(m.frame) -> workspace \(m.workspace)") }
    for w in wm.windowSummary() {
        print("ws \(w.ws)  \(w.floating ? "float" : "tile ")  \(w.app)  —  \(w.title)")
    }
    exit(0)
}

// Another instance already running?
let sock = HyprmacInfo.socketPath(uid: getuid())
if let reply = try? Control.send("version", socket: sock), reply.hasPrefix("hyprmac") {
    log("already running (\(reply)). Use hyprmacctl, or quit it first.")
    exit(1)
}

signal(SIGPIPE, SIG_IGN)
ensureConfig()

final class AppDelegate: NSObject, NSApplicationDelegate {
    var wm: WindowManager?
    var waitTimer: Timer?
    var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                if sig == SIGHUP { self?.wm?.reload() } else if let wm = self?.wm { wm.shutdown() } else { exit(0) }
            }
            src.resume()
            signalSources.append(src)
        }

        if accessibilityTrusted(prompt: true) {
            startManager()
        } else {
            log("waiting for Accessibility permission: System Settings > Privacy & Security > Accessibility")
            waitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                if accessibilityTrusted(prompt: false) {
                    t.invalidate()
                    self?.startManager()
                }
            }
        }
    }

    func startManager() {
        let wm = WindowManager(configPath: configPath)
        self.wm = wm
        wm.start()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
