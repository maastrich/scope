import Foundation
import ScopeCore

/// Owner of `<home>/graph/<scope-slug>.json`. Same rules as the other stores: atomic writes; a file
/// with a newer schema version is reported, skipped and never overwritten; a corrupt file is
/// quarantined (`<slug>.corrupt-<timestamp>.json`) and reported.
public actor GraphStore {
    /// `<home>/graph/`
    public nonisolated let directory: URL
    private var refused: Set<String> = []

    public init(home: URL) {
        directory = ScopeHome.graphURL(home: home)
    }

    /// `<home>/graph/<slug>.json`
    public nonisolated func url(for slug: String) -> URL {
        directory.appending(path: "\(slug).json", directoryHint: .notDirectory)
    }

    /// The graph of `slug`, `nil` when there is none yet or the file could not be used (see `problem`).
    public func load(slug: String) -> (graph: ScopeGraph?, problem: StoreProblem?) {
        let file = url(for: slug)
        guard FileManager.default.fileExists(atPath: file.path) else { return (nil, nil) }
        do {
            let data = try Data(contentsOf: file)
            let version = try JSONStore.makeDecoder().decode(VersionProbe.self, from: data).version ?? 1
            if version > ScopeGraph.currentVersion {
                refused.insert(slug)
                return (nil, StoreProblem(
                    file: file,
                    message: "schema version \(version) is newer than this build (\(ScopeGraph.currentVersion)); not loaded"
                ))
            }
            let graph = try JSONStore.makeDecoder().decode(ScopeGraph.self, from: data)
            return (graph, nil)
        } catch {
            let backup = try? JSONStore.quarantine(file)
            Log.scopes.error("graph \(file.lastPathComponent) is corrupt: \(String(describing: error))")
            return (nil, StoreProblem(
                file: file,
                message: backup.map { "corrupt JSON (moved to \($0.lastPathComponent))" } ?? "corrupt JSON",
                backup: backup
            ))
        }
    }

    /// The graph of `slug`, or an empty one.
    public func loadOrEmpty(slug: String) -> ScopeGraph {
        load(slug: slug).graph ?? ScopeGraph(scopeSlug: slug)
    }

    /// Immediate atomic write. Silently dropped for a slug whose file has a newer schema version.
    public func save(_ graph: ScopeGraph) throws {
        guard !refused.contains(graph.scopeSlug) else {
            Log.scopes.error("graph \(graph.scopeSlug) not saved: the file on disk has a newer schema version")
            return
        }
        try JSONStore.save(graph, to: url(for: graph.scopeSlug))
    }

    /// Load → mutate → save, in one actor hop. Returns the saved graph.
    @discardableResult
    public func update(slug: String, _ body: (inout ScopeGraph) throws -> Void) throws -> ScopeGraph {
        var graph = loadOrEmpty(slug: slug)
        try body(&graph)
        try save(graph)
        return graph
    }

    /// Stores a user-edited card (`edited = true`), so generation never overwrites it.
    @discardableResult
    public func saveManual(_ card: RepoCard, for key: String, slug: String) throws -> ScopeGraph {
        try update(slug: slug) { $0.setManual(card, for: key) }
    }

    /// Removes `<slug>.json`. A missing file is not an error.
    public func delete(slug: String) throws {
        let file = url(for: slug)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    private struct VersionProbe: Decodable {
        var version: Int?
    }
}
