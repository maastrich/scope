import Foundation
import Testing
@testable import ScopeCore

@Suite struct TaskDeliverableTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "deliverable-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func reply(_ thread: String, _ text: String, at seconds: TimeInterval) -> TaskDeliverable.Reply {
        .init(threadID: thread, title: "Thread \(thread)", driver: "claude", text: text, at: Date(timeIntervalSince1970: seconds))
    }

    @Test func aLongReplyKeepsItsEnd() {
        let text = String(repeating: "é", count: TaskDeliverable.replyLimit) + "THE END"
        let kept = TaskDeliverable(taskID: "t", replies: [reply("a", text, at: 1)]).replies[0].text
        #expect(kept.hasPrefix("…") && kept.hasSuffix("THE END"))
        #expect(kept.utf8.count <= TaskDeliverable.replyLimit)
        #expect(!kept.contains("\u{FFFD}"))
    }

    @Test func mergingKeepsWhatAnEarlierRunSaved() {
        let first = TaskDeliverable(taskID: "t", savedAt: .init(timeIntervalSince1970: 10),
                                    replies: [reply("a", "old a", at: 1), reply("b", "b", at: 2)],
                                    files: [.init(name: "REPORT.md", text: "v1")])
        // A resumed archive: thread b is gone, thread a said more, the report was rewritten.
        let second = TaskDeliverable(taskID: "t", savedAt: .init(timeIntervalSince1970: 20),
                                     replies: [reply("a", "new a", at: 3)], files: [.init(name: "REPORT.md", text: "v2")])
        let merged = first.merging(second)
        #expect(merged.replies.map(\.text) == ["b", "new a"])
        #expect(merged.files == [.init(name: "REPORT.md", text: "v2")])
        #expect(merged.lastReply?.threadID == "a")
        // An empty run on top changes nothing.
        #expect(merged.merging(TaskDeliverable(taskID: "t")).replies == merged.replies)
    }

    @Test func collectsReportsFromTheRootAndEverySandbox() throws {
        let root = try folder()
        let api = root.appending(path: "api"), web = root.appending(path: "web")
        for url in [api, web, root.appending(path: "api/docs")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try "root report".write(to: root.appending(path: "REPORT.md"), atomically: true, encoding: .utf8)
        try "api study".write(to: api.appending(path: "docs/study.md"), atomically: true, encoding: .utf8)
        try "web report".write(to: web.appending(path: "REPORT.md"), atomically: true, encoding: .utf8)

        let files = TaskDeliverable.collectFiles(named: ["docs/study.md", "REPORT.md", "REPORT.md"], in: [
            .init(url: root, label: nil), .init(url: api, label: "api"), .init(url: web, label: "web"),
        ])
        #expect(files.map(\.name) == ["REPORT.md", "api/docs/study.md", "web/REPORT.md"])
        #expect(files.map(\.text) == ["root report", "api study", "web report"])
    }

    @Test func aNameCannotLeaveItsFolder() throws {
        let outside = try folder()
        try "secret".write(to: outside.appending(path: "secret.md"), atomically: true, encoding: .utf8)
        let root = try folder()
        try FileManager.default.createSymbolicLink(at: root.appending(path: "REPORT.md"), withDestinationURL: outside.appending(path: "secret.md"))
        let names = ["../\(outside.lastPathComponent)/secret.md", outside.appending(path: "secret.md").path, "REPORT.md", "~/x.md"]
        #expect(TaskDeliverable.collectFiles(named: names, in: [.init(url: root, label: nil)]).isEmpty)
    }

    @Test func aBigFileIsCutAndABinaryOneSkipped() throws {
        let root = try folder()
        try Data(repeating: UInt8(ascii: "a"), count: 100).write(to: root.appending(path: "REPORT.md"))
        try Data([0xFF, 0xFE, 0x00]).write(to: root.appending(path: "blob.bin"))
        let files = TaskDeliverable.collectFiles(named: ["REPORT.md", "blob.bin"], in: [.init(url: root, label: nil)], limit: 10)
        #expect(files == [.init(name: "REPORT.md", text: String(repeating: "a", count: 10), truncated: true)])
    }

    @Test func theStoreMergesAndSkipsEmptyDeliverables() throws {
        let home = try folder()
        TaskDeliverableStore.keep(TaskDeliverable(taskID: "t1"), home: home)
        #expect(TaskDeliverableStore.load(home: home, taskID: "t1") == nil)
        TaskDeliverableStore.keep(TaskDeliverable(taskID: "t1", replies: [reply("a", "answer", at: 1)]), home: home)
        TaskDeliverableStore.keep(TaskDeliverable(taskID: "t1", files: [.init(name: "REPORT.md", text: "r")]), home: home)
        let kept = try #require(TaskDeliverableStore.load(home: home, taskID: "t1"))
        #expect(kept.replies.map(\.text) == ["answer"] && kept.files.map(\.name) == ["REPORT.md"])
        #expect(TaskDeliverableStore.loadAll(home: home).keys.sorted() == ["t1"])
    }

    @Test func markdownPutsTheReportFirst() {
        let one = TaskDeliverable(taskID: "t", replies: [reply("a", "Only answer", at: 1)])
        #expect(one.markdown == "Only answer")
        let both = TaskDeliverable(taskID: "t", replies: [reply("a", "Answer", at: 1)], files: [.init(name: "REPORT.md", text: "Report")])
        #expect(both.markdown == "# REPORT.md\n\nReport\n\n# Thread a\n\nAnswer")
    }
}
