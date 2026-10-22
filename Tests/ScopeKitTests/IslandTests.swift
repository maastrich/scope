import Foundation
import Testing
@testable import ScopeAdapters
@testable import ScopeControl
@testable import ScopeCore

private let acme = ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10")
private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func thread(_ id: String, _ state: ThreadState, at minutes: Double = 0, task: String? = nil,
                    activity: String? = nil, lastEvent: Double? = nil, background: Bool = false,
                    request: ClaudePendingRequest? = nil, foreground: Bool = false, turn: Int = 0) -> Island.ThreadInput {
    Island.ThreadInput(id: ThreadID(rawValue: id)!, scopeID: acme, scopeName: "acme", taskID: task,
                       taskName: task.map { "task \($0)" }, title: "thread \(id.suffix(1))", state: state,
                       activity: activity, since: t0.addingTimeInterval(minutes * 60),
                       lastEventAt: lastEvent.map { t0.addingTimeInterval($0 * 60) }, hasBackgroundWork: background,
                       request: request, isForeground: foreground, turn: turn)
}

private func permission(_ id: String = "p1", command: String = "git push origin main", at minutes: Double = 0) -> ClaudePendingRequest {
    var request = ClaudePendingRequest(id: id, kind: .permission, tool: "Bash", askedAt: t0.addingTimeInterval(minutes * 60), shown: true)
    request.command = command
    return request
}

private func question(multi: Bool = false, count: Int = 1) -> ClaudePendingRequest {
    var request = ClaudePendingRequest(id: "q1", kind: .question, tool: "AskUserQuestion", askedAt: t0, shown: true)
    request.questions = (0..<count).map { index in
        .init(question: "Which colour? \(index)", multiSelect: multi, options: [.init(label: "Red"), .init(label: "Blue")])
    }
    return request
}

private func plan() -> ClaudePendingRequest {
    var request = ClaudePendingRequest(id: "plan1", kind: .plan, tool: "ExitPlanMode", askedAt: t0, shown: true)
    request.plan = "## Plan\n- Add the island\n- Test it"
    return request
}

@Suite struct IslandSnapshotTests {
    @Test func idleAndExitedThreadsHideTheIsland() {
        let snapshot = Island.snapshot([thread("aaaaaaaaaaa1", .idle), thread("aaaaaaaaaaa2", .exited)], now: t0)
        #expect(snapshot.isEmpty)
        #expect(snapshot == .empty)
    }

    @Test func countsRunningAndWaitingAndDrawsADotPerThreadMostUrgentFirst() {
        let snapshot = Island.snapshot([
            thread("aaaaaaaaaaa1", .running),
            thread("aaaaaaaaaaa2", .done),
            thread("aaaaaaaaaaa3", .waiting(reason: .permission), request: permission()),
            thread("aaaaaaaaaaa4", .failed),
            thread("aaaaaaaaaaa5", .idle),
        ], now: t0)
        #expect(snapshot.activeCount == 2)
        #expect(snapshot.dots == [.waiting(reason: .permission), .failed, .running, .done])
        #expect(snapshot.dominant == .waiting(reason: .permission))
        #expect(snapshot.overflow == 0)
    }

    @Test func dotsPastTheLimitBecomeAnOverflow() {
        let threads = (1...8).map { thread("aaaaaaaaaaa\($0)", .running) }
        let snapshot = Island.snapshot(threads, now: t0)
        #expect(snapshot.dots.count == Island.dotLimit)
        #expect(snapshot.overflow == 2)
    }

    @Test func requestsComeFirstOldestFirstAndLeaveTheGroups() {
        let snapshot = Island.snapshot([
            thread("aaaaaaaaaaa1", .running, task: "t1"),
            thread("aaaaaaaaaaa2", .waiting(reason: .permission), task: "t1", request: permission("late", at: 5)),
            thread("aaaaaaaaaaa3", .waiting(reason: .input), task: "t2", request: question()),
        ], now: t0)
        #expect(snapshot.requests.map(\.id.rawValue) == ["aaaaaaaaaaa3", "aaaaaaaaaaa2"])
        #expect(snapshot.groups.map(\.id) == ["task:t1"])
        #expect(snapshot.requests[1].line == "git push origin main")
    }

