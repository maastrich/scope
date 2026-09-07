import Foundation
import ScopeCore

/// UI-only state that is not worth a place in `config.json`: what is selected, which scopes are
/// expanded, whether the inspector is open and on which tab.
struct UIState: Codable, Sendable, Equatable {
    var selectedItem: SidebarItem?
    var selectedThread: ThreadID?
    var expandedScopes: Set<ScopeID> = []
    var inspectorVisible = false
    var inspectorTab: InspectorTab = .graph

    static let empty = UIState()

    private enum CodingKeys: String, CodingKey {
        case selectedItem, selectedThread, expandedScopes, inspectorVisible, inspectorTab
    }

    init() {}

    // Lenient: a field the file lacks (or that no longer decodes) falls back to its default.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedItem = try? container.decodeIfPresent(SidebarItem.self, forKey: .selectedItem)
        selectedThread = try? container.decodeIfPresent(ThreadID.self, forKey: .selectedThread)
        expandedScopes = (try? container.decodeIfPresent(Set<ScopeID>.self, forKey: .expandedScopes)) ?? []
        inspectorVisible = (try? container.decodeIfPresent(Bool.self, forKey: .inspectorVisible)) ?? false
        inspectorTab = (try? container.decodeIfPresent(InspectorTab.self, forKey: .inspectorTab)) ?? .graph
    }
}

/// `~/Library/Application Support/Scope/ui-state.json`, written through `JSONStore` with a short
/// coalescing delay so a burst of selection changes costs one write.
@MainActor
final class UIStateStore {
    let url: URL
    private var pending: UIState?
    private var timer: Task<Void, Never>?

    /// Default location under Application Support (created on the first save).
    static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "Scope/ui-state.json", directoryHint: .notDirectory)
    }

    init(url: URL = UIStateStore.defaultURL()) {
        self.url = url
    }

    /// Reads the file; a missing or corrupt file yields `.empty` (nothing here is precious).
    func load() -> UIState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        do {
            return try JSONStore.load(UIState.self, from: url)
        } catch {
            Log.app.warning("ui-state.json unreadable, starting fresh: \(String(describing: error), privacy: .public)")
            return .empty
        }
    }

    /// Schedules a write after 300 ms of silence.
    func save(_ state: UIState) {
        pending = state
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.writePending()
        }
    }

    /// Writes now (quit).
    func flush() {
        timer?.cancel()
        timer = nil
        writePending()
    }

    private func writePending() {
        guard let state = pending else { return }
        pending = nil
        do {
            try JSONStore.save(state, to: url)
        } catch {
            Log.app.error("ui-state.json write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
