import SwiftUI

/// The scope-wide views as a sheet over the window: a title row with Close (Esc), then the panel itself — the
/// open pull requests of a repo, or the repository cards of the graph. Both used to be inspector tabs, where they
/// sat next to panels about the selected task and followed a different subject; the sidebar, which is about
/// the whole scope, is where they are opened from now.
struct GlobalSheetView: View {
    @Environment(AppModel.self) private var model
    let sheet: GlobalSheet

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let scope = model.currentScope {
                    Text(scope.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Button("Close") { model.globalSheet = nil }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 16))
            .background(Color("PanelBackground"))
            Divider()
            Group {
                switch sheet {
                case .pullRequests: PullRequestsView()
                case .graph: GraphView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width, height: 620)
    }

    private var title: String {
        switch sheet {
        case .pullRequests: "Pull Requests"
        case .graph: "Graph"
        }
    }

    private var width: CGFloat {
        switch sheet {
        case .pullRequests: 780
        case .graph: 900
        }
    }
}
