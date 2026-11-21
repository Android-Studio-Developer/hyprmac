import Darwin  // not Foundation: its swift-testing overlay is missing from the Command Line Tools
import Testing
@testable import HyprLua
@testable import HyprmacCore

@Suite(.serialized) struct LuaTests {
    func write(_ files: [String: String]) throws -> String {
        var template = Array("/tmp/hyprmac-lua-XXXXXX".utf8CString)
        guard let p = mkdtemp(&template) else { throw TestError() }
        let dir = String(cString: p)
        for (name, text) in files {
            guard let f = fopen(dir + "/" + name, "w") else { throw TestError() }
            fputs(text, f)
            fclose(f)
        }
        return dir
    }
    struct TestError: Error {}

    @Test func hyprlandLuaConfigBecomesConfig() throws {
        LuaConfig.install()
        let dir = try write([
            "hyprland.lua": """
            mainMod = "SUPER"
            hl.config({
                general = {
                    gaps_in = 4,
                    gaps_out = { top = 5, right = 8, bottom = 8, left = 8 },
                    border_size = 1,
                    col = { active_border = "rgba(89b4faff)", inactive_border = "rgba(45475aaa)" },
                    layout = "master",
                },
                decoration = { rounding = 8, blur = { enabled = true } },
                master = { new_status = "master" },
            })
            hl.env("QT_QPA_PLATFORM", "wayland")
            hl.on("hyprland.start", function() hl.exec_cmd("echo started") end)
            hl.exec_cmd("echo top-level")
            require("keys")
            hl.window_rule({ name = "x", match = { class = "^(kitty)$" }, float = true, size = "900 600" })
            hl.window_rule({ match = { class = ".*", fullscreen = true }, opacity = "1.0 override" })
            hl.layer_rule({ match = { namespace = "rofi" }, blur = true })
            """,
            "keys.lua": """
            hl.bind(mainMod .. " + T", hl.dsp.exec_cmd("kitty"))
            hl.bind(mainMod .. " + SHIFT + Q", hl.dsp.window.close())
            hl.bind(mainMod .. " + H", hl.dsp.focus({ direction = "left" }))
            hl.bind(mainMod .. " + SHIFT + 3", hl.dsp.window.move({ workspace = 3 }))
            hl.bind(mainMod .. " + 3", hl.dsp.focus({ workspace = 3 }))
            hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
            hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute"))
            hl.bind("Delete", hl.dsp.exec_cmd([==[sh -c '
            grim /tmp/x.png # shot
            ']==]))
            hl.bind(mainMod .. " + Space", function()
                hl.dispatch(hl.dsp.window.float({ action = "toggle" }))
                local w = hl.get_active_window()
                if w and w.floating then
                    hl.dispatch(hl.dsp.window.resize({ x = 100, y = 50, relative = false }))
                end
            end)
            """,
        ])
        let c = ConfigParser.load(path: dir + "/hyprland.lua")
        #expect(c.errors.isEmpty, "\(c.errors)")
        #expect(c.gapsIn == Insets(all: 4))
        #expect(c.gapsOut == Insets(top: 5, right: 8, bottom: 8, left: 8))
        #expect(c.borderSize == 1)
        #expect(c.rounding == 8)
        #expect(c.layout == "master")
        #expect(c.newStatus == "master")
        #expect(c.activeBorder.colors[0].hex == "89b4faff")
        #expect(c.files.contains { $0.hasSuffix("/keys.lua") })

        func bind(_ key: String, _ mods: Modifiers = [.superKey]) -> KeyBind? {
            c.binds.first { $0.key == key && $0.mods == mods }
        }
        #expect(bind("t")?.dispatcher == "exec")
        #expect(bind("t")?.arg == "kitty")
        #expect(bind("q", [.superKey, .shift])?.dispatcher == "killactive")
        #expect(bind("h")?.dispatcher == "movefocus")
        #expect(bind("h")?.arg == "l")
        #expect(bind("3", [.superKey, .shift])?.dispatcher == "movetoworkspace")
        #expect(bind("3")?.arg == "3")
        #expect(bind("delete", [])?.dispatcher == "lua")
        #expect(LuaConfig.storedCommand(bind("delete", [])!.arg)?.contains("grim") == true)
        #expect(c.ignored.contains { $0.contains("XF86AudioMute") })
        #expect(c.ignored.contains("bindm"))
        #expect(c.ignored.contains("env"))
        #expect(c.ignored.contains("windowrule:match_fullscreen"))
        #expect(c.rules.map(\.effect).sorted() == ["float", "size 900 600"])
        #expect(c.rules[0].matches(appClasses: ["kitty"], title: ""))

        // Function binds and hl.on handlers run later, against the window manager.
        var calls: [String] = []
        LuaConfig.host = { op, arg in
            calls.append(op + " " + arg)
            if op == "activewindow" { return LuaConfig.table(["floating": true, "class": "kitty"]) }
            return nil
        }
        let space = try #require(bind("space"))
        LuaConfig.call(space.arg)
        #expect(calls == ["dispatch togglefloating\t", "activewindow ", "dispatch resizeactive\texact 100 50"])

        calls = []
        LuaConfig.emit("hyprland.start")
        #expect(calls == ["exec echo top-level", "exec echo started"])
        LuaConfig.host = nil
    }