    @Test func threadsAreGroupedByTaskElseByScopeMostUrgentGroupFirst() {
        let snapshot = Island.snapshot([
            thread("aaaaaaaaaaa1", .done, at: 3, task: "t1"),
            thread("aaaaaaaaaaa2", .running, at: 1),
            thread("aaaaaaaaaaa3", .running, at: 2, task: "t1"),
            thread("aaaaaaaaaaa4", .failed, at: 0, task: "t2"),
        ], now: t0)
        #expect(snapshot.groups.map(\.id) == ["task:t2", "task:t1", "scope:\(acme.rawValue)"])
        #expect(snapshot.groups[1].title == "task t1")
        #expect(snapshot.groups[1].subtitle == "acme")
        #expect(snapshot.groups[1].rows.map(\.id.rawValue) == ["aaaaaaaaaaa3", "aaaaaaaaaaa1"])
        #expect(snapshot.groups[2].title == "acme")
        #expect(snapshot.groups[2].subtitle == nil)
    }

    @Test func aRunningThreadSilentTooLongSaysSoUnlessItHasBackgroundWork() {
        let now = t0.addingTimeInterval(30 * 60)
        let snapshot = Island.snapshot([
            thread("aaaaaaaaaaa1", .running, activity: "Running swift test", lastEvent: 5),
            thread("aaaaaaaaaaa2", .running, activity: "Running swift test", lastEvent: 5, background: true),
            thread("aaaaaaaaaaa3", .running, activity: "Editing Island.swift", lastEvent: 25),
        ], now: now)
        let rows = Dictionary(uniqueKeysWithValues: snapshot.groups.flatMap(\.rows).map { ($0.id.rawValue, $0) })
        #expect(rows["aaaaaaaaaaa1"]?.isQuiet == true)
        #expect(rows["aaaaaaaaaaa1"]?.line == "No news for 25 min")
        #expect(rows["aaaaaaaaaaa2"]?.isQuiet == false)
        #expect(rows["aaaaaaaaaaa3"]?.line == "Editing Island.swift")
    }
}

@Suite struct IslandActionTests {
    @Test func aShortPermissionOffersAllowDenyAndOpen() {
        #expect(Island.actions(thread("aaaaaaaaaaa1", .waiting(reason: .permission), request: permission())) == [.allow, .deny, .open])
    }

    @Test func aPermissionTheIslandCannotShowWholeIsNeverAllowedFromIt() {
        let long = permission(command: "rm -rf build && " + String(repeating: "x", count: 200))
        let multiline = permission(command: "echo one\nrm -rf ~")
        #expect(Island.actions(thread("aaaaaaaaaaa1", .waiting(reason: .permission), request: long)) == [.deny, .open])
        #expect(Island.actions(thread("aaaaaaaaaaa1", .waiting(reason: .permission), request: multiline)) == [.deny, .open])
    }

    @Test func aSingleChoiceQuestionOffersItsOptions() {
        #expect(Island.actions(thread("aaaaaaaaaaa1", .waiting(reason: .input), request: question()))
                == [.choose(0, "Red"), .choose(1, "Blue"), .open])
    }

    @Test func multipleChoicesSeveralQuestionsPlansAndUnknownWaitsOnlyOpen() {
        for request in [question(multi: true), question(count: 2), plan()] {
            #expect(Island.actions(thread("aaaaaaaaaaa1", .waiting(reason: .input), request: request)) == [.open])
        }
        #expect(Island.actions(thread("aaaaaaaaaaa1", .waiting(reason: .input))) == [.open])
        #expect(Island.actions(thread("aaaaaaaaaaa1", .running)).isEmpty)
    }
}

