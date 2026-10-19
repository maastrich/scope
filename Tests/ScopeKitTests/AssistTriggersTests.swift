import Foundation
import Testing
import ScopeAdapters
import ScopeCore
@testable import ScopeAssist

/// The rules of spec §4.10: when a digest, a triage, an archive hint or a topic pick is due, and which tier answers.
@Suite struct AssistTriggersTests {
    let a = ThreadID(rawValue: "aaaaaaaaaaaa")!
    let b = ThreadID(rawValue: "bbbbbbbbbbbb")!
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func running(_ id: ThreadID, since seconds: TimeInterval) -> AssistTriggers.ThreadSnapshot {
        .init(id: id, state: .running, turnStartedAt: now.addingTimeInterval(-seconds))
    }

    @Test func aThreadRunningForFourMinutesGetsADigestAndNotBefore() {
        let young = AssistTriggers.jobs(for: .tick, threads: [running(a, since: 3 * 60)], history: .init(), now: now)
        #expect(young.isEmpty)
        let old = AssistTriggers.jobs(for: .tick, threads: [running(a, since: 4 * 60)], history: .init(), now: now)
        #expect(old == [.digest(a)])
    }

    @Test func aDigestRepeatsEveryEightMinutesAtMost() {
        var history = AssistTriggers.History()
        history.ran(.digest(a), at: now.addingTimeInterval(-4 * 60))
        #expect(AssistTriggers.jobs(for: .tick, threads: [running(a, since: 900)], history: history, now: now).isEmpty)
        history.ran(.digest(a), at: now.addingTimeInterval(-8 * 60))
        #expect(AssistTriggers.jobs(for: .tick, threads: [running(a, since: 900)], history: history, now: now) == [.digest(a)])
    }

    @Test func onlyRunningThreadsWithAnOpenTurnAreDigested() {
        let threads: [AssistTriggers.ThreadSnapshot] = [
            .init(id: a, state: .done, turnStartedAt: now.addingTimeInterval(-600)),
            .init(id: b, state: .running, turnStartedAt: nil),
        ]
        #expect(AssistTriggers.jobs(for: .tick, threads: threads, history: .init(), now: now).isEmpty)
    }

    @Test func aFinishedTurnAndAQuestionAreTriaged() {
        let threads = [AssistTriggers.ThreadSnapshot(id: a, state: .done)]
        #expect(AssistTriggers.jobs(for: .hook(thread: a, kind: .turnEnded), threads: threads, history: .init(), now: now) == [.triage(a)])
        #expect(AssistTriggers.jobs(for: .hook(thread: a, kind: .inputRequested), threads: threads, history: .init(), now: now) == [.triage(a)])
        #expect(AssistTriggers.jobs(for: .hook(thread: a, kind: .turnStarted), threads: threads, history: .init(), now: now).isEmpty)
        #expect(AssistTriggers.jobs(for: .hook(thread: a, kind: .permissionRequested), threads: threads, history: .init(), now: now).isEmpty)
    }

    @Test func triageIsDebouncedPerThread() {
        let threads = [AssistTriggers.ThreadSnapshot(id: a, state: .waiting(reason: .input)), .init(id: b, state: .done)]
        var history = AssistTriggers.History()
        history.ran(.triage(a), at: now.addingTimeInterval(-20))
        #expect(AssistTriggers.jobs(for: .hook(thread: a, kind: .inputRequested), threads: threads, history: history, now: now).isEmpty)
        #expect(AssistTriggers.jobs(for: .hook(thread: b, kind: .turnEnded), threads: threads, history: history, now: now) == [.triage(b)])
    }

    /// The verdict only quiets a finished turn's notification: no call when no notification would go.
    @Test func aTriageIsWorthACallOnlyWhenItCanQuietANotification() {
        #expect(AssistTriggers.triageMatters(kind: .turnEnded, appIsActive: false, quietsInformational: true))
        #expect(!AssistTriggers.triageMatters(kind: .turnEnded, appIsActive: true, quietsInformational: true))
        #expect(!AssistTriggers.triageMatters(kind: .turnEnded, appIsActive: false, quietsInformational: false))
        #expect(!AssistTriggers.triageMatters(kind: .inputRequested, appIsActive: false, quietsInformational: true))
    }

    @Test func anUnknownThreadAsksNothing() {
        #expect(AssistTriggers.jobs(for: .hook(thread: a, kind: .turnEnded), threads: [], history: .init(), now: now).isEmpty)
    }

