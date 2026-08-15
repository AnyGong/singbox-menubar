import Foundation

/// Runs a command as root, preferring silent `sudo -n` (works once you've done the
/// one-time NOPASSWD sudoers setup — see README) and falling back to an interactive
/// AppleScript admin-password prompt when that isn't configured yet.
///
/// This is what removes the "authorize every single toggle" friction: after the
/// one-time setup, `sudo -n` succeeds immediately with no dialog at all.
enum PrivilegedCommandRunner {

    enum RunError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Admin authorization was cancelled."
            case .failed(let message): return message
            }
        }
    }

    /// Runs `command args...` as root. Call from a background queue — this blocks.
    static func runSync(_ command: String, _ args: [String]) -> Result<String, RunError> {
        if let result = trySudoNonInteractive(command, args) {
            return result
        }
        return runViaAppleScriptPrompt(command, args)
    }

    /// Cheap synchronous check: does passwordless sudo already work for this exact
    /// command? Used as a preflight before starting a long-lived privileged process
    /// (sing-box), where falling back to a blocking AppleScript prompt isn't practical.
    static func hasPasswordlessAccess(_ command: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", command] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Internals

    /// Returns nil (meaning "caller should fall back to an interactive prompt") when
    /// sudo can't proceed without a password. Returns an actual Result when sudo did
    /// run (successfully or not, for reasons unrelated to needing a password).
    private static func trySudoNonInteractive(_ command: String, _ args: [String]) -> Result<String, RunError>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", command] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return .failure(.failed("Could not launch sudo: \(error.localizedDescription)"))
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus == 0 {
            return .success(output)
        }
        let lower = output.lowercased()
        if lower.contains("password is required") || lower.contains("a terminal is required") {
            return nil // not configured yet — let caller fall back
        }
        return .failure(.failed(output.isEmpty ? "sudo failed (status \(process.terminationStatus))" : output))
    }

    private static func runViaAppleScriptPrompt(_ command: String, _ args: [String]) -> Result<String, RunError> {
        let quotedArgs = args
            .map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
        let script = "do shell script \"\(command) \(quotedArgs)\" with administrator privileges"

        guard let appleScript = NSAppleScript(source: script) else {
            return .failure(.failed("Could not prepare the privileged command."))
        }
        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)
        if let errorDict {
            let code = (errorDict[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (errorDict[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            return code == -128 ? .failure(.cancelled) : .failure(.failed(message))
        }
        return .success(result.stringValue ?? "")
    }
}
