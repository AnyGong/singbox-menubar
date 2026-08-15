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
}

enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let outboundMode = "outboundMode"
        static let activeProfilePath = "activeProfilePath"
        static let systemProxyEnabled = "systemProxyEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let preferredNetworkService = "preferredNetworkService"
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
}
