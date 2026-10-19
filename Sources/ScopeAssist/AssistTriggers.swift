import Foundation
import ScopeAdapters
import ScopeCore

/// When the assistant is asked something (spec §4.10): a pure function of an occasion, what the threads are doing,
/// what was asked before, and the clock. Never a loop: it runs on hook events, on task creation, and on a coarse
/// tick that only exists to notice a thread that has been running for a while without any event.
public enum AssistTriggers {
    /// A thread running for longer than this without ending a turn gets a digest, and then one every `digestInterval`
    /// at most — and only when its terminal printed something since (`AssistMemory`). Going in circles shows over
    /// minutes; a caption refreshed every four minutes cost two hundred calls a day for words nobody read.
    public static let digestAfter: TimeInterval = 4 * 60
    public static let digestInterval: TimeInterval = 8 * 60
    /// Two triages of one thread closer than this are one: a `Stop` and its late copy, a question's `PreToolUse` and
    /// its permission prompt. A thread does not finish two turns worth telling apart within half a minute.
    public static let triageDebounce: TimeInterval = 30

    /// Whether a triage can change anything: the verdict only decides whether a finished turn's notification is
    /// quieted, so it is worth a call when a notification would go (the app is in the background) and the preference
    /// lets an informational one stay silent. A question always notifies; so does any event while the app is up.
    public static func triageMatters(kind: HookEvent.Kind, appIsActive: Bool, quietsInformational: Bool) -> Bool {
        kind == .turnEnded && !appIsActive && quietsInformational
    }

    /// What happened.
    public enum Occasion: Sendable, Equatable {
        case hook(thread: ThreadID, kind: HookEvent.Kind)
        case taskCreated(task: String, hasTopic: Bool, topicsAvailable: Bool)
        case tick
    }

    /// A thread as the triggers see it.
    public struct ThreadSnapshot: Sendable, Equatable {
        public var id: ThreadID
        public var state: ThreadState
        /// When the open turn started; `nil` between turns.
        public var turnStartedAt: Date?
        /// The task the thread works in, if any, and whether that task has a pull request.
        public var task: String?
        public var taskHasPullRequest: Bool
        /// The reply that closed the last turn passes `ArchiveHint.replyLooksFinal`.
        public var replyLooksFinal: Bool

        public init(id: ThreadID, state: ThreadState, turnStartedAt: Date? = nil, task: String? = nil,
                    taskHasPullRequest: Bool = false, replyLooksFinal: Bool = false) {
            self.id = id
            self.state = state
            self.turnStartedAt = turnStartedAt
            self.task = task
            self.taskHasPullRequest = taskHasPullRequest
            self.replyLooksFinal = replyLooksFinal
        }
    }

    /// When each job last ran per thread, kept by the caller between calls.
    public struct History: Sendable, Equatable {
        public var lastRun: [AssistJob: Date]

        public init(lastRun: [AssistJob: Date] = [:]) {
            self.lastRun = lastRun
        }

        public mutating func ran(_ job: AssistJob, at date: Date) {
            lastRun[job] = date
        }

        /// A thread closed for good leaves nothing behind.
        public mutating func forget(_ thread: ThreadID) {
            lastRun = lastRun.filter { $0.key.thread != thread }
        }
    }

    /// What `occasion` asks for, in the order to run it. Applies the rules:
    ///
    /// - **digest**: a thread `running` whose turn opened more than `digestAfter` ago, at most every `digestInterval`;
    /// - **triage**: the thread of an `input.requested` or `turn.ended` event, once per `triageDebounce` (whether it is
    ///   worth a call is `triageMatters`);
    /// - **archive hint**: the thread of a `turn.ended` in a task without pull request, when its reply looks final;
    /// - **topic pick**: a task created without a topic, when the scope has topics to choose from.
    public static func jobs(for occasion: Occasion, threads: [ThreadSnapshot], history: History,
                            now: Date = .now) -> [AssistJob] {
        var jobs: [AssistJob] = []
        switch occasion {
        case .hook(let thread, let kind):
            guard let snapshot = threads.first(where: { $0.id == thread }) else { break }
            if kind == .inputRequested || kind == .turnEnded {
                let triage = AssistJob.triage(thread)
                if history.lastRun[triage].map({ now.timeIntervalSince($0) >= triageDebounce }) ?? true {
                    jobs.append(triage)
                }
            }
            if kind == .turnEnded, let task = snapshot.task, !snapshot.taskHasPullRequest, snapshot.replyLooksFinal {
                jobs.append(.archiveHint(thread, task: task))
            }
        case .taskCreated(let task, let hasTopic, let topicsAvailable):
            if !hasTopic, topicsAvailable { jobs.append(.topicPick(task: task)) }
        case .tick:
            break
        }
        // The long-running check rides on every occasion: an event from one thread is as good a moment as a tick to
        // look at the others.
        for snapshot in threads where snapshot.state == .running {
            guard let started = snapshot.turnStartedAt, now.timeIntervalSince(started) >= digestAfter else { continue }
            let digest = AssistJob.digest(snapshot.id)
            if let last = history.lastRun[digest], now.timeIntervalSince(last) < digestInterval { continue }
            if !jobs.contains(digest) { jobs.append(digest) }
        }
        return jobs
    }
}

/// Which tier answers a job, and whether a second opinion is due (spec §4.10): the on-device model first; the
/// driver's light model only when the preference allows it, under the daily cap, as a second opinion on a stuck verdict
/// or as the fallback when the on-device model is unavailable.
public enum AssistPlan {
    public static func tier(mode: AssistMode, onDeviceAvailable: Bool, haikuAvailable: Bool, haikuCallsToday: Int,
                            dailyCap: Int) -> AssistTier? {
        guard mode != .off else { return nil }
        if onDeviceAvailable { return .onDevice }
        guard mode.allowsSecondTier, haikuAvailable, haikuCallsToday < dailyCap else { return nil }
        return .haiku
    }

    /// A stuck verdict from the on-device model is checked by the second tier when it may run.
    public static func wantsSecondOpinion(on digest: ThreadDigest, answeredBy tier: AssistTier, mode: AssistMode,
                                          haikuAvailable: Bool, haikuCallsToday: Int, dailyCap: Int) -> Bool {
        digest.stuck && tier == .onDevice && mode.allowsSecondTier && haikuAvailable && haikuCallsToday < dailyCap
    }
}
