import Foundation
import Testing
import ScopeCore

/// The base every child of the app starts from: never `install`ed here — it is process-wide and other suites spawn
/// git in parallel — only `compose`d.
struct SubprocessEnvironmentTests {
    private let home = "/Users/u"
    private let launchd = "/usr/bin:/bin:/usr/sbin:/sbin"

    private func everyFolder(_: String) -> Bool { true }

    @Test func fallbackPutsHomebrewBeforeLaunchdPATHAndUserFoldersAfter() {
        let base = SubprocessEnvironment.compose(["PATH": launchd, "HOME": home], source: .fallback, home: home,
                                                 isDirectory: everyFolder)
        #expect(base["PATH"] == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:\(launchd):/Users/u/.local/bin:/Users/u/.cargo/bin")
        #expect(base["HOME"] == home)
    }

    @Test func fallbackSkipsFoldersThatDoNotExist() {
        let base = SubprocessEnvironment.compose(["PATH": launchd], source: .fallback, home: home,
                                                 isDirectory: { $0 == "/opt/homebrew/bin" })
        #expect(base["PATH"] == "/opt/homebrew/bin:\(launchd)")
    }

    @Test func probedPATHComesFirstAndOnlyMissingFoldersAreAppended() {
        let probed = "/Users/u/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        let base = SubprocessEnvironment.compose(["PATH": probed, "SSH_AUTH_SOCK": "/tmp/agent"], source: .probed, home: home,
                                                 isDirectory: everyFolder)
        // Nothing the shell listed moves; a thread's PATH is a prefix of git's.
        #expect(base["PATH"] == "\(probed):/opt/homebrew/sbin:/usr/local/bin:/Users/u/.cargo/bin")
        #expect(base["SSH_AUTH_SOCK"] == "/tmp/agent")
    }

    @Test func probedVariablesLoseWhatDescribesTheProbeShell() {
        let base = SubprocessEnvironment.compose(
            ["PATH": "/usr/bin", "PWD": "/", "OLDPWD": "/tmp", "SHLVL": "2", "_": "/usr/bin/env", "TERM": "dumb",
             "SCOPE_ENV_PROBE": "1", "LANG": "fr_FR.UTF-8"],
            source: .probed, home: home, isDirectory: { _ in false })
        #expect(Set(base.keys) == ["PATH", "LANG"])
    }

    @Test func duplicatesAreDroppedKeepingTheFirst() {
        let base = SubprocessEnvironment.compose(["PATH": "/usr/local/bin:/usr/bin:/usr/local/bin"], source: .fallback,
                                                 home: home, isDirectory: { $0 == "/usr/local/bin" })
        #expect(base["PATH"] == "/usr/local/bin:/usr/bin")
    }

    @Test func emptyPATHStillGetsTheFallbackFolders() {
        let base = SubprocessEnvironment.compose([:], source: .fallback, home: home, isDirectory: everyFolder)
        #expect(base["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
    }

    @Test func nothingInstalledMeansTheProcessEnvironment() {
        // The command line and the tests never install a base: their children see what they were started with.
        guard !SubprocessEnvironment.isInstalled else { return }
        #expect(SubprocessEnvironment.current == ProcessInfo.processInfo.environment)
    }
}
