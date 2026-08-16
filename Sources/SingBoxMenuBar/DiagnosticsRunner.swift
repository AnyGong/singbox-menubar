import Foundation

/// One-shot health check across everything the menu bar controls: the sing-box
/// process itself, System Proxy, the TUN interface, the Clash API, and the current
/// outbound mode. Pure data/logic — no UI here; see AppDelegate's `runDiagnostics`/
/// `presentDiagnostics` for how results get shown.
struct DiagnosticsResult {
    struct Check {
        enum Status {
            case ok
            case warning
            case failure

            /// Presentation glyph — kept here rather than in AppDelegate since it's
            /// a fixed property of the status itself, not a display choice specific
            /// to any one presentation.
            var symbol: String {
                switch self {
                case .ok: return "✅"
                case .warning: return "⚠️"
                case .failure: return "❌"
                }
            }
        }
        let title: String
        let status: Status
        let detail: String
    }

    let checks: [Check]
    let generatedAt = Date()
}

enum DiagnosticsRunner {

    /// Runs all checks and reports the combined result on the main thread.
    ///
    /// - Parameter systemProxyService: The network service to verify System Proxy
    ///   against (whatever AppDelegate currently considers "the" service — its
    ///   `currentSystemProxyService ?? Preferences.preferredNetworkService`
    ///   fallback, same as every other System Proxy call site). Passed in rather
    ///   than looked up here so this stays a pure function of what the caller
    ///   already knows, instead of duplicating that resolution logic.
    /// - Parameter expectedProxyPort: The active profile's actual proxy inbound
    ///   port (see `SingBoxPortInspector.proxyInboundPort`), used to verify System
    ///   Proxy is pointed at the *right* port — not a hardcoded assumption, since
    ///   different configs can use different ports.
    static func run(systemProxyService: String?, expectedProxyPort: Int?, completion: @escaping (DiagnosticsResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var checks: [DiagnosticsResult.Check] = []
            checks.append(singBoxProcessCheck())
            checks.append(systemProxyCheck(service: systemProxyService, expectedPort: expectedProxyPort))
            checks.append(tunInterfaceCheck())
            checks.append(outboundModeCheck())

            // Clash API reachability needs a network round trip — do it last and
            // hop back to main once everything (sync + async) is assembled.
            clashAPICheck { clashCheck in
                checks.append(clashCheck)
                DispatchQueue.main.async {
                    completion(DiagnosticsResult(checks: checks))
                }
            }
        }
    }

    // MARK: - Individual checks

    private static func singBoxProcessCheck() -> DiagnosticsResult.Check {
        let manager = SingBoxProcessManager.shared
        guard manager.isSingBoxProcessAlive() else {
            return DiagnosticsResult.Check(
                title: "sing-box Process",
                status: .failure,
                detail: "Not running. Start it via Switch Profile, Enhanced Mode (TUN), or Set as System Proxy."
            )
        }
        let ownership = manager.isRunning ? "started by this app" : "running, but not started by this app"
        return DiagnosticsResult.Check(title: "sing-box Process", status: .ok, detail: "Running (\(ownership)).")
    }

    private static func systemProxyCheck(service: String?, expectedPort: Int?) -> DiagnosticsResult.Check {
        guard Preferences.systemProxyEnabled else {
            return DiagnosticsResult.Check(title: "System Proxy", status: .ok, detail: "Off.")
        }
        guard let service else {
            return DiagnosticsResult.Check(
                title: "System Proxy",
                status: .warning,
                detail: "Marked on, but no network service is currently tracked to verify against. Try toggling it off and back on."
            )
        }

        let settings = SystemProxyManager.currentProxySettings(service: service)
        guard settings.enabled else {
            return DiagnosticsResult.Check(
                title: "System Proxy",
                status: .failure,
                detail: "Marked on in the app, but '\(service)' reports it disabled at the OS level."
            )
        }

        guard let expectedPort else {
            return DiagnosticsResult.Check(
                title: "System Proxy",
                status: .warning,
                detail: "Enabled for '\(service)' (pointing at \(settings.host ?? "?"):\(settings.port ?? "?")), but the active profile no longer has a mixed/http/socks inbound to verify the port against."
            )
        }

        let expectedHost = SystemProxyManager.proxyHost
        let expectedPortString = String(expectedPort)
        if settings.host == expectedHost, settings.port == expectedPortString {
            return DiagnosticsResult.Check(
                title: "System Proxy",
                status: .ok,
                detail: "Enabled for '\(service)', pointing at \(expectedHost):\(expectedPortString) as expected."
            )
        } else {
            let actual = "\(settings.host ?? "?"):\(settings.port ?? "?")"
            return DiagnosticsResult.Check(
                title: "System Proxy",
                status: .warning,
                detail: "Enabled for '\(service)', but pointing at \(actual) — expected \(expectedHost):\(expectedPortString). Toggle System Proxy off and back on to fix this."
            )
        }
    }

