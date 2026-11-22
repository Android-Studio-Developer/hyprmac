import Testing
@testable import HyprmacCore

@Suite struct ConfigTests {
    @Test func defaultConfigParsesClean() {
        let c = ConfigParser.parse(DefaultConfig.text)
        #expect(c.errors.isEmpty, "\(c.errors)")
        #expect(c.binds.count > 30)
        #expect(c.gapsOut == Insets(all: 10))
        #expect(c.preserveSplit)
        #expect(c.rules.count == 2)
        #expect(c.shell && c.hideTaskbar && c.scheme == "auto")
        #expect(!c.bordersExplicit)
    }

    @Test func shellOptions() {
        let c = ConfigParser.parse("""
        hyprmac {
            shell = false
            hide_menubar = false
            scheme = rgb(cba6f7)
        }
        general {
            col.active_border = rgb(ff0000)
        }
        """)
        #expect(c.errors.isEmpty, "\(c.errors)")
        #expect(!c.shell && !c.hideTaskbar && c.scheme == "rgb(cba6f7)")
        #expect(c.bordersExplicit)
        #expect(!ConfigParser.parse("hyprmac {\n scheme = purple\n}").errors.isEmpty)
    }

    @Test func sectionsVariablesAndColonKeys() {
        let c = ConfigParser.parse("""
        $mod = SUPER
        $gap = 7
        general {
            gaps_in = $gap
            gaps_out = 10 20
            border_size = 3
            layout = master
        }
        master:mfact = 0.6
        decoration {
            rounding = 4
            blur {
                enabled = true
            }
        }
        bind = $mod SHIFT, Q, killactive,
        bind = $mod, Return, exec, open -a "kitty", --args # comment
        """)
        #expect(c.errors.isEmpty, "\(c.errors)")
        #expect(c.gapsIn == Insets(all: 7))
        #expect(c.gapsOut == Insets(top: 10, right: 20, bottom: 10, left: 20))
        #expect(c.borderSize == 3)
        #expect(c.layout == "master")
        #expect(c.mfact == 0.6)
        #expect(c.rounding == 4)
        #expect(c.binds[0] == KeyBind(mods: [.superKey, .shift], key: "q", dispatcher: "killactive", arg: ""))
        #expect(c.binds[1].arg == #"open -a "kitty", --args"#)
        #expect(c.ignored.contains("decoration:blur:enabled"))
    }

    @Test func doubleHashIsLiteral() {
        let c = ConfigParser.parse("bind = ALT, 1, exec, echo ##1 # real comment")
        #expect(c.binds.first?.arg == "echo #1")
    }

    @Test func errorsAreReported() {
        let c = ConfigParser.parse("""
        bind = HYPER, Q, killactive,
        bind = ALT, notakey, killactive,
        bind = ALT, Q, frobnicate,
        general:gaps_in = lots
        nonsense
        foo:bar = 1
        }
        """)
        #expect(c.errors.count == 7, "\(c.errors)")
    }

    @Test func linuxOnlyOptionsAreIgnoredNotErrors() {
        let c = ConfigParser.parse("""
        monitor = ,preferred,auto,1
        env = XCURSOR_SIZE,24
        input {
            kb_layout = us
            touchpad {
                natural_scroll = true
            }
        }
        animations {
            enabled = yes
            bezier = myBezier, 0.05, 0.9, 0.1, 1.05
            animation = windows, 1, 7, myBezier
        }
        bindm = SUPER, mouse:272, movewindow
        """)
        #expect(c.errors.isEmpty, "\(c.errors)")
        #expect(c.ignored.count == 8)
    }

    @Test func sourceIncludesRelativeFile() {
        let files = ["/cfg/extra.conf": "bind = ALT, T, exec, kitty\ngeneral:border_size = 5"]
        let c = ConfigParser.parse("source = extra.conf\n", file: "/cfg/hyprland.conf", readFile: { files[$0] })
        #expect(c.errors.isEmpty, "\(c.errors)")
        #expect(c.binds.first?.key == "t")
        #expect(c.borderSize == 5)
        #expect(c.files == ["/cfg/hyprland.conf", "/cfg/extra.conf"])
    }

    @Test func laterBindReplacesAndUnbindRemoves() {
        let c = ConfigParser.parse("""
        bind = ALT, Q, exec, a
        bind = ALT, Q, exec, b
        bind = ALT, W, exec, c
        unbind = ALT, W
        """)
        #expect(c.binds.count == 1)
        #expect(c.binds[0].arg == "b")
    }

    @Test func windowRules() {
        let c = ConfigParser.parse("""
        windowrulev2 = float, class:^(kitty)$
        windowrulev2 = workspace 3 silent, class:Safari, title:.*YouTube.*
        windowrule = size 800 600, ^(Calculator)$
        """)
        #expect(c.errors.isEmpty, "\(c.errors)")
        #expect(c.rules[0].matches(appClasses: ["Kitty", "net.kovidgoyal.kitty"], title: "zsh"))
        #expect(!c.rules[0].matches(appClasses: ["kitty2"], title: ""))
        #expect(c.rules[1].matches(appClasses: ["Safari"], title: "Cats - YouTube"))
        #expect(!c.rules[1].matches(appClasses: ["Safari"], title: "News"))
        #expect(c.rules[1].effectName == "workspace")
        #expect(c.rules[1].effectArgs == ["3", "silent"])
        #expect(c.rules[2].classPattern == "^(Calculator)$")
    }

    @Test func colors() {
        let g = BorderColor.parse("rgba(33ccffee) rgba(00ff99ee) 45deg")!
        #expect(g.colors.count == 2)
        #expect(g.angle == 45)
        #expect(g.colors[0].hex == "33ccffee")
        #expect(BorderColor.parse("rgb(ff0000)")!.colors[0] == RGBA(r: 1, g: 0, b: 0, a: 1))
        #expect(BorderColor.parse("0xff00ff00")!.colors[0] == RGBA(r: 0, g: 1, b: 0, a: 1))
        #expect(BorderColor.parse("rgba(255, 0, 0, 0.5)")!.colors[0] == RGBA(r: 1, g: 0, b: 0, a: 0.5))
        #expect(BorderColor.parse("red") == nil)
        #expect(BorderColor.parse("rgba(33ccffee) junk") == nil)
    }

    @Test func modifiers() {
        #expect(Modifiers.parse("SUPER_SHIFT") == [.superKey, .shift])
        #expect(Modifiers.parse("CTRL ALT") == [.ctrl, .alt])
        #expect(Modifiers.parse("") == [])
        #expect(Modifiers.parse("HYPER") == nil)
    }
}
