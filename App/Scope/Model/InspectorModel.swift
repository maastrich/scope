import Foundation
import ScopeCore

/// What the viewer column beside the inspector shows: the diff of the file selected in Delta, or the base file
/// opened from Files or Search.
enum InspectorViewer: Hashable, Sendable {
    case diff, file
    /// A file a thread printed and the user clicked (`PathPreview`).
    case path
    /// Markdown to read: an agent's answer, a task's deliverable or brief (`ReadingContent`).
    case reading
    /// The task's shell pane (`TaskShellPane`): a login shell of the task, tabs for several.
    case shell
}

/// A file opened from a link in a terminal: every file the link can mean (`FileLinkResolver`), which one is shown,
/// the line to bring into view, and the content once read.
struct PathPreview: Equatable {
    var candidates: [FileLinkResolver.Candidate]
    var index = 0
    var line: Int?
    var content: BaseFileContent?
    /// Repository key (`TaskRepo.repoRelativePath`, or the repo's path in its scope) to the name shown.
    var repoNames: [String: String] = [:]

    var current: FileLinkResolver.Candidate { candidates[index] }
}

/// Layout state of the inspector column: which sections are open (per scope, through `ScopePlace`), how the lists
/// share the height, and what the viewer shows. The content of each section stays in its own model (`DeltaModel`,
/// `BaseModel`); this only says what is on screen.
struct FocusRequest: Equatable {
    let section: InspectorSection
    let token: Int
}

@MainActor
@Observable
final class InspectorModel {
    /// The open sections of the current scope; swapped when the scope changes.
    var sections = InspectorSections.defaults
    /// Relative heights of the open lists, as left by the last drag. Global: a habit of the eye, not of a scope.
    var weights: [InspectorSection: Double] = [:]
    /// The viewer column's share of the width the sidebar and the inspector leave, the terminal taking the rest. A share
    /// rather than points, so half stays half when the window or the other columns change; dragged, remembered.
    var viewerShare: Double = ColumnLayout.defaultViewerShare
    /// The background task whose output the Background card shows (`BackgroundCard`), by id; one at a time.
    var backgroundOutput: String?
    /// What the viewer shows, `nil` when closed. Only a gesture opens it — a click on a file, `j` / `k`, a search
    /// jump — so a task comes up with its list, not with a diff nobody asked for.
    var viewer: InspectorViewer?
    /// The file a terminal link opened, for the `.path` viewer.
    var pathPreview: PathPreview?
    /// What the `.reading` viewer shows.
    var reading: ReadingContent?
    /// What the viewer showed before, for its back button.
    private(set) var previousViewer: InspectorViewer?
    /// A section that should take the keyboard (⌘D, opening Search), with a counter so asking twice asks again.
    private(set) var focusRequest: FocusRequest?
    /// The list heights when a sash drag started; the drag is measured from there, not accumulated.
    @ObservationIgnored private var focusToken = 0
    @ObservationIgnored var dragStart: [InspectorSection: Double]?

    nonisolated static let defaultViewerShare = ColumnLayout.defaultViewerShare

    func show(_ viewer: InspectorViewer) {
        if self.viewer != viewer { previousViewer = self.viewer }
        self.viewer = viewer
    }

    func closeViewer() {
        previousViewer = nil
        viewer = nil
    }

    func goBack() {
        guard let previous = previousViewer else { return }
        previousViewer = viewer
        viewer = previous
    }

    func requestFocus(_ section: InspectorSection) {
        focusToken += 1
        focusRequest = FocusRequest(section: section, token: focusToken)
    }

    /// Whether `section` was asked to take the keyboard, clearing the request: a section that appears later — the
    /// inspector shown again, the scope switched back — must not take the keyboard from the terminal.
    func takeFocus(for section: InspectorSection) -> Bool {
        guard focusRequest?.section == section else { return false }
        focusRequest = nil
        return true
    }
}
