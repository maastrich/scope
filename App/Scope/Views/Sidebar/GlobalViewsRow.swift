import SwiftUI

/// The two scope-wide views, as a row of equal-width buttons under the scope switcher: **Pull Requests** — with
/// the count of open ones when the list is loaded — and **Graph**. Each opens a sheet over the window. They sit
/// in the sidebar because the sidebar is the view of the whole scope; the inspector is about the selected task.
struct GlobalViewsRow: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    @State private var width: CGFloat = 0

    /// Below this width the buttons drop their titles, like the footer does.
    private static let titleThreshold: CGFloat = 230

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.showPullRequests()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.pull")
                    if width >= Self.titleThreshold {
                        Text("Pull Requests").lineLimit(1)
                    }
                    if let count = openCount {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 4)
                            .frame(height: 15)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .help("Open pull requests of the scope's repositories (⇧⌘P)")
            .accessibilityLabel(openCount.map { "Pull Requests, \($0) open" } ?? "Pull Requests")

            Button {
                model.presentGraph()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    if width >= Self.titleThreshold {
                        Text("Graph").lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .help("Repository cards of the scope (⌥⌘G)")
            .accessibilityLabel("Graph")
        }
        .font(.system(size: 12, weight: .medium))
        .controlSize(.small)
        .disabled(scope.repos.isEmpty)
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 4, trailing: 10))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The open count of the repo the sheet last listed, while that list is current. `nil` says nothing rather
    /// than a stale or a zero that would read as "none anywhere".
    private var openCount: Int? {
        guard case .loaded = model.pullRequests.status, let repo = model.pullRequestsRepo,
              model.pullRequests.repoURL == repo.url else { return nil }
        let count = model.pullRequests.pullRequests.count
        return count > 0 ? count : nil
    }
}
