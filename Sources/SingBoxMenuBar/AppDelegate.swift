import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let processManager = SingBoxProcessManager.shared

    // Menu items kept as properties so we can update their checkmarks/titles in place.
    private var outboundModeItem = NSMenuItem()
    private var systemProxyItem = NSMenuItem()
    private var tunItem = NSMenuItem()
    private var switchProfileItem = NSMenuItem()
    private var launchAtLoginItem = NSMenuItem()

    private var currentSystemProxyService: String?

    /// Periodically reconciles the menu bar with sing-box's *actual* state, so
    /// changes made externally (via the Clash API, another client, `networksetup`,
    /// or the sing-box process being started/stopped outside this app) are picked
    /// up even if this app's own controls were never touched. See `syncExternalState`.
    private var stateSyncTimer: Timer?
    private static let stateSyncInterval: TimeInterval = 3

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.log("App launched")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        buildMenu()
        refreshIcon()

        processManager.onStateChange = { [weak self] running in
            guard let self else { return }
            self.tunItem.state = self.processManager.isTUNEnabled ? .on : .off
            if !running {
                self.disableSystemProxyIfDangling()
            }
            self.refreshIcon()
        }

        // Restore last profile automatically is intentionally NOT done here — starting
        // sing-box is an explicit user action (Enhanced Mode toggle), matching the
        // "no background surprises" spirit of the requirements doc.
        if Preferences.activeProfilePath == nil {
            Preferences.activeProfilePath = ConfigManager.defaultProfile()?.path
        }

        // Catch up with reality immediately (e.g. sing-box was already running before
        // this app launched), then keep polling so later external changes are caught too.
        syncExternalState()
        stateSyncTimer = Timer.scheduledTimer(withTimeInterval: Self.stateSyncInterval, repeats: true) { [weak self] _ in
            self?.syncExternalState()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.log("App terminating — cleaning up")
        stateSyncTimer?.invalidate()
        stateSyncTimer = nil
        if let service = currentSystemProxyService, Preferences.systemProxyEnabled {
            SystemProxyManager.disable(service: service) { _ in }
        }
        processManager.stop()
    }

    // MARK: - External state sync

    /// Also triggered on demand right before the menu opens (see `menuWillOpen`), so
    /// the menu never shows stale checkmarks even in between poll ticks.
    func menuWillOpen(_ menu: NSMenu) {
        syncExternalState()
    }

    /// Pulls the real, current state of sing-box/macOS and reconciles the menu bar's
    /// icon, letters, and checkmarks with it. Covers everything the menu bar can show
    /// that could also be changed from outside this app:
    ///   - process running / Enhanced Mode (TUN)   — via `pgrep`
    ///   - outbound mode (Direct/Global/Rule)       — via Clash API `GET /configs`
    ///   - system proxy on/off                      — via `networksetup` readback
    private func syncExternalState() {
        processManager.reconcileRunningState()

        if processManager.isRunning {
            syncOutboundModeFromKernel()
            syncSystemProxyStateFromSystem()
        } else {
            // sing-box isn't running, so System Proxy can't be doing anything useful
            // regardless of what macOS's proxy setting currently says — force it off
            // rather than risking `syncSystemProxyStateFromSystem` racing back to "on"
            // based on a stale `networksetup` readback taken before disabling finishes.
            disableSystemProxyIfDangling()
        }
    }

    private func syncOutboundModeFromKernel() {
        ClashAPIClient.shared.getMode { [weak self] result in
            guard let self, case .success(let mode) = result, mode != Preferences.outboundMode else { return }
            AppLog.log("Detected outbound mode changed externally to \(mode.rawValue); syncing menu bar")
            Preferences.outboundMode = mode
            self.outboundModeItem.title = "Outbound Mode  (\(mode.badgeLetter))"
            self.outboundModeItem.submenu?.items.forEach {
                $0.state = ($0.representedObject as? OutboundMode) == mode ? .on : .off
            }
            self.refreshIcon()
        }
    }

    private func syncSystemProxyStateFromSystem() {
        guard let service = currentSystemProxyService ?? Preferences.preferredNetworkService else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let actuallyEnabled = SystemProxyManager.isEnabled(service: service)
            DispatchQueue.main.async { [weak self] in
                guard let self, actuallyEnabled != Preferences.systemProxyEnabled else { return }
                AppLog.log("Detected system proxy \(actuallyEnabled ? "enabled" : "disabled") externally for '\(service)'; syncing menu bar")
                Preferences.systemProxyEnabled = actuallyEnabled
                self.currentSystemProxyService = actuallyEnabled ? service : nil
                self.systemProxyItem.state = actuallyEnabled ? .on : .off
                self.refreshIcon()
            }
        }
    }

    /// System Proxy only does anything useful while sing-box is actually running and
    /// listening on the proxy port — see `toggleSystemProxy`, which auto-starts
    /// sing-box (in normal, no-TUN mode) rather than requiring that separately. This
    /// is the other half of that invariant: if sing-box stops (deliberately via
    /// Enhanced Mode, a crash, or externally) while System Proxy is still marked on,
    /// turn it back off rather than leaving traffic pointed at a dead port while the
    /// menu bar keeps showing a checkmark.
    private func disableSystemProxyIfDangling() {
        guard Preferences.systemProxyEnabled,
              let service = currentSystemProxyService ?? Preferences.preferredNetworkService else { return }

        AppLog.log("sing-box is not running while System Proxy is enabled for '\(service)'; disabling System Proxy")
        SystemProxyManager.disable(service: service) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                AppLog.error("Failed to cleanly disable dangling System Proxy: \(error.localizedDescription)")
                // Fall through and mark it off in our own state regardless — we know
                // it's non-functional either way (sing-box isn't there to serve it),
                // so an inaccurate "off" the user can re-enable is safer than an
                // inaccurate "on" that silently drops their traffic.
            }
            Preferences.systemProxyEnabled = false
            self.currentSystemProxyService = nil
            self.systemProxyItem.state = .off
            self.refreshIcon()
        }
    }

    // MARK: - Menu construction

    private func buildMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "Show Main Window", action: #selector(showMainWindow), keyEquivalent: "")
        .target = self

        menu.addItem(withTitle: "Open Control Panel in Default Browser", action: #selector(openControlPanel), keyEquivalent: "")
        .target = self

        menu.addItem(.separator())

        // Outbound Mode submenu
        outboundModeItem.title = "Outbound Mode  (\(Preferences.outboundMode.badgeLetter))"
        let modeSubmenu = NSMenu()
        for mode in OutboundMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = (mode == Preferences.outboundMode) ? .on : .off
            modeSubmenu.addItem(item)
        }
        outboundModeItem.submenu = modeSubmenu
        menu.addItem(outboundModeItem)

        // Set as System Proxy
        systemProxyItem.title = "Set as System Proxy"
        systemProxyItem.action = #selector(toggleSystemProxy)
        systemProxyItem.target = self
        systemProxyItem.state = Preferences.systemProxyEnabled ? .on : .off
        menu.addItem(systemProxyItem)

        // Enhanced Mode (TUN)
        tunItem.title = "Enhanced Mode (TUN)"
        tunItem.action = #selector(toggleTUN)
        tunItem.target = self
        tunItem.state = processManager.isTUNEnabled ? .on : .off
        menu.addItem(tunItem)

        menu.addItem(.separator())

        // Switch Profile submenu
        switchProfileItem.title = "Switch Profile"
        rebuildProfileSubmenu()
        menu.addItem(switchProfileItem)

        menu.addItem(withTitle: "Reload Configuration", action: #selector(reloadConfiguration), keyEquivalent: "")
        .target = self

        menu.addItem(.separator())

        launchAtLoginItem.title = "Launch at Login"
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        launchAtLoginItem.target = self
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Reveal Logs in Finder", action: #selector(revealLogs), keyEquivalent: "")
        .target = self

        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        .target = self

        menu.delegate = self
        statusItem.menu = menu
    }

    private func rebuildProfileSubmenu() {
        let submenu = NSMenu()
        let profiles = ConfigManager.availableProfiles()
        if profiles.isEmpty {
            let empty = NSMenuItem(title: "No profiles found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for profile in profiles {
            let item = NSMenuItem(title: profile.lastPathComponent, action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile
            item.state = (profile.path == Preferences.activeProfilePath) ? .on : .off
            submenu.addItem(item)
        }
        switchProfileItem.submenu = submenu
    }

    private func refreshIcon() {
        let active = processManager.isRunning || Preferences.systemProxyEnabled
        statusItem.button?.image = IconRenderer.makeIcon(mode: Preferences.outboundMode, active: active)
    }

    // MARK: - Actions

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Wire up to an actual window controller if/when a main window is added.
        // Left as a stub since the spec treats the menu bar as the primary surface.
    }

    @objc private func openControlPanel() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:9090")!)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? OutboundMode else { return }
        Preferences.outboundMode = mode
        outboundModeItem.title = "Outbound Mode  (\(mode.badgeLetter))"
        outboundModeItem.submenu?.items.forEach { $0.state = ($0.representedObject as? OutboundMode) == mode ? .on : .off }
        refreshIcon()
        AppLog.log("Outbound mode preference set to \(mode.rawValue)")

        if processManager.isRunning {
            ClashAPIClient.shared.setMode(mode) { result in
                if case .failure(let error) = result {
                    self.showNonBlockingAlert(title: "Mode Switch Failed",
                        message: "Preference was saved, but the running kernel could not be switched live: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func toggleSystemProxy() {
        if Preferences.systemProxyEnabled {
            guard let service = currentSystemProxyService else {
                Preferences.systemProxyEnabled = false
                systemProxyItem.state = .off
                refreshIcon()
                return
            }
            SystemProxyManager.disable(service: service) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    Preferences.systemProxyEnabled = false
                    self.systemProxyItem.state = .off
                    self.currentSystemProxyService = nil
                    self.refreshIcon()
                case .failure(let error):
                    self.handleSystemProxyError(error)
                }
            }
        } else {
            // System Proxy routes traffic to sing-box's local HTTP inbound, so it
            // needs sing-box actually running. If it isn't, start it ourselves in
            // normal mode — the active profile's config, with the TUN inbound left
            // disabled — rather than erroring and making the user start it by hand
            // first. Enhanced Mode (TUN) stays a separate, explicit opt-in.
            guard processManager.isRunning else {
                guard let path = Preferences.activeProfilePath else {
                    showNonBlockingAlert(title: "No Profile Selected", message: "Choose a profile under Switch Profile first, then try again.")
                    return
                }
                processManager.start(configPath: path, enableTUN: false) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.beginEnablingSystemProxy()
                    case .failure(let error):
                        self.showNonBlockingAlert(title: "Failed to Start sing-box", message: error.localizedDescription)
                    }
                }
                return
            }

            beginEnablingSystemProxy()
        }
    }

    /// Picks (or reuses) a network service and turns System Proxy on for it. Split
    /// out from `toggleSystemProxy` so it can run either immediately, when sing-box
    /// is already running, or after auto-starting it in normal mode.
    private func beginEnablingSystemProxy() {
        let services = SystemProxyManager.activeNetworkServices()

        if services.isEmpty {
            showNonBlockingAlert(title: "No Active Network Service", message: "No active network services were found to set a proxy on.")
            return
        }

        // Reuse a previously chosen service without prompting again, as long as
        // it's still active. Falls through to picker/auto-pick logic otherwise.
        if let preferred = Preferences.preferredNetworkService, services.contains(preferred) {
            enableSystemProxy(on: preferred)
            return
        }

        if services.count == 1 {
            let only = services[0]
            Preferences.preferredNetworkService = only
            enableSystemProxy(on: only)
            return
        }

        presentServicePicker(services: services) { [weak self] chosen in
            guard let self, let chosen else { return }
            Preferences.preferredNetworkService = chosen
            self.enableSystemProxy(on: chosen)
        }
    }

    private func enableSystemProxy(on service: String) {
        SystemProxyManager.enable(service: service) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                Preferences.systemProxyEnabled = true
                self.currentSystemProxyService = service
                self.systemProxyItem.state = .on
                self.refreshIcon()
            case .failure(let error):
                self.handleSystemProxyError(error)
            }
        }
    }

    private func handleSystemProxyError(_ error: Error) {
        if case PrivilegedCommandRunner.RunError.cancelled = error {
            return // deliberate cancel, no alert needed
        }
        showNonBlockingAlert(title: "System Proxy Error", message: error.localizedDescription)
    }

    @objc private func toggleTUN() {
        if processManager.isTUNEnabled {
            // Fully stopping is the only way to drop the TUN interface — there's no
            // "downgrade to normal mode in place" path. If System Proxy is also on,
            // `disableSystemProxyIfDangling` (via `onStateChange`) will turn it off
            // too rather than leaving it pointed at a now-dead port.
            processManager.stop()
        } else {
            guard let path = Preferences.activeProfilePath else {
                showNonBlockingAlert(title: "No Profile Selected", message: "Choose a profile under Switch Profile first.")
                return
            }
            // Note: sing-box may already be running here in normal mode (e.g.
            // auto-started for System Proxy) — `start` restarts cleanly in that case.
            processManager.start(configPath: path, enableTUN: true) { [weak self] result in
                if case .failure(let error) = result {
                    self?.showNonBlockingAlert(title: "Failed to Start sing-box", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let wasRunning = processManager.isRunning
        let wasTUNEnabled = processManager.isTUNEnabled
        Preferences.activeProfilePath = url.path
        rebuildProfileSubmenu()
        AppLog.log("Active profile switched to \(url.lastPathComponent)")

        if wasRunning {
            // Preserve whatever mode was already active (normal vs. TUN) rather than
            // defaulting to TUN — a profile switch shouldn't silently turn Enhanced
            // Mode on for someone who was only using System Proxy.
            processManager.start(configPath: url.path, enableTUN: wasTUNEnabled) { [weak self] result in
                if case .failure(let error) = result {
                    self?.showNonBlockingAlert(title: "Profile Switch Failed", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func reloadConfiguration() {
        guard let path = Preferences.activeProfilePath else { return }
        // Same mode it was already running in — reload shouldn't change that.
        processManager.start(configPath: path, enableTUN: processManager.isTUNEnabled) { [weak self] result in
            switch result {
            case .success:
                AppLog.log("Configuration reloaded")
            case .failure(let error):
                self?.showNonBlockingAlert(title: "Reload Failed", message: error.localizedDescription)
            }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let newValue = !LaunchAtLogin.isEnabled
        LaunchAtLogin.setEnabled(newValue)
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func revealLogs() {
        NSWorkspace.shared.open(AppLog.directory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func presentServicePicker(services: [String], completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Choose Network Service"
        alert.informativeText = "Multiple active network services were found. Which one should use the proxy?"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        popup.addItems(withTitles: services)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Set Proxy")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        completion(response == .alertFirstButtonReturn ? popup.titleOfSelectedItem : nil)
    }

    private func showNonBlockingAlert(title: String, message: String) {
        AppLog.error("\(title): \(message)")
        guard Thread.isMainThread else {
            // Safety net: NSAlert/NSWindow must be created on the main thread. If
            // some future caller reaches this from a background queue, hop over
            // instead of crashing.
            DispatchQueue.main.async { [weak self] in
                self?.showNonBlockingAlert(title: title, message: message)
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        // Using a sheet-less, non-activating panel keeps this non-blocking to the rest
        // of the UI; runModal() here is still a modal alert window, but it does not
        // block the sing-box process or other app logic, only further menu clicks
        // until dismissed — acceptable for a single-user local tool.
        alert.runModal()
    }
}