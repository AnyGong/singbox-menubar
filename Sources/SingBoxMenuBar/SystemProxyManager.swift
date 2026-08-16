import Foundation
import AppKit

/// Sets/unsets the macOS system HTTP(S) proxy via `networksetup`. Requires admin
/// rights. Uses PrivilegedCommandRunner, which tries silent passwordless sudo first
/// (see README "One-time setup: passwordless sudo") and only falls back to an
/// interactive admin-password prompt if that isn't configured yet.
enum SystemProxyManager {

    /// Host sing-box's proxy inbounds bind to — this app only ever runs configs
    /// with a loopback-bound mixed/http/socks inbound, so unlike the port (see
    /// `SingBoxPortInspector.proxyInboundPort`, parsed from the active config
    /// rather than assumed) this one constant is a safe, documented assumption.
    static let proxyHost = "127.0.0.1"
    static let networksetupPath = "/usr/sbin/networksetup"

    /// Returns all active network service names (e.g. "Wi-Fi", "Ethernet"), in the
    /// order `networksetup` reports them, excluding disabled ones (prefixed "*").
    static func activeNetworkServices() -> [String] {
        guard let output = runUnprivileged(networksetupPath, ["-listallnetworkservices"]) else {
            return []
        }
        return output
                .split(separator: "\n")
                .map(String.init)
                .dropFirst() // first line is an informational header
                .filter { !$0.hasPrefix("*") }
    }

    /// Enables the system proxy for the given service, pointed at `port` — the
    /// active config's actual proxy inbound port (see `SingBoxPortInspector`), not
    /// a hardcoded assumption.
    static func enable(service: String, port: String, completion: @escaping (Result<Void, Error>) -> Void) {
        applyAll(service: service, action: "enable", completion: completion) {
            [
                PrivilegedCommandRunner.runSync(networksetupPath, ["-setwebproxy", service, proxyHost, port]),
                PrivilegedCommandRunner.runSync(networksetupPath, ["-setsecurewebproxy", service, proxyHost, port]),
                PrivilegedCommandRunner.runSync(networksetupPath, ["-setwebproxystate", service, "on"]),
                PrivilegedCommandRunner.runSync(networksetupPath, ["-setsecurewebproxystate", service, "on"])
            ]
        }
    }

    /// Disables the system proxy for the given service.
    static func disable(service: String, completion: @escaping (Result<Void, Error>) -> Void) {
        applyAll(service: service, action: "disable", completion: completion) {
            [
                PrivilegedCommandRunner.runSync(networksetupPath, ["-setwebproxystate", service, "off"]),
                PrivilegedCommandRunner.runSync(networksetupPath, ["-setsecurewebproxystate", service, "off"])
            ]
        }
    }

    /// Verifies current state by reading it back (per requirements §5).
    static func isEnabled(service: String) -> Bool {
        guard let output = runUnprivileged(networksetupPath, ["-getwebproxy", service]) else {
            return false
        }
        return output.contains("Enabled: Yes")
    }

    /// Reads back the actual enabled/host/port `networksetup` reports for `service`
    /// right now — used by Diagnostics to confirm the system proxy isn't just
    /// marked "on" in our own preferences, but genuinely pointing at sing-box's
    /// local proxy port at the OS level. `host`/`port` are `nil` if the command
    /// failed or the expected lines weren't present in its output.
    static func currentProxySettings(service: String) -> (enabled: Bool, host: String?, port: String?) {
        guard let output = runUnprivileged(networksetupPath, ["-getwebproxy", service]) else {
            return (false, nil, nil)
        }
        var host: String?
        var port: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("Server: ") {
                host = line.dropFirst("Server: ".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Port: ") {
                port = line.dropFirst("Port: ".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return (output.contains("Enabled: Yes"), host, port)
    }

    // MARK: - Internals

    private static func applyAll(
        service: String,
        action: String,
        completion: @escaping (Result<Void, Error>) -> Void,
        commands: @escaping () -> [Result<String, PrivilegedCommandRunner.RunError>]
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let results = commands()
            if let firstFailure = results.compactMap({ result -> PrivilegedCommandRunner.RunError? in
                if case .failure(let error) = result { return error }
                return nil
            }).first {
                DispatchQueue.main.async {
                    AppLog.error("Failed to \(action) system proxy for '\(service)': \(firstFailure.localizedDescription)")
                    completion(.failure(firstFailure))
                }
                return
            }
            DispatchQueue.main.async {
                AppLog.log("System proxy \(action)d for service '\(service)'")
                completion(.success(()))
            }
        }
    }

    private static func runUnprivileged(_ launchPath: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLog.error("Failed to run \(launchPath): \(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}