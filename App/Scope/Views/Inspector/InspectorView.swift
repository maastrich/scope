import SwiftUI

/// Right-hand inspector: a segmented Graph / Delta / Base / PRs control in its own header and, for M0, placeholders
/// in place of the three panels. ⌘D / ⌘⇧B already switch tabs so the muscle memory exists from day one.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Inspector tab", selection: $model.inspectorTab) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
