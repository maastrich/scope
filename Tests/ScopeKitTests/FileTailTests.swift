import Foundation
import Testing
@testable import ScopeCore

@Suite struct FileTailTests {
    private func file(_ text: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "scope-tail-\(UUID().uuidString).output")
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @Test func aShortFileIsReadWhole() throws {
        #expect(FileTail.read(try file("one\ntwo\n")) == .text("one\ntwo\n", truncated: false, size: 8))
    }

    @Test func aLongFileKeepsItsEndFromAFullLine() throws {
        let path = try file("first line\nsecond line\nthird\n")
        #expect(FileTail.read(path, limit: 14) == .text("third\n", truncated: true, size: 29))
    }

    @Test func aMissingFileSaysSo() {
        #expect(FileTail.read("/nonexistent/scope/tasks/b1.output") == .missing)
    }
}
