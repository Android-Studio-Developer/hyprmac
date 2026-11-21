import AppKit
import HyprmacCore

/// PATH, Linux-tool shims and "is this program available" checks for commands hyprmac runs.
enum MacCompat {
    static var dataDir: String { ConfigParser.home + "/.local/share/hyprmac" }
    static var shimDir: String { dataDir + "/shims" }

    /// PATH for exec'd commands: shims, Homebrew, then the inherited PATH.
    static var path: String {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var dirs = [shimDir, "/opt/homebrew/bin", "/usr/local/bin", ConfigParser.home + "/.local/bin"]
        for d in inherited.split(separator: ":").map(String.init) where !dirs.contains(d) { dirs.append(d) }
        for d in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !dirs.contains(d) { dirs.append(d) }
        return dirs.joined(separator: ":")
    }

    private static var cache: [String: Bool] = [:]
    /// Shims that exist (or would, for --check-config). They count as available.
    private static var shimNames: Set<String> = []

    static func isAvailable(_ program: String) -> Bool {
        if shimNames.contains(program) { return true }
        if let c = cache[program] { return c }
        var ok = false
        if program.contains("/") {
            ok = FileManager.default.isExecutableFile(atPath: ConfigParser.expand(program))
        } else {
            ok = path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(program)") }
        }
        cache[program] = ok
        return ok
    }

    /// Missing programs for a command, including inside a script file it runs directly
    /// (e.g. `~/.config/hypr/scripts/screenshot-area.sh` calling grim and slurp).
    static func missing(in command: String) -> [String] {
        var out = LinuxCompat.missing(in: command, available: isAvailable)
        let first = command.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let candidates = [first] + command.split(separator: " ").dropFirst().prefix(2).map(String.init)  // `bash script.sh`
        for word in candidates where word.contains("/") {
            let path = ConfigParser.expand(word)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  (attrs[.size] as? Int ?? 0) < 256 * 1024,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for prog in LinuxCompat.programs(in: text) where !isAvailable(prog) && !out.contains(prog) {
                out.append(prog)
            }
        }
        return out
    }

    static func appExists(_ name: String) -> Bool {
        let dirs = ["/Applications", "/System/Applications", ConfigParser.home + "/Applications", "/Applications/Utilities"]
        return dirs.contains { FileManager.default.fileExists(atPath: "\($0)/\(name).app") }
    }

    /// hyprmacctl next to this binary (inside Hyprmac.app or .build), else on PATH.
    static var ctlPath: String {
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sibling = me.deletingLastPathComponent().appendingPathComponent("hyprmacctl").path
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        return "hyprmacctl"
    }

    /// Writes shims for missing Linux tools (replacing old ones). With `write: false` only works
    /// out which shims would exist, for --check-config. Returns the shim names.
    @discardableResult
    static func installShims(write: Bool = true) -> [String] {
        let fm = FileManager.default
        if write {
            try? fm.removeItem(atPath: shimDir)
            try? fm.createDirectory(atPath: shimDir, withIntermediateDirectories: true)
        }
        shimNames = []
        cache.removeAll()
        var installed: [String] = []
        for (name, script) in LinuxCompat.macShims(ctlPath: ctlPath, appExists: appExists).sorted(by: { $0.key < $1.key }) {
            let real = path.split(separator: ":").filter { $0 != shimDir }
                .contains { fm.isExecutableFile(atPath: "\($0)/\(name)") }
            guard !real else { continue }  // the real program wins
            if write {
                let p = shimDir + "/" + name
                guard fm.createFile(atPath: p, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755]) else { continue }
            }
            installed.append(name)
        }
        shimNames = Set(installed)
        cache.removeAll()
        return installed
    }
}