    @Test func luaErrorsAreReportedNotFatal() throws {
        LuaConfig.install()
        let dir = try write(["hyprland.lua": """
        hl.config({ general = { gaps_in = 2 } })
        hl.bind("SUPER + T", hl.dsp.exec_cmd("kitty"))
        error("boom")
        """])
        let c = ConfigParser.load(path: dir + "/hyprland.lua")
        #expect(c.errors.count == 1)
        #expect(c.errors[0].contains("boom"))
        #expect(c.gapsIn == Insets(all: 2))  // everything before the error still applies
        #expect(c.binds.count == 1)
    }

    @Test func confCanSourceLua() throws {
        LuaConfig.install()
        let dir = try write(["rice.lua": #"hl.config({ general = { border_size = 4 } })"#])
        let c = ConfigParser.parse("hyprmac {\n super = alt\n}\nsource = \(dir)/rice.lua\ngeneral:gaps_in = 9\n", file: dir + "/hyprland.conf")
        #expect(c.errors.isEmpty, "\(c.errors)")
        #expect(c.borderSize == 4)
        #expect(c.gapsIn == Insets(all: 9))
        #expect(c.superMapsTo == [.alt])
    }

    @Test func luaQuoting() {
        #expect(LuaRuntime.quote("a\"b\\c\n1") == #""a\"b\\c\0101""#)
    }
}

@Suite struct CompatTests {
    @Test func findsProgramsInCommands() {
        #expect(LinuxCompat.programs(in: "pgrep -x rofi >/dev/null && pkill -x rofi || rofi -show drun") == ["rofi"])
        #expect(LinuxCompat.programs(in: "grim -g \"$(slurp)\" - | wl-copy") == ["grim", "slurp", "wl-copy"])
        #expect(LinuxCompat.programs(in: "qs ipc call bar toggle") == ["qs"])
        #expect(LinuxCompat.programs(in: "echo kitty.conf") == [])  // "kitty.conf" is not "kitty"
    }

    @Test func missingIncludesFirstWord() {
        let have: Set<String> = ["sh", "echo", "kitty"]
        #expect(LinuxCompat.missing(in: "thunar ~", available: have.contains) == ["thunar"])
        #expect(LinuxCompat.missing(in: "kitty -e btop", available: have.contains) == [])
        #expect(LinuxCompat.missing(in: "sh -c 'grim x'", available: have.contains) == ["grim"])
        #expect(LinuxCompat.missing(in: "FOO=1 echo hi", available: have.contains) == [])
    }

    @Test func shimsCoverCommonTools() {
        let s = LinuxCompat.macShims(ctlPath: "/x/hyprmacctl", appExists: { $0 == "kitty" || $0 == "Brave Browser" })
        #expect(s["hyprctl"]?.contains("'/x/hyprmacctl'") == true)
        #expect(s["kitty"]?.contains("open -na 'kitty'") == true)
        #expect(s["alacritty"]?.contains("Terminal") == true)
        #expect(s["brave"] != nil)
        #expect(s["firefox"] == nil)  // not installed: no shim, so binds needing it are skipped
        #expect(s["thunar"]?.contains("open") == true)
    }

    @Test func riceCatalog() {
        #expect(RiceCatalog.classify("kitty") == .link)
        #expect(RiceCatalog.classify("quickshell") == .linuxOnly)
        #expect(RiceCatalog.classify(".zshrc") == .shell)
        #expect(RiceCatalog.classify("mystery") == .unknown)
        let walls = RiceCatalog.wallpaperCandidates([
            "assets/desktop.png", "assets/banner.png", "wallhaven-k8jvm7.jpg", "README.md",
            ".config/neofetch/pfp.png", "walls/a.png", ".config/spicetify/Themes/text/screenshots/Nord.png",
        ])
        #expect(walls == ["walls/a.png", "wallhaven-k8jvm7.jpg"])
    }
}
