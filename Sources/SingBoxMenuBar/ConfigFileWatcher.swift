import Foundation

/// Watches a single file — in practice, the active profile — for changes made
/// outside this app (hand-editing, a sync tool, a config generator, etc.) and
/// reports them via `onChange`. Backed by a kqueue `DispatchSourceFileSystemObject`
/// rather than polling, so detection is near-instant and cheap to leave running for
/// the app's whole lifetime.
final class ConfigFileWatcher {

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var watchedPath: String?

    /// Called on the main thread when the watched file is written to, or replaced
    /// (many editors save by writing a temp file and renaming it over the original
    /// rather than writing in place — see `reopen`). Debounced so a single save,
    /// which can fire several raw filesystem events in quick succession, is only
    /// reported once.
    var onChange: ((String) -> Void)?

    private var debounceWorkItem: DispatchWorkItem?
    private static let debounceInterval: TimeInterval = 0.5

    deinit { stop() }

    /// Starts (or switches to) watching `path`. No-op if already watching this
    /// exact path, so callers can call this unconditionally on every profile
    /// selection without worrying about redundant teardown/setup.
    func watch(path: String) {
        guard path != watchedPath else { return }
        stop()
        watchedPath = path
        startSource(for: path)
    }

    func stop() {
        source?.cancel()
        source = nil
        watchedPath = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        // fileDescriptor is closed by the source's cancel handler, not here — see
        // startSource. Cancellation is asynchronous, so don't close it out from
        // under a handler that may still be about to run.
    }

    private func startSource(for path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            AppLog.error("ConfigFileWatcher: could not open '\(path)' for watching (errno \(errno)) — external changes to this file won't be detected until the next profile switch or app restart.")
            return
        }
        fileDescriptor = fd

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: DispatchQueue.global(qos: .utility)
        )
        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = newSource.data
            // Atomic saves (write-to-temp-then-rename, or delete-then-create) sever
            // this descriptor's connection to the path on disk. Re-open on the same
            // path so watching survives that, instead of silently going dead after
            // the very first external edit.
            if flags.contains(.delete) || flags.contains(.rename) {
                self.reopen()
            }
            self.debounceAndReport()
        }
        newSource.setCancelHandler { [weak self] in
            guard let self else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }
        source = newSource
        newSource.resume()
    }

    /// Re-establishes the watch on `watchedPath` after the underlying inode changed
    /// out from under us (see `startSource`'s event handler). Runs after a brief
    /// delay so a fast editor save (write temp file, then rename) has time to finish
    /// before we try to reopen — reopening mid-rename can otherwise race and miss.
    private func reopen() {
        guard let path = watchedPath else { return }
        source?.cancel()
        source = nil
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.watchedPath == path else { return }
            self.startSource(for: path)
        }
    }

    private func debounceAndReport() {
        debounceWorkItem?.cancel()
        let path = watchedPath
        let work = DispatchWorkItem { [weak self] in
            guard let self, let path, self.watchedPath == path else { return }
            DispatchQueue.main.async {
                self.onChange?(path)
            }
        }
        debounceWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }
}
