import Foundation
import ScopeCore

/// What the viewer under the inspector's sections shows: the diff of the file selected in Delta, or the base file
/// opened from Files or Search.
enum InspectorViewer: Hashable, Sendable {
    case diff, file
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
    /// The share of the column the viewer takes while it is open and a list sits above it.
    var viewerShare = 0.55
    /// What the viewer shows, `nil` when closed. Only a gesture opens it — a click on a file, `j` / `k`, a search
    /// jump — so a task comes up with its list, not with a diff nobody asked for.
    var viewer: InspectorViewer?
    /// The viewer fills the column, the sections out of the way, for a diff that needs the width of every line and
    /// the height of the panel. Not saved: a look, not a layout.
    var viewerMaximized = false
    /// What the viewer showed before, for its back button.
    private(set) var previousViewer: InspectorViewer?
    /// A section that should take the keyboard (⌘D, opening Search), with a counter so asking twice asks again.
    private(set) var focusRequest: FocusRequest?
    /// The list heights when a sash drag started; the drag is measured from there, not accumulated.
    @ObservationIgnored private var focusToken = 0
    @ObservationIgnored var dragStart: [InspectorSection: Double]?
    @ObservationIgnored var viewerDragStart: Double?

    func show(_ viewer: InspectorViewer) {
        if self.viewer != viewer { previousViewer = self.viewer }
        self.viewer = viewer
    }

    func closeViewer() {
        viewerMaximized = false
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
