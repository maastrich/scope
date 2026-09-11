import Darwin
import Foundation
import Testing
@testable import ScopeAdapters
@testable import ScopeCore

@Suite struct VibeIslandJumpsTests {
    private let t0 = Date(timeIntervalSince1970: 1_789_115_550.727)
    private let bundle = "dev.<user>.scope.debug"

    private func stamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    // Lines as Vibe Island 1.0.48 writes them (tty slashes escaped, as in the real file).
    private func shadow(_ session: String, at date: Date) -> String {
        #"{"c":"jump","l":"info","m":"jump-shadow: session=\#(session) bundle=\#(bundle) tmux=false pane=nil cmuxWs=nil <scrubbed>s=- exec=false legacy=activateAppFallback(bundleId: Optional(\"\#(bundle)\")) planned=noLocalHandle(noClues)","t":"\#(stamp(date))"}"#
    }

    private func route(at date: Date) -> String {
        #"{"c":"jump","l":"info","m":"jump route decided","d":{"route":"legacy","session":"e8a9b5ece5a6","pane":"2146ba19257d"},"t":"\#(stamp(date))"}"#
    }

    private func jump(pid: String = "53462", at date: Date) -> String {
        #"{"c":"jump","l":"info","m":"jump: bid=\#(bundle) iterm=nil tmux=false zellij=nil tty=\/dev\/ttys012 ideWin=nil pid=\#(pid) ottyPane=nil","t":"\#(stamp(date))"}"#
    }

    private func done(at date: Date) -> String {
        #"{"c":"jump","l":"info","m":"jump: done 38ms","t":"\#(stamp(date))"}"#
    }

    private func click(at date: Date) -> String {
        [shadow("bffb9897", at: date), route(at: date + 0.002), jump(at: date + 0.003), done(at: date + 0.04)]
            .joined(separator: "\n") + "\n"
    }

    private func consume(_ text: String, now: Date? = nil) -> [VibeIslandJump] {
        var log = VibeIslandJumpLog()
        return log.consume(Data(text.utf8), now: now ?? t0 + 1)
    }

    /// `date` as it comes back from the log: written to the millisecond, so not always bit-identical.
    private func logged(_ date: Date) -> Date {
        VibeIslandJumpLog.date(stamp(date))!
    }

    private var expected: VibeIslandJump {
        VibeIslandJump(date: logged(t0 + 0.003), bundle: bundle, sessionPrefix: "bffb9897", pid: 53462, tty: "/dev/ttys012")
    }

    // MARK: Parsing

    @Test func aClickIsOneJump() {
        #expect(consume(click(at: t0)) == [expected])
    }

    @Test func aClickSplitAcrossReadsIsStillOneJump() {
        let bytes = Data(click(at: t0).utf8)
        for cut in [10, 200, bytes.count / 2, bytes.count - 5] {
            var log = VibeIslandJumpLog()
            let first = log.consume(bytes.prefix(cut), now: t0 + 1)
            let second = log.consume(bytes.suffix(from: cut), now: t0 + 1)
            #expect(first + second == [expected], "cut at \(cut)")
        }
    }

    @Test func aShadowAloneIsNotAJump() {
        #expect(consume(shadow("bffb9897", at: t0) + "\n").isEmpty)
    }

    @Test func aJumpWithoutShadowKeepsThePID() {
        #expect(consume(jump(at: t0) + "\n") == [VibeIslandJump(date: logged(t0), bundle: bundle, pid: 53462, tty: "/dev/ttys012")])
    }

    @Test func aShadowFromAnEarlierClickIsNotPaired() {
        let text = shadow("aaaaaaaa", at: t0) + "\n" + jump(at: t0 + 3) + "\n"
        #expect(consume(text, now: t0 + 3).first?.sessionPrefix == nil)
    }

    @Test func staleJumpsAreNotFollowed() {
        #expect(consume(click(at: t0), now: t0 + 60).isEmpty)
    }

