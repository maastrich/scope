import SwiftUI

/// Right-hand inspector: a segmented Graph / Delta / Base / PRs control with the context it follows
/// (`acme · auth-refresh`) in its own header, then the panel pinned to the top. ⌘D / ⌘⇧B switch tabs.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // One 30 pt band, level with the window toolbar, so the header reads as a single line across the window.
            HStack(spacing: 8) {
                Picker("Inspector tab", selection: $model.inspectorTab) {
                    ForEach(InspectorTab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                if let context = model.contextDescription {
                    Text(context)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel("Inspector context: \(context)")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(Color("PanelBackground"))
            Divider()
            Group {
                switch model.inspectorTab {
                case .graph:
                    GraphView()
                case .delta:
                    DeltaView()
                case .base:
                    BaseView()
                case .pullRequests:
                    PullRequestsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
