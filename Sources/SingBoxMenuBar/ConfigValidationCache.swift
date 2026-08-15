import Foundation

/// Caches `sing-box check` results keyed by (file path, content hash), so a config
/// file that hasn't changed since it was last actually checked doesn't pay for a
/// fresh `sing-box check` on every start/reload/profile-switch — see
/// `SingBoxProcessManager.validateConfig`, the single place this is consulted and
/// updated, and `AppDelegate.handleExternalConfigChange`/`applicationDidFinishLaunching`,
/// which proactively warm it in the background so a later manual start/reload can
/// hit it instead of blocking on a real check.
///
/// Keyed by content hash rather than mtime: mtime can change without content
/// changing (a touch, a metadata-only rewrite from some editors) and vice versa on
/// some filesystems/sync tools, where content hashing is unambiguous — "did the
/// bytes sing-box would actually read change" is exactly the question that
/// determines whether a cached check result still applies.
///
/// Not persisted across app launches — the cache lives only for this run. A cold
/// cache after a relaunch just means the first check runs for real, same as
/// before this feature existed; that's a fine trade for not having to reason
/// about a stale on-disk cache surviving in unexpected ways.
final class ConfigValidationCache {
    static let shared = ConfigValidationCache()

    private struct Entry {
        let contentHash: Int
        let result: (ok: Bool, output: String)
    }

    private var entriesByPath: [String: Entry] = [:]
    private let lock = NSLock() // guards entriesByPath — validateConfig can be called from any queue

    /// Returns the cached result for `path` if its content hasn't changed since
    /// the cached entry was stored, else `nil` (meaning: caller should actually run
    /// `sing-box check` and call `store` with the result).
    func cachedResult(for path: String) -> (ok: Bool, output: String)? {
        guard let hash = Self.contentHash(of: path) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entriesByPath[path], entry.contentHash == hash else { return nil }
        return entry.result
    }

    /// Stores `result` for `path`, keyed by its content hash *as of right now* —
    /// call this immediately after a real `sing-box check` run on `path`, so a
    /// later call for the same still-unchanged file can skip re-checking.
    func store(result: (ok: Bool, output: String), for path: String) {
        guard let hash = Self.contentHash(of: path) else { return }
        lock.lock()
        entriesByPath[path] = Entry(contentHash: hash, result: result)
        lock.unlock()
    }

    /// Cheap, deterministic-within-this-process content fingerprint. `Hasher`'s
    /// per-launch random seed is fine here — this cache never outlives the process
    /// that populated it, so cross-launch stability isn't needed, only "did this
    /// exact file change since I last hashed it in this run."
    private static func contentHash(of path: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var hasher = Hasher()
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }
}