    @Test func everythingElseIsIgnored() {
        let text = [
            #"{"c":"ui","l":"info","m":"hover lifecycle: gate cleared on collapse","t":"\#(stamp(t0))"}"#,
            "not json at all",
            done(at: t0),
            route(at: t0),
            #"{"c":"jump","m":"jump: bid=com.apple.Terminal pid=nil tty=nil","t":"\#(stamp(t0))"}"#,
        ].joined(separator: "\n") + "\n"
        #expect(consume(text).isEmpty)
    }

    @Test func sessionPrefixesAreValidated() {
        #expect(VibeIslandJumpLog.sessionPrefix("BFFB9897") == "bffb9897")
        #expect(VibeIslandJumpLog.sessionPrefix("abc") == nil)
        #expect(VibeIslandJumpLog.sessionPrefix("not-hex!") == nil)
        #expect(VibeIslandJumpLog.sessionPrefix(nil) == nil)
    }

    // MARK: The file

    private func tempLog() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vi-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "vibe-island.log")
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func historyBeforeStartIsSkipped() throws {
        let url = try tempLog()
        try click(at: t0).write(to: url, atomically: true, encoding: .utf8)
        var log = VibeIslandJumpLog(startingAtEndOf: url)
        #expect(log.read(url, now: t0 + 1).isEmpty)
        try append(click(at: t0 + 0.5), to: url)
        #expect(log.read(url, now: t0 + 1).count == 1)
        #expect(log.read(url, now: t0 + 1).isEmpty)
    }

    @Test func rotationStartsTheNewFileFromTheTop() throws {
        let url = try tempLog()
        try (route(at: t0) + "\n").write(to: url, atomically: false, encoding: .utf8)
        var log = VibeIslandJumpLog(startingAtEndOf: url)
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
        try click(at: t0).write(to: url, atomically: false, encoding: .utf8)
        #expect(log.read(url, now: t0 + 1) == [expected])
    }

    @Test func aMissingLogReadsNothing() {
        var log = VibeIslandJumpLog()
        #expect(log.read(URL(fileURLWithPath: "/nonexistent/vibe-island.log")).isEmpty)
    }

    // MARK: Resolution

    private let a = ThreadID(rawValue: "745f8bbb64bd")!
    private let b = ThreadID(rawValue: "643adaeaab3d")!

    private func noParent(_: pid_t) -> pid_t? { nil }

    @Test func theSessionPrefixPicksTheThread() {
        let candidates: [ThreadLink.Candidate] = [
            .init(id: a, sessionID: "bffb9897-49c8-4e0c-a852-ebda9f7ca487", pid: 100),
            .init(id: b, sessionID: "cc213c34-dcfa-470b-976c-272f5f26370e", pid: 200),
        ]
        #expect(expected.resolve(candidates, parent: noParent) == a)
    }

    @Test func anAmbiguousPrefixFallsBackToThePID() {
        let candidates: [ThreadLink.Candidate] = [
            .init(id: a, sessionID: "bffb9897-0000", pid: 100),
            .init(id: b, sessionID: "bffb9897-1111", pid: 53462),
        ]
        #expect(expected.resolve(candidates, parent: noParent) == b)
    }

    @Test func thePIDClimbsToThePTYChild() {
        let candidates: [ThreadLink.Candidate] = [.init(id: a, sessionID: nil, pid: 100)]
        let tree: [pid_t: pid_t] = [53462: 100]
        #expect(VibeIslandJump(date: t0, pid: 53462).resolve(candidates, parent: { tree[$0] }) == a)
    }

    @Test func anotherAppsSessionMatchesNothing() {
        let candidates: [ThreadLink.Candidate] = [.init(id: a, sessionID: "cc213c34-dcfa", pid: 100)]
        #expect(expected.resolve(candidates, parent: noParent) == nil)
    }
}
