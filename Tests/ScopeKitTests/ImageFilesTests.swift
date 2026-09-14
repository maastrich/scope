import Foundation
import Testing
import ScopeCore
@testable import ScopeGit

@Suite(.serialized) struct ImageFilesTests {
    @Test func detectsImagesByExtensionCaseInsensitively() {
        #expect(ImageFiles.isImage("assets/logo.png"))
        #expect(ImageFiles.isImage("Shot.JPG"))
        #expect(ImageFiles.isImage("a/b/c.webp"))
        #expect(!ImageFiles.isImage("icon.svg"))
        #expect(!ImageFiles.isImage("README.md"))
        #expect(!ImageFiles.isImage("png"))
    }

    @Test func readsDiskFilesAndBlobsAtARef() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api")
        let client = await scope.client(for: repo)
        let old = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        let new = Data([0x89, 0x50, 0x4E, 0x47, 0x02, 0x03])
        try old.write(to: repo.appending(path: "logo.png"))
        try await scope.commit(in: repo, "add logo")
        try new.write(to: repo.appending(path: "logo.png"))

        #expect(try ImageFiles.read(at: repo.appending(path: "logo.png")) == new)
        #expect(try ImageFiles.read(at: repo.appending(path: "missing.png")) == nil)
        #expect(try ImageFiles.read(at: repo) == nil)
        #expect(try await ImageFiles.blob("logo.png", at: "HEAD", in: repo, using: client) == old)
        #expect(try await ImageFiles.blob("missing.png", at: "HEAD", in: repo, using: client) == nil)
    }

    @Test func refusesOversizedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "scope-imagefiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "huge.png")
        try Data(count: ImageFiles.maxBytes + 1).write(to: url)
        #expect(throws: BaseError.fileTooLarge(path: url.path, bytes: ImageFiles.maxBytes + 1)) { try ImageFiles.read(at: url) }
    }
}