    private static func tunInterfaceCheck() -> DiagnosticsResult.Check {
        let expectedByApp = SingBoxProcessManager.shared.isTUNEnabled
        let activeInterfaces = activeUTUNInterfaces()

        if !expectedByApp {
            if activeInterfaces.isEmpty {
                return DiagnosticsResult.Check(title: "TUN Interface", status: .ok, detail: "Not enabled (Enhanced Mode is off).")
            }
            return DiagnosticsResult.Check(
                title: "TUN Interface",
                status: .warning,
                detail: "Enhanced Mode is off in this app, but an active TUN interface was found (\(activeInterfaces.joined(separator: ", "))) — likely belongs to another VPN/tool."
            )
        }

        guard !activeInterfaces.isEmpty else {
            return DiagnosticsResult.Check(
                title: "TUN Interface",
                status: .failure,
                detail: "Enhanced Mode is on, but no active TUN interface with an assigned address was found."
            )
        }
        return DiagnosticsResult.Check(title: "TUN Interface", status: .ok, detail: "Active: \(activeInterfaces.joined(separator: ", ")).")
    }

    private static func outboundModeCheck() -> DiagnosticsResult.Check {
        DiagnosticsResult.Check(title: "Outbound Mode", status: .ok, detail: Preferences.outboundMode.rawValue)
    }

    /// Deliberately doesn't reuse `ClashAPIClient.ping` — this needs a short,
    /// diagnostics-appropriate timeout so a dead endpoint reports back in a couple
    /// of seconds instead of `ping`'s default ~60s URLSession timeout, which would
    /// make "quick health check" not very quick.
    private static func clashAPICheck(completion: @escaping (DiagnosticsResult.Check) -> Void) {
        let baseURL = ClashAPIClient.shared.baseURL
        var request = URLRequest(url: baseURL.appendingPathComponent("version"))
        request.timeoutInterval = 2.5
        if let secret = ClashAPIClient.shared.secret {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { _, response, error in
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            let detail = ok
                    ? "Reachable at \(baseURL.absoluteString)."
                    : "Not reachable at \(baseURL.absoluteString). sing-box may not be running, or the active config may be missing experimental.clash_api."
            completion(DiagnosticsResult.Check(title: "Clash API", status: ok ? .ok : .failure, detail: detail))
        }.resume()
    }

    // MARK: - TUN interface detection

    /// Best-effort: shells out to `ifconfig`, and considers a `utunN` interface
    /// "active" if it has at least one `inet` (IPv4) address assigned — this can't
    /// distinguish sing-box's own TUN interface from some other VPN's, which is why
    /// callers treat this as informational/heuristic (see `tunInterfaceCheck`'s
    /// "likely belongs to another VPN/tool" wording) rather than definitive.
    private static func activeUTUNInterfaces() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLog.error("Diagnostics: failed to run ifconfig: \(error.localizedDescription)")
            return []
        }

        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return []
        }

        // ifconfig groups output in blocks starting with an unindented "name: flags=…"
        // line; everything indented under it (including "inet …" lines) belongs to
        // that interface. Track the current block and flush it when the next one starts.
        var results: [String] = []
        var currentName: String?
        var currentHasInet = false

        func flush() {
            if let name = currentName, currentHasInet, name.hasPrefix("utun") {
                results.append(name)
            }
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") && line.contains(":") {
                flush()
                currentName = line.split(separator: ":").first.map(String.init)
                currentHasInet = false
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("inet ") {
                currentHasInet = true
            }
        }
        flush()

        return results
    }
}