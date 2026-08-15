import Foundation

/// Minimal flat-file logger. No unified-logging, no rotation — just a file you can
/// `tail -f` while troubleshooting. Two files are written:
///   - app.log: everything this app itself does (state changes, errors, user actions)
///   - sing-box.log: raw stdout/stderr from the sing-box child process (see
///     SingBoxProcessManager, which writes to this file directly via Process pipes)
enum AppLog {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Logs/singbox-menubar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let appLogURL = directory.appendingPathComponent("app.log")
    static let singBoxLogURL = directory.appendingPathComponent("sing-box.log")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let queue = DispatchQueue(label: "app.log.queue")

    static func log(_ message: String, level: String = "INFO") {
        let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)\n"
        queue.async {
            append(line, to: appLogURL)
        }
        #if DEBUG
        print(line, terminator: "")
        #endif
    }

    static func error(_ message: String) {
        log(message, level: "ERROR")
    }

    private static func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            }
        } else {
            try? data.write(to: url)
        }
    }
}
