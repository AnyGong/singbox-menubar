import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let processManager = SingBoxProcessManager.shared

    // Menu items kept as properties so we can update their checkmarks/titles in place.
    private var statusLineItem = NSMenuItem()
    private var restartSingBoxItem = NSMenuItem()
    private var stopSingBoxItem = NSMenuItem()
    private var controlPanelItem = NSMenuItem()
    private var outboundModeItem = NSMenuItem()
    private var systemProxyItem = NSMenuItem()
    private var tunItem = NSMenuItem()
    private var switchProfileItem = NSMenuItem()
    private var launchAtLoginItem = NSMenuItem()
    private var autoReloadItem = NSMenuItem()
    private var remoteConfigItem = NSMenuItem()

    private var currentSystemProxyService: String?

    /// Periodically reconciles the menu bar with sing-box's *actual* state, so
    /// changes made externally (via the Clash API, another client, `networksetup`,
    /// or the sing-box process being started/stopped outside this app) are picked
    /// up even if this app's own controls were never touched. See `syncExternalState`.
    private var stateSyncTimer: Timer?
    private static let stateSyncInterval: TimeInterval = 3

    /// Watches the active profile file on disk and reports changes made outside
    /// this app — see `handleExternalConfigChange` and the "Auto Reload on Config
    /// Change" menu item.
    private let configWatcher = ConfigFileWatcher()

    /// Tracked separately from `processManager.isTUNEnabled` so the `onStateChange`
    /// handler can tell whether TUN specifically changed (vs. just run state), since
    /// it fires on every start/stop/restart, not only ones where TUN flipped.
    private var lastKnownTUNEnabled = false

    /// Set by `processManager.onUnexpectedExit`, immediately before `onStateChange`
    /// fires for that same stop — consumed (and cleared) there to post a "crashed"
    /// notification instead of a plain "stopped" one.
    private var pendingCrashStatus: Int32?

    /// Transient message shown on the status line in place of "Running · Mode" /
    /// "Stopped" while an async validate/start/reload is in flight — e.g.
    /// "Switching to TUN mode…". `sing-box check` (run before every start — see
    /// `SingBoxProcessManager.start`) can take several seconds resolving remote
    /// rule-sets, so without this the status line would just sit unchanged for
    /// that long with no indication anything is happening. Set/cleared via
    /// `setBusyStatus`/`clearBusyStatus`, read by `updateStatusLine`.
    private var busyStatusMessage: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.log("App launched")

        AppNotifier.requestAuthorizationIfNeeded()

        // .variableLength, not .squareLength — the icon is no longer a fixed square
        // now that it can show icon+letter side-by-side (see IconRenderer), so the
        // button needs to size itself to whatever width the current image actually is.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        refreshIcon()

        lastKnownTUNEnabled = processManager.isTUNEnabled

        configWatcher.onChange = { [weak self] path in
            self?.handleExternalConfigChange(path)
        }

        processManager.onUnexpectedExit = { [weak self] status in
            self?.pendingCrashStatus = status
        }

        processManager.onStateChange = { [weak self] running in
            guard let self else { return }

            let tunNowEnabled = self.processManager.isTUNEnabled
            if tunNowEnabled != self.lastKnownTUNEnabled {
                self.lastKnownTUNEnabled = tunNowEnabled
                AppNotifier.post(
                    title: tunNowEnabled ? "Enhanced Mode (TUN) Enabled" : "Enhanced Mode (TUN) Disabled",
                    body: tunNowEnabled ? "sing-box is now routing traffic through the TUN interface." : "TUN interface torn down.",
                    identifier: "tun-mode"
                )
            }
            self.tunItem.state = tunNowEnabled ? .on : .off

            if let crashStatus = self.pendingCrashStatus, !running {
                self.pendingCrashStatus = nil
                AppNotifier.post(
                    title: "sing-box Stopped Unexpectedly",
                    body: "sing-box exited unexpectedly (status \(crashStatus)). Check sing-box.log for details.",
                    identifier: "singbox-run-state"
                )
            } else {
                AppNotifier.post(
                    title: running ? "sing-box Started" : "sing-box Stopped",
                    body: running ? "sing-box is now running." : "sing-box is no longer running.",
                    identifier: "singbox-run-state"
                )
            }

            if running {
                // A run just (genuinely) started — make sure System Proxy, if it's
                // marked on, still has something to actually serve it. Covers TUN
                // being enabled (config may or may not also keep a mixed/http/socks
                // inbound — see reconcileSystemProxyCapability) as well as profile
                // switches and reloads.
                if let path = Preferences.activeProfilePath {
                    self.reconcileSystemProxyCapability(configPath: path)
                }
            } else {
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

        if let path = Preferences.activeProfilePath {
            configWatcher.watch(path: path)
            // Warm the validation cache for the active profile at launch, in the
            // background, so the *first* start/reload the user does — likely
            // moments after opening the menu — can hit the cache instead of
            // waiting on a real `sing-box check`. See requirements: "reuse cache
            // at startup." Fire-and-forget: nothing here needs the result, only
            // the side effect of `validateConfig` populating `ConfigValidationCache`.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = self?.processManager.validateConfig(at: path)
            }
        }

        RemoteConfigUpdater.shared.onResult = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // No notification of our own here — writing the new config over the
                // active profile file is exactly what `configWatcher` is watching
                // for, and it (via `handleExternalConfigChange`) already posts a
                // notification and either auto-reloads or waits for a manual
                // reload, per "Auto Reload on Config Change". Posting a second,
                // separate notification here would just be noise.
                AppLog.log("Remote config check succeeded")
            case .failure(let error):
                if case RemoteConfigError.notConfigured = error {
                    // Only reachable from the manual "Update Now" action — a
                    // scheduled tick can't fire without both a URL and an interval
                    // configured (see `reschedule`) — so this is worth telling the
                    // user about, not a silent no-op.
                    self.showNonBlockingAlert(title: "Remote Config Not Set Up", message: error.localizedDescription)
                } else {
                    self.showNonBlockingAlert(title: "Remote Config Update Failed", message: error.localizedDescription)
                }
            }
        }
        RemoteConfigUpdater.shared.reschedule()

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
        configWatcher.stop()
        RemoteConfigUpdater.shared.stop()
        if let service = currentSystemProxyService, Preferences.systemProxyEnabled {
            SystemProxyManager.disable(service: service) { _ in }
        }
        processManager.stop()
    }

    // MARK: - External configuration-file changes

    /// Invoked (on the main thread) by `configWatcher` when the active profile file
    /// changes on disk outside this app. Always notifies; additionally reloads
    /// automatically if the user has "Auto Reload on Config Change" enabled and
    /// sing-box is actually running the file in question — otherwise it just waits
    /// for a manual "Reload Configuration", per the feature's spec.
    private func handleExternalConfigChange(_ path: String) {
        // Guards against a stale/in-flight watcher callback racing a profile switch
        // that happened in the meantime.
        guard path == Preferences.activeProfilePath else { return }
        let name = (path as NSString).lastPathComponent
        AppLog.log("Detected external change to active configuration '\(name)'")

        let willReloadNow = processManager.isRunning && Preferences.autoReloadOnConfigChange
        if !willReloadNow {
            // Nothing below is about to run a real `sing-box check` on its own —
            // warm the validation cache now, in the background, so whenever the
            // user does reload manually (or starts sing-box fresh on this file)
            // it's instant instead of waiting on the check right then. See
            // requirements: "run sing-box check when a configuration file is
            // newly added or modified." If a reload *is* about to happen (the
            // branch below), skip this — `start` will validate for real in a
            // moment anyway, and racing a second concurrent check here would just
            // be redundant work for the same result.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = self?.processManager.validateConfig(at: path)
            }
        }

        guard processManager.isRunning else {
            // Nothing is currently serving this config, so there's nothing to
            // reload — just let the user know the file on disk changed.
            AppNotifier.post(
                title: "Configuration Changed",
                body: "\(name) changed on disk.",
                identifier: "config-change"
            )
            return
        }

        if Preferences.autoReloadOnConfigChange {
            AppNotifier.post(
                title: "Configuration Changed",
                body: "\(name) changed on disk. Reloading automatically…",
                identifier: "config-change"
            )
            reloadConfiguration()
        } else {
            AppNotifier.post(
                title: "Configuration Changed",
                body: "\(name) changed on disk. Reload it from the menu to apply, or enable Auto Reload on Config Change.",
                identifier: "config-change"
            )
        }
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
            AppNotifier.post(
                title: "Outbound Mode Changed",
                body: "Now using \(mode.rawValue) mode.",
                identifier: "outbound-mode"
            )
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
                AppNotifier.post(
                    title: actuallyEnabled ? "System Proxy Enabled" : "System Proxy Disabled",
                    body: actuallyEnabled ? "Enabled externally for '\(service)'." : "Disabled externally for '\(service)'.",
                    identifier: "system-proxy"
                )
                self.refreshIcon()
            }
        }
    }

    /// System Proxy only does anything useful while sing-box is actually running and
    /// listening on a proxy-capable inbound — see `toggleSystemProxy`, which
    /// auto-starts sing-box (in normal, no-TUN mode) rather than requiring that
    /// separately, and blocks enabling System Proxy for a config with no such
    /// inbound in the first place. This is the "sing-box isn't running at all"
    /// half of that invariant: if sing-box stops (deliberately, a crash, or
    /// externally) while System Proxy is still marked on, turn it back off rather
    /// than leaving traffic pointed at a dead port while the menu bar keeps
    /// showing a checkmark. See `reconcileSystemProxyCapability` for the other
    /// half — sing-box still running, but its *current* config no longer has an
    /// inbound to serve System Proxy with.
    private func disableSystemProxyIfDangling() {
        disableSystemProxy()
    }

    /// While sing-box is running, checks whether `configPath` — the config it was
    /// just (re)started with — still has an inbound System Proxy can point at
    /// (`mixed`/`http`/`socks`). If System Proxy is enabled and it doesn't, turns
    /// it off and tells the user why, rather than leaving a checkmark on a proxy
    /// setting pointed at nothing.
    ///
    /// If the config *does* have one — the common case, e.g. enabling TUN on a
    /// config that also keeps its mixed/http/socks inbound — this deliberately
    /// does nothing: System Proxy stays exactly as it was, so it coexists with
    /// Enhanced Mode instead of being dropped as a side effect of the restart.
    private func reconcileSystemProxyCapability(configPath: String) {
        guard Preferences.systemProxyEnabled,
              !SingBoxProcessManager.hasProxyCapableInbound(at: configPath) else { return }
        AppLog.log("'\((configPath as NSString).lastPathComponent)' has no mixed/http/socks inbound while System Proxy is enabled; disabling it")
        disableSystemProxy(alertMessage: "\((configPath as NSString).lastPathComponent) has no mixed/http/socks inbound anymore, so System Proxy has nothing to connect to. It's been turned off.")
    }

    /// Turns System Proxy off and syncs menu bar/preference state to match.
    /// `alertMessage`, if given, is shown to the user — use it when disabling
    /// something they'd reasonably expect to still be working (config no longer
    /// serves a proxy inbound); omit it for the unsurprising case of sing-box
    /// simply not running at all.
    private func disableSystemProxy(alertMessage: String? = nil) {
        guard Preferences.systemProxyEnabled,
              let service = currentSystemProxyService ?? Preferences.preferredNetworkService else { return }

        AppLog.log("Disabling System Proxy for '\(service)'")
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
            AppNotifier.post(
                title: "System Proxy Disabled",
                body: alertMessage ?? "System Proxy has been turned off for '\(service)'.",
                identifier: "system-proxy"
            )
            self.refreshIcon()
            if let alertMessage {
                self.showNonBlockingAlert(title: "System Proxy Turned Off", message: alertMessage)
            }
        }
    }

    // MARK: - Menu construction

    private func buildMenu() {
        let menu = NSMenu()

        // Status line: reflects current sing-box state ("Running · Normal mode" /
        // "Running · TUN mode" / "Stopped"). No action/target of its own — clicking
        // it just reveals the submenu below, same as any other AppKit menu item with
        // a submenu. Kept in sync by `updateStatusLine`, called from `refreshIcon`.
        let advancedActionsSubmenu = NSMenu()

        restartSingBoxItem.title = "Restart sing-box"
        restartSingBoxItem.action = #selector(restartSingBox)
        restartSingBoxItem.target = self
        advancedActionsSubmenu.addItem(restartSingBoxItem)

        stopSingBoxItem.title = "Stop sing-box"
        stopSingBoxItem.action = #selector(stopSingBoxManually)
        stopSingBoxItem.target = self
        advancedActionsSubmenu.addItem(stopSingBoxItem)

        advancedActionsSubmenu.addItem(.separator())

        advancedActionsSubmenu.addItem(withTitle: "Reveal Logs in Finder", action: #selector(revealLogs), keyEquivalent: "")
        .target = self

        statusLineItem.submenu = advancedActionsSubmenu
        menu.addItem(statusLineItem)

        menu.addItem(.separator())

        // Only one entry point to the dashboard — previously duplicated by "Show
        // Main Window" (an unwired stub opening no window) and this item. Disabled
        // when sing-box isn't running, since 127.0.0.1:9090 won't be reachable —
        // kept in sync alongside restart/stop in `updateStatusLine`.
        controlPanelItem.title = "Open Control Panel"
        controlPanelItem.action = #selector(openControlPanel)
        controlPanelItem.target = self
        controlPanelItem.isEnabled = processManager.isRunning
        menu.addItem(controlPanelItem)

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

        // Work regardless of run state — opening the folder or an editor doesn't
        // touch sing-box at all, so neither is gated on `processManager.isRunning`.
        menu.addItem(withTitle: "Open Config Folder", action: #selector(openConfigFolder), keyEquivalent: "")
        .target = self

        menu.addItem(withTitle: "Edit Current Config", action: #selector(editCurrentConfig), keyEquivalent: "")
        .target = self

        menu.addItem(withTitle: "Reload Configuration", action: #selector(reloadConfiguration), keyEquivalent: "")
        .target = self

        // Governs how external changes to the active profile file are handled — see
        // `handleExternalConfigChange`. Off by default: notify and wait for a
        // manual reload rather than restarting a privileged process unprompted.
        autoReloadItem.title = "Auto Reload on Config Change"
        autoReloadItem.action = #selector(toggleAutoReloadOnConfigChange)
        autoReloadItem.target = self
        autoReloadItem.state = Preferences.autoReloadOnConfigChange ? .on : .off
        menu.addItem(autoReloadItem)

        // Remote Config submenu — a periodic downloader that writes over the
        // active profile file (see RemoteConfigUpdater); what happens after a
        // successful write is governed by the same Auto Reload setting above.
        remoteConfigItem.title = "Remote Config"
        rebuildRemoteConfigSubmenu()
        menu.addItem(remoteConfigItem)

        menu.addItem(.separator())

        launchAtLoginItem.title = "Launch at Login"
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        launchAtLoginItem.target = self
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

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

    /// Rebuilds the Remote Config submenu from current preferences — called at
    /// menu construction and again whenever the URL or interval changes, same
    /// pattern as `rebuildProfileSubmenu`.
    private func rebuildRemoteConfigSubmenu() {
        let submenu = NSMenu()

        let urlTitle: String
        if let url = Preferences.remoteConfigURL, !url.isEmpty {
            urlTitle = "URL: \(url)"
        } else {
            urlTitle = "URL: Not Set"
        }
        let urlDisplayItem = NSMenuItem(title: urlTitle, action: nil, keyEquivalent: "")
        urlDisplayItem.isEnabled = false
        submenu.addItem(urlDisplayItem)

        let setURLItem = NSMenuItem(title: "Set Remote Config URL…", action: #selector(setRemoteConfigURL), keyEquivalent: "")
        setURLItem.target = self
        submenu.addItem(setURLItem)

        submenu.addItem(.separator())

        for interval in RemoteConfigInterval.allCases {
            let item = NSMenuItem(title: interval.rawValue, action: #selector(selectRemoteConfigInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            item.state = (interval == Preferences.remoteConfigInterval) ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        let updateNowItem = NSMenuItem(title: "Update Now", action: #selector(updateRemoteConfigNow), keyEquivalent: "")
        updateNowItem.target = self
        submenu.addItem(updateNowItem)

        remoteConfigItem.submenu = submenu
    }

    private func refreshIcon() {
        let active = processManager.isRunning || Preferences.systemProxyEnabled
        statusItem.button?.image = IconRenderer.makeIcon(mode: Preferences.outboundMode, active: active)
        updateStatusLine()
    }

    /// Keeps the status line's title, and the enabled state of its Restart/Stop
    /// actions, in sync with reality. Deliberately folded into `refreshIcon` rather
    /// than given its own scattered call sites — `refreshIcon` already runs from
    /// every internal action AND from the periodic/on-menu-open external-state sync
    /// (see `syncExternalState`), so piggybacking on it is what makes the status
    /// line track external changes (sing-box started/stopped/reconfigured outside
    /// this app) in real time too, without duplicating those triggers here.
    ///
    /// `busyStatusMessage`, when set, takes priority over the normal
    /// running/stopped text — see `setBusyStatus`.
    private func updateStatusLine() {
        if let busyStatusMessage {
            statusLineItem.title = "sing-box: \(busyStatusMessage)"
        } else if processManager.isRunning {
            let mode = processManager.isTUNEnabled ? "TUN mode" : "Normal mode"
            statusLineItem.title = "sing-box: Running · \(mode)"
        } else {
            statusLineItem.title = "sing-box: Stopped"
        }
        let busy = busyStatusMessage != nil
        restartSingBoxItem.isEnabled = processManager.isRunning && !busy
        stopSingBoxItem.isEnabled = processManager.isRunning && !busy
        controlPanelItem.isEnabled = processManager.isRunning && !busy
    }

    /// Shows a transient status-line message (e.g. "Switching to TUN mode…") and
    /// disables Restart/Stop for the duration, so a several-second async operation
    /// reads as "working on it" instead of the menu just not responding — see
    /// `busyStatusMessage`'s doc comment for why this is needed.
    private func setBusyStatus(_ message: String) {
        busyStatusMessage = message
        updateStatusLine()
    }

    private func clearBusyStatus() {
        busyStatusMessage = nil
        updateStatusLine()
    }

    /// Thin wrapper around `processManager.start` that shows/clears a busy status
    /// message for the duration — every call site that starts/restarts sing-box
    /// should go through this rather than calling `processManager.start` directly,
    /// so the "don't just freeze" treatment is consistent everywhere (Enhanced
    /// Mode, Reload Configuration, profile switches, System Proxy's auto-start).
    private func startSingBox(configPath: String, enableTUN: Bool, busyMessage: String, completion: @escaping (Result<Void, Error>) -> Void) {
        setBusyStatus(busyMessage)
        processManager.start(configPath: configPath, enableTUN: enableTUN) { [weak self] result in
            self?.clearBusyStatus()
            completion(result)
        }
    }

    // MARK: - Actions

    @objc private func openControlPanel() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:9090")!)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? OutboundMode else { return }
        let changed = mode != Preferences.outboundMode
        Preferences.outboundMode = mode
        outboundModeItem.title = "Outbound Mode  (\(mode.badgeLetter))"
        outboundModeItem.submenu?.items.forEach { $0.state = ($0.representedObject as? OutboundMode) == mode ? .on : .off }
        refreshIcon()
        AppLog.log("Outbound mode preference set to \(mode.rawValue)")
        if changed {
            AppNotifier.post(
                title: "Outbound Mode Changed",
                body: "Now using \(mode.rawValue) mode.",
                identifier: "outbound-mode"
            )
        }

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
                AppNotifier.post(title: "System Proxy Disabled", body: "System Proxy has been turned off.", identifier: "system-proxy")
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
                    AppNotifier.post(title: "System Proxy Disabled", body: "Disabled for '\(service)'.", identifier: "system-proxy")
                    self.refreshIcon()
                case .failure(let error):
                    self.handleSystemProxyError(error)
                }
            }
        } else {
            // System Proxy routes traffic to a mixed/http/socks inbound in sing-box's
            // config, so it needs both sing-box running AND that inbound to actually
            // exist — a TUN-only config has nothing for it to connect to. Check that
            // up front and block with a clear message rather than silently enabling
            // a setting that won't do anything.
            guard let path = Preferences.activeProfilePath else {
                showNonBlockingAlert(title: "No Profile Selected", message: "Choose a profile under Switch Profile first, then try again.")
                return
            }
            guard SingBoxProcessManager.hasProxyCapableInbound(at: path) else {
                showNonBlockingAlert(
                    title: "No Proxy Inbound in Config",
                    message: "\((path as NSString).lastPathComponent) has no mixed/http/socks inbound, so there's nothing for System Proxy to connect to. Add one to the profile, then try again."
                )
                return
            }

            // Config supports it — start sing-box ourselves in normal mode (TUN left
            // disabled) if it isn't running yet, rather than erroring and making the
            // user start it by hand first. Enhanced Mode (TUN) stays a separate,
            // explicit opt-in, and — since we already confirmed a proxy-capable
            // inbound is present — the two can coexist: turning TUN on later won't
            // disable this (see reconcileSystemProxyCapability).
            guard processManager.isRunning else {
                startSingBox(configPath: path, enableTUN: false, busyMessage: "Starting…") { [weak self] result in
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
                AppNotifier.post(
                    title: "System Proxy Enabled",
                    body: "Enabled for '\(service)'.",
                    identifier: "system-proxy"
                )
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
            startSingBox(configPath: path, enableTUN: true, busyMessage: "Switching to TUN mode…") { [weak self] result in
                if case .failure(let error) = result {
                    self?.showNonBlockingAlert(title: "Failed to Start sing-box", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }

        // Preflight validation before switching anything — an invalid profile
        // shouldn't become "active" in the menu/Preferences, and definitely
        // shouldn't touch a currently-running sing-box, just because it was
        // clicked. Covers the case where sing-box isn't running yet too, where
        // otherwise nothing would validate this config until some later start.
        //
        // Runs off the main thread: `sing-box check` can take several seconds
        // (e.g. resolving remote rule-sets), and this is invoked directly from an
        // @objc menu action — doing it inline here would freeze the whole menu for
        // that long, same failure mode this file's `startSingBox` wrapper exists
        // to avoid for the actual start/restart calls below.
        setBusyStatus("Validating \(url.lastPathComponent)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (ok, output) = self.processManager.validateConfig(at: url.path)
            DispatchQueue.main.async {
                guard ok else {
                    self.clearBusyStatus()
                    self.showNonBlockingAlert(title: "Invalid Configuration", message: "\(url.lastPathComponent) failed validation:\n\(output)")
                    return
                }
                self.finishSelectingProfile(url: url) // clears busy status itself once settled
            }
        }
    }

    /// The state-switching half of `selectProfile`, run once preflight validation
    /// (on a background queue — see `selectProfile`) has confirmed the config is
    /// valid.
    private func finishSelectingProfile(url: URL) {
        let wasRunning = processManager.isRunning
        let wasTUNEnabled = processManager.isTUNEnabled
        Preferences.activeProfilePath = url.path
        rebuildProfileSubmenu()
        configWatcher.watch(path: url.path)
        AppLog.log("Active profile switched to \(url.lastPathComponent)")

        if wasRunning {
            // Preserve whatever mode was already active (normal vs. TUN) rather than
            // defaulting to TUN — a profile switch shouldn't silently turn Enhanced
            // Mode on for someone who was only using System Proxy. `start` validates
            // again internally, which is redundant here but harmless — it's the
            // single source of truth for "is this config OK to run" and every start
            // path goes through it.
            startSingBox(configPath: url.path, enableTUN: wasTUNEnabled, busyMessage: "Switching profile…") { [weak self] result in
                if case .failure(let error) = result {
                    self?.showNonBlockingAlert(title: "Profile Switch Failed", message: error.localizedDescription)
                }
            }
        } else {
            clearBusyStatus() // nothing running to restart — the "Validating…" message from selectProfile is done
        }
    }

    /// Opens the profiles directory in Finder — works whether or not sing-box is
    /// running, and regardless of whether a profile is currently selected. Creates
    /// the directory first if it doesn't exist yet, so a first-run user gets a real
    /// folder to drop configs into rather than Finder silently failing to open one.
    @objc private func openConfigFolder() {
        let dir = Preferences.profilesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// Opens the active profile file with whatever app macOS has associated with
    /// its extension (a text editor for the .yaml/.json profiles this app deals
    /// in). Works regardless of sing-box's run state — editing a config doesn't
    /// require sing-box to be running, and doesn't touch it either; use "Reload
    /// Configuration" afterward to apply changes.
    @objc private func editCurrentConfig() {
        guard let path = Preferences.activeProfilePath else {
            showNonBlockingAlert(title: "No Profile Selected", message: "Choose a profile under Switch Profile first.")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func reloadConfiguration() {
        guard let path = Preferences.activeProfilePath else { return }
        // Same mode it was already running in — reload shouldn't change that.
        startSingBox(configPath: path, enableTUN: processManager.isTUNEnabled, busyMessage: "Reloading configuration…") { [weak self] result in
            switch result {
            case .success:
                AppLog.log("Configuration reloaded")
            case .failure(let error):
                self?.showNonBlockingAlert(title: "Reload Failed", message: error.localizedDescription)
            }
        }
    }

    /// Manual control from the status line's Advanced Actions submenu. Currently
    /// the same operation as "Reload Configuration" (restart with the active
    /// profile, preserving normal-vs-TUN mode) — exposed again here, disabled
    /// unless sing-box is actually running, alongside Stop for discoverability.
    @objc private func restartSingBox() {
        reloadConfiguration()
    }

    /// Manual control from the status line's Advanced Actions submenu.
    /// `processManager.stop()` already disables System Proxy
    /// (`disableSystemProxyIfDangling`, via `onStateChange`) and clears TUN state
    /// as part of a genuine stop — this is just the explicit, user-facing entry
    /// point for that same path, which also drives the icon/status line update.
    @objc private func stopSingBoxManually() {
        processManager.stop()
    }

    @objc private func toggleAutoReloadOnConfigChange() {
        let newValue = !Preferences.autoReloadOnConfigChange
        Preferences.autoReloadOnConfigChange = newValue
        autoReloadItem.state = newValue ? .on : .off
        AppLog.log("Auto Reload on Config Change \(newValue ? "enabled" : "disabled")")
    }

    @objc private func setRemoteConfigURL() {
        let alert = NSAlert()
        alert.messageText = "Remote Config URL"
        alert.informativeText = "Enter the URL sing-box's config should be downloaded from on the schedule below. Leave blank to disable remote updates."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = Preferences.remoteConfigURL ?? ""
        field.placeholderString = "https://example.com/config.json"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Preferences.remoteConfigURL = trimmed.isEmpty ? nil : trimmed
        AppLog.log(trimmed.isEmpty ? "Remote config URL cleared" : "Remote config URL set")
        rebuildRemoteConfigSubmenu()
        RemoteConfigUpdater.shared.reschedule()
    }

    @objc private func selectRemoteConfigInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? RemoteConfigInterval else { return }
        Preferences.remoteConfigInterval = interval
        rebuildRemoteConfigSubmenu()
        RemoteConfigUpdater.shared.reschedule()
        AppLog.log("Remote config update interval set to \(interval.rawValue)")
    }

    /// Feedback for both this and any scheduled checks arrives via
    /// `RemoteConfigUpdater.onResult`, wired once in `applicationDidFinishLaunching`.
    @objc private func updateRemoteConfigNow() {
        RemoteConfigUpdater.shared.checkNow()
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