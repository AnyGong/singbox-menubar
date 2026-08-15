import Foundation

/// Talks to sing-box's built-in Clash-API (exposed per your config, default
/// 127.0.0.1:9090). Used for live mode switching without restarting the process.
/// This replaces the custom IPC protocol from the original NE-based design.
final class ClashAPIClient {

    static let shared = ClashAPIClient()

    var baseURL = URL(string: "http://127.0.0.1:9090")!
    /// Set this if your config requires a Clash-API secret.
    var secret: String?

    /// Switches sing-box's Clash-mode (Direct/Global/Rule) live via `PATCH /configs`.
    /// This is a top-level mode switch, distinct from Clash's "select a proxy within
    /// a group" API — no selector/group needs to exist in your config for this to
    /// work. See sing-box's experimental.clash_api.default_mode setting for the
    /// config-side counterpart.
    func setMode(_ mode: OutboundMode, completion: @escaping (Result<Void, Error>) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("configs"))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["mode": mode.clashModeValue])

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                AppLog.error("Clash API setMode failed: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLog.error("Clash API setMode returned status \(status)")
                DispatchQueue.main.async { completion(.failure(ClashAPIError.badStatus(status))) }
                return
            }
            AppLog.log("Outbound mode switched live to \(mode.rawValue) via Clash API")
            DispatchQueue.main.async { completion(.success(())) }
        }.resume()
    }

    /// Quick reachability check, e.g. before assuming live-switch will work.
    func ping(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("version"))
        if let secret {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { _, response, error in
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }
}

enum ClashAPIError: LocalizedError {
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Clash API returned unexpected status \(code)"
        }
    }
}
