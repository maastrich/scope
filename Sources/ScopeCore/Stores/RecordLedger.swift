import CryptoKit
import Foundation

/// The SHA-256 of a document's bytes: what a store remembers of every file it wrote or read, so that a file-system
/// event can be told apart from an edit made outside the app.
///
/// This is the whole anti-loop strategy of the external reload (spec §3): the app never asks *who* wrote a file,
/// it asks *whether the bytes differ from the last ones it wrote or read*. Its own atomic write produces an event
/// whose bytes it knows — ignored. An outside edit produces bytes it does not know — reloaded, and the new bytes
/// become the known ones, so the reload itself never writes anything back and nothing re-triggers.
public struct ContentFingerprint: Hashable, Sendable {
    private let bytes: [UInt8]

    public init(_ data: Data) {
        bytes = Array(SHA256.hash(data: data))
    }
}

/// What a scan of a store's folder found changed since the ledger last looked: files whose bytes are new to the
/// app, and files the app knew that are gone. `unreadable` lists files that exist but could not be read (a
/// permission, a write in progress): they stay as they were and the next event looks again.
public struct ExternalChanges<ID: Hashable & Sendable>: Sendable {
    public var changed: [(id: ID, data: Data)] = []
    public var removed: [ID] = []
    public var unreadable: [ID] = []

    public init() {}

    public var isEmpty: Bool { changed.isEmpty && removed.isEmpty }
}

/// The fingerprints of every document of one store, keyed by record id.
///
/// The store notes what it writes (`noteWritten`), what it loads (`noteLoaded`, the same thing) and what it
/// deletes (`noteRemoved`); `diff` then compares a listing of the folder against that memory. A document that
/// fails to decode after `diff` reported it must *not* be noted: its fingerprint stays the old one, so the next
/// valid write is seen as a change again (a half-written file, an editor's temp state).
public struct RecordLedger<ID: Hashable & Sendable>: Sendable {
    private var known: [ID: ContentFingerprint] = [:]

    public init() {}

    /// The ids the ledger knows.
    public var ids: Set<ID> { Set(known.keys) }

    /// Bytes the app just wrote to, or read from, the file of `id`.
    public mutating func noteWritten(_ id: ID, _ data: Data) {
        known[id] = ContentFingerprint(data)
    }

    /// Same as `noteWritten`: reading a file makes its bytes the app's own.
    public mutating func noteLoaded(_ id: ID, _ data: Data) {
        noteWritten(id, data)
    }

    /// The app removed the file of `id` (or learned it was removed).
    public mutating func noteRemoved(_ id: ID) {
        known[id] = nil
    }

    /// `true` when `data` is exactly what the app last wrote or read for `id`.
    public func isKnown(_ id: ID, _ data: Data) -> Bool {
        known[id] == ContentFingerprint(data)
    }

    /// Compares the folder, as `files` lists it (`data` nil when the file could not be read), with the ledger.
    /// Pure: the caller notes what it accepts.
    public func diff(files: [(id: ID, data: Data?)]) -> ExternalChanges<ID> {
        var changes = ExternalChanges<ID>()
        var present: Set<ID> = []
        for file in files {
            present.insert(file.id)
            guard let data = file.data else {
                changes.unreadable.append(file.id)
                continue
            }
            if !isKnown(file.id, data) { changes.changed.append((file.id, data)) }
        }
        changes.removed = known.keys.filter { !present.contains($0) }
        return changes
    }
}

/// What one store's external reload produced: the records to take as they are on disk, the ids whose file went,
/// and the files that could not be used (left alone, reported once).
public struct ExternalReload<Record: Sendable, ID: Hashable & Sendable>: Sendable {
    public var changed: [Record] = []
    public var removed: [ID] = []
    /// `<file name>: <why>` for each file skipped — a decoding error, a newer schema. Not an error of the app: the
    /// file is left untouched and read again at its next change.
    public var skipped: [String] = []

    public init() {}

    public var isEmpty: Bool { changed.isEmpty && removed.isEmpty }
}
