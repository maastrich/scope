import Foundation
import ScopeCore

/// What the assistant last read about each thread, so the same words are never classified twice (spec §4.10).
///
/// A hook event can reach the app more than once for one moment of a thread — a `Stop` and a late copy of it, a
/// question's `PreToolUse` and its permission prompt — and a long turn shows the same terminal tail for minutes.
/// This keeps, per thread, a fingerprint of what each job last read and what it answered: the same text again gets
/// the same verdict without a call, without a usage event, and without a second notification. Kept by the caller;
/// nothing persists, a relaunch starts over.
public struct AssistMemory: Sendable, Equatable {
    /// The last triage of a thread: what it read and what it said.
    public struct Triage: Sendable, Equatable {
        public var fingerprint: Int
        public var verdict: NotificationTriage
        /// The notification this verdict decided already went (or was quieted): not again for the same words.
        public var handled: Bool

        public init(fingerprint: Int, verdict: NotificationTriage, handled: Bool = false) {
            self.fingerprint = fingerprint
            self.verdict = verdict
            self.handled = handled
        }
    }

    private var triages: [ThreadID: Triage] = [:]
    private var digests: [ThreadID: Int] = [:]

    public init() {}

    /// A stable mark for `text` within one run of the app.
    public static func fingerprint(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }

    // MARK: Triage

    /// What the thread's last triage said, when it read exactly `text`; `nil` when the words changed or it was
    /// never triaged.
    public func triage(of thread: ThreadID, for text: String) -> Triage? {
        guard let last = triages[thread], last.fingerprint == Self.fingerprint(text) else { return nil }
        return last
    }

    public mutating func rememberTriage(of thread: ThreadID, for text: String, verdict: NotificationTriage, handled: Bool = false) {
        triages[thread] = Triage(fingerprint: Self.fingerprint(text), verdict: verdict, handled: handled)
    }

    /// The notification the last verdict decided is done with: the same words will not bring another.
    public mutating func markHandled(_ thread: ThreadID) {
        triages[thread]?.handled = true
    }

    /// The person said the last verdict was wrong (*Not blocking*): the words stay remembered as informational, so
    /// they are neither re-asked nor re-notified.
    public mutating func overruleTriage(of thread: ThreadID) {
        guard var last = triages[thread] else { return }
        last.verdict = NotificationTriage(kind: .informational)
        last.handled = true
        triages[thread] = last
    }

    // MARK: Digest

    /// `true` when the terminal tail is the one the last digest read: the agent printed nothing new, the verdict holds.
    public func digestIsCurrent(for thread: ThreadID, tailFingerprint: Int) -> Bool {
        digests[thread] == tailFingerprint
    }

    public mutating func rememberDigest(of thread: ThreadID, tailFingerprint: Int) {
        digests[thread] = tailFingerprint
    }

    // MARK: Lifetime

    /// A new turn: what was read belongs to the previous one.
    public mutating func turnStarted(_ thread: ThreadID) {
        digests[thread] = nil
    }

    /// A thread closed for good leaves nothing behind.
    public mutating func forget(_ thread: ThreadID) {
        triages[thread] = nil
        digests[thread] = nil
    }
}