@Suite struct IslandAlertTests {
    private func alerts(_ before: [Island.ThreadInput], _ after: [Island.ThreadInput],
                        settings: IslandSettings = IslandSettings(), quiet: Island.Quiet = Island.Quiet(),
                        memory: inout Island.AlertMemory) -> [Island.Alert] {
        Island.alerts(from: before, to: after, settings: settings, quiet: quiet, memory: &memory)
    }

    @Test func aFinishedTurnAPermissionAPlanAndAFailureEachReveal() {
        var memory = Island.AlertMemory()
        let before = (1...4).map { thread("aaaaaaaaaaa\($0)", .running) }
        let after = [
            thread("aaaaaaaaaaa1", .done, turn: 1),
            thread("aaaaaaaaaaa2", .waiting(reason: .permission), request: permission()),
            thread("aaaaaaaaaaa3", .waiting(reason: .input), request: plan()),
            thread("aaaaaaaaaaa4", .failed, turn: 1),
        ]
        #expect(alerts(before, after, memory: &memory).map(\.kind) == [.finished, .permission, .plan, .failed])
    }

    @Test func theFirstReadingAndANewThreadRevealNothing() {
        var memory = Island.AlertMemory()
        #expect(alerts([], [thread("aaaaaaaaaaa1", .done)], memory: &memory).isEmpty)
    }

    @Test func theSameRequestRevealsOnceEvenAfterABlip() {
        var memory = Island.AlertMemory()
        let running = thread("aaaaaaaaaaa1", .running)
        let waiting = thread("aaaaaaaaaaa1", .waiting(reason: .permission), request: permission())
        #expect(alerts([running], [waiting], memory: &memory).count == 1)
        #expect(alerts([waiting], [waiting], memory: &memory).isEmpty)
        #expect(alerts([waiting], [running], memory: &memory).isEmpty)
        #expect(alerts([running], [waiting], memory: &memory).isEmpty)
        let next = thread("aaaaaaaaaaa1", .waiting(reason: .permission), request: permission("p2"))
        #expect(alerts([waiting], [next], memory: &memory).map(\.kind) == [.permission])
    }

    @Test func twoTurnsEndingAreTwoReveals() {
        var memory = Island.AlertMemory()
        #expect(alerts([thread("aaaaaaaaaaa1", .running, turn: 1)], [thread("aaaaaaaaaaa1", .done, turn: 1)], memory: &memory).count == 1)
        #expect(alerts([thread("aaaaaaaaaaa1", .running, turn: 2)], [thread("aaaaaaaaaaa1", .done, turn: 2)], memory: &memory).count == 1)
    }

    @Test func theForegroundThreadAQuietMacAndSettingsSkipButRemember() {
        var memory = Island.AlertMemory()
        let running = thread("aaaaaaaaaaa1", .running)
        let shown = thread("aaaaaaaaaaa1", .waiting(reason: .permission), request: permission(), foreground: true)
        #expect(alerts([running], [shown], memory: &memory).isEmpty)
        // Looking away later does not bring the old permission out.
        var away = shown
        away.isForeground = false
        #expect(alerts([running], [away], memory: &memory).isEmpty)

        var quietMemory = Island.AlertMemory()
        let done = thread("aaaaaaaaaaa2", .done, turn: 3)
        #expect(alerts([thread("aaaaaaaaaaa2", .running)], [done], quiet: Island.Quiet(focus: true), memory: &quietMemory).isEmpty)
        #expect(alerts([thread("aaaaaaaaaaa2", .running)], [done], memory: &quietMemory).isEmpty)

        var settingsMemory = Island.AlertMemory()
        let off = IslandSettings(alertsOnFinish: false)
        #expect(alerts([thread("aaaaaaaaaaa3", .running)], [thread("aaaaaaaaaaa3", .done)], settings: off, memory: &settingsMemory).isEmpty)
        #expect(Island.Quiet(screenLocked: true).isQuiet)
    }

