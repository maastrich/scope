import Foundation
import Testing
@testable import ScopeAdapters

@Suite struct SocketPathTests {
    @Test func shortHomeUsesTheHomeSocket() {
        let home = URL(fileURLWithPath: "/Users/me/.scope", isDirectory: true)
        let path = SocketPath.resolve(home: home, tmp: "/tmp/", uid: 501)
        #expect(path == "/Users/me/.scope/scope.sock")
    }

    @Test func longHomeFallsBackToTemporaryDirectory() {
        let deep = "/Users/me/" + String(repeating: "abcdefghij", count: 11)   // 120+ chars
        let home = URL(fileURLWithPath: deep, isDirectory: true)
        let path = SocketPath.resolve(home: home, tmp: "/var/folders/xx/T/", uid: 501)
        #expect(path == "/var/folders/xx/T/scope-501.sock")
        #expect(SocketPath.fits(path))
    }

    @Test func boundaryIsOneHundredAndThreeBytes() {
        // "/scope.sock" is 11 bytes: a 92-byte home still fits, a 93-byte one does not.
        let fitting = "/" + String(repeating: "a", count: 91)
        let tooLong = "/" + String(repeating: "a", count: 92)
        #expect(SocketPath.resolve(home: URL(fileURLWithPath: fitting, isDirectory: true), tmp: "/tmp", uid: 1) == fitting + "/scope.sock")
        #expect(SocketPath.resolve(home: URL(fileURLWithPath: tooLong, isDirectory: true), tmp: "/tmp", uid: 1) == "/tmp/scope-1.sock")
        #expect(SocketPath.fits(String(repeating: "b", count: 103)))
        #expect(!SocketPath.fits(String(repeating: "b", count: 104)))
    }

    @Test func multibyteHomeIsMeasuredInBytes() {
        // "é" is 2 bytes precomposed and 3 bytes decomposed (`URL.path` may return either form), plus
        // "/Users/" (7) and "/scope.sock" (11):
        // 20 × "é" → 58 or 78 bytes: fits either way.
        // 45 × "é" → 108 or 153 bytes: too long either way, although it is only 63 characters.
        let fitting = URL(fileURLWithPath: "/Users/" + String(repeating: "é", count: 20), isDirectory: true)
        let tooLong = URL(fileURLWithPath: "/Users/" + String(repeating: "é", count: 45), isDirectory: true)
        #expect(SocketPath.resolve(home: fitting, tmp: "/tmp", uid: 7).hasSuffix("/scope.sock"))
        #expect(SocketPath.resolve(home: tooLong, tmp: "/tmp", uid: 7) == "/tmp/scope-7.sock")
    }

    @Test func defaultsPointAtTheCurrentUserAndTemporaryDirectory() {
        let deep = "/" + String(repeating: "x", count: 150)
        let path = SocketPath.resolve(home: URL(fileURLWithPath: deep, isDirectory: true))
        #expect(path.hasSuffix("/scope-\(getuid()).sock"))
        #expect(path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).path))
        #expect(SocketPath.fits(path))
    }
}
