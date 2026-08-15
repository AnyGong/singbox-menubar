import Foundation
import UserNotifications

/// Thin wrapper around `UNUserNotificationCenter` for the local system notifications
/// this app posts on key state changes — outbound mode, System Proxy, Enhanced Mode
/// (TUN), sing-box start/stop/crash, and external configuration-file changes.
///
/// Every call here is fire-and-forget and best-effort by design: a denied
/// authorization, a missing app bundle (e.g. running via `swift run` rather than a
/// packaged .app — see README), or a delivery failure should never block or alter
/// any actual app behavior. Whether a notification is actually shown is left
/// entirely up to `UNUserNotificationCenter`, which already accounts for the
/// system's own notification settings (per-app permission, Do Not Disturb/Focus,
/// etc.) — this type does not duplicate or second-guess that.
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

    /// Posts a local, non-blocking notification. Safe to call from any thread.
    /// No-ops (after logging once) if not running as a bundled app — see
    /// `isRunningAsBundledApp`.
    ///
    /// - Parameter identifier: Notifications sharing an identifier replace one
    ///   another instead of piling up in Notification Center — used per-category
    ///   (e.g. "outbound-mode", "system-proxy") so a burst of the same kind of
    ///   change (rapid toggling, a flapping connection) doesn't spam the user with
    ///   a growing stack, while still always showing the *latest* state. Pass a
    ///   unique value (the default) for one-off notifications that should stack
    ///   normally.
    static func post(title: String, body: String, identifier: String = UUID().uuidString) {
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
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    AppLog.error("Failed to post notification '\(title)': \(error.localizedDescription)")
                }
            }
        }
    }
}