    @Test func aWaitWithoutItsRequestStillRevealsOnce() {
        var memory = Island.AlertMemory()
        let waiting = thread("aaaaaaaaaaa1", .waiting(reason: .input), at: 2)
        #expect(alerts([thread("aaaaaaaaaaa1", .running)], [waiting], memory: &memory).map(\.kind) == [.question])
        #expect(alerts([waiting], [waiting], memory: &memory).isEmpty)
    }

    @Test func theMemoryIsBounded() {
        var memory = Island.AlertMemory()
        for index in 0..<(Island.AlertMemory.limit + 10) { memory.insert("k\(index)") }
        #expect(memory.keys.count == Island.AlertMemory.limit)
        #expect(!memory.contains("k0"))
        #expect(memory.contains("k\(Island.AlertMemory.limit + 9)"))
    }
}

@Suite struct IslandPlacementTests {
    /// A 14" MacBook Pro: 1512 × 982 points, a 32 pt notch 180 pt wide.
    private let notched = Island.Screen(
        name: "Built-in Retina Display", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeTop: 32,
        auxiliaryLeft: CGRect(x: 0, y: 950, width: 666, height: 32),
        auxiliaryRight: CGRect(x: 846, y: 950, width: 666, height: 32), menuBarHeight: 32, isMain: true)
    private let external = Island.Screen(name: "LG Ultra HD", frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                                         menuBarHeight: 25)

    @Test func theNotchIsTheGapBetweenTheAuxiliaryAreas() {
        #expect(notched.notch == CGRect(x: 666, y: 950, width: 180, height: 32))
        #expect(external.notch == nil)
    }

    @Test func theCollapsedIslandWrapsTheNotchElseHangsCentredAsHighAsTheMenuBar() {
        let onNotch = Island.frame(for: CGSize(width: 300, height: 32), on: notched)
        #expect(onNotch == CGRect(x: 606, y: 950, width: 300, height: 32))
        let pill = Island.frame(for: CGSize(width: 160, height: 25), on: external)
        #expect(pill == CGRect(x: 1512 + 880, y: 1055, width: 160, height: 25))
        var hidden = external
        hidden.menuBarHeight = 0
        #expect(Island.band(on: hidden).height == Island.pillHeight)
    }

    @Test func theOpenIslandStaysOnItsScreen() {
        let wide = Island.frame(for: CGSize(width: 4000, height: 400), on: external)
        #expect(wide.minX == external.frame.minX)
        #expect(wide.width == external.frame.width)
        #expect(wide.maxY == external.frame.maxY)
    }

