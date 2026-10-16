import AppKit
import SwiftUI
import ScopeCore
import ScopeTasks

/// "Since 11:40 — 2 turns finished · 1 question for you · PR merged on token-refresh": what moved in the scope
/// while the owner looked elsewhere (`ReturnDigest`, `AppModel+ReturnDigest`). A quiet band under the scope's
/// header, never a toast: it takes no focus and goes on its own — at the first selection change, after ten seconds
/// on screen with the app in front, or with its ×. Each fragment reveals what it names.
struct ReturnDigestStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let shown = model.returnDigests.shown, shown.scopeID == model.currentScopeID {
                Band(shown: shown)
                    .id(shown.returnID)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.returnDigests.shown?.returnID)
        .usageArea("sidebar.return-digest")
    }

    /// Seconds the band stays once the app is in front.
    static let lifetime: Duration = .seconds(10)

    private struct Band: View {
        @Environment(AppModel.self) private var model
        let shown: ReturnDigestModel.Shown
        /// The selection the band arrived with: a different one is the owner moving on.
        @State private var baseline: SidebarItem??
        @State private var appActive = NSApplication.shared.isActive

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Ink.tertiary)
                    Text(Self.sinceLabel(shown.digest.since))
                        .font(.scopeCaption.weight(.medium))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        model.returnDigests.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Ink.tertiary)
                    }
                    .buttonStyle(.iconTight)
                    .usageID("dismiss", label: "Dismiss what moved")
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss what moved since your last visit")
                }
                FlowLayout(spacing: 2) {
                    ForEach(shown.digest.fragments) { fragment in
                        FragmentButton(fragment: fragment)
                    }
                    if shown.digest.overflow > 0 {
                        Text("+\(shown.digest.overflow) more")
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.tertiary)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 2)
                    }
                }
                .padding(.leading, -3)
            }
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Surface.stroke))
            .padding(EdgeInsets(top: 0, leading: 10, bottom: 4, trailing: 10))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Since your last visit")
            .onAppear { baseline = .some(model.selection) }
            .onChange(of: model.selection) { _, selection in
                if let baseline, selection != baseline { model.returnDigests.dismiss() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
            // Ten seconds *seen*: the clock runs only while the app is in front, and starts over when it comes back.
            .task(id: appActive) {
                guard appActive else { return }
                try? await Task.sleep(for: ReturnDigestStrip.lifetime)
                guard !Task.isCancelled, model.returnDigests.shown?.returnID == shown.returnID else { return }
                model.returnDigests.dismiss()
            }
        }

        /// "Since 11:40", "Since yesterday 18:02", "Since Mon 09:15", "Since 3 Oct".
        static func sinceLabel(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
            let time = date.formatted(date: .omitted, time: .shortened)
            if calendar.isDate(date, inSameDayAs: now) { return "Since \(time)" }
            if calendar.isDateInYesterday(date) { return "Since yesterday \(time)" }
            if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
                return "Since \(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
            }
            return "Since \(date.formatted(.dateTime.day().month(.abbreviated)))"
        }
    }

    private struct FragmentButton: View {
        @Environment(AppModel.self) private var model
        let fragment: ReturnDigest.Fragment

        var body: some View {
            Button {
                if let target = fragment.target { model.open(target) }
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Self.color(fragment.kind))
                        .frame(width: 6, height: 6)
                    Text(fragment.text)
                        .lineLimit(1)
                }
                .font(.scopeCaption)
            }
            .buttonStyle(.scopeLink)
            .disabled(fragment.target == nil)
            .usageID(fragment.kind.rawValue, label: Self.usageLabel(fragment.kind))
            .help(Self.help(fragment))
        }

        static func color(_ kind: ReturnDigest.Fragment.Kind) -> Color {
            switch kind {
            case .questions: ThreadStateStyle.waiting
            case .checksFailing, .turnsFailed: PullRequestStyle.failing
            case .checksPassing: PullRequestStyle.passing
            case .merged, .turnsFinished: ThreadStateStyle.done
            case .opened, .closed: Ink.tertiary
            }
        }

        static func usageLabel(_ kind: ReturnDigest.Fragment.Kind) -> String {
            switch kind {
            case .questions: "Questions for you"
            case .checksFailing: "Checks failing"
            case .turnsFailed: "Turns failed"
            case .merged: "PR merged"
            case .turnsFinished: "Turns finished"
            case .closed: "PR closed"
            case .opened: "PR opened"
            case .checksPassing: "Checks passing"
            }
        }

        static func help(_ fragment: ReturnDigest.Fragment) -> String {
            switch fragment.target {
            case .thread: "Show the thread"
            case .task: "Show the task"
            case .url: "Open the pull request on GitHub"
            case nil: fragment.text
            }
        }
    }
}
