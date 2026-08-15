import ServiceManagement

/// Wraps SMAppService for the "Launch at Login" menu toggle. Requires the app to be
/// a proper .app bundle (see README) — SMAppService.mainApp does not work from a bare
/// SwiftPM executable run outside a bundle.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            AppLog.log("Launch at login set to \(enabled)")
        } catch {
            AppLog.error("Failed to set launch at login: \(error.localizedDescription)")
        }
    }
}
