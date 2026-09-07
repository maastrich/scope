import SwiftUI
import ScopeCore

/// Toasts for threads that exited live, newest at the bottom, overlaid at the bottom of the scene (never
/// over the tab strip). Each one: icon, `Title exited (status)`, Relaunch, Details (popover), dismiss.
/// Hovering holds the 10 s countdown.
struct ExitToastStack: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.exitNotices) { notice in
                ExitToast(notice: notice)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 12)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.exitNotices.map(\.id))
    }
}

private struct ExitToast: View {
    @Environment(AppModel.self) private var model
    let notice: ThreadExitNotice
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.status.isClean ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundStyle(notice.status.isClean ? Color.secondary : Color(nsColor: .systemOrange))
            Text("\(model.session(notice.id).map(model.displayTitle(for:)) ?? notice.title) exited (\(notice.shortStatus))")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Button("Relaunch") {
                    Task { await model.relaunchExitNotice(notice.id) }
                }
                Button("Details") {
                    showsDetails.toggle()
                }
                .popover(isPresented: $showsDetails, arrowEdge: .top) {
                    ExitDetails(notice: notice, isPresented: $showsDetails)
                }
            }
            .controlSize(.small)
            Button {
                Task { await model.dismissExitNotice(notice.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(notice.closesThread ? "Close for good" : "Dismiss (the tab stays until you close it)")
            .accessibilityLabel(notice.closesThread ? "Close thread" : "Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .frame(maxWidth: 560)
        .onHover { model.holdExitNotice(notice.id, $0 || showsDetails) }
        .onChange(of: showsDetails) { _, open in model.holdExitNotice(notice.id, open) }
    }
}

/// Driver, cwd, exit status, started at, duration, last title; Relaunch or Close from here.
private struct ExitDetails: View {
    @Environment(AppModel.self) private var model
    let notice: ThreadExitNotice
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(notice.title)
                .font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Driver", notice.profile.name)
                row("Directory", notice.record.cwd)
                row("Exit", exitText)
                if let launchedAt = notice.record.lastLaunchedAt {
                    row("Started", launchedAt.formatted(date: .abbreviated, time: .standard))
                }
                if let duration = notice.duration {
                    row("Ran for", duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                }
                if let lastTitle = notice.lastTitle {
                    row("Last title", lastTitle)
                }
            }
            .font(.system(size: 12))
            HStack(spacing: 6) {
                Spacer()
                Button("Close Thread") {
                    isPresented = false
                    Task { await model.closeExitedThread(notice.id) }
                }
                Button("Relaunch") {
                    isPresented = false
                    Task { await model.relaunchExitNotice(notice.id) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
    }

    private var exitText: String {
        if let code = notice.status.code { return "code \(code)" }
        if let signal = notice.status.signal { return "\(ExitStatus.signalName(signal)) (signal \(signal))" }
        return "unknown"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