    @Test func anArchiveHintNeedsATaskWithoutPullRequestAndAFinalReply() {
        func snapshot(task: String?, pr: Bool, final: Bool) -> [AssistTriggers.ThreadSnapshot] {
            [.init(id: a, state: .done, task: task, taskHasPullRequest: pr, replyLooksFinal: final)]
        }
        let ended = AssistTriggers.Occasion.hook(thread: a, kind: .turnEnded)
        #expect(AssistTriggers.jobs(for: ended, threads: snapshot(task: "t1", pr: false, final: true), history: .init(), now: now)
                == [.triage(a), .archiveHint(a, task: "t1")])
        #expect(AssistTriggers.jobs(for: ended, threads: snapshot(task: "t1", pr: true, final: true), history: .init(), now: now) == [.triage(a)])
        #expect(AssistTriggers.jobs(for: ended, threads: snapshot(task: nil, pr: false, final: true), history: .init(), now: now) == [.triage(a)])
        #expect(AssistTriggers.jobs(for: ended, threads: snapshot(task: "t1", pr: false, final: false), history: .init(), now: now) == [.triage(a)])
    }

    @Test func aTaskCreatedWithoutTopicGetsAPickWhenThereAreTopics() {
        #expect(AssistTriggers.jobs(for: .taskCreated(task: "t1", hasTopic: false, topicsAvailable: true), threads: [], history: .init(), now: now)
                == [.topicPick(task: "t1")])
        #expect(AssistTriggers.jobs(for: .taskCreated(task: "t1", hasTopic: true, topicsAvailable: true), threads: [], history: .init(), now: now).isEmpty)
        #expect(AssistTriggers.jobs(for: .taskCreated(task: "t1", hasTopic: false, topicsAvailable: false), threads: [], history: .init(), now: now).isEmpty)
    }

    @Test func anEventOnOneThreadStillNoticesAnotherRunningForLong() {
        let threads = [AssistTriggers.ThreadSnapshot(id: a, state: .done), running(b, since: 500)]
        #expect(AssistTriggers.jobs(for: .hook(thread: a, kind: .turnEnded), threads: threads, history: .init(), now: now) == [.triage(a), .digest(b)])
    }

    @Test func forgettingAThreadDropsItsHistoryOnly() {
        var history = AssistTriggers.History()
        history.ran(.digest(a), at: now)
        history.ran(.triage(b), at: now)
        history.forget(a)
        #expect(history.lastRun.keys.map(\.thread) == [b])
    }

    // MARK: Tiers

    @Test func theOnDeviceModelAnswersFirstAndHaikuOnlyUnderTheCap() {
        #expect(AssistPlan.tier(mode: .off, onDeviceAvailable: true, haikuAvailable: true, haikuCallsToday: 0, dailyCap: 40) == nil)
        #expect(AssistPlan.tier(mode: .onDevice, onDeviceAvailable: true, haikuAvailable: true, haikuCallsToday: 0, dailyCap: 40) == .onDevice)
        #expect(AssistPlan.tier(mode: .onDevice, onDeviceAvailable: false, haikuAvailable: true, haikuCallsToday: 0, dailyCap: 40) == nil)
        #expect(AssistPlan.tier(mode: .onDeviceAndHaiku, onDeviceAvailable: false, haikuAvailable: true, haikuCallsToday: 39, dailyCap: 40) == .haiku)
        #expect(AssistPlan.tier(mode: .onDeviceAndHaiku, onDeviceAvailable: false, haikuAvailable: true, haikuCallsToday: 40, dailyCap: 40) == nil)
        #expect(AssistPlan.tier(mode: .onDeviceAndHaiku, onDeviceAvailable: false, haikuAvailable: false, haikuCallsToday: 0, dailyCap: 40) == nil)
    }

    @Test func aStuckVerdictGetsASecondOpinionWhenHaikuMay() {
        let stuck = ThreadDigest(activity: "Retrying swift test", stuck: true, reason: "same error three times")
        let fine = ThreadDigest(activity: "Editing a file", stuck: false)
        #expect(AssistPlan.wantsSecondOpinion(on: stuck, answeredBy: .onDevice, mode: .onDeviceAndHaiku, haikuAvailable: true, haikuCallsToday: 0, dailyCap: 40))
        #expect(!AssistPlan.wantsSecondOpinion(on: fine, answeredBy: .onDevice, mode: .onDeviceAndHaiku, haikuAvailable: true, haikuCallsToday: 0, dailyCap: 40))
        #expect(!AssistPlan.wantsSecondOpinion(on: stuck, answeredBy: .onDevice, mode: .onDevice, haikuAvailable: true, haikuCallsToday: 0, dailyCap: 40))
        #expect(!AssistPlan.wantsSecondOpinion(on: stuck, answeredBy: .haiku, mode: .onDeviceAndHaiku, haikuAvailable: true, haikuCallsToday: 0, dailyCap: 40))
        #expect(!AssistPlan.wantsSecondOpinion(on: stuck, answeredBy: .onDevice, mode: .onDeviceAndHaiku, haikuAvailable: true, haikuCallsToday: 40, dailyCap: 40))
    }
}
