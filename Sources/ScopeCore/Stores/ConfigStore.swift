import Foundation

/// Why `config.json` could not be used as found.
public enum ConfigStoreError: Error, Sendable, Equatable {
    /// The file was unreadable or undecodable; it was renamed to `backup` and an empty config is in use.
    case corrupt(backup: URL, underlying: String)
    /// The file was written by a newer Scope (`version` > `ScopeConfig.currentVersion`).
    /// It is left untouched and the store refuses every save until the app is updated.
    case unsupportedVersion(Int)
}

/// Owner of `<home>/config.json`: load with corrupt-file quarantine, coalesced atomic saves, flush.
///
/// Single writer for the file (spec §3 / blueprint risk 11): the app keeps one instance and calls
/// `flush()` on quit and before spawning a child that reads the config.
public actor ConfigStore {
    /// `<home>/config.json`
    public nonisolated let url: URL

    /// `true` after `load()` met a newer schema version; every `save` is then dropped and logged.
    public private(set) var isReadOnly = false

    /// Number of successful file writes (diagnostics and tests).
    public private(set) var writeCount = 0

    private let saveDelay: Duration
    private var pending: ScopeConfig?
    /// The bytes last read from or written to the file (`RecordLedger`): what `reloadIfChanged` compares against.
    private var ledger = RecordLedger<Int>()
    private let fileKey = 0
    private var timer: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(home: URL, saveDelay: Duration = .milliseconds(150)) {
        url = ScopeHome.configURL(home: home)
        self.saveDelay = saveDelay
    }

    /// Reads the document.
    ///
    /// - Missing file → `.empty` (nothing is written until the first save).
    /// - Newer `version` → `.empty` + `.unsupportedVersion`; the file is left untouched and the store
    ///   becomes read-only.
    /// - Unreadable / undecodable → renamed `config.corrupt-<timestamp>.json`, `.empty` + `.corrupt`.
    public func load() async -> (config: ScopeConfig, problem: ConfigStoreError?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (.empty, nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let version = try JSONStore.makeDecoder().decode(VersionProbe.self, from: data).version
            if version > ScopeConfig.currentVersion {
                isReadOnly = true
                Log.app.error("config.json has schema version \(version) (this build supports \(ScopeConfig.currentVersion)); refusing to touch it")
                return (.empty, .unsupportedVersion(version))
            }
            let config = try JSONStore.makeDecoder().decode(ScopeConfig.self, from: data)
            ledger.noteLoaded(fileKey, data)
            return (config, nil)
        } catch {
            let message = String(describing: error)
            let backup = quarantine()
            Log.app.error("config.json is corrupt, moved to \(backup.path): \(message)")
            return (.empty, .corrupt(backup: backup, underlying: message))
        }
    }

    /// Schedules `config` to be written after `saveDelay` of silence; only the last value is written.
    public func save(_ config: ScopeConfig) {
        guard !isReadOnly else {
            Log.app.error("config.json save dropped: the file on disk has a newer schema version")
            return
        }
        pending = config
        generation += 1
        let expected = generation
        timer?.cancel()
        timer = Task.detached { [saveDelay] in
            try? await Task.sleep(for: saveDelay)
            await self.timerFired(generation: expected)
        }
    }

    /// Writes the pending value now (quit, or before spawning children that read the config).
    public func flush() async {
        timer?.cancel()
        timer = nil
        generation += 1
        writePending()
    }

    private func timerFired(generation expected: UInt64) {
        guard expected == generation else { return }
        timer = nil
        writePending()
    }

    private func writePending() {
        guard let config = pending else { return }
        pending = nil
        do {
            let data = try JSONStore.makeEncoder().encode(config)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            // Noted before the event the write causes is looked at: that event finds bytes the store knows.
            ledger.noteWritten(fileKey, data)
            writeCount += 1
        } catch {
            Log.app.error("config.json write failed: \(String(describing: error))")
        }
    }

    /// Reads the file again after something changed it on disk; `nil` when there is nothing to take.
    ///
    /// The bytes on disk are compared with the last ones the store read or wrote (`RecordLedger`): the store's
    /// own writes come back as events too, and must not come back as reloads. A file that does not decode, or
    /// that a newer Scope wrote, is left as it is and the config in memory stays: the next valid write is read
    /// again. Never quarantines, never writes.
    ///
    /// A save still pending (`saveDelay` has not elapsed) wins over the disk: it is about to overwrite the file
    /// with what the user just changed in the app, and reading the disk now would throw that away. Outside that
    /// window the disk wins.
    public func reloadIfChanged() -> ScopeConfig? {
        guard pending == nil, !isReadOnly else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard !ledger.isKnown(fileKey, data) else { return nil }
        do {
            let version = try JSONStore.makeDecoder().decode(VersionProbe.self, from: data).version
            if version > ScopeConfig.currentVersion {
                Log.app.error("config.json changed on disk to schema version \(version); this build keeps what it has")
                return nil
            }
            let config = try JSONStore.makeDecoder().decode(ScopeConfig.self, from: data)
            ledger.noteLoaded(fileKey, data)
            Log.app.info("config.json changed on disk; reloaded")
            return config
        } catch {
            Log.app.error("config.json changed on disk but does not decode; keeping the config in memory: \(String(describing: error))")
            return nil
        }
    }

    private func quarantine() -> URL {
        do {
            return try JSONStore.quarantine(url)
        } catch {
            Log.app.error("could not quarantine config.json: \(String(describing: error))")
            return url
        }
    }

    private struct VersionProbe: Decodable {
        var version: Int
    }
}
