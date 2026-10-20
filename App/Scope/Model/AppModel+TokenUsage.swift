import Foundation
import ScopeAdapters
import ScopeControl
import ScopeCore

/// The latest totals of `TokenLedgerStore`, for the toolbar meter, the task band and hover card, and `scope list` —
/// and, above them, the subscription's limits Claude Code last reported (`RateLimits`), which is what the meter leads
/// with when it has them.
@MainActor
@Observable
final class TokenUsageModel {
    private(set) var snapshot: TokenUsageSnapshot = .empty
    /// The last `limits.reported`, or what the previous run saved; `nil` until a Pro/Max thread has answered.
    private(set) var limits: RateLimits?
    /// What Claude Code's account file says of the plan, re-read with each scan.
    private(set) var account: ClaudeAccount?
    /// Moves with each scan so the "resets in" countdowns and the staleness advance without an event.
    private(set) var clock = Date.now
    @ObservationIgnored fileprivate var loop: Task<Void, Never>?

    fileprivate func publish(_ snapshot: TokenUsageSnapshot) {
        if snapshot != self.snapshot { self.snapshot = snapshot }
    }

    fileprivate func publish(limits: RateLimits?) {
        if limits != self.limits { self.limits = limits }
    }

    fileprivate func publish(account: ClaudeAccount?) {
        if account != self.account { self.account = account }
    }

    fileprivate func tick() { clock = .now }

    /// Whether any thread was ever counted or any limit reported: the meter stays out of the toolbar until then.
    var hasUsage: Bool { !snapshot.threads.isEmpty || limits != nil }

    /// The windows still running at `now`, `nil` when none was reported or all have reset.
    func currentLimits(now: Date = .now) -> RateLimits? {
        guard let limits, !limits.current(now: now).isEmpty else { return nil }
        return limits
    }

    /// The plan's name for the meter: the account file's, else what the limits imply.
    var planLabel: String? {
        if let label = account?.planLabel { return "Claude " + label }
        return limits == nil ? nil : "Claude subscription"
    }

    /// `true` when usage is billed per token rather than bounded by windows: the account file says so and no
    /// limits ever arrived. Then tokens and cost are the main figures, as before.
    var isPerTokenBilling: Bool {
        limits == nil && account.map { !$0.isSubscription } == true
    }

    /// The limits as the CLI and MCP report them.
    func limitsSummary(now: Date = .now) -> RateLimitsSummary? {
        RateLimitsSummary(limits, plan: account?.planLabel, now: now)
    }
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
            if let self {
                tokenUsage.publish(limits: await env.rateLimits.load())
                tokenUsage.publish(await env.tokenLedger.snapshot(calendar: ActivityPeriod.calendar()))
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                await scanTokens()
                tokenUsage.tick()
                try? await Task.sleep(for: Self.tokenScanInterval)
            }
        }
    }

    /// Reads what each thread's transcript gained since the last scan, and what Claude Code's account file says.
    func scanTokens() async {
        let sources = threads.compactMap { session -> TokenLedgerStore.Source? in
            guard let path = session.activity.transcriptPath, !path.isEmpty else { return nil }
            return TokenLedgerStore.Source(thread: session.id.rawValue, title: displayTitle(for: session),
                                           scope: session.record.scopeID.rawValue, task: session.record.taskID, transcript: path)
        }
        let snapshot = await env.tokenLedger.scan(sources, calendar: ActivityPeriod.calendar())
        tokenUsage.publish(snapshot)
        let account = await Task.detached(priority: .utility) { ClaudeAccount.read() }.value
        tokenUsage.publish(account: account)
    }

    /// A `limits.reported` event: the status line of one thread said where the account stands. Kept and saved; an
    /// older report than the one held (two threads answering at once) changes nothing.
    func receiveLimits(_ event: AdapterEvent) {
        guard let json = event.payload[HookEvent.limitsKey],
              let limits = RateLimits.parse(json, reportedAt: event.receivedAt, thread: event.threadID.rawValue) else { return }
        if let held = tokenUsage.limits, held.reportedAt > limits.reportedAt { return }
        tokenUsage.publish(limits: limits)
        let store = env.rateLimits
        Task { await store.save(limits) }
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
