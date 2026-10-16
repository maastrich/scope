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

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.scopeCaption)
            .foregroundStyle(Ink.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

extension ThreadSession {
    /// The headline as Settings ▸ Sidebar wants a finished turn told.
    func activityHeadline(_ finished: FinishedThreadLine) -> ThreadActivityHeadline? {
        activityHeadline?.showing(finished)
    }
}