    @Test func theScreenIsTheNamedOneTheOneUnderThePointerElseTheMain() {
        let screens = [external, notched]
        let pointerOnExternal = CGPoint(x: 2000, y: 500)
        #expect(Island.screen(screens, settings: IslandSettings(placement: .main), pointer: pointerOnExternal)?.name == notched.name)
        #expect(Island.screen(screens, settings: IslandSettings(placement: .pointer), pointer: pointerOnExternal)?.name == external.name)
        #expect(Island.screen(screens, settings: IslandSettings(placement: .named, screenName: "LG Ultra HD"),
                              pointer: .zero)?.name == external.name)
        #expect(Island.screen(screens, settings: IslandSettings(placement: .named, screenName: "Gone"),
                              pointer: .zero)?.name == notched.name)
        #expect(Island.screen([], settings: IslandSettings(), pointer: .zero) == nil)
    }

    /// Two 4K screens side by side, the secondary to the left of the primary and higher: negative x, and its top above
    /// the primary's in AppKit's coordinates.
    private let primary = Island.Screen(name: "LG UltraFine", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                        menuBarHeight: 25, isMain: true)
    private let left = Island.Screen(name: "LG UltraFine (2)", frame: CGRect(x: -2560, y: 200, width: 2560, height: 1440),
                                     menuBarHeight: 25)

    @Test func theActiveWindowIsTheDefault() {
        #expect(IslandSettings().placement == .activeWindow)
    }

    @Test func theActiveWindowPicksTheScreenHoldingMostOfIt() {
        let screens = [primary, left]
        let settings = IslandSettings()
        let pointerOnPrimary = CGPoint(x: 100, y: 100)
        let onLeft = CGRect(x: -2000, y: 400, width: 800, height: 600)
        #expect(Island.screen(screens, settings: settings, pointer: pointerOnPrimary, activeWindow: onLeft)?.name == left.name)
        // Straddling: 300 pt on the left screen, 500 on the primary.
        let straddling = CGRect(x: -300, y: 400, width: 800, height: 600)
        #expect(Island.screen(screens, settings: settings, pointer: CGPoint(x: -100, y: 500), activeWindow: straddling)?.name
                == primary.name)
        let mostlyLeft = CGRect(x: -500, y: 400, width: 800, height: 600)
        #expect(Island.screen(screens, settings: settings, pointer: pointerOnPrimary, activeWindow: mostlyLeft)?.name == left.name)
    }

    @Test func withoutAWindowTheActiveWindowFallsBackToThePointerThenTheMain() {
        let screens = [left, primary]
        let settings = IslandSettings()
        #expect(Island.screen(screens, settings: settings, pointer: CGPoint(x: -1000, y: 800))?.name == left.name)
        // A window off every screen counts as none.
        let offScreen = CGRect(x: 9000, y: 9000, width: 800, height: 600)
        #expect(Island.screen(screens, settings: settings, pointer: CGPoint(x: -1000, y: 800), activeWindow: offScreen)?.name
                == left.name)
        // Neither the window nor the pointer on a screen: the main one.
        #expect(Island.screen(screens, settings: settings, pointer: CGPoint(x: 9000, y: 9000), activeWindow: offScreen)?.name
                == primary.name)
    }

    @Test func otherPlacementsIgnoreTheActiveWindow() {
        let onLeft = CGRect(x: -2000, y: 400, width: 800, height: 600)
        #expect(Island.screen([primary, left], settings: IslandSettings(placement: .main), pointer: .zero,
                              activeWindow: onLeft)?.name == primary.name)
        #expect(Island.screen([primary, left], settings: IslandSettings(placement: .pointer), pointer: CGPoint(x: 10, y: 10),
                              activeWindow: onLeft)?.name == primary.name)
    }

    @Test func overlapIsTheSharedArea() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(Island.overlap(rect, CGRect(x: 50, y: 50, width: 100, height: 100)) == 2500)
        #expect(Island.overlap(rect, CGRect(x: 100, y: 0, width: 100, height: 100)) == 0)
        #expect(Island.overlap(rect, CGRect(x: 500, y: 500, width: 10, height: 10)) == 0)
        #expect(Island.screen(holdingMostOf: CGRect(x: 9000, y: 0, width: 10, height: 10), among: [primary, left]) == nil)
    }

    @Test func quartzRectsFlipAroundThePrimaryScreen() {
        // A window 100 pt below the top of the primary screen.
        #expect(Island.appKitRect(fromQuartz: CGRect(x: 10, y: 100, width: 800, height: 600), primaryHeight: 1440)
                == CGRect(x: 10, y: 740, width: 800, height: 600))
        // On the left screen, whose top is 200 pt above the primary's: a negative Quartz y.
        let quartz = CGRect(x: -2000, y: -150, width: 800, height: 600)
        let appKit = Island.appKitRect(fromQuartz: quartz, primaryHeight: 1440)
        #expect(appKit == CGRect(x: -2000, y: 990, width: 800, height: 600))
        #expect(Island.screen(holdingMostOf: appKit, among: [primary, left])?.name == left.name)
    }

    @Test func theFrontWindowIsTheAppsFirstRealDocumentWindow() {
        let windows = [
            Island.WindowInfo(pid: 9, layer: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 500)),
            Island.WindowInfo(pid: 42, layer: 25, bounds: CGRect(x: 1000, y: 0, width: 300, height: 32)),
            Island.WindowInfo(pid: 42, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1, height: 1)),
            Island.WindowInfo(pid: 42, layer: 0, alpha: 0, bounds: CGRect(x: 0, y: 0, width: 600, height: 400)),
            Island.WindowInfo(pid: 42, layer: 0, bounds: CGRect(x: -2000, y: -150, width: 800, height: 600)),
            Island.WindowInfo(pid: 42, layer: 0, bounds: CGRect(x: 10, y: 100, width: 800, height: 600)),
        ]
        #expect(Island.frontWindow(of: 42, in: windows) == CGRect(x: -2000, y: -150, width: 800, height: 600))
        #expect(Island.frontWindow(of: 7, in: windows) == nil)
    }

    @Test func aWindowListEntryReadsTheFieldsThatNeedNoPermission() {
        let entry: [String: Any] = [
            "kCGWindowOwnerPID": NSNumber(value: 42), "kCGWindowLayer": NSNumber(value: 0),
            "kCGWindowAlpha": NSNumber(value: 1.0),
            "kCGWindowBounds": ["X": NSNumber(value: -2000), "Y": NSNumber(value: -150), "Width": NSNumber(value: 800),
                                "Height": NSNumber(value: 600)] as [String: Any],
        ]
        #expect(Island.WindowInfo(entry) == Island.WindowInfo(pid: 42, layer: 0,
                                                             bounds: CGRect(x: -2000, y: -150, width: 800, height: 600)))
        #expect(Island.WindowInfo(["kCGWindowOwnerPID": NSNumber(value: 42)]) == nil)
    }
}

