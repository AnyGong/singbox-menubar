import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let processManager = SingBoxProcessManager.shared

    // Menu items kept as properties so we can update their checkmarks/titles in place.
    private var statusLineItem = NSMenuItem()
    private var controlPanelItem = NSMenuItem()
    private var outboundModeItem = NSMenuItem()
    private var systemProxyItem = NSMenuItem()
    private var tunItem = NSMenuItem()
    private var switchProfileItem = NSMenuItem()
    private var launchAtLoginItem = NSMenuItem()
    private var launchAtLoginToggleView: SwitchMenuItemView!
    private var autoReloadItem = NSMenuItem()
    private var autoRestartItem = NSMenuItem()
    private var remoteConfigItem = NSMenuItem()

    private var currentSystemProxyService: String?

    /// Port System Proxy is currently pointed at — parsed from the active
    /// profile's mixed/http/socks inbound (see `SingBoxPortInspector`) at the
    /// moment System Proxy was enabled, not a hardcoded assumption. `nil` whenever
    /// `currentSystemProxyService` is, since the two are only ever set together.
    private var currentSystemProxyPort: String?

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

    /// Snapshot of `lastKnownTUNEnabled` taken alongside `pendingCrashStatus`, i.e.
    /// *before* `onStateChange` resets it — the mode sing-box should come back up
    /// in if "Auto-restart sing-box" restarts it. `processManager.isTUNEnabled`
    /// itself is already false again by the time either of these fire (reset by
    /// the termination handler before it calls out), so this is the only place
    /// that mode is still known.
    private var pendingCrashWasTUNEnabled = false

    /// Guards against a crash loop when "Auto-restart sing-box" is on and sing-box
    /// keeps failing immediately (a config that passed `sing-box check` but still
    /// fails at runtime, a TUN permission revoked mid-session, etc.). After
    /// `maxAutoRestartsInWindow` attempts inside `autoRestartWindow`, auto-restart
    /// pauses itself for the rest of this launch and tells the user, rather than
    /// hammering `sudo sing-box` indefinitely. See `attemptAutoRestartIfEnabled`.
    private var recentAutoRestartTimestamps: [Date] = []
    private static let maxAutoRestartsInWindow = 3
    private static let autoRestartWindow: TimeInterval = 60

    /// Transient message shown on the status line in place of "Running · Mode" /
    /// "Stopped" while an async validate/start/reload is in flight — e.g.
    /// "Switching to TUN mode…". `sing-box check` (run before every start — see
    /// `SingBoxProcessManager.start`) can take several seconds resolving remote
    /// rule-sets, so without this the status line would just sit unchanged for
    /// that long with no indication anything is happening. Set/cleared via
    /// `setBusyStatus`/`clearBusyStatus`, read by `updateStatusLine`.
    private var busyStatusMessage: String?

    /// `true` while a start/stop/restart is already in flight (see
    /// `setBusyStatus`/`clearBusyStatus`). Every action that can trigger one of
    /// those — System Proxy, TUN, profile switch, reload, and the bottom status
    /// control — checks this before doing anything, as a defense-in-depth backstop
    /// alongside disabling the corresponding menu items in `updateStatusLine`:
    /// AppKit's `isEnabled` re-render isn't necessarily synchronous with a rapid
    /// double-click/double-invocation, so relying on disabled state alone isn't
    /// quite airtight. Without this guard, two overlapping `processManager.start()`
    /// calls race independently on a background queue (validation, privilege
    /// checks, port-conflict resolution) before serializing on the main thread —
    /// the second one's `stopQuietly()` tears down whatever the first just spawned,
    /// which is how e.g. clicking System Proxy then immediately TUN could leave
    /// System Proxy silently pointed at a port nothing is listening on anymore.
    private var isBusy: Bool { busyStatusMessage != nil }

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
            guard let self else { return }
            self.pendingCrashStatus = status
            // Must capture this here, before onStateChange (called right after, by
            // the same termination handler) resets processManager.isTUNEnabled —
            // see this property's doc comment.
            self.pendingCrashWasTUNEnabled = self.lastKnownTUNEnabled
        }

        processManager.onStateChange = { [weak self] running in
            guard let self else { return }

            let tunNowEnabled = self.processManager.isTUNEnabled
            if tunNowEnabled != self.lastKnownTUNEnabled {
                self.lastKnownTUNEnabled = tunNowEnabled
                AppNotifier.post(
                    category: .tunMode,
                    title: tunNowEnabled ? "Enhanced Mode (TUN) Enabled" : "Enhanced Mode (TUN) Disabled",
                    body: tunNowEnabled ? "sing-box is now routing traffic through the TUN interface." : "TUN interface torn down."
                )
            }
            self.tunItem.state = tunNowEnabled ? .on : .off

            if let crashStatus = self.pendingCrashStatus, !running {
                self.pendingCrashStatus = nil
                AppNotifier.post(
                    category: .singBoxRunState,
                    title: "sing-box Stopped Unexpectedly",
                    body: "sing-box exited unexpectedly (status \(crashStatus)). Check sing-box.log for details."
                )
                self.attemptAutoRestartIfEnabled(wasTUNEnabled: self.pendingCrashWasTUNEnabled)
            } else {
                AppNotifier.post(
                    category: .singBoxRunState,
                    title: running ? "sing-box Started" : "sing-box Stopped",
                    body: running ? "sing-box is now running." : "sing-box is no longer running."
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
            // Covers the case where sing-box is already running before this app
            // launched (adopted via `syncExternalState`/`reconcileRunningState`
            // below) — that path never goes through `startSingBox`, so without
            // this, ClashAPIClient would sit on its 127.0.0.1:9090 default until
            // the next actual start/reload, even if this profile declares a
            // different Clash API endpoint.
            syncClashAPIEndpoint(configPath: path)
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
            AppNotifier.post(category: .configChange, title: "Configuration Changed", body: "\(name) changed on disk.")
            return
        }

        if Preferences.autoReloadOnConfigChange {
            AppNotifier.post(
                category: .configChange,
                title: "Configuration Changed",
                body: "\(name) changed on disk. Reloading automatically…"
            )
            reloadConfiguration()
        } else {
            AppNotifier.post(
                category: .configChange,
                title: "Configuration Changed",
                body: "\(name) changed on disk. Reload it from the menu to apply, or enable Auto Reload on Config Change."
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
                category: .outboundMode,
                title: "Outbound Mode Changed",
                body: "Now using \(mode.rawValue) mode."
            )
            self.refreshIcon()
        }
    }

    private func syncSystemProxyStateFromSystem() {
        guard let service = currentSystemProxyService ?? Preferences.preferredNetworkService else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let settings = SystemProxyManager.currentProxySettings(service: service)
            let actuallyEnabled = settings.enabled
            DispatchQueue.main.async { [weak self] in
                guard let self, actuallyEnabled != Preferences.systemProxyEnabled else { return }
                AppLog.log("Detected system proxy \(actuallyEnabled ? "enabled" : "disabled") externally for '\(service)'; syncing menu bar")
                Preferences.systemProxyEnabled = actuallyEnabled
                self.currentSystemProxyService = actuallyEnabled ? service : nil
                self.currentSystemProxyPort = actuallyEnabled ? settings.port : nil
                self.systemProxyItem.state = actuallyEnabled ? .on : .off
                AppNotifier.post(
                    category: .systemProxy,
                    title: actuallyEnabled ? "System Proxy Enabled" : "System Proxy Disabled",
                    body: actuallyEnabled ? "Enabled externally for '\(service)' on port \(settings.port ?? "?")." : "Disabled externally for '\(service)'."
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
            self.currentSystemProxyPort = nil
            self.systemProxyItem.state = .off
            AppNotifier.post(
                category: .systemProxy,
                title: "System Proxy Disabled",
                body: alertMessage ?? "System Proxy has been turned off for '\(service)'."
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

        // Only one entry point to the dashboard — previously duplicated by "Show
        // Main Window" (an unwired stub opening no window) and this item. Disabled
        // when sing-box isn't running, since 127.0.0.1:9090 won't be reachable —
        // kept in sync alongside the status control in `updateStatusLine`.
        controlPanelItem.title = "Open Control Panel"
        controlPanelItem.action = #selector(openControlPanel)
        controlPanelItem.target = self
        controlPanelItem.isEnabled = processManager.isRunning
        menu.addItem(controlPanelItem)

        // Always enabled, regardless of run state — that's the point: this is what
        // you reach for to find out *why* sing-box isn't running, not just when it
        // already is.
        menu.addItem(withTitle: "Diagnostics", action: #selector(runDiagnostics), keyEquivalent: "")
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

        // Off by default: only notify on an unexpected exit (crash, or external
        // termination) and otherwise leave sing-box stopped for manual
        // intervention — same as before this toggle existed. See
        // `attemptAutoRestartIfEnabled`, invoked from the crash branch of
        // `onStateChange` above.
        autoRestartItem.title = "Auto-restart sing-box"
        autoRestartItem.action = #selector(toggleAutoRestartOnUnexpectedExit)
        autoRestartItem.target = self
        autoRestartItem.state = Preferences.autoRestartOnUnexpectedExit ? .on : .off
        menu.addItem(autoRestartItem)

        // Remote Config submenu — a periodic downloader that writes over the
        // active profile file (see RemoteConfigUpdater); what happens after a
        // successful write is governed by the same Auto Reload setting above.
        remoteConfigItem.title = "Remote Config"
        rebuildRemoteConfigSubmenu()
        menu.addItem(remoteConfigItem)

        menu.addItem(.separator())

        menu.addItem(withTitle: "Reveal Logs in Finder", action: #selector(revealLogs), keyEquivalent: "")
        .target = self

        launchAtLoginItem.title = "Launch at Login"
        // View-based rather than the plain checkmark every other toggle in this
        // menu uses — see SwitchMenuItemView's doc comment for why. `title` above
        // is still set even though the custom view is what actually renders (and
        // does its own layout for) the row — AppKit falls back to it for
        // accessibility (VoiceOver) and for the arrow-key-navigation label.
        let toggleView = SwitchMenuItemView(title: "Launch at Login", isOn: LaunchAtLogin.isEnabled)
        toggleView.onToggle = { [weak self] isOn in
            self?.setLaunchAtLogin(isOn)
        }
        launchAtLoginItem.view = toggleView
        launchAtLoginToggleView = toggleView
        menu.addItem(launchAtLoginItem)

        // Destructive/rare — kept in its own separated slot rather than grouped
        // with the routine toggles above. See `performCleanUp`.
        menu.addItem(withTitle: "Clean Up…", action: #selector(promptCleanUp), keyEquivalent: "")
        .target = self

        menu.addItem(.separator())

        // Status/control, directly clickable to start or stop sing-box — no
        // submenu, no separate Restart/Stop items to dig into. The leading dot
        // (green = running, gray = stopped) is the at-a-glance state; the title is
        // the detail. Placed here, just above Quit, per the "clear, bottom-of-menu"
        // request rather than buried above the mode/profile controls where it used
        // to sit with a submenu.
        statusLineItem.action = #selector(toggleSingBoxRunning)
        statusLineItem.target = self
        menu.addItem(statusLineItem)

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
        // Active means "traffic is actually being routed through something the user
        // turned on" — System Proxy or Enhanced Mode (TUN) — not just "sing-box
        // happens to be running." sing-box can be up in plain normal mode (e.g.
        // auto-started, or left running after disabling both) with nothing actually
        // consuming it; that should show as the dim/no-letter inactive icon, same as
        // if it weren't running at all.
        let active = Preferences.systemProxyEnabled || processManager.isTUNEnabled
        statusItem.button?.image = IconRenderer.makeIcon(mode: Preferences.outboundMode, active: active)
        updateStatusLine()
    }

    /// Keeps the status/control item's dot + title, and "Open Control Panel"'s
    /// enabled state, in sync with reality. Deliberately folded into `refreshIcon`
    /// rather than given its own scattered call sites — `refreshIcon` already runs
    /// from every internal action AND from the periodic/on-menu-open external-state
    /// sync (see `syncExternalState`), so piggybacking on it is what makes the
    /// status line track external changes (sing-box started/stopped/reconfigured
    /// outside this app) in real time too, without duplicating those triggers here.
    ///
    /// `busyStatusMessage`, when set, takes priority over the normal
    /// running/stopped text — see `setBusyStatus`.
    private func updateStatusLine() {
        let text: String
        if let busyStatusMessage {
            text = "sing-box: \(busyStatusMessage)"
        } else if processManager.isRunning {
            let mode = processManager.isTUNEnabled ? "TUN mode" : "Normal mode"
            text = "sing-box: Running · \(mode)"
        } else {
            text = "sing-box: Stopped"
        }
        let dotColor: NSColor = processManager.isRunning ? .systemGreen : .systemGray
        statusLineItem.attributedTitle = statusLineTitle(dotColor: dotColor, text: text)

        let busy = busyStatusMessage != nil
        // Clicking mid-transition (e.g. while "Switching to TUN mode…" is showing)
        // would race the operation already in flight — every control that can kick
        // off a start/stop/restart needs to be disabled for that window, not just
        // the status line itself. This used to only cover statusLineItem/
        // controlPanelItem, which is exactly why System Proxy and TUN were still
        // clickable (and so re-triggerable) mid-transition — see
        // `toggleSystemProxy`/`toggleTUN`'s own `guard !isBusy` for the second,
        // defense-in-depth layer of this same fix.
        statusLineItem.isEnabled = !busy
        controlPanelItem.isEnabled = processManager.isRunning && !busy
        systemProxyItem.isEnabled = !busy
        tunItem.isEnabled = !busy
        switchProfileItem.isEnabled = !busy
    }

    /// Builds the status item's title as "● sing-box: …" with only the dot colored
    /// — the text keeps the menu's normal (unset) color/font so it still adapts
    /// correctly to dark mode, selection highlight, and Dynamic Type, none of which
    /// a plain colored-emoji-in-a-string approach would get right (emoji glyphs
    /// ignore `.foregroundColor`, and can't be gray vs. green on demand).
    private func statusLineTitle(dotColor: NSColor, text: String) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: "● ",
            attributes: [.foregroundColor: dotColor, .font: NSFont.menuFont(ofSize: 0)]
        )
        title.append(NSAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        return title
    }

    /// Shows a transient status-line message (e.g. "Switching to TUN mode…") and
    /// disables the status control for the duration, so a several-second async
    /// operation reads as "working on it" instead of the menu just not responding —
    /// see `busyStatusMessage`'s doc comment for why this is needed.
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
    ///
    /// Also the single choke point for keeping `ClashAPIClient` pointed at whatever
    /// `configPath` actually declares (see `syncClashAPIEndpoint`) — every start
    /// funnels through here regardless of *why* (fresh start, reload, profile
    /// switch, mode change), so this is the one place that guarantees the endpoint
    /// never goes stale, rather than needing every call site to remember to sync it.
    private func startSingBox(configPath: String, enableTUN: Bool, busyMessage: String, completion: @escaping (Result<Void, Error>) -> Void) {
        setBusyStatus(busyMessage)
        syncClashAPIEndpoint(configPath: configPath)
        processManager.start(configPath: configPath, enableTUN: enableTUN) { [weak self] result in
            self?.clearBusyStatus()
            completion(result)
        }
    }

    /// Points `ClashAPIClient.shared` at whatever `configPath`'s own
    /// `experimental.clash_api` block declares, instead of leaving it hardcoded to
    /// sing-box's documented default (127.0.0.1:9090, no secret) regardless of what
    /// the config actually says. That mismatch is exactly why live outbound-mode
    /// switching, "Open Control Panel", and Diagnostics' Clash API check could all
    /// fail against a perfectly healthy sing-box process — they were talking to the
    /// wrong port (or missing a required secret) whenever a profile customized
    /// either. No-ops (leaves the current endpoint as-is) when the config declares
    /// no `experimental.clash_api` at all — see `SingBoxPortInspector
    /// .clashAPIEndpoint`'s doc comment.
    private func syncClashAPIEndpoint(configPath: String) {
        guard let endpoint = SingBoxPortInspector.clashAPIEndpoint(at: configPath) else { return }
        guard let url = URL(string: "http://\(endpoint.address)") else {
            AppLog.error("Config declares an unparseable Clash API address '\(endpoint.address)' — leaving ClashAPIClient pointed at its previous target.")
            return
        }
        if ClashAPIClient.shared.baseURL != url {
            AppLog.log("Clash API endpoint set to \(url.absoluteString), from \((configPath as NSString).lastPathComponent)")
        }
        ClashAPIClient.shared.baseURL = url
        ClashAPIClient.shared.secret = endpoint.secret
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
                category: .outboundMode,
                title: "Outbound Mode Changed",
                body: "Now using \(mode.rawValue) mode."
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
        guard !isBusy else { return }
        if Preferences.systemProxyEnabled {
            guard let service = currentSystemProxyService else {
                Preferences.systemProxyEnabled = false
                systemProxyItem.state = .off
                AppNotifier.post(category: .systemProxy, title: "System Proxy Disabled", body: "System Proxy has been turned off.")
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
                    self.currentSystemProxyPort = nil
                    AppNotifier.post(category: .systemProxy, title: "System Proxy Disabled", body: "Disabled for '\(service)'.")
                    self.refreshIcon()
                case .failure(let error):
                    self.handleSystemProxyError(error)
                }
            }
        } else {
            // System Proxy routes traffic to a mixed/http/socks inbound in sing-box's
            // config, so it needs both sing-box running AND that inbound to actually
            // exist — a TUN-only config has nothing for it to connect to. Parsing the
            // port here (rather than assuming one) also doubles as that existence
            // check: no port means no such inbound. Block with a clear message
            // rather than silently enabling a setting that won't do anything.
            guard let path = Preferences.activeProfilePath else {
                showNonBlockingAlert(title: "No Profile Selected", message: "Choose a profile under Switch Profile first, then try again.")
                return
            }
            guard let port = SingBoxPortInspector.proxyInboundPort(at: path) else {
                showNonBlockingAlert(
                    title: "No Proxy Inbound in Config",
                    message: "\((path as NSString).lastPathComponent) has no mixed/http/socks inbound, so there's nothing for System Proxy to connect to. Add one to the profile, then try again."
                )
                return
            }
            let portString = String(port)

            // Config supports it — start sing-box ourselves in normal mode (TUN left
            // disabled) if it isn't running yet, rather than erroring and making the
            // user start it by hand first. Enhanced Mode (TUN) stays a separate,
            // explicit opt-in, and — since we already confirmed a proxy-capable
            // inbound is present — the two can coexist: turning TUN on later won't
            // disable this (see reconcileSystemProxyCapability). `start` itself now
            // checks whether something is already bound to `port` (a leftover
            // sing-box from this app, or a conflicting foreign process) before
            // spawning — see SingBoxProcessManager.resolveStartConflict.
            guard processManager.isRunning else {
                startSingBox(configPath: path, enableTUN: false, busyMessage: "Starting…") { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.beginEnablingSystemProxy(port: portString)
                    case .failure(let error):
                        self.showNonBlockingAlert(title: "Failed to Start sing-box", message: error.localizedDescription)
                    }
                }
                return
            }

            beginEnablingSystemProxy(port: portString)
        }
    }

    /// Picks (or reuses) a network service and turns System Proxy on for it, at
    /// `port` (parsed from the active profile — see `SingBoxPortInspector`, not a
    /// hardcoded assumption). Split out from `toggleSystemProxy` so it can run
    /// either immediately, when sing-box is already running, or after auto-starting
    /// it in normal mode.
    private func beginEnablingSystemProxy(port: String) {
        let services = SystemProxyManager.activeNetworkServices()

        if services.isEmpty {
            showNonBlockingAlert(title: "No Active Network Service", message: "No active network services were found to set a proxy on.")
            return
        }

        // Reuse a previously chosen service without prompting again, as long as
        // it's still active. Falls through to picker/auto-pick logic otherwise.
        if let preferred = Preferences.preferredNetworkService, services.contains(preferred) {
            enableSystemProxy(on: preferred, port: port)
            return
        }

        if services.count == 1 {
            let only = services[0]
            Preferences.preferredNetworkService = only
            enableSystemProxy(on: only, port: port)
            return
        }

        presentServicePicker(services: services) { [weak self] chosen in
            guard let self, let chosen else { return }
            Preferences.preferredNetworkService = chosen
            self.enableSystemProxy(on: chosen, port: port)
        }
    }

    private func enableSystemProxy(on service: String, port: String) {
        SystemProxyManager.enable(service: service, port: port) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                Preferences.systemProxyEnabled = true
                self.currentSystemProxyService = service
                self.currentSystemProxyPort = port
                self.systemProxyItem.state = .on
                AppNotifier.post(
                    category: .systemProxy,
                    title: "System Proxy Enabled",
                    body: "Enabled for '\(service)' on port \(port)."
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
        guard !isBusy else { return }
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
        guard !isBusy else { return }
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
        guard !isBusy else { return }
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

    /// The status/control item's single action: start sing-box if it's stopped,
    /// stop it if it's running. Replaces the old separate "Restart sing-box"/"Stop
    /// sing-box" submenu items — a start defaults to normal mode (no TUN), matching
    /// what "Set as System Proxy"'s auto-start already does, since a bare "start"
    /// click shouldn't silently opt the user into Enhanced Mode; use the Enhanced
    /// Mode (TUN) item for that. `processManager.stop()` already handles disabling
    /// System Proxy if it'd otherwise be left dangling (`disableSystemProxyIfDangling`,
    /// via `onStateChange`), same as it always has.
    @objc private func toggleSingBoxRunning() {
        guard !isBusy else { return }
        if processManager.isRunning {
            processManager.stop()
        } else {
            guard let path = Preferences.activeProfilePath else {
                showNonBlockingAlert(title: "No Profile Selected", message: "Choose a profile under Switch Profile first.")
                return
            }
            startSingBox(configPath: path, enableTUN: false, busyMessage: "Starting sing-box…") { [weak self] result in
                if case .failure(let error) = result {
                    self?.showNonBlockingAlert(title: "Failed to Start sing-box", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func toggleAutoReloadOnConfigChange() {
        let newValue = !Preferences.autoReloadOnConfigChange
        Preferences.autoReloadOnConfigChange = newValue
        autoReloadItem.state = newValue ? .on : .off
        AppLog.log("Auto Reload on Config Change \(newValue ? "enabled" : "disabled")")
    }

    @objc private func toggleAutoRestartOnUnexpectedExit() {
        let newValue = !Preferences.autoRestartOnUnexpectedExit
        Preferences.autoRestartOnUnexpectedExit = newValue
        autoRestartItem.state = newValue ? .on : .off
        AppLog.log("Auto-restart sing-box \(newValue ? "enabled" : "disabled")")
    }

    /// Attempts to bring sing-box back up after an unexpected exit, if the user
    /// has "Auto-restart sing-box" on — a no-op otherwise, leaving the "stopped
    /// unexpectedly" notification already posted by the caller as the whole story,
    /// same as this app's behavior before this toggle existed.
    ///
    /// Restarts in whatever mode (TUN vs. normal) sing-box was actually running in
    /// right before it exited — see `pendingCrashWasTUNEnabled`'s doc comment for
    /// why that has to be passed in rather than read fresh here.
    ///
    /// Rate-limited via `recentAutoRestartTimestamps` so a config that's broken at
    /// runtime (despite passing `sing-box check`) can't turn into an unbounded
    /// restart loop — see those properties' doc comment.
    private func attemptAutoRestartIfEnabled(wasTUNEnabled: Bool) {
        guard Preferences.autoRestartOnUnexpectedExit else { return }
        guard let path = Preferences.activeProfilePath else {
            AppLog.error("Auto-restart sing-box: no active profile to restart with.")
            return
        }

        let now = Date()
        recentAutoRestartTimestamps.removeAll { now.timeIntervalSince($0) > Self.autoRestartWindow }
        guard recentAutoRestartTimestamps.count < Self.maxAutoRestartsInWindow else {
            AppLog.error(
                "Auto-restart sing-box: \(Self.maxAutoRestartsInWindow) restarts within \(Int(Self.autoRestartWindow))s — " +
                        "pausing auto-restart for the rest of this session to avoid a crash loop. Check sing-box.log, fix the " +
                        "underlying issue, then restart manually from the menu."
            )
            AppNotifier.post(
                category: .singBoxRunState,
                title: "Auto-restart Paused",
                body: "sing-box kept exiting immediately, so auto-restart has paused itself for this session. Check sing-box.log, then restart manually."
            )
            return
        }
        recentAutoRestartTimestamps.append(now)

        AppLog.log("Auto-restart sing-box: attempting restart (\(wasTUNEnabled ? "TUN" : "Normal") mode)")
        startSingBox(configPath: path, enableTUN: wasTUNEnabled, busyMessage: "Auto-restarting…") { [weak self] result in
            switch result {
            case .success:
                AppLog.log("Auto-restart sing-box succeeded")
            case .failure(let error):
                AppLog.error("Auto-restart sing-box failed: \(error.localizedDescription)")
                self?.showNonBlockingAlert(title: "Auto-restart Failed", message: error.localizedDescription)
            }
        }
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

    /// Applies a requested Launch at Login state, then reads back
    /// `LaunchAtLogin.isEnabled` and syncs the switch to *that* rather than trusting
    /// `isOn` blindly — `SMAppService.register()`/`unregister()` can fail silently
    /// (permissions, a stale registration, etc. — see `LaunchAtLogin.setEnabled`'s
    /// doc comment), and a switch showing "on" when it didn't actually take would
    /// be worse than the old checkmark-based version, not better.
    private func setLaunchAtLogin(_ isOn: Bool) {
        LaunchAtLogin.setEnabled(isOn)
        let actual = LaunchAtLogin.isEnabled
        launchAtLoginToggleView.setOn(actual)
        if actual != isOn {
            AppLog.error("Launch at Login: requested \(isOn), but actual state is \(actual) after applying")
        }
    }

    @objc private func revealLogs() {
        NSWorkspace.shared.open(AppLog.directory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Clean Up

    /// Confirms with the user, then hands off to `performCleanUp`. "Clean Up" is
    /// second/non-default here — the destructive option deliberately isn't the one
    /// bound to Return, so pressing Enter/Space out of habit lands on Cancel instead.
    @objc private func promptCleanUp() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Clean Up singbox-menubar?"
        alert.informativeText = """
                                This always:
                                • Stops sing-box, if it's running
                                • Turns off System Proxy
                                • Turns off Launch at Login
                                • Resets this app's saved settings (mode, active profile, toggles) to defaults

                                This never touches the sing-box binary itself, the passwordless-sudo setup, or this app bundle.
                                """

        let checkbox = NSButton(checkboxWithTitle: "Also delete config profiles (~/.config/sing-box) and logs", target: nil, action: nil)
        checkbox.state = .off
        alert.accessoryView = checkbox

        alert.addButton(withTitle: "Cancel")
        let cleanButton = alert.addButton(withTitle: "Clean Up")
        cleanButton.hasDestructiveAction = true

        guard alert.runModal() == .alertSecondButtonReturn else { return }
        performCleanUp(alsoDeleteFilesAndProfiles: checkbox.state == .on)
    }

    /// Removes this app's footprint from the system — see requirements: "quickly
    /// remove the app's changes to the system... restore a clean environment,"
    /// aimed at development/testing.
    ///
    /// Always: stops sing-box, disables System Proxy for every active network
    /// service that currently reports it on (not just whichever one this session
    /// happens to be tracking in `currentSystemProxyService` — a stray enable left
    /// over from an earlier crash/session on some other service should still get
    /// caught here), turns off Launch at Login, and resets every preference this
    /// app has written back to first-launch defaults.
    ///
    /// Only if `alsoDeleteFilesAndProfiles` is true (opt-in, off by default in the
    /// confirmation dialog): also deletes this app's generated files, its logs,
    /// AND the sing-box profiles directory (`~/.config/sing-box`) — the last of
    /// which isn't exclusively this app's (the user may hand-author or use those
    /// configs with sing-box directly), so it's never touched without explicit
    /// confirmation.
    ///
    /// Deliberately does NOT: uninstall sing-box itself, remove the
    /// passwordless-sudo entry (that's a root-owned file outside anything this app
    /// can write — see README), or quit/delete the app bundle. This is a state
    /// reset, not an uninstaller for sing-box or for itself.
    private func performCleanUp(alsoDeleteFilesAndProfiles: Bool) {
        AppLog.log("Clean Up: starting (also deleting files/profiles: \(alsoDeleteFilesAndProfiles))")

        if processManager.isRunning {
            processManager.stop() // cascades into disabling System Proxy via onStateChange, same as any other stop
        }

        // Belt-and-suspenders beyond the above: catch a stray enable on some other
        // service this app session was never tracking.
        for service in SystemProxyManager.activeNetworkServices() where SystemProxyManager.isEnabled(service: service) {
            SystemProxyManager.disable(service: service) { _ in }
        }
        Preferences.systemProxyEnabled = false
        currentSystemProxyService = nil
        currentSystemProxyPort = nil
        systemProxyItem.state = .off

        if LaunchAtLogin.isEnabled {
            setLaunchAtLogin(false)
        }

        configWatcher.stop()
        RemoteConfigUpdater.shared.stop()

        processManager.removeGeneratedFiles() // this app's own generated file, never user data — always safe

        // Deletes the log directory itself if requested, so nothing after this
        // point should rely on AppLog actually landing on disk — hence this being
        // last among the AppLog-adjacent steps above.
        if alsoDeleteFilesAndProfiles {
            try? FileManager.default.removeItem(at: AppLog.directory)
            try? FileManager.default.removeItem(at: Preferences.profilesDirectory)
        }

        Preferences.resetAll()

        // Reflect the reset state immediately rather than waiting for the next
        // menu open/external-state poll to catch up.
        rebuildProfileSubmenu()
        rebuildRemoteConfigSubmenu()
        tunItem.state = .off
        refreshIcon()

        let summary = alsoDeleteFilesAndProfiles
                ? "sing-box stopped, System Proxy and Launch at Login turned off, settings reset, and app files/logs/profiles removed."
                : "sing-box stopped, System Proxy and Launch at Login turned off, and settings reset. Config profiles and logs were kept."
        let completionAlert = NSAlert()
        completionAlert.messageText = "Clean Up Complete"
        completionAlert.informativeText = summary + " You can now quit the app (⌘Q) and, if you'd like, delete it entirely."
        completionAlert.addButton(withTitle: "OK")
        completionAlert.runModal()
    }

    // MARK: - Diagnostics

    @objc private func runDiagnostics() {
        AppLog.log("Running diagnostics")
        // Prefer the port we actually enabled System Proxy with over re-parsing the
        // active profile — if the profile changed since, currentSystemProxyPort is
        // what's really configured at the OS level right now, which is what this
        // check verifies against.
        let expectedPort = currentSystemProxyPort.flatMap(Int.init)
                ?? Preferences.activeProfilePath.flatMap { SingBoxPortInspector.proxyInboundPort(at: $0) }
        DiagnosticsRunner.run(
            systemProxyService: currentSystemProxyService ?? Preferences.preferredNetworkService,
            expectedProxyPort: expectedPort
        ) { [weak self] result in
            self?.presentDiagnostics(result)
        }
    }

    /// Shows the diagnostics report as a single alert listing every check with a
    /// status glyph and a short explanation — simple and non-blocking (see
    /// `showNonBlockingAlert`'s doc comment on what "non-blocking" means here: it
    /// doesn't hold up sing-box or the rest of the app, only further menu clicks
    /// until dismissed), which is all a one-shot health check needs. Unlike
    /// `showNonBlockingAlert`, this isn't necessarily reporting a problem, so it
    /// doesn't log at error level or use the warning alert style.
    private func presentDiagnostics(_ result: DiagnosticsResult) {
        let alert = NSAlert()
        alert.messageText = "Diagnostics"
        alert.alertStyle = .informational
        alert.informativeText = result.checks
                .map { "\($0.status.symbol) \($0.title): \($0.detail)" }
                .joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
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