import Foundation

/// Owns the sing-box child process directly. No Network Extension, no IPC — process
/// lifecycle *is* the state. See requirements doc §1, §5, §6.
final class SingBoxProcessManager {

    static let shared = SingBoxProcessManager()

    /// Adjust if `brew --prefix` differs on your machine (e.g. Intel Macs use
    /// /usr/local instead of /opt/homebrew).
    var singBoxBinaryPath = "/opt/homebrew/bin/sing-box"

    private(set) var process: Process?
    private(set) var isRunning: Bool = false

    /// Whether the *current* run has the TUN inbound active. Independent of
    /// `isRunning` — sing-box can also run in "normal mode" (HTTP inbound only, no
    /// TUN interface), e.g. when auto-started for System Proxy. See `start`.
    private(set) var isTUNEnabled: Bool = false

    /// Called on the main thread whenever run state changes (started, stopped, crashed).
    var onStateChange: ((Bool) -> Void)?

    /// Called on the main thread, immediately before `onStateChange(false)`, only
    /// when the process that just stopped exited on its own with a non-zero status
    /// (i.e. crashed or was killed) rather than being deliberately stopped by this
    /// app. Lets observers (see AppDelegate) distinguish "sing-box stopped" from
    /// "sing-box crashed" for notification purposes without needing to inspect
    /// termination status themselves.
    var onUnexpectedExit: ((Int32) -> Void)?

    // MARK: - Validation

    /// Runs `sing-box check -c <config>` synchronously and returns (isValid, output).
    /// Used before every start/reload/profile-switch per requirements §7.
    func validateConfig(at path: String) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: singBoxBinaryPath)
        process.arguments = ["check", "-c", path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            let msg = "Failed to launch sing-box for validation: \(error.localizedDescription)"
            AppLog.error(msg)
            return (false, msg)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let ok = process.terminationStatus == 0
        if !ok {
            AppLog.error("Config validation failed for \(path): \(output)")
        }
        return (ok, output)
    }

    // MARK: - Start / Stop

    /// TUN requires root to create a utun interface, so sing-box always runs under
    /// `sudo -n`. That only succeeds silently once the one-time passwordless sudoers
    /// rule is set up (README → "One-time setup: passwordless sudo"); a long-lived
    /// process is a poor fit for a blocking interactive prompt, so we preflight-check
    /// instead of falling back to one.
    private func hasPrivilegedAccess() -> Bool {
        PrivilegedCommandRunner.hasPasswordlessAccess(singBoxBinaryPath, ["version"])
    }

    /// Validates then starts sing-box with the given config. Safe to call while a
    /// previous instance is running — it will be stopped first.
    ///
    /// - Parameter enableTUN: When `true` (the default — matches the previous
    ///   behavior of this method), the config is run as-authored. When `false`, any
    ///   `tun`-type inbound is stripped from a generated copy of the config before
    ///   running it, so sing-box comes up in "normal mode" (HTTP inbound only,
    ///   never touching the TUN interface). Used by "Set as System Proxy" to
    ///   auto-start sing-box without also opting the user into Enhanced Mode.
    func start(configPath: String, enableTUN: Bool = true, completion: @escaping (Result<Void, Error>) -> Void) {
        let (ok, output) = validateConfig(at: configPath)
        guard ok else {
            completion(.failure(SingBoxError.invalidConfig(output)))
            return
        }

        guard hasPrivilegedAccess() else {
            let msg = "Passwordless sudo isn't set up for sing-box yet. See README → \"One-time setup: passwordless sudo\", then try again."
            AppLog.error(msg)
            completion(.failure(SingBoxError.privilegeNotConfigured(msg)))
            return
        }

        let runPath: String
        if enableTUN {
            runPath = configPath
        } else {
            switch Self.normalModeConfigPath(from: configPath) {
            case .success(let path):
                runPath = path
            case .failure(let error):
                completion(.failure(error))
                return
            }
        }

        let wasRunningBeforeRestart = isRunning
        stopQuietly() // ensure clean slate before starting a new instance — see stopQuietly's doc comment for why this doesn't fire onStateChange

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", singBoxBinaryPath, "run", "-c", runPath]

        // Redirect stdout+stderr straight to sing-box.log. Truncate on each start so
        // the file corresponds to the current run — sing-box's own log lines are
        // detailed enough on their own, we don't reprocess them.
        FileManager.default.createFile(atPath: AppLog.singBoxLogURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: AppLog.singBoxLogURL) else {
            completion(.failure(SingBoxError.logFileUnavailable))
            // stopQuietly() above already tore down any previous instance without
            // notifying observers (that's the point, for a normal restart) — but
            // we're not actually restarting anymore, so they still need to hear
            // about the now-genuine stop.
            if wasRunningBeforeRestart {
                DispatchQueue.main.async { self.onStateChange?(false) }
            }
            return
        }
        process.standardOutput = logHandle
        process.standardError = logHandle

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            DispatchQueue.main.async {
                let wasRunning = self.isRunning
                self.isRunning = false
                self.isTUNEnabled = false
                self.process = nil
                try? logHandle.close()

                if wasRunning {
                    if proc.terminationStatus != 0 {
                        AppLog.error("sing-box exited unexpectedly (status \(proc.terminationStatus)). See sing-box.log.")
                        self.onUnexpectedExit?(proc.terminationStatus)
                    } else {
                        AppLog.log("sing-box exited cleanly.")
                    }
                }
                self.onStateChange?(false)
            }
        }

        do {
            try process.run()
            self.process = process
            self.isRunning = true
            self.isTUNEnabled = enableTUN
            AppLog.log("sing-box started (pid \(process.processIdentifier)) with config \(runPath)\(enableTUN ? "" : " [normal mode — TUN inbound disabled]")")
            DispatchQueue.main.async { self.onStateChange?(true) }
            completion(.success(()))
        } catch {
            try? logHandle.close()
            AppLog.error("Failed to start sing-box: \(error.localizedDescription)")
            completion(.failure(error))
            if wasRunningBeforeRestart {
                DispatchQueue.main.async { self.onStateChange?(false) }
            }
        }
    }

    /// Stops the running process, if any, WITHOUT notifying `onStateChange`. Used
    /// internally by `start` to clear out a previous instance immediately before
    /// launching its replacement — that's an implementation detail of a restart, not
    /// a real stop, and firing `onStateChange(false)` here would make callers like
    /// `disableSystemProxyIfDangling` think sing-box had genuinely gone away and act
    /// accordingly (e.g. turning off System Proxy) purely because of the brief gap
    /// mid-restart, even when the new config keeps serving it just fine — see
    /// requirements: enabling TUN must not disable System Proxy when the config
    /// still has a mixed/HTTP/SOCKS inbound.
    private func stopQuietly() {
        guard let process, isRunning else { return }
        AppLog.log("Stopping sing-box (pid \(process.processIdentifier)) to restart with new config/mode")
        process.terminationHandler = nil // avoid double-firing our async handler above
        process.terminate()
        process.waitUntilExit()
        self.process = nil
        self.isRunning = false
        self.isTUNEnabled = false
    }

    // MARK: - Normal-mode (no-TUN) config generation

    /// Directory for files this app generates itself, as opposed to user-authored
    /// profiles (which live under `Preferences.profilesDirectory`).
    private static let generatedConfigDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("singbox-menubar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let normalModeConfigURL = generatedConfigDirectory.appendingPathComponent("normal-mode.generated.json")

    /// Produces a copy of `configPath` with any `tun`-type inbound removed, so
    /// System Proxy's auto-start doesn't also stand up a TUN interface the user
    /// didn't explicitly ask for via Enhanced Mode. Requires the source config to be
    /// JSON — sing-box's native config format (see `ConfigManager`'s allowance of
    /// `.yaml`/`.yml` profiles, which this can't currently strip).
    private static func normalModeConfigPath(from configPath: String) -> Result<String, Error> {
        guard let data = FileManager.default.contents(atPath: configPath) else {
            return .failure(SingBoxError.normalModeConfigGenerationFailed("Could not read \((configPath as NSString).lastPathComponent)."))
        }
        guard let originalJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(SingBoxError.normalModeConfigGenerationFailed(
                "\((configPath as NSString).lastPathComponent) isn't valid JSON, so its TUN inbound (if any) couldn't be stripped for normal mode. sing-box configs must be JSON for System Proxy's auto-start to work."
            ))
        }

        // Start from a full copy of the original config, not a hand-picked subset of
        // keys — normal mode only ever changes `inbounds`. Everything else (dns,
        // route, outbounds, and crucially `experimental.clash_api`, which is how
        // this app talks to a running sing-box for outbound-mode switching — see
        // ClashAPIClient) must survive untouched, or the app loses control of the
        // very process it just started.
        var normalModeJSON = originalJSON
        if let inbounds = originalJSON["inbounds"] as? [[String: Any]] {
            normalModeJSON["inbounds"] = inbounds.filter { ($0["type"] as? String)?.lowercased() != "tun" }
        }

        guard let stripped = try? JSONSerialization.data(withJSONObject: normalModeJSON, options: [.prettyPrinted]) else {
            return .failure(SingBoxError.normalModeConfigGenerationFailed("Failed to serialize the generated normal-mode config."))
        }

        // Sanity-check the round trip before handing this off to sing-box. If the
        // source profile declares experimental.clash_api but it didn't make it into
        // the generated file, outbound-mode switching fails later with a confusing
        // "Could not connect to the server" instead of a clear reason — catch that
        // here, at generation time, instead.
        let hadClashAPI = (originalJSON["experimental"] as? [String: Any])?["clash_api"] != nil
        if hadClashAPI {
            guard
            let reparsed = try? JSONSerialization.jsonObject(with: stripped) as? [String: Any],
            (reparsed["experimental"] as? [String: Any])?["clash_api"] != nil
            else {
                return .failure(SingBoxError.normalModeConfigGenerationFailed(
                    "experimental.clash_api didn't survive generating the normal-mode config, so outbound mode switching would silently fail. This looks like a bug in the menu bar app — check the generated file at \(normalModeConfigURL.path)."
                ))
            }
        } else {
            AppLog.log(
                "Source profile \((configPath as NSString).lastPathComponent) has no experimental.clash_api — outbound mode switching from the menu bar won't work while running from it.",
                level: "WARN"
            )
        }

        do {
            try stripped.write(to: normalModeConfigURL, options: .atomic)
            return .success(normalModeConfigURL.path)
        } catch {
            return .failure(SingBoxError.normalModeConfigGenerationFailed("Could not write generated config: \(error.localizedDescription)"))
        }
    }

    /// Whether `configPath`'s `inbounds` array has at least one entry System Proxy
    /// can actually point at — `mixed`, `http`, or `socks` — independent of whether
    /// a `tun` inbound is *also* present. This is what determines whether System
    /// Proxy and Enhanced Mode (TUN) can coexist for a given config: see
    /// `AppDelegate.toggleSystemProxy`, which blocks enabling System Proxy without
    /// one, and `AppDelegate.reconcileSystemProxyCapability`, which catches one
    /// disappearing later (e.g. after a profile switch) while System Proxy is on.
    ///
    /// Best-effort: an unreadable or non-JSON config is treated as "no such
    /// inbound" (fails closed), same as `normalModeConfigPath` above.
    static func hasProxyCapableInbound(at configPath: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let inbounds = json["inbounds"] as? [[String: Any]] else {
            return false
        }
        let proxyCapableTypes: Set<String> = ["mixed", "http", "socks"]
        return inbounds.contains { ($0["type"] as? String).map { proxyCapableTypes.contains($0.lowercased()) } ?? false }
    }

    /// Best-effort check for whether *a* sing-box process is alive on this machine,
    /// regardless of whether this app is the one that launched it. Synchronous and
    /// cheap enough to run on a timer; callers should still hop off the main thread
    /// if calling frequently.
    func isSingBoxProcessAlive() -> Bool {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-x", "sing-box"]
        check.standardOutput = Pipe() // discard; we only care about the exit status
        do {
            try check.run()
            check.waitUntilExit()
        } catch {
            AppLog.error("Failed to check sing-box process state: \(error.localizedDescription)")
            return isRunning // fall back to what we already believe
        }
        return check.terminationStatus == 0
    }

    /// Reconciles `isRunning` with the actual OS-level process state and fires
    /// `onStateChange` if it changed. Call this periodically (see AppDelegate's
    /// state-sync timer) to catch sing-box being started, stopped, or killed outside
    /// of this app — e.g. from Terminal, another launcher, or a crash we didn't own.
    func reconcileRunningState() {
        // If we hold a live process handle, our termination handler is already the
        // source of truth — skip the pgrep-based reconciliation to avoid any chance
        // of a name-matching false negative/positive fighting with it.
        guard process == nil else { return }

        let actuallyRunning = isSingBoxProcessAlive()
        guard actuallyRunning != isRunning else { return }

        AppLog.log("Detected sing-box \(actuallyRunning ? "started" : "stopped") externally; syncing state")
        isRunning = actuallyRunning
        onStateChange?(actuallyRunning)
    }

    /// Terminates the running process, if any, and notifies `onStateChange(false)` —
    /// this is a genuine, deliberate stop (Quit, "disable Enhanced Mode", etc.), as
    /// opposed to `stopQuietly`'s use inside `start` for a transient restart. Safe to
    /// call when nothing is running.
    /// Note: `process` here is the `sudo` wrapper, not sing-box itself — sudo forwards
    /// SIGTERM to its child by default, so this still shuts sing-box down cleanly. If
    /// you ever notice an orphaned sing-box process surviving Quit, check
    /// `ps aux | grep sing-box` and let me know.
    func stop() {
        guard isRunning else { return }
        stopQuietly()
        onStateChange?(false)
    }
}

enum SingBoxError: LocalizedError {
    case invalidConfig(String)
    case logFileUnavailable
    case privilegeNotConfigured(String)
    case normalModeConfigGenerationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig(let output):
            return "Configuration is invalid:\n\(output)"
        case .logFileUnavailable:
            return "Could not open sing-box.log for writing."
        case .privilegeNotConfigured(let message):
            return message
        case .normalModeConfigGenerationFailed(let message):
            return "Couldn't prepare a normal-mode (no-TUN) configuration:\n\(message)"
        }
    }
}