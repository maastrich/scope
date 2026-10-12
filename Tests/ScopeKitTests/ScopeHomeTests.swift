import Foundation
import Testing
@testable import ScopeCore

@Suite("ScopeHome")
struct ScopeHomeTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    @Test("a Debug build ignores a SCOPE_HOME it inherited from a thread")
    func debugIgnoresInheritedHome() {
        let env = ["SCOPE_HOME": "/Users/someone/.scope", "SCOPE_THREAD": "8a18d7476063"]
        let url = ScopeHome.appURL(environment: env, debugBuild: true)
        #expect(url == home.appending(path: ".scope-debug", directoryHint: .isDirectory))
    }

    @Test("a Debug build still obeys a SCOPE_HOME set by hand")
    func debugObeysDeliberateHome() {
        let env = ["SCOPE_HOME": "/tmp/scope-demo"]
        let url = ScopeHome.appURL(environment: env, debugBuild: true)
        #expect(url.path == "/tmp/scope-demo")
    }

    @Test("a Debug build with no override lands in .scope-debug")
    func debugDefault() {
        let url = ScopeHome.appURL(environment: [:], debugBuild: true)
        #expect(url == home.appending(path: ".scope-debug", directoryHint: .isDirectory))
    }

    @Test("a release build honours SCOPE_HOME however it arrived")
    func releaseHonoursInheritedHome() {
        let env = ["SCOPE_HOME": "/tmp/scope-prod", "SCOPE_THREAD": "8a18d7476063"]
        let url = ScopeHome.appURL(environment: env, debugBuild: false)
        #expect(url.path == "/tmp/scope-prod")
    }

    @Test("a release build with no override lands in .scope")
    func releaseDefault() {
        let url = ScopeHome.appURL(environment: [:], debugBuild: false)
        #expect(url == home.appending(path: ".scope", directoryHint: .isDirectory))
    }
}
