import SwiftUI

/// Scope selected, no thread yet: "No thread in *acme*" + "Open a shell here (⌘T)" + a driver picker.
struct ScopeEmptyView: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState

    /// The selected repo's base checkout when a repo row is selected, else the scope root.
    private var threadCwd: URL {
        if case .repoBase(let scope, let relativePath) = model.newThreadTarget, let repo = scope.repo(relativePath: relativePath) {
            return repo.url
        }
        return scope.url
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.tertiary)
            (Text("No thread in ") + Text(scope.name).italic())
                .font(.system(size: 20, weight: .semibold))
            if scope.kind == .missing {
                Text("The folder \(scope.url.path) is missing. Threads open once it is back.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            } else {
                Text("Threads run in \(threadCwd.path) with SCOPE_SCOPE, SCOPE_THREAD and the login-shell environment injected.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await model.newThreadInCurrentContext() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Open a shell here")
                        Text("⌘T")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(scope.kind == .missing)

                Menu("Other driver…") {
                    ForEach(model.drivers.profiles) { profile in
                        Button(profile.name) {
                            Task { await model.newThreadInCurrentContext(driverID: profile.id) }
                        }
                    }
                }
                .fixedSize()
                .disabled(scope.kind == .missing || model.drivers.profiles.isEmpty)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
