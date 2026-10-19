import SwiftUI

/// "Scope 1.2.3 is ready — Restart to Update": the band across the top of the window once Sparkle has staged a
/// release (`UpdaterController.readyUpdate`). Restarting hangs up every running thread, so the band says how many
/// and leaves the choice to the owner; closed or ignored, the update still installs at the next quit, and the
/// Scope menu keeps "Restart to Update".
struct UpdateReadyBand: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdaterController.self) private var updater

    var body: some View {
        if updater.bandShown, let ready = updater.readyUpdate {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Scope \(ready.version) is ready.")
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Restart to Update") { updater.installAndRelaunch() }
                    .buttonStyle(.scopePrimary)
                    .usageID("restart", label: "Restart to update")
                Button {
                    updater.dismissBand()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Later: the update installs when Scope quits")
                .accessibilityLabel("Dismiss, install when Scope quits")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Surface.panel)
            .overlay(alignment: .bottom) { Divider() }
            .usageSurface("update-band", label: "Update ready band")
            .accessibilityElement(children: .contain)
        }
    }

    private var detail: String {
        let running = model.runningThreadCount
        switch running {
        case 0: return "Restart now, or let it install when you quit."
        case 1: return "Restarting hangs up the running thread; or let it install when you quit."
        default: return "Restarting hangs up \(running) running threads; or let it install when you quit."
        }
    }
}
