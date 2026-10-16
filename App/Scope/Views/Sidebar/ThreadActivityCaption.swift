import SwiftUI
import ScopeControl
import ScopeCore

/// The second line of a detailed row while a thread has something to say (`ThreadActivityHeadline`): what its agent
/// is doing, what it asks, how its turn ended and when.
///
/// Only a line with a time ticks, on a coarse timeline and inside this view: the clock redraws the caption, never
/// the row or the sidebar around it.
struct ThreadActivityCaption: View {
    let headline: ThreadActivityHeadline
    /// Set for a finished turn: a click on the caption opens the answer in the reading column.
    var readReply: (() -> Void)?
    @State private var hovering = false

    /// Minutes are the finest unit worth reading after the first one.
    private static let tick: TimeInterval = 30

    var body: some View {
        if let since = headline.since {
            TimelineView(.periodic(from: .now, by: Self.tick)) { context in
                caption("\(headline.text) · \(ThreadActivityHeadline.ago(since, now: context.date))")
            }
        } else {
            caption(headline.text)
        }
    }

    @ViewBuilder
    private func caption(_ text: String) -> some View {
        let label = Text(text)
            .font(.scopeCaption)
            .foregroundStyle(Ink.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
        if let readReply {
            label
                .underline(hovering, color: Ink.tertiary)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture(perform: readReply)
                .help("Read the reply (⇧⌘R)")
                .usageID("sidebar.thread.read-reply", label: "Read reply from the sidebar caption")
        } else {
            label
        }
    }
}

extension ThreadActivityHeadline {
    /// A line about a turn that ended with an answer: the answer is one click away. Lines about a turn in progress,
    /// a request or a failure are not.
    var opensReply: Bool { since != nil && reply != nil }
}

extension ThreadSession {
    /// The headline as Settings ▸ Sidebar wants a finished turn told.
    func activityHeadline(_ finished: FinishedThreadLine) -> ThreadActivityHeadline? {
        activityHeadline?.showing(finished)
    }
}
