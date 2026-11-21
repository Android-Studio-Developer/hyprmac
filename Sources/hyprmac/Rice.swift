import AppKit
import HyprmacCore

/// `hyprmac rice ...`: install a dotfiles repo ("rice") and apply the parts that work on macOS.
///
/// Applying = symlink the rice's portable `.config/<app>` folders into ~/.config (existing ones are
/// moved to a backup), point hyprmac at the rice's hyprland.lua / hyprland.conf, and set its
/// wallpaper. `rice off` undoes all of it from the saved manifest. The rice's own install script
/// is never run.
enum Rice {
    static var root: String { MacCompat.dataDir + "/rices" }
    static var manifestPath: String { MacCompat.dataDir + "/active-rice.json" }
    static var backupRoot: String { MacCompat.dataDir + "/backups" }
    static var home: String { ConfigParser.home }
    static let fm = FileManager.default
    /// Set inside the running daemon: it reloads itself instead of messaging its own socket
    /// (which would deadlock the main thread).
    static var onApplied: (() -> Void)?

    struct Manifest: Codable {
        struct Link: Codable {
            var target: String
            var source: String
            var backup: String?
        }
        var rice: String
        var appliedAt: Date
        var links: [Link]
        /// hyprmac config file we wrote, and where the previous one was moved.
        var configWritten: String?
        var configBackup: String?
        /// Screen name -> previous wallpaper URL.
        var wallpapers: [String: String]
    }

    struct Plan {
        var name: String
        var dir: String
        var configRoot: String
        var items: [(name: String, kind: RiceCatalog.Kind)]
        /// Path of the Hyprland config inside the rice.
        var hyprConfig: String?
        var wallpaper: String?
    }

    static let usage = """
    usage: hyprmac rice install <git-url | folder> [--name NAME]
           hyprmac rice show <name>                 what `use` would do
           hyprmac rice use <name> [--dry-run] [--no-wallpaper] [--with-shell] [--all]
           hyprmac rice off                         undo the active rice, restore backups
           hyprmac rice list
           hyprmac rice update <name>               git pull
           hyprmac rice remove <name>

    Rices live in ~/.local/share/hyprmac/rices/. Replaced configs are backed up to
    ~/.local/share/hyprmac/backups/. A rice's own install script is never run, but its
    Lua config and keybinds do run commands, so only use rices you trust.
    """

