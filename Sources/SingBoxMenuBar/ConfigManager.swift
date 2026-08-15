import Foundation

/// Discovers available profile files for the "Switch Profile" submenu.
enum ConfigManager {
    /// Returns .yaml/.yml/.json files in the profiles directory, sorted by name.
    static func availableProfiles() -> [URL] {
        let dir = Preferences.profilesDirectory
        let fm = FileManager.default

        // First run / fresh install: directory simply doesn't exist yet. Create it
        // and return an empty list rather than logging this as an error every launch.
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                AppLog.log("Created profiles directory at \(dir.path) (none existed yet)")
            } catch {
                AppLog.error("Could not create profiles directory at \(dir.path): \(error.localizedDescription)")
            }
            return []
        }

        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else {
            AppLog.error("Could not read profiles directory at \(dir.path)")
            return []
        }
        let allowed: Set<String> = ["yaml", "yml", "json"]
        return items
            .filter { allowed.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Picks a sensible default profile if none is set yet: prefers a file literally
    /// named config.yaml/json, else the first alphabetically.
    static func defaultProfile() -> URL? {
        let profiles = availableProfiles()
        if let preferred = profiles.first(where: { $0.lastPathComponent.hasPrefix("config.") }) {
            return preferred
        }
        return profiles.first
    }
}
