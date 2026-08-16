import Foundation

/// Parses the actual proxy inbound port out of a sing-box config, and inspects
/// what (if anything) is currently listening on a given TCP port. Exists so this
/// app stops assuming System Proxy's target is always port 7890 and can detect a
/// port/process conflict before starting sing-box instead of just letting it fail
/// with "address already in use" — see requirements: "Detect existing sing-box
/// process and actual configured port before starting."
enum SingBoxPortInspector {

    /// A single TCP listener found via `lsof`.
    struct Listener {
        let pid: Int32
        let command: String
    }

    /// Inbound types System Proxy (and this app in general) can actually point a
    /// browser/system HTTP(S) setting at — same set `SingBoxProcessManager` uses to
    /// decide whether System Proxy and Enhanced Mode (TUN) can coexist for a config.
    static let proxyCapableInboundTypes: Set<String> = ["mixed", "http", "socks"]

    /// The `listen_port` of the first `mixed`/`http`/`socks` inbound in `configPath`,
    /// if any — this is the port System Proxy actually needs to point at, and the
    /// one that needs to be free (or already correctly served) before sing-box can
    /// bind it. Returns `nil` — not a hardcoded fallback like the old 7890 — when
    /// the config can't be read/parsed or simply has no such inbound (e.g. a
    /// TUN-only config); callers should treat that as "no proxy port to check or
    /// use", not substitute a guess.
    static func proxyInboundPort(at configPath: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let inbounds = json["inbounds"] as? [[String: Any]] else {
            return nil
        }
        for inbound in inbounds {
            guard let type = (inbound["type"] as? String)?.lowercased(), proxyCapableInboundTypes.contains(type) else { continue }
            // sing-box's own config schema always encodes this as a JSON integer,
            // but NSNumber-vs-Int bridging through JSONSerialization can go either
            // way depending on how the value was written — check both.
            if let port = inbound["listen_port"] as? Int { return port }
            if let portNumber = inbound["listen_port"] as? NSNumber { return portNumber.intValue }
        }
        return nil
    }

    /// Whoever (if anyone) is listening on `port` right now, via `lsof`. Read-only —
    /// doesn't need root, only whatever the caller decides to do with the result
    /// might. Best-effort: an `lsof` failure or unparseable output returns `[]`
    /// ("nothing listening"), matching this app's existing fail-open posture for
    /// other process-detection helpers (see `SingBoxProcessManager.isSingBoxProcessAlive`).
    static func listeners(onPort port: Int) -> [Listener] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // -n/-P: skip hostname/service-name resolution — faster, and keeps the
        // numeric port itself in the output instead of a name lsof might swap in.
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // discard — "nothing listening" isn't an error, it's just empty stdout
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLog.error("Failed to check port \(port): \(error.localizedDescription)")
            return []
        }
        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return []
        }
        // `lsof -nP` output: one header line, then one line per listener —
        // "COMMAND   PID   USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME" — command
        // is column 0, PID is column 1.
        return output
                .split(separator: "\n")
                .dropFirst() // header
                .compactMap { line -> Listener? in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 2, let pid = Int32(columns[1]) else { return nil }
            return Listener(pid: pid, command: String(columns[0]))
        }
    }

    /// The Clash API's `external_controller` address (e.g. "127.0.0.1:9090") and
    /// optional `secret`, as declared in `configPath`'s `experimental.clash_api`
    /// block. This app previously assumed sing-box's documented default (9090, no
    /// secret) everywhere `ClashAPIClient` is used — which silently broke live mode
    /// switching, "Open Control Panel", and Diagnostics' reachability check for any
    /// profile that customizes either, since sing-box itself was listening
    /// somewhere else entirely. Returns `nil` if the config can't be read/parsed or
    /// declares no `experimental.clash_api` block at all — callers should leave
    /// whatever endpoint is already configured untouched in that case, not fall
    /// back to a guess (see `AppDelegate.syncClashAPIEndpoint`).
    static func clashAPIEndpoint(at configPath: String) -> (address: String, secret: String?)? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let experimental = json["experimental"] as? [String: Any],
              let clashAPI = experimental["clash_api"] as? [String: Any],
              let controller = clashAPI["external_controller"] as? String,
              !controller.isEmpty else {
            return nil
        }
        return (controller, clashAPI["secret"] as? String)
    }
}