    static func main(_ args: [String]) -> Int32 {
        guard let cmd = args.first else {
            print(usage)
            return 1
        }
        var rest = Array(args.dropFirst())
        func flag(_ f: String) -> Bool {
            guard let i = rest.firstIndex(of: f) else { return false }
            rest.remove(at: i)
            return true
        }
        func option(_ f: String) -> String? {
            guard let i = rest.firstIndex(of: f), i + 1 < rest.count else { return nil }
            let v = rest[i + 1]
            rest.removeSubrange(i...(i + 1))
            return v
        }
        do {
            switch cmd {
            case "install":
                let name = option("--name")
                guard let src = rest.first else { throw RiceError("install needs a git URL or folder") }
                try install(src, name: name)
            case "show":
                guard let name = rest.first else { throw RiceError("show needs a rice name") }
                printPlan(try plan(name))
            case "use", "apply":
                let dry = flag("--dry-run")
                let noWall = flag("--no-wallpaper")
                let shell = flag("--with-shell")
                let all = flag("--all")
                guard let name = rest.first else { throw RiceError("use needs a rice name") }
                try use(name, dryRun: dry, wallpaper: !noWall, withShell: shell, all: all)
            case "off", "restore":
                try off()
            case "list", "ls":
                list()
            case "update":
                guard let name = rest.first else { throw RiceError("update needs a rice name") }
                let dir = root + "/" + name
                guard fm.fileExists(atPath: dir + "/.git") else { throw RiceError("\(name) is not a git clone") }
                try git(["-C", dir, "pull", "--ff-only"])
            case "remove", "rm":
                guard let name = rest.first else { throw RiceError("remove needs a rice name") }
                try remove(name)
            case "help", "-h", "--help":
                print(usage)
            default:
                throw RiceError("unknown rice command \(cmd)\n\n\(usage)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("hyprmac rice: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: install / list / remove

    static func defaultName(for src: String) -> String {
        var s = src
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(whereSeparator: { $0 == "/" || $0 == ":" }).map(String.init)
        let repo = parts.last ?? "rice"
        let owner = parts.count >= 2 ? parts[parts.count - 2] : ""
        let generic: Set<String> = ["dotfiles", ".dotfiles", "dots", "dotfile", "config", "configs", "rice", ".config"]
        let raw = generic.contains(repo.lowercased()) && !owner.isEmpty ? owner : repo
        let cleaned = raw.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    }

    static func install(_ src: String, name: String?) throws {
        let name = name ?? defaultName(for: src)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw RiceError("bad rice name \(name)") }
        let dest = root + "/" + name
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: dest) else {
            throw RiceError("\(name) is already installed (hyprmac rice update \(name), or remove it first)")
        }
        let local = ConfigParser.expand(src)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: local, isDirectory: &isDir), isDir.boolValue {
            let abs = URL(fileURLWithPath: local).standardizedFileURL.path
            try fm.createSymbolicLink(atPath: dest, withDestinationPath: abs)
            print("linked local rice \(abs) as \(name)")
        } else {
            guard src.hasPrefix("https://") || src.hasPrefix("git@") || src.hasPrefix("ssh://") else {
                throw RiceError("\(src) is not a folder or a git URL")
            }
            try git(["clone", "--depth", "1", src, dest])
        }
        print("")
        print("Only use rices you trust: their keybinds and Lua config run commands on this Mac.")
        print("")
        printPlan(try plan(name))
        print("\nApply it with: hyprmac rice use \(name)")
    }

    static func list() {
        let active = loadManifest()?.rice
        let names = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        if names.isEmpty {
            print("no rices installed (hyprmac rice install <git-url>)")
        }
        for n in names { print((n == active ? "* " : "  ") + n) }
    }

    static func remove(_ name: String) throws {
        let dest = root + "/" + name
        guard !name.isEmpty, !name.contains("/"), fm.fileExists(atPath: dest) || isSymlink(dest) else {
            throw RiceError("no rice named \(name)")
        }
        if loadManifest()?.rice == name { try off() }
        try fm.removeItem(atPath: dest)  // a symlinked local rice: removes only the link
        print("removed \(name)")
    }

    // MARK: plan

    static func plan(_ name: String) throws -> Plan {
        let dir = root + "/" + name
        guard fm.fileExists(atPath: dir) else { throw RiceError("no rice named \(name) (hyprmac rice list)") }
        let dotConfig = dir + "/.config"
        var configRoot = dir
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dotConfig, isDirectory: &isDir), isDir.boolValue { configRoot = dotConfig }

        let entries = ((try? fm.contentsOfDirectory(atPath: configRoot)) ?? [])
            .filter { $0 != ".git" && $0 != ".DS_Store" && $0 != ".github" }
            .sorted()
        var items = entries.map { (name: $0, kind: RiceCatalog.classify($0)) }
        if configRoot == dir {
            // Repo-root layout: ignore files that are clearly not configs.
            let junk = ["README", "LICENSE", "install", "update", "assets", "docs", "packages", "screenshots"]
            items = items.filter { item in item.kind != .unknown || !junk.contains { item.name.hasPrefix($0) } }
        }

        var hypr: String?
        for candidate in ["hyprmac/hyprland.lua", "hyprmac/hyprland.conf", "hypr/hyprland.lua", "hypr/hyprland.conf",
                          "hyprland.lua", "hyprland.conf"] {
            let p = configRoot + "/" + candidate
            if fm.fileExists(atPath: p) {
                hypr = p
                break
            }
        }

        var images: [String] = []
        if let e = fm.enumerator(atPath: dir) {
            while let rel = e.nextObject() as? String {
                if rel.hasPrefix(".git/") || rel.contains("node_modules") { e.skipDescendants(); continue }
                if rel.split(separator: "/").count > 5 { e.skipDescendants(); continue }
                images.append(rel)
            }
        }
        let wall = RiceCatalog.wallpaperCandidates(images).first.map { dir + "/" + $0 }
        return Plan(name: name, dir: dir, configRoot: configRoot, items: items, hyprConfig: hypr, wallpaper: wall)
    }

    static func printPlan(_ p: Plan) {
        print("rice \(p.name)  (\(p.dir))")
        if let h = p.hyprConfig {
            let rel = h.replacingOccurrences(of: p.dir + "/", with: "")
            print("  window manager config: \(rel)\(h.hasSuffix(".lua") ? " (Hyprland Lua)" : "")")
        } else {
            print("  no hyprland.conf / hyprland.lua found: hyprmac keeps your current config")
        }
        func names(_ k: RiceCatalog.Kind) -> String {
            let n = p.items.filter { $0.kind == k }.map(\.name)
            return n.isEmpty ? "-" : n.joined(separator: ", ")
        }
        print("  link into ~/.config:   \(names(.link))")
        print("  Linux-only, skipped:   \(names(.linuxOnly))")
        print("  shell files, skipped:  \(names(.shell))  (--with-shell to link)")
        print("  unknown, skipped:      \(names(.unknown))  (--all to link)")
        if let w = p.wallpaper {
            print("  wallpaper:             \(w.replacingOccurrences(of: p.dir + "/", with: ""))")
        }
    }

    // MARK: use / off

    static func target(for item: String) -> String {
        // Shell dotfiles go to ~, everything else to ~/.config.
        item.hasPrefix(".") ? home + "/" + item : home + "/.config/" + item
    }

