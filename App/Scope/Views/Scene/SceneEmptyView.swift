import SwiftUI

/// First-launch scene (UI direction A §7): a dashed drop zone inviting the user to declare a scope.
struct SceneEmptyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FolderDropZone { urls in
            Task { await model.addScopes(urls) }
        } content: { isTargeted in
            VStack(spacing: 14) {
                Image(systemName: "folder")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text("Drop a folder to declare a scope")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.2)
                Text("A scope is any folder: a cloned GitHub org, a folder of projects, or a single repo. Scope reads it and writes nothing inside.")
                    .font(.system(size: 13))
                    .lineSpacing(6)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button {
                    Task {
                        let urls = await FolderPicker.chooseFolders()
                        await model.addScopes(urls)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Choose Folder…")
                        Text("⌘O")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut("o", modifiers: .command)
                HStack(spacing: 8) {
                    Text("Repos are discovered one level deep")
                    Text("·")
                    Text("Agents work in sandboxes, never in your checkout")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 56)
            .frame(width: 560)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.18)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .contentShape(Rectangle())
        }
    }
}
