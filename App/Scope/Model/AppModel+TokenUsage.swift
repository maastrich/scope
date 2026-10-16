import Foundation
import ScopeAdapters
import ScopeControl
import ScopeCore

/// The latest totals of `TokenLedgerStore`, for the toolbar meter, the task band and hover card, and `scope list`.
@MainActor
@Observable
final class TokenUsageModel {
    private(set) var snapshot: TokenUsageSnapshot = .empty
    @ObservationIgnored fileprivate var loop: Task<Void, Never>?

    fileprivate func publish(_ snapshot: TokenUsageSnapshot) {
        if snapshot != self.snapshot { self.snapshot = snapshot }
    }

    /// Whether any thread was ever counted: the meter stays out of the toolbar until then.
    var hasUsage: Bool { !snapshot.threads.isEmpty }
}

/// Reading what Claude Code threads consumed. The transcripts are read by the ledger's actor, off the main thread;
/// a scan only stats each file when nothing was appended to it, so the interval is a matter of freshness, not cost.
extension AppModel {
    /// How often the transcripts are looked at.
    static let tokenScanInterval: Duration = .seconds(30)

    func startTokenMeter() {
        guard tokenUsage.loop == nil else { return }
        tokenUsage.loop = Task { [weak self] in
            // What the last launch counted shows at once; the first scan follows once threads are restored.
            if let self { tokenUsage.publish(await env.tokenLedger.snapshot(calendar: ActivityPeriod.calendar())) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                await scanTokens()
                try? await Task.sleep(for: Self.tokenScanInterval)
            }
        }
    }

    /// Reads what each thread's transcript gained since the last scan.
    func scanTokens() async {
        let sources = threads.compactMap { session -> TokenLedgerStore.Source? in
            guard let path = session.activity.transcriptPath, !path.isEmpty else { return nil }
            return TokenLedgerStore.Source(thread: session.id.rawValue, title: displayTitle(for: session),
                                           scope: session.record.scopeID.rawValue, task: session.record.taskID, transcript: path)
        }
        let snapshot = await env.tokenLedger.scan(sources, calendar: ActivityPeriod.calendar())
        tokenUsage.publish(snapshot)
    }

    /// Thread id → tokens consumed all told, for `scope summary`.
    var tokenTotalsByThread: [String: Int] {
        tokenUsage.snapshot.threads.compactMapValues { $0.total.isZero ? nil : $0.total.total }
    }

    /// A scope's name for the meter: the declared one, else what the id was.
    func tokenScopeName(_ id: String) -> String {
        scope(ScopeID(rawValue: id))?.name ?? "Removed scope"
    }

    /// A thread's title for the meter: the live one, else the one it had when last counted.
    func tokenThreadTitle(_ row: TokenUsageSnapshot.Row) -> String {
        ThreadID(rawValue: row.id).flatMap { session($0) }.map { displayTitle(for: $0) } ?? row.title
    }
}