    static func use(_ name: String, dryRun: Bool, wallpaper: Bool, withShell: Bool, all: Bool) throws {
        let p = try plan(name)
        let chosen = p.items.filter { item in
            switch item.kind {
            case .link: return true
            case .shell: return withShell
            case .unknown: return all
            case .linuxOnly: return false
            }
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let backupDir = backupRoot + "/\(name)-\(stamp.string(from: Date()))"

        if dryRun {
            print("dry run: nothing changes")
            if let active = loadManifest()?.rice { print("would first undo the active rice \(active)") }
            for item in chosen {
                let t = target(for: item.name)
                let exists = fm.fileExists(atPath: t) || isSymlink(t)
                print("  link \(t) -> \(p.configRoot)/\(item.name)\(exists ? "  (existing moved to backup)" : "")")
            }
            if let h = p.hyprConfig, !chosen.contains(where: { $0.name == "hyprmac" }) {
                print("  write \(ConfigParser.expand(Config.defaultPath)): source = \(configSource(h, plan: p, linked: chosen.map(\.name)))")
            }
            if wallpaper, let w = p.wallpaper { print("  wallpaper: \(w)") }
            return
        }

        if loadManifest() != nil { try off(quiet: true) }

        var manifest = Manifest(rice: name, appliedAt: Date(), links: [], configWritten: nil, configBackup: nil, wallpapers: [:])
        // Save as we go so `rice off` can undo a half-applied rice.
        func save() throws {
            try fm.createDirectory(atPath: MacCompat.dataDir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(manifest).write(to: URL(fileURLWithPath: manifestPath))
        }
        try save()

        try fm.createDirectory(atPath: home + "/.config", withIntermediateDirectories: true)
        for item in chosen {
            let t = target(for: item.name)
            let src = p.configRoot + "/" + item.name
            var backup: String?
            if fm.fileExists(atPath: t) || isSymlink(t) {
                if let dest = try? fm.destinationOfSymbolicLink(atPath: t), dest == src { continue }
                let b = backupDir + "/" + t.replacingOccurrences(of: home + "/", with: "")
                try fm.createDirectory(atPath: (b as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: t, toPath: b)
                backup = b
            }
            try fm.createSymbolicLink(atPath: t, withDestinationPath: src)
            manifest.links.append(.init(target: t, source: src, backup: backup))
            try save()
            print("linked \(t)\(backup != nil ? "  (old one backed up)" : "")")
        }

        if let h = p.hyprConfig, !chosen.contains(where: { $0.name == "hyprmac" }) {
            let cfg = ConfigParser.expand(Config.defaultPath)
            try fm.createDirectory(atPath: (cfg as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: cfg) || isSymlink(cfg) {
                let b = backupDir + "/.config/hyprmac/hyprland.conf"
                try fm.createDirectory(atPath: (b as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: cfg, toPath: b)
                manifest.configBackup = b
            }
            try pointerConfig(rice: name, source: configSource(h, plan: p, linked: chosen.map(\.name)))
                .write(toFile: cfg, atomically: true, encoding: .utf8)
            manifest.configWritten = cfg
            try save()
            print("hyprmac now loads \(configSource(h, plan: p, linked: chosen.map(\.name)).replacingOccurrences(of: home, with: "~"))")
        }

        if wallpaper, let w = p.wallpaper {
            for screen in NSScreen.screens {
                if let old = NSWorkspace.shared.desktopImageURL(for: screen) {
                    manifest.wallpapers[screen.localizedName] = old.path
                }
                try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: w), for: screen, options: [:])
            }
            try save()
            print("wallpaper set")
        }

        print("\nrice \(name) applied. Linux-only parts skipped: \(p.items.filter { $0.kind == .linuxOnly }.map(\.name).joined(separator: ", "))")
        print("SUPER is mapped to Option (edit ~/.config/hyprmac/hyprland.conf to change). Undo: hyprmac rice off")
        notifyReload()
    }

    /// `source =` path for the rice's config: through ~/.config/hypr when that folder was linked,
    /// because rice Lua files often hard-code ~/.config/hypr/... paths.
    static func configSource(_ hypr: String, plan p: Plan, linked: [String]) -> String {
        let rel = hypr.replacingOccurrences(of: p.configRoot + "/", with: "")
        if let top = rel.split(separator: "/").first, linked.contains(String(top)), rel.contains("/") {
            return "~/.config/" + rel
        }
        return hypr
    }

    static func pointerConfig(rice: String, source: String) -> String {
        """
        # Managed by `hyprmac rice use \(rice)`.
        # `hyprmac rice off` puts back the config you had before.
        #
        # Linux rices bind SUPER + C, V, Q... which would break Cmd+C / Cmd+V, so SUPER is
        # mapped to Option. Other choices: cmd, ctrl, "ctrl alt".
        hyprmac {
            super = alt
        }

        source = \(source)

        # Your macOS tweaks go below; they apply after the rice.

        """
    }

    static func off(quiet: Bool = false) throws {
        guard let m = loadManifest() else {
            if !quiet { print("no rice is active") }
            return
        }
        for link in m.links.reversed() {
            if isSymlink(link.target), (try? fm.destinationOfSymbolicLink(atPath: link.target)) == link.source {
                try fm.removeItem(atPath: link.target)
            }
            if let b = link.backup, fm.fileExists(atPath: b) || isSymlink(b), !fm.fileExists(atPath: link.target), !isSymlink(link.target) {
                try fm.moveItem(atPath: b, toPath: link.target)
            }
        }
        if let cfg = m.configWritten, fm.fileExists(atPath: cfg) {
            try fm.removeItem(atPath: cfg)
        }
        if let b = m.configBackup, let cfg = m.configWritten, fm.fileExists(atPath: b) {
            try fm.moveItem(atPath: b, toPath: cfg)
        } else if m.configWritten != nil {
            // There was no config before: start from the default again.
            try? DefaultConfig.text.write(toFile: ConfigParser.expand(Config.defaultPath), atomically: true, encoding: .utf8)
        }
        for screen in NSScreen.screens {
            if let old = m.wallpapers[screen.localizedName] {
                try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: old), for: screen, options: [:])
            }
        }
        try fm.removeItem(atPath: manifestPath)
        if !quiet { print("rice \(m.rice) removed; previous configs restored") }
        notifyReload()
    }

    // MARK: helpers

    static func loadManifest() -> Manifest? {
        guard let d = fm.contents(atPath: manifestPath) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Manifest.self, from: d)
    }

    static func isSymlink(_ path: String) -> Bool {
        (try? fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    static func notifyReload() {
        if let onApplied {
            onApplied()
        } else {
            _ = try? Control.send("reload", socket: HyprmacInfo.socketPath(uid: getuid()))
        }
    }

    static var installed: [String] {
        ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    static var active: String? { loadManifest()?.rice }

    static func git(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw RiceError("git \(args.first ?? "") failed") }
    }
}

struct RiceError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
