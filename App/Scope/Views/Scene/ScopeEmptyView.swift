import SwiftUI
import ScopeDrivers

/// Scope selected, no thread yet: "No thread in *acme*", one button per installed driver — the preferred one
/// first and prominent (`AppModel.preferredProfile`), the others plain beside it. Naming them is the point:
/// the driver you want should be one click, not one click inside a menu.
struct ScopeEmptyView: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState

    /// Every driver but the preferred one, in the order the registry lists them.
    private var others: [DriverProfile] {
        model.drivers.profiles.filter { $0.id != model.preferredProfile?.id }
    }

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
                if let preferred = model.preferredProfile {
                    Button {
                        Task { await model.newThreadInCurrentContext(driverID: preferred.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Label(preferred.name, systemImage: preferred.icon ?? "terminal")
                            Text("⌘T")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .disabled(scope.kind == .missing)
                    .help("Open a \(preferred.name) thread here (⌘T)")
                }
                ForEach(others) { profile in
                    Button {
                        Task { await model.newThreadInCurrentContext(driverID: profile.id) }
                    } label: {
                        Label(profile.name, systemImage: profile.icon ?? "terminal")
                            .font(.system(size: 12))
                            .padding(.horizontal, 2)
                    }
                    .fixedSize()
                    .disabled(scope.kind == .missing)
                    .help("Open a \(profile.name) thread here")
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
