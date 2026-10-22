import Foundation
import ScopeControl
import ScopeCore

/// UI-only state that is not worth a place in `config.json`: what is selected, which scope the sidebar
/// shows, which scopes list their repositories, whether the inspector is open and on which tab.
/// Where the user was in one scope: what switching back to it restores.
struct ScopePlace: Codable, Sendable, Equatable {
    var selection: SidebarItem?
    /// The thread on screen; tells which thread of a selected task was being read.
    var thread: ThreadID?
    /// The open inspector sections (`InspectorModel.sections`); `nil` in a file written before sections, which
    /// then start from the defaults.
    var sections: InspectorSections?
}

struct UIState: Codable, Sendable, Equatable {
    var selectedItem: SidebarItem?
    var selectedThread: ThreadID?
    /// The scope the sidebar shows (`nil` = the first declared).
    var currentScope: ScopeID?
    /// Scopes whose Repositories section is expanded (collapsed by default).
    var reposShown: Set<ScopeID> = []
    /// Scopes whose "Loose threads" group is collapsed (expanded by default, so the set holds the exceptions).
    var looseThreadsCollapsed: Set<ScopeID> = []
    var inspectorVisible = false
    /// Relative heights of the inspector's open lists (`InspectorModel.weights`).
    var inspectorWeights: [InspectorSection: Double] = [:]
    /// The viewer column's share of the width beside the inspector (`InspectorModel.viewerShare`).
    var viewerShare: Double = ColumnLayout.defaultViewerShare
    /// Repositories pinned in the Base panel, keyed by `BaseContext.key`.
    var basePins: [String: String] = [:]
    /// Points; clamped to `ColumnLayout.sidebarWidthRange` on restore.
    var sidebarWidth: Double = UIState.defaultSidebarWidth
    /// The place left in each scope, the current one included.
    var places: [ScopeID: ScopePlace] = [:]
    /// Points; clamped to `ColumnLayout.inspectorWidthRange` on restore.
    var inspectorWidth: Double = UIState.defaultInspectorWidth
    /// Driver last opened in each scope, keyed by scope id: ⌘T reaches for it before the preference, so a
    /// scope you drive with Claude Code keeps giving you Claude Code.
    var lastDrivers: [ScopeID: String] = [:]
    /// The Graph sheet's view and folded groups in each scope.
    var graphPlaces: [ScopeID: GraphPlace] = [:]

    static let empty = UIState()
    static let defaultInspectorWidth = ColumnLayout.defaultInspectorWidth
    static let defaultSidebarWidth = ColumnLayout.defaultSidebarWidth

    private enum CodingKeys: String, CodingKey {
        case selectedItem, selectedThread, currentScope, reposShown, looseThreadsCollapsed
        case inspectorVisible, inspectorWeights, viewerShare, inspectorWidth, lastDrivers, basePins, places, sidebarWidth, graphPlaces
    }

    init() {}

    // Lenient: a field the file lacks (or that no longer decodes) falls back to its default.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedItem = try? container.decodeIfPresent(SidebarItem.self, forKey: .selectedItem)
        selectedThread = try? container.decodeIfPresent(ThreadID.self, forKey: .selectedThread)
        currentScope = try? container.decodeIfPresent(ScopeID.self, forKey: .currentScope)
        reposShown = (try? container.decodeIfPresent(Set<ScopeID>.self, forKey: .reposShown)) ?? []
        looseThreadsCollapsed = (try? container.decodeIfPresent(Set<ScopeID>.self, forKey: .looseThreadsCollapsed)) ?? []
        inspectorVisible = (try? container.decodeIfPresent(Bool.self, forKey: .inspectorVisible)) ?? false
        inspectorWeights = (try? container.decodeIfPresent([InspectorSection: Double].self, forKey: .inspectorWeights)) ?? [:]
        viewerShare = (try? container.decodeIfPresent(Double.self, forKey: .viewerShare)) ?? ColumnLayout.defaultViewerShare
        inspectorWidth = (try? container.decodeIfPresent(Double.self, forKey: .inspectorWidth)) ?? UIState.defaultInspectorWidth
        lastDrivers = (try? container.decodeIfPresent([ScopeID: String].self, forKey: .lastDrivers)) ?? [:]
        basePins = (try? container.decodeIfPresent([String: String].self, forKey: .basePins)) ?? [:]
        places = (try? container.decodeIfPresent([ScopeID: ScopePlace].self, forKey: .places)) ?? [:]
        sidebarWidth = (try? container.decodeIfPresent(Double.self, forKey: .sidebarWidth)) ?? UIState.defaultSidebarWidth
        graphPlaces = (try? container.decodeIfPresent([ScopeID: GraphPlace].self, forKey: .graphPlaces)) ?? [:]
    }
}

/// `<home>/ui-state.json`, written through `JSONStore` with a short coalescing delay so a burst of selection
/// changes costs one write.
@MainActor
final class UIStateStore {
    let url: URL
    /// Read once when `url` does not exist yet, never written.
    private let legacyURL: URL?
    private var pending: UIState?
    private var timer: Task<Void, Never>?

    /// `~/Library/Application Support/Scope/ui-state.json`: where the file lived before it moved under the
    /// home, shared by every build and every `SCOPE_HOME`.
    static func legacyURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return support.appending(path: "Scope/ui-state.json", directoryHint: .notDirectory)
    }

    /// - Parameter home: the app's home. The installed app on its default home picks up the legacy file once, so
    ///   the move costs nobody their selection; a Debug build and a custom home never look at it — it is the
    ///   installed app's state, not theirs.
    convenience init(home: URL) {
        let inherits = !BuildFlavor.isDebug && AppHome.isProductionHome(home)
        self.init(url: ScopeHome.uiStateURL(home: home), legacyURL: inherits ? UIStateStore.legacyURL() : nil)
    }

    init(url: URL, legacyURL: URL? = nil) {
        self.url = url
        self.legacyURL = legacyURL
    }

    /// Reads the file; a missing or corrupt file yields `.empty` (nothing here is precious).
    func load() -> UIState {
        let source = FileManager.default.fileExists(atPath: url.path) ? url : legacyURL
        guard let source, FileManager.default.fileExists(atPath: source.path) else { return .empty }
        do {
            return try JSONStore.load(UIState.self, from: source)
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
