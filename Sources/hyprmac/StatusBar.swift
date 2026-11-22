import AppKit
import HyprmacCore

/// Menu bar item showing workspaces, e.g. "1 [2] 4". Menu: reload, edit config, errors, quit.
final class StatusBar {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var manager: WindowManager?
    private let menu: HyprmacMenu

    init(manager: WindowManager) {
        self.manager = manager
        menu = HyprmacMenu(manager: manager)
        item.menu = menu.make()
        update()
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }

    func update() {
        guard let m = manager?.model else { return }
        let current = m.currentWorkspace
        var ids = Set(m.workspaces.values.filter { !$0.isEmpty }.map(\.id))
        for mon in m.monitors { ids.insert(mon.workspace) }
        let text = ids.sorted().map { $0 == current ? "[\($0)]" : "\($0)" }.joined(separator: " ")
        let warn = (manager?.configErrors.isEmpty ?? true) ? "" : "⚠ "
        item.button?.title = warn + text
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }
}

/// The hyprmac menu, shared by the menu bar item and the shell bar's logo.
final class HyprmacMenu: NSObject, NSMenuDelegate {
    private weak var manager: WindowManager?

    init(manager: WindowManager) {
        self.manager = manager
    }

    /// A menu filled when it opens. The caller keeps this object alive (menu delegates are weak).
    func make() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let manager else { return }
        menu.addItem(withTitle: "hyprmac \(HyprmacInfo.version)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "\(manager.windowCount) windows managed", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let errors = manager.configErrors
        if !errors.isEmpty {
            menu.addItem(withTitle: "Config errors (\(errors.count)):", action: nil, keyEquivalent: "")
            for e in errors.prefix(10) { menu.addItem(withTitle: "  " + e, action: nil, keyEquivalent: "") }
            menu.addItem(.separator())
        }
        let rices = Rice.installed
        let riceItem = NSMenuItem(title: "Rice", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let active = Rice.active
        for name in rices {
            let i = NSMenuItem(title: name, action: #selector(useRice(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = name
            i.state = name == active ? .on : .off
            sub.addItem(i)
        }
        if rices.isEmpty {
            sub.addItem(withTitle: "No rices: hyprmac rice install <git-url>", action: nil, keyEquivalent: "")
        }
        sub.addItem(.separator())
        let offItem = NSMenuItem(title: "Off (restore my configs)", action: active == nil ? nil : #selector(riceOff), keyEquivalent: "")
        offItem.target = self
        sub.addItem(offItem)
        riceItem.submenu = sub
        menu.addItem(riceItem)
        menu.addItem(.separator())
        add(menu, "Reload config", #selector(reload))
        add(menu, "Edit config", #selector(editConfig))
        add(menu, "Show config folder", #selector(showFolder))
        menu.addItem(.separator())
        add(menu, "Quit hyprmac (restores windows)", #selector(quit))
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        menu.addItem(i)
    }

    @objc private func reload() { manager?.reload() }

    @objc private func editConfig() {
        guard let path = manager?.configPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: ConfigParser.expand(path)))
    }

    @objc private func showFolder() {
        guard let path = manager?.configPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ConfigParser.expand(path))])
    }

    @objc private func quit() { manager?.shutdown() }

    @objc private func useRice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        _ = Rice.main(["use", name])
    }

    @objc private func riceOff() { _ = Rice.main(["off"]) }
}
