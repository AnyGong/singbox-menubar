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

    /// Called on the main thread whenever run state changes (started, stopped, crashed).
    var onStateChange: ((Bool) -> Void)?

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
    func start(configPath: String, completion: @escaping (Result<Void, Error>) -> Void) {
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

        stop() // ensure clean slate before starting a new instance

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", singBoxBinaryPath, "run", "-c", configPath]

        // Redirect stdout+stderr straight to sing-box.log. Truncate on each start so
        // the file corresponds to the current run — sing-box's own log lines are
        // detailed enough on their own, we don't reprocess them.
        FileManager.default.createFile(atPath: AppLog.singBoxLogURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: AppLog.singBoxLogURL) else {
            completion(.failure(SingBoxError.logFileUnavailable))
            return
        }
        process.standardOutput = logHandle
        process.standardError = logHandle

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            DispatchQueue.main.async {
                let wasRunning = self.isRunning
                self.isRunning = false
                self.process = nil
                try? logHandle.close()

                if wasRunning {
                    if proc.terminationStatus != 0 {
                        AppLog.error("sing-box exited unexpectedly (status \(proc.terminationStatus)). See sing-box.log.")
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
            AppLog.log("sing-box started (pid \(process.processIdentifier)) with config \(configPath)")
            DispatchQueue.main.async { self.onStateChange?(true) }
            completion(.success(()))
        } catch {
            try? logHandle.close()
            AppLog.error("Failed to start sing-box: \(error.localizedDescription)")
            completion(.failure(error))
        }
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

    /// Terminates the running process, if any. Safe to call when nothing is running.
    /// Note: `process` here is the `sudo` wrapper, not sing-box itself — sudo forwards
    /// SIGTERM to its child by default, so this still shuts sing-box down cleanly. If
    /// you ever notice an orphaned sing-box process surviving Quit, check
    /// `ps aux | grep sing-box` and let me know.
    func stop() {
        guard let process, isRunning else { return }
        AppLog.log("Stopping sing-box (pid \(process.processIdentifier))")
        process.terminationHandler = nil // avoid double-firing our async handler above
        process.terminate()
        process.waitUntilExit()
        self.process = nil
        self.isRunning = false
        onStateChange?(false)
    }
}

enum SingBoxError: LocalizedError {
    case invalidConfig(String)
    case logFileUnavailable
    case privilegeNotConfigured(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig(let output):
            return "Configuration is invalid:\n\(output)"
        case .logFileUnavailable:
            return "Could not open sing-box.log for writing."
        case .privilegeNotConfigured(let message):
            return message
        }
    }
}
