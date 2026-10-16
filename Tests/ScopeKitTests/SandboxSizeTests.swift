import Foundation
import Testing
@testable import ScopeCore

@Suite struct SandboxSizeTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "scope-size-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url.appending(path: "a/b"), withIntermediateDirectories: true)
        return url
    }

    @Test func countsRegularFilesOnceAndIgnoresLinks() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 100_000).write(to: root.appending(path: "big.bin"))
        try Data(repeating: 2, count: 10_000).write(to: root.appending(path: "a/b/small.bin"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: root.appending(path: "big.bin"))
        try FileManager.default.linkItem(at: root.appending(path: "big.bin"), to: root.appending(path: "a/hard.bin"))
        let bytes = SandboxSize.bytes(under: root)
        // Allocated size rounds up to the block; the hard link and the symlink add nothing.
        #expect(bytes >= 110_000 && bytes < 200_000)
        #expect(SandboxSize.bytes(under: [root, root]) == bytes)
        #expect(SandboxSize.bytes(under: root.appending(path: "nowhere")) == 0)
    }

    @Test func textIsShort() {
        #expect(SandboxSize.text(0) == "0 B")
        #expect(SandboxSize.text(999) == "999 B")
        #expect(SandboxSize.text(12_300) == "12 KB")
        #expect(SandboxSize.text(1_234_000) == "1.2 MB")
        #expect(SandboxSize.text(45_600_000_000) == "46 GB")
    }

    @Test func largestKeepsTheHeaviest() {
        let sizes: [String: Int64] = ["a": 10, "b": 30, "c": 20, "d": 30]
        #expect(SandboxSize.largest(sizes, count: 3).map(\.key) == ["b", "d", "c"])
    }
}
