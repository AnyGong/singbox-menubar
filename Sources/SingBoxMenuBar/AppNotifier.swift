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

    /// Call once, early in app launch. Safe to call more than once — only the first
    /// call actually prompts the user.
    static func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                // Most commonly happens when running as a bare `swift run` binary
                // without a proper .app bundle/identity — expected there, harmless.
                AppLog.error("Notification authorization request failed (expected if not running as a bundled .app): \(error.localizedDescription)")
            } else {
                AppLog.log("Notification authorization \(granted ? "granted" : "denied")")
            }
        }
    }

    /// Posts a local, non-blocking notification. Safe to call from any thread.
    ///
    /// - Parameter identifier: Notifications sharing an identifier replace one
    ///   another instead of piling up in Notification Center — used per-category
    ///   (e.g. "outbound-mode", "system-proxy") so a burst of the same kind of
    ///   change (rapid toggling, a flapping connection) doesn't spam the user with
    ///   a growing stack, while still always showing the *latest* state. Pass a
    ///   unique value (the default) for one-off notifications that should stack
    ///   normally.
    static func post(title: String, body: String, identifier: String = UUID().uuidString) {
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
