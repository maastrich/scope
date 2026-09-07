import SwiftUI

/// First-launch sidebar: "No scopes yet — Drop a folder here or press ⌘O". The whole column accepts folder drops.
struct SidebarEmptyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FolderDropZone { urls in
            Task { await model.addScopes(urls) }
        } content: { isTargeted in
            VStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 28, weight: .thin))
                Text("No scopes yet")
                    .font(.system(size: 12, weight: .medium))
                Text("Drop a folder here or press ⌘O")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 24)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
    }
}
