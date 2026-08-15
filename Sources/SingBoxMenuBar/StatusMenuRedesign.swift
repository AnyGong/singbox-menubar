import AppKit

/// Reorganizes and visually normalizes the status-bar menu without changing the
/// underlying actions in AppDelegate. The menu itself remains a native NSMenu,
/// so selection/hover/click feedback continues to come from AppKit.
final class StatusMenuRedesign {
    static let shared = StatusMenuRedesign()

    private weak var statusMenu: NSMenu?
    private var didRebuildRoot = false
    private var installed = false

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidFinishLaunching),
            name: NSApplication.didFinishLaunchingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMenuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )

        if NSApp.isRunning {
            DispatchQueue.main.async { [weak self] in
                self?.apply()
            }
        }
    }

    @objc private func handleApplicationDidFinishLaunching() {
        DispatchQueue.main.async { [weak self] in
            self?.apply()
        }
    }

    @objc private func handleMenuDidBeginTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        guard menu === statusMenu || menu === statusMenu?.items.first?.submenu else {
            // The status menu may be delivered after AppKit begins tracking. If we
            // have not captured it yet, a root-menu search is cheap and reliable.
            apply()
            guard menu === statusMenu || containsMenu(menu, inside: statusMenu) else { return }
            styleMenu(menu)
            return
        }
        styleMenu(menu)
    }

    private func apply() {
        guard let statusItem = findStatusItem(), let menu = statusItem.menu else { return }
        statusMenu = menu

        if !didRebuildRoot {
            rebuildRootMenu(menu)
            didRebuildRoot = true
        }
        styleMenu(menu)
    }

    private func findStatusItem() -> NSStatusItem? {
        guard let delegate = NSApp.delegate else { return nil }

        // AppDelegate keeps the status item as a private stored property. Mirror
        // gives this presentation layer access to that instance without coupling
        // the redesign to AppDelegate's private API or changing its behavior.
        for child in Mirror(reflecting: delegate).children {
            if child.label == "statusItem", let item = child.value as? NSStatusItem {
                return item
            }
        }
        return nil
    }

    private func rebuildRootMenu(_ menu: NSMenu) {
        let items = menu.items

        func take(_ predicate: (NSMenuItem) -> Bool) -> NSMenuItem? {
            items.first(where: predicate)
        }

        let status = take { item in
            item === items.first(where: { $0.action != nil && $0.title.contains("sing-box:") })
                || item.title.contains("sing-box:")
        }
        let controlPanel = take { $0.title == "Open Control Panel" }
        let systemProxy = take { $0.title == "Set as System Proxy" }
        let tun = take { $0.title == "Enhanced Mode (TUN)" }
        let outbound = take { $0.title.hasPrefix("Outbound Mode") }
        let profile = take { $0.title == "Switch Profile" }
        let configFolder = take { $0.title == "Open Config Folder" }
        let editConfig = take { $0.title == "Edit Current Config" }
        let reloadConfig = take { $0.title == "Reload Configuration" }
        let autoReload = take { $0.title == "Auto Reload on Config Change" }
        let autoRestart = take { $0.title == "Auto-restart sing-box" }
        let remoteConfig = take { $0.title == "Remote Config" }
        let diagnostics = take { $0.title == "Diagnostics" }
        let logs = take { $0.title == "Reveal Logs in Finder" }
        let launchAtLogin = take { $0.title == "Launch at Login" }
        let cleanup = take { $0.title == "Clean Up…" || $0.title == "Clean Up..." }
        let quit = take { $0.title == "Quit" }

        let configuration = makeGroupItem(
            title: "Configuration",
            symbolName: "doc.text.gearshape",
            items: [editConfig, reloadConfig, configFolder]
        )

        let automation = makeGroupItem(
            title: "Automation & Startup",
            symbolName: "gearshape.2",
            items: [autoReload, autoRestart, remoteConfig, launchAtLogin]
        )

        let diagnosticsGroup = makeGroupItem(
            title: "Diagnostics & Maintenance",
            symbolName: "stethoscope",
            items: [diagnostics, logs, cleanup]
        )

        menu.removeAllItems()

        if let status { menu.addItem(status) }
        menu.addItem(.separator())

        if let controlPanel {
            menu.addItem(controlPanel)
        }
        if let systemProxy {
            menu.addItem(systemProxy)
        }
        if let tun {
            menu.addItem(tun)
        }
        if let outbound {
            menu.addItem(outbound)
        }

        menu.addItem(.separator())

        if let profile {
            menu.addItem(profile)
        }
        menu.addItem(configuration)
        menu.addItem(automation)
        menu.addItem(diagnosticsGroup)

        menu.addItem(.separator())

        if let quit {
            menu.addItem(quit)
        }
    }

    private func makeGroupItem(title: String, symbolName: String, items: [NSMenuItem?]) -> NSMenuItem {
        let group = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        group.image = templateSymbol(named: symbolName)

        let submenu = NSMenu()
        submenu.autoenablesItems = true
        for item in items.compactMap({ $0 }) {
            submenu.addItem(item)
        }
        group.submenu = submenu
        return group
    }

    private func styleMenu(_ menu: NSMenu?) {
        guard let menu else { return }

        for item in menu.items {
            if let submenu = item.submenu {
                styleMenu(submenu)
            }
            applyIcon(to: item)

            // Let AppKit own the hover/highlight treatment. Explicitly opting into
            // native menu-item views here would suppress the standard macOS selection
            // animation and make the menu feel unlike other system menus.
            item.view = nil
        }
    }

    private func applyIcon(to item: NSMenuItem) {
        let symbolName: String?
        let title = item.title

        if title == "Open Control Panel" {
            symbolName = "rectangle.inset.filled"
        } else if title == "Set as System Proxy" {
            symbolName = "network"
        } else if title == "Enhanced Mode (TUN)" {
            symbolName = "shield.lefthalf.filled"
        } else if title.hasPrefix("Outbound Mode") {
            symbolName = "arrow.triangle.branch"
        } else if title == "Switch Profile" {
            symbolName = "person.crop.rectangle.stack"
        } else if title == "Edit Current Config" {
            symbolName = "pencil.line"
        } else if title == "Reload Configuration" {
            symbolName = "arrow.clockwise"
        } else if title == "Open Config Folder" {
            symbolName = "folder"
        } else if title == "Auto Reload on Config Change" {
            symbolName = "arrow.triangle.2.circlepath"
        } else if title == "Auto-restart sing-box" {
            symbolName = "arrow.counterclockwise"
        } else if title == "Remote Config" || title == "Set Remote Config URL…" {
            symbolName = "arrow.down.doc"
        } else if title == "Update Now" {
            symbolName = "arrow.down.circle"
        } else if title == "Diagnostics" {
            symbolName = "stethoscope"
        } else if title == "Reveal Logs in Finder" {
            symbolName = "doc.text.magnifyingglass"
        } else if title == "Launch at Login" {
            symbolName = "power"
        } else if title == "Clean Up…" || title == "Clean Up..." {
            symbolName = "trash"
        } else if title == "Quit" {
            symbolName = "power.circle"
        } else {
            symbolName = nil
        }

        guard let symbolName else { return }
        item.image = templateSymbol(named: symbolName)
    }

    private func templateSymbol(named name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    private func containsMenu(_ menu: NSMenu, inside root: NSMenu?) -> Bool {
        guard let root else { return false }
        if menu === root { return true }
        return root.items.contains { item in
            if let submenu = item.submenu {
                return submenu === menu || containsMenu(menu, inside: submenu)
            }
            return false
        }
    }
}

private let _statusMenuRedesignBootstrap: Void = {
    StatusMenuRedesign.shared.install()
}()

@available(macOS 13.0, *)
private func bootstrapStatusMenuRedesign() {
    _ = _statusMenuRedesignBootstrap
}

// Force evaluation at module initialization. Swift guarantees global initialization
// before the executable starts processing UI events.
private let _statusMenuRedesignStart: Void = {
    bootstrapStatusMenuRedesign()
}()
