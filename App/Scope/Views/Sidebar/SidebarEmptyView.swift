import SwiftUI

/// First-launch sidebar: "No scopes yet — Press ⌘O to declare one".
struct SidebarEmptyView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 28, weight: .thin))
            Text("No scopes yet")
                .font(.system(size: 12, weight: .medium))
            Text("Press ⌘O to declare one")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