@Suite struct IslandSettingsTests {
    @Test func aConfigWithoutTheIslandDecodesToAutomaticDefaults() throws {
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(preferences.island == IslandSettings())
        #expect(preferences.island.isEnabled(automatic: true))
        #expect(!preferences.island.isEnabled(automatic: false))
    }

    @Test func anExplicitChoiceWinsOverAutomaticAndBadValuesFallBack() throws {
        let json = #"{"island":{"enabled":false,"opening":"click","placement":"sideways","playsSound":true}}"#
        let island = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8)).island
        #expect(!island.isEnabled(automatic: true))
        #expect(island.opening == .click)
        #expect(island.placement == .activeWindow)
        #expect(island.playsSound)
        #expect(island.alertsOnRequest)
    }

    @Test func itRoundTrips() throws {
        let island = IslandSettings(enabled: true, opening: .click, placement: .named, screenName: "LG",
                                    alertsOnFinish: false, alertsOnFailure: false, alertsOnRequest: true, playsSound: true)
        let data = try JSONEncoder().encode(Preferences(island: island))
        #expect(try JSONDecoder().decode(Preferences.self, from: data).island == island)
    }

    @Test func theMainScreenV030WroteByDefaultBecomesTheActiveWindow() throws {
        let legacy = #"{"island":{"opening":"hover","placement":"main","playsSound":false}}"#
        #expect(try JSONDecoder().decode(Preferences.self, from: Data(legacy.utf8)).island.placement == .activeWindow)
        // A pointer or a named screen could only have been chosen: they stay.
        let pointer = #"{"island":{"placement":"pointer"}}"#
        #expect(try JSONDecoder().decode(Preferences.self, from: Data(pointer.utf8)).island.placement == .pointer)
        let named = #"{"island":{"placement":"named","screenName":"LG"}}"#
        #expect(try JSONDecoder().decode(Preferences.self, from: Data(named.utf8)).island.placement == .named)
    }

    @Test func theMainScreenChosenSinceStays() throws {
        let data = try JSONEncoder().encode(Preferences(island: IslandSettings(placement: .main)))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""placementRevision":2"#))
        #expect(try JSONDecoder().decode(Preferences.self, from: data).island.placement == .main)
        let stamped = #"{"island":{"placement":"main","placementRevision":2}}"#
        #expect(try JSONDecoder().decode(Preferences.self, from: Data(stamped.utf8)).island.placement == .main)
    }
}
