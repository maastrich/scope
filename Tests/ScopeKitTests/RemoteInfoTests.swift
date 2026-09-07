import Foundation
import Testing
@testable import ScopeCore

@Suite struct RemoteInfoTests {
    @Test(arguments: [
        ("git@github.com:acme/api.git", "github.com", "acme", "api"),
        ("git@github.com:acme/api", "github.com", "acme", "api"),
        ("ssh://git@github.com/acme/api.git", "github.com", "acme", "api"),
        ("ssh://git@github.com:2222/acme/api", "github.com", "acme", "api"),
        ("https://github.com/acme/api.git", "github.com", "acme", "api"),
        ("https://user@gitlab.com/group/sub/api.git", "gitlab.com", "sub", "api"),
        ("git://github.com/acme/api.git", "github.com", "acme", "api"),
        ("file:///Users/me/src/api", nil, "src", "api"),
        ("/Users/me/src/api/", nil, "src", "api"),
    ] as [(String, String?, String?, String)])
    func parsesEveryVerifiedRemoteForm(remote: String, host: String?, owner: String?, name: String) throws {
        let info = try #require(RemoteInfo(remote: remote))
        #expect(info.host == host)
        #expect(info.owner == owner)
        #expect(info.name == name)
        #expect(info.fullName == "\(owner.map { $0 + "/" } ?? "")\(name)")
    }

    @Test func toleratesSurroundingWhitespace() throws {
        let info = try #require(RemoteInfo(remote: "  https://github.com/acme/api.git\n"))
        #expect(info.fullName == "acme/api")
    }

    @Test func repoWithoutOwnerHasBareFullName() throws {
        let info = try #require(RemoteInfo(remote: "https://example.com/api.git"))
        #expect(info.host == "example.com")
        #expect(info.owner == nil)
        #expect(info.fullName == "api")
    }

    @Test func rejectsEmptyAndPathlessRemotes() {
        #expect(RemoteInfo(remote: "") == nil)
        #expect(RemoteInfo(remote: "   ") == nil)
        #expect(RemoteInfo(remote: "https://github.com") == nil)
        #expect(RemoteInfo(remote: "https://github.com/") == nil)
        #expect(RemoteInfo(remote: "git@github.com:.git") == nil)
    }

    @Test func scpFormIsNotConfusedWithAWindowsStylePath() throws {
        // A colon after a slash is a path, not an scp host.
        let info = try #require(RemoteInfo(remote: "/Users/me/odd:name/api"))
        #expect(info.host == nil)
        #expect(info.owner == "odd:name")
        #expect(info.name == "api")
    }

    @Test func isHashableForSetsAndDictionaries() throws {
        let a = try #require(RemoteInfo(remote: "git@github.com:acme/api.git"))
        let b = try #require(RemoteInfo(remote: "ssh://git@github.com/acme/api.git"))
        #expect(Set([a, b]).count == 1)
    }
}

@Suite struct GitConfigReaderTests {
    private final class TempGitDirectory {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory
                .appending(path: "scope-gitconfig-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ text: String, to relativePath: String) throws {
            let file = url.appending(path: relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    @Test func readsTheOriginURLFromConfig() throws {
        let git = try TempGitDirectory()
        try git.write("""
        [core]
        \trepositoryformatversion = 0
        [remote "upstream"]
        \turl = https://github.com/other/api.git
        [remote "origin"]
        \turl = git@github.com:acme/api.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [branch "main"]
        \tremote = origin
        """, to: "config")

        #expect(GitConfigReader.originURL(gitDirectory: git.url) == "git@github.com:acme/api.git")
    }

    @Test func toleratesLooseSectionSpacingAndPushurl() throws {
        let git = try TempGitDirectory()
        try git.write("""
        [ remote  "origin" ]
            pushurl = git@github.com:acme/api-push.git
            url=https://github.com/acme/api.git
        """, to: "config")

        #expect(GitConfigReader.originURL(gitDirectory: git.url) == "https://github.com/acme/api.git")
    }

    @Test func missingOriginOrConfigGivesNil() throws {
        let git = try TempGitDirectory()
        #expect(GitConfigReader.originURL(gitDirectory: git.url) == nil, "no config file yet")

        try git.write("[core]\n\tbare = false\n[remote \"upstream\"]\n\turl = x\n", to: "config")
        #expect(GitConfigReader.originURL(gitDirectory: git.url) == nil)
    }

    @Test func followsCommondirForWorktrees() throws {
        let git = try TempGitDirectory()
        try git.write("[remote \"origin\"]\n\turl = git@github.com:acme/api.git\n", to: "config")
        try git.write("../..\n", to: "worktrees/demo/commondir")

        let worktreeGitDirectory = git.url.appending(path: "worktrees/demo", directoryHint: .isDirectory)
        #expect(GitConfigReader.originURL(gitDirectory: worktreeGitDirectory) == "git@github.com:acme/api.git")
    }

    @Test func absoluteCommondirIsHonoured() throws {
        let common = try TempGitDirectory()
        try common.write("[remote \"origin\"]\n\turl = https://github.com/acme/api.git\n", to: "config")
        let worktree = try TempGitDirectory()
        try worktree.write(common.url.path + "\n", to: "commondir")

        #expect(GitConfigReader.originURL(gitDirectory: worktree.url) == "https://github.com/acme/api.git")
    }
}
