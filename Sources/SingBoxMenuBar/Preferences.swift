import Foundation

enum OutboundMode: String, CaseIterable {
    case direct = "Direct"
    case global = "Global"
    case rule = "Rule"

    /// Badge letter shown on the menu-bar icon.
    var badgeLetter: String {
        switch self {
        case .direct: return "D"
        case .global: return "G"
        case .rule:   return "R"
        }
    }

    /// Value sent to sing-box's Clash API for `PATCH /configs`, e.g. {"mode": "rule"}.
    var clashModeValue: String {
        rawValue.lowercased()
    }

    /// Reverse of `clashModeValue` — used when reading the live mode back from
    /// `GET /configs` so externally-made changes can be reflected in the menu bar.
    init?(clashModeValue: String) {
        guard let match = OutboundMode.allCases.first(where: { $0.clashModeValue == clashModeValue.lowercased() }) else {
            return nil
        }
        self = match
    }
}

enum RemoteConfigInterval: String, CaseIterable {
    case off = "Off"
    case hourly = "Hourly"
    case daily = "Daily"
    case weekly = "Weekly"

    /// `nil` for `.off` — the updater treats that as "don't schedule anything".
    var timeInterval: TimeInterval? {
        switch self {
        case .off: return nil
        case .hourly: return 3600
        case .daily: return 86400
        case .weekly: return 604800
        }
    }
}

enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let outboundMode = "outboundMode"
        static let activeProfilePath = "activeProfilePath"
        static let systemProxyEnabled = "systemProxyEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let preferredNetworkService = "preferredNetworkService"
        static let autoReloadOnConfigChange = "autoReloadOnConfigChange"
        static let autoRestartOnUnexpectedExit = "autoRestartOnUnexpectedExit"
        static let remoteConfigURL = "remoteConfigURL"
        static let remoteConfigInterval = "remoteConfigInterval"
        static let disabledNotificationCategories = "disabledNotificationCategories"
    }

    static var outboundMode: OutboundMode {
        get {
            guard let raw = defaults.string(forKey: Keys.outboundMode),
                  let mode = OutboundMode(rawValue: raw) else {
                return .rule // default per spec
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.outboundMode) }
    }

    static var activeProfilePath: String? {
        get { defaults.string(forKey: Keys.activeProfilePath) }
        set { defaults.set(newValue, forKey: Keys.activeProfilePath) }
    }

    static var systemProxyEnabled: Bool {
        get { defaults.bool(forKey: Keys.systemProxyEnabled) }
        set { defaults.set(newValue, forKey: Keys.systemProxyEnabled) }
    }

    /// Remembered choice from the "multiple network services" picker, so the picker
    /// only appears once and subsequent toggles reuse it silently. Cleared implicitly
    /// whenever it's no longer among the active services — see AppDelegate.toggleSystemProxy.
    static var preferredNetworkService: String? {
        get { defaults.string(forKey: Keys.preferredNetworkService) }
        set { defaults.set(newValue, forKey: Keys.preferredNetworkService) }
    }

    /// Directory scanned for available profile .yaml/.json files (Switch Profile submenu).
    static var profilesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sing-box", isDirectory: true)
    }

    /// Whether the app should reload the active configuration automatically when it
    /// detects the file changed on disk (see `ConfigFileWatcher`), versus just
    /// notifying and waiting for a manual "Reload Configuration". Off by default —
    /// silently reloading whatever a file watcher noticed felt like the wrong
    /// default for something that restarts a privileged process; opt in explicitly
    /// via the "Auto Reload on Config Change" menu item.
    static var autoReloadOnConfigChange: Bool {
        get { defaults.bool(forKey: Keys.autoReloadOnConfigChange) }
        set { defaults.set(newValue, forKey: Keys.autoReloadOnConfigChange) }
    }

    /// Off by default — matches the pre-existing behavior of only notifying on an
    /// unexpected exit (crash, or external termination of a process this app
    /// started) and otherwise leaving sing-box stopped until manual intervention.
    /// See `AppDelegate.attemptAutoRestartIfEnabled`.
    static var autoRestartOnUnexpectedExit: Bool {
        get { defaults.bool(forKey: Keys.autoRestartOnUnexpectedExit) }
        set { defaults.set(newValue, forKey: Keys.autoRestartOnUnexpectedExit) }
    }

    /// URL sing-box's config is downloaded from on the schedule below. `nil`/empty
    /// means remote auto-update is unconfigured, independent of the interval
    /// setting — both must be set for `RemoteConfigUpdater` to actually schedule
    /// anything (see `RemoteConfigUpdater.reschedule`).
    static var remoteConfigURL: String? {
        get { defaults.string(forKey: Keys.remoteConfigURL) }
        set { defaults.set(newValue, forKey: Keys.remoteConfigURL) }
    }

    static var remoteConfigInterval: RemoteConfigInterval {
        get {
            guard let raw = defaults.string(forKey: Keys.remoteConfigInterval),
                  let interval = RemoteConfigInterval(rawValue: raw) else {
                return .off // default: no auto-update until explicitly configured
            }
            return interval
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.remoteConfigInterval) }
    }

    /// Which notification categories are turned OFF — see the "Notifications"
    /// submenu and `NotificationCategory`. Deliberately an opt-out set (stored as
    /// the *disabled* ones) rather than an opt-in set of enabled ones: an empty set
    /// means every category is on, matching this app's behavior before per-category
    /// control existed, and any category added in the future is automatically on
    /// for existing users too — no migration needed to "turn on" something new.
    static var disabledNotificationCategories: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.disabledNotificationCategories) ?? []) }
        set { defaults.set(Array(newValue), forKey: Keys.disabledNotificationCategories) }
    }

    static func isNotificationCategoryEnabled(_ category: NotificationCategory) -> Bool {
        !disabledNotificationCategories.contains(category.rawValue)
    }

    static func setNotificationCategory(_ category: NotificationCategory, enabled: Bool) {
        var disabled = disabledNotificationCategories
        if enabled {
            disabled.remove(category.rawValue)
        } else {
            disabled.insert(category.rawValue)
        }
        disabledNotificationCategories = disabled
    }

    /// Removes every preference this app has ever written, restoring first-launch
    /// defaults (Rule mode, no active profile, System Proxy/auto-reload/auto-restart
    /// all off, etc.) without needing to keep this list in sync with every default
    /// value individually. Used by "Clean Up" (see AppDelegate) — deliberately does
    /// NOT touch anything outside `UserDefaults` (files, System Proxy, Launch at
    /// Login, the running process); those are each cleaned up independently by the
    /// caller, since only some of them should happen unconditionally.
    static func resetAll() {
        for key in [
            Keys.outboundMode,
            Keys.activeProfilePath,
            Keys.systemProxyEnabled,
            Keys.launchAtLogin,
            Keys.preferredNetworkService,
            Keys.autoReloadOnConfigChange,
            Keys.autoRestartOnUnexpectedExit,
            Keys.remoteConfigURL,
            Keys.remoteConfigInterval,
            Keys.disabledNotificationCategories
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}