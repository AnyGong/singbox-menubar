import Foundation

/// Periodically downloads `Preferences.remoteConfigURL` and, if it passes
/// `sing-box check`, replaces the active profile file on disk with it.
///
/// Deliberately does *not* decide what happens next (reload vs. just notify) —
/// that's `ConfigFileWatcher` + `Preferences.autoReloadOnConfigChange`'s job, and
/// it already runs for any change to the active profile file regardless of source.
/// A successful write here is indistinguishable to that watcher from someone
/// hand-editing the file, so the existing "auto-reload or notify" behavior applies
/// for free — this type's whole job is fetch, validate, and (on success only) write.
final class RemoteConfigUpdater {

    static let shared = RemoteConfigUpdater()

    private var timer: Timer?

    /// Invoked on the main thread after every check, scheduled or manual, with the
    /// outcome — set by AppDelegate to surface a notification on success or an
    /// alert on failure. On failure, the existing config file is always left
    /// completely untouched; nothing partial is ever written.
    var onResult: ((Result<Void, Error>) -> Void)?

    /// (Re)starts the schedule from scratch based on current preferences. Safe to
    /// call anytime — at launch, and again whenever the URL or interval changes.
    /// No-op (timer left off) unless both a URL and a non-"Off" interval are set.
    func reschedule() {
        timer?.invalidate()
        timer = nil

        guard let urlString = Preferences.remoteConfigURL, !urlString.isEmpty,
              let interval = Preferences.remoteConfigInterval.timeInterval else {
            return
        }

        AppLog.log("Remote config auto-update scheduled every \(Preferences.remoteConfigInterval.rawValue.lowercased())")
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkNow()
        }
    }

    /// Unconditionally tears down the schedule, regardless of preferences — unlike
    /// `reschedule()`, which would just re-arm it. Call on app termination.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Downloads, validates, and — only if both succeed — writes the remote config
    /// over the active profile file. Reports the outcome via `onResult`. Safe to
    /// call whether or not a schedule is active (used directly by "Update Now").
    func checkNow() {
        guard let urlString = Preferences.remoteConfigURL, !urlString.isEmpty, let url = URL(string: urlString) else {
            onResult?(.failure(RemoteConfigError.notConfigured("No remote config URL is set. Set one first via \"Set Remote Config URL…\".")))
            return
        }
        guard let activePath = Preferences.activeProfilePath else {
            onResult?(.failure(RemoteConfigError.notConfigured("Choose a profile under Switch Profile first — remote updates replace the active profile's file.")))
            return
        }

        AppLog.log("Checking remote config at \(url.absoluteString)")
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleDownload(data: data, response: response, error: error, activePath: activePath)
            }
        }.resume()
    }

    private func handleDownload(data: Data?, response: URLResponse?, error: Error?, activePath: String) {
        if let error {
            AppLog.error("Remote config download failed: \(error.localizedDescription)")
            onResult?(.failure(error))
            return
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLog.error("Remote config download failed with status \(status)")
            onResult?(.failure(RemoteConfigError.badStatus(status)))
            return
        }
        guard let data, !data.isEmpty else {
            AppLog.error("Remote config download returned an empty response")
            onResult?(.failure(RemoteConfigError.emptyResponse))
            return
        }

        // Validate against a temp copy before touching the real config — a failed
        // `sing-box check` here must leave the existing, presumably-working config
        // completely untouched.
        let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("singbox-remote-config-\(UUID().uuidString)")
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            AppLog.error("Could not write downloaded config to a temp file for validation: \(error.localizedDescription)")
            onResult?(.failure(error))
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let (ok, output) = SingBoxProcessManager.shared.validateConfig(at: tempURL.path)
        guard ok else {
            AppLog.error("Downloaded remote config failed validation; leaving existing config unchanged:\n\(output)")
            onResult?(.failure(RemoteConfigError.invalidConfig(output)))
            return
        }

        do {
            try data.write(to: URL(fileURLWithPath: activePath), options: .atomic)
        } catch {
            AppLog.error("Downloaded and validated remote config, but failed to write it to '\(activePath)': \(error.localizedDescription)")
            onResult?(.failure(error))
            return
        }

        AppLog.log("Remote config downloaded, validated, and applied to \((activePath as NSString).lastPathComponent)")
        onResult?(.success(()))
    }
}

enum RemoteConfigError: LocalizedError {
    case notConfigured(String)
    case badStatus(Int)
    case emptyResponse
    case invalidConfig(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message):
            return message
        case .badStatus(let code):
            return "Download failed with HTTP status \(code)."
        case .emptyResponse:
            return "Downloaded file was empty."
        case .invalidConfig(let output):
            return "Downloaded config failed validation:\n\(output)"
        }
    }
}