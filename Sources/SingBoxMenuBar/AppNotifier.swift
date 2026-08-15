import Foundation
import UserNotifications

/// A distinguishable class of notification this app can post, individually
/// toggleable via the "Notifications" submenu (see AppDelegate.buildMenu) so users
/// who find one category noisy can turn just that one off rather than all-or-nothing.
///
/// The raw value doubles as the `UNNotificationRequest` identifier — notifications
/// within a category replace one another instead of piling up (e.g. rapid System
/// Proxy toggling only ever shows the latest state), which was already true before
/// per-category enable/disable existed and continues to double as basic "don't spam
/// duplicates" rate limiting alongside the new opt-out controls.
enum NotificationCategory: String, CaseIterable {
    case outboundMode = "outbound-mode"
    case systemProxy = "system-proxy"
    case tunMode = "tun-mode"
    case singBoxRunState = "singbox-run-state"
    case configChange = "config-change"

    /// Shown in the "Notifications" submenu.
    var displayName: String {
        switch self {
        case .outboundMode: return "Outbound Mode Changes"
        case .systemProxy: return "System Proxy On/Off"
        case .tunMode: return "Enhanced Mode (TUN) On/Off"
        case .singBoxRunState: return "sing-box Started/Stopped"
        case .configChange: return "Configuration File Changes"
        }
    }
}

/// Thin wrapper around `UNUserNotificationCenter` for the local system notifications
/// this app posts on key state changes — outbound mode, System Proxy, Enhanced Mode
/// (TUN), sing-box start/stop/crash, and external configuration-file changes (see
/// `NotificationCategory`). Which categories are actually allowed through is
/// user-controlled — see the "Notifications" submenu and `Preferences
/// .isNotificationCategoryEnabled`.
///
/// Every call here is fire-and-forget and best-effort by design: a denied
/// authorization, a missing app bundle (e.g. running via `swift run` rather than a
/// packaged .app — see README), a disabled category, or a delivery failure should
/// never block or alter any actual app behavior. Whether a notification is actually
/// shown is left entirely up to `UNUserNotificationCenter`, which already accounts
/// for the system's own notification settings (per-app permission, Do Not
/// Disturb/Focus, etc.) — this type does not duplicate or second-guess that, only
/// adds this app's own category-level opt-out on top.
enum AppNotifier {
    private static var authorizationRequested = false
    private static var loggedMissingBundleWarning = false

    /// `UNUserNotificationCenter.current()` doesn't just fail gracefully without a
    /// proper .app bundle (an Info.plist with a real bundle identifier) — it throws
    /// an uncaught Objective-C exception ("bundleProxyForCurrentProcess is nil")
    /// that crashes the whole process outright. That's a synchronous Obj-C
    /// exception, not a Swift `Error`, so none of the try/catch or Result-based
    /// handling elsewhere in this type can intercept it — it has to be avoided
    /// entirely by never calling into UserNotifications in the first place when
    /// this is false. This is exactly the "running as a bare `swift run` binary"
    /// case the README already calls out; `Bundle.main.bundleIdentifier` is `nil`
    /// there and non-nil for a real packaged/signed .app.
    private static var isRunningAsBundledApp: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private static func warnIfNotBundled() {
        guard !isRunningAsBundledApp, !loggedMissingBundleWarning else { return }
        loggedMissingBundleWarning = true
        AppLog.log("Notifications disabled: no bundle identifier (expected under `swift run` — see README → \"Building a real .app bundle\"). Notifications will be silently skipped until run as a bundled .app.")
    }

    /// Call once, early in app launch. Safe to call more than once — only the first
    /// call actually prompts the user. No-ops (after logging once) if not running
    /// as a bundled app — see `isRunningAsBundledApp`.
    static func requestAuthorizationIfNeeded() {
        guard isRunningAsBundledApp else {
            warnIfNotBundled()
            return
        }
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLog.error("Notification authorization request failed: \(error.localizedDescription)")
            } else {
                AppLog.log("Notification authorization \(granted ? "granted" : "denied")")
            }
        }
    }

    /// Posts a local, non-blocking notification, unless `category` is disabled in
    /// Preferences (see the "Notifications" submenu) — checked first and cheaply,
    /// before touching `UNUserNotificationCenter` at all, so a muted category costs
    /// nothing beyond a dictionary lookup. Safe to call from any thread. Also
    /// no-ops (after logging once) if not running as a bundled app — see
    /// `isRunningAsBundledApp`.
    ///
    /// Notifications within the same `category` replace one another in Notification
    /// Center instead of piling up (identifier = `category.rawValue`) — a burst of
    /// the same kind of change (rapid toggling, a flapping connection) always just
    /// shows the latest state rather than a growing stack.
    static func post(category: NotificationCategory, title: String, body: String) {
        guard Preferences.isNotificationCategoryEnabled(category) else { return }
        guard isRunningAsBundledApp else {
            warnIfNotBundled()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // No sound: several of these fire routinely during normal use (profile
            // switches restart sing-box, external syncs pick up outside changes), so
            // a silent banner keeps this from getting noisy without hiding it from
            // Notification Center.
            content.sound = nil
            // nil trigger = deliver immediately.
            let request = UNNotificationRequest(identifier: category.rawValue, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    AppLog.error("Failed to post notification '\(title)': \(error.localizedDescription)")
                }
            }
        }
    }
}