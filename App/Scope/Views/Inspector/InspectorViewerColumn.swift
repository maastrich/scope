import SwiftUI
import ScopeCore

/// The diff of the file selected in Delta, or the base file opened from Files or Search, in a column of its own
/// between the scene and the inspector.
///
/// It sat under the inspector's sections first, and every diff opened pushed every section header up the panel: a
/// reading pane does not belong in a column of lists. Here it is VSCode's editor area to the inspector's sidebar — the
/// height of the window, a width of its own (dragged, remembered), next to the list it was opened from, and the
/// terminal keeps the rest of the scene. It opens on a gesture (a click on a file, `j` / `k`, a search jump) and ✕
/// closes it.
struct InspectorViewerColumn: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            switch model.shownViewer {
            case .diff:
                if let task = model.currentTask, let ref = model.delta.selectedFile, let file = model.delta.file(ref),
                   let repo = model.delta.taskRepo(ref.repo) {
                    DiffView(task: task, repo: repo, ref: ref, file: file,
                             leading: AnyView(backButton), trailing: AnyView(closeButton))
                        .modifier(DeltaKeyboard(focused: $focused))
                }
            case .file:
                BaseFileViewer(leading: AnyView(backButton), trailing: AnyView(closeButton))
            case .path:
                PathFileViewer(leading: AnyView(backButton), trailing: AnyView(closeButton))
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.ground)
        // The width is dragged on the column's edge in `RootView`; the store coalesces the writes of a drag.
        .onChange(of: model.inspector.viewerShare) { model.persistUIState() }
        .onKeyPress(.escape) {
            model.inspector.closeViewer()
            return .handled
        }
    }

    /// Back to what the viewer showed before, when that still has something to show.
    @ViewBuilder
    private var backButton: some View {
        if let previous = model.inspector.previousViewer, model.isShowable(previous) {
            Button {
                model.inspector.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
            }
            .help(previous == .diff ? "Back to the diff" : "Back to the previous file")
            .accessibilityLabel("Back")
        }
    }

    private var closeButton: some View {
        Button {
            model.inspector.closeViewer()
        } label: {
            Image(systemName: "xmark")
        }
        .help("Close (Esc)")
        .accessibilityLabel("Close the viewer")
    }
}
