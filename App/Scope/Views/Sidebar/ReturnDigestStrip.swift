import AppKit
import SwiftUI
import ScopeCore
import ScopeTasks

/// "Since 11:40 — 2 turns finished · 1 question for you · PR merged on token-refresh": what moved in the scope
/// while the owner looked elsewhere (`ReturnDigest`, `AppModel+ReturnDigest`). One quiet line under the scope's
/// header, truncated at its end rather than wrapped, never a toast: it takes no focus and goes on its own — at the first selection change, after ten seconds
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
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Ink.tertiary)
                Text(line)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .tint(Fill.selected)
                    .environment(\.openURL, OpenURLAction(handler: open))
                    .help(shown.digest.fragments.map(\.text).joined(separator: " · "))
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
            .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 6))
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

        /// One line: *Since 11:40 — 1 question for you · checks failing on api-cache · 2 turns finished · +1 more*.
        /// A fragment with somewhere to go is a link; the scheme is private to this view and `open` resolves it.
        /// One `Text`, so the whole thing truncates at the end instead of each fragment being squeezed.
        private var line: AttributedString {
            var line = AttributedString(Self.sinceLabel(shown.digest.since) + " — ")
            line.font = .scopeCaption.weight(.medium)
            line.foregroundColor = Ink.secondary
            for (index, fragment) in shown.digest.fragments.enumerated() {
                if index > 0 { line += Self.separator }
                var piece = AttributedString(fragment.text)
                piece.font = .scopeCaption
                if fragment.target != nil {
                    piece.link = URL(string: "scope-digest://\(index)")
                } else {
                    piece.foregroundColor = Ink.tertiary
                }
                line += piece
            }
            if shown.digest.overflow > 0 {
                line += Self.separator
                var more = AttributedString("+\(shown.digest.overflow) more")
                more.font = .scopeCaption
                more.foregroundColor = Ink.tertiary
                line += more
            }
            return line
        }

        private static var separator: AttributedString {
            var dot = AttributedString(" · ")
            dot.font = .scopeCaption
            dot.foregroundColor = Ink.tertiary
            return dot
        }

        private func open(_ url: URL) -> OpenURLAction.Result {
            guard url.scheme == "scope-digest", let index = url.host().flatMap(Int.init),
                  shown.digest.fragments.indices.contains(index), let target = shown.digest.fragments[index].target
            else { return .discarded }
            Usage.click("sidebar.return-digest.\(shown.digest.fragments[index].kind.rawValue)",
                        label: Self.usageLabel(shown.digest.fragments[index].kind))
            model.open(target)
            return .handled
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
}
