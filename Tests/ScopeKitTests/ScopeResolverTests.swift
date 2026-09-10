import Foundation
import Testing
@testable import ScopeControl

/// Turning "acme", "/Users/me/work/acme" or nothing at all into one scope.
@Suite struct ScopeResolverTests {
    static func scope(_ slug: String, path: String, name: String? = nil, repos: [String] = []) -> ScopeSummary {
        ScopeSummary(id: "id-\(slug)", slug: slug, name: name ?? slug, path: path, status: "ok", repos: repos)
    }

    static let scopes = [
        scope("acme", path: "/Users/me/work/acme", name: "Acme", repos: ["api", "web", "services/api"]),
        scope("scope", path: "/Users/me/contributions/scope", name: "Scope"),
        scope("acme-infra", path: "/Users/me/work/acme/infra", name: "Acme"),
    ]

    @Test func aSlugWins() throws {
        #expect(try ScopeResolver.resolve("acme", in: Self.scopes).get().slug == "acme")
    }

    @Test func anIDWorks() throws {
        #expect(try ScopeResolver.resolve("id-scope", in: Self.scopes).get().slug == "scope")
    }

    @Test func aPathResolvesToTheScopeHoldingIt() throws {
        #expect(try ScopeResolver.resolve("/Users/me/work/acme/api", in: Self.scopes).get().slug == "acme")
    }

    /// Nested scopes: the deepest root wins, not the first declared.
    @Test func theDeepestScopeWinsForAPath() throws {
        #expect(try ScopeResolver.resolve("/Users/me/work/acme/infra/terraform", in: Self.scopes).get().slug == "acme-infra")
    }

    /// A slug is unique, a name is not: an exact slug match wins even when the name is ambiguous.
    @Test func aSlugBeatsAnAmbiguousName() throws {
        #expect(try ScopeResolver.resolve("Acme", in: Self.scopes).get().slug == "acme")
    }

    @Test func anAmbiguousNameIsAnErrorRatherThanAGuess() {
        let twins = [Self.scope("first", path: "/a", name: "Platform"), Self.scope("second", path: "/b", name: "Platform")]
        guard case .failure(let error) = ScopeResolver.resolve("platform", in: twins) else {
            Issue.record("two scopes are called Platform")
            return
        }
        #expect(error.code == .badRequest)
        #expect(error.detail?.contains("second") == true)
    }

    @Test func anUnknownScopeListsTheChoices() {
        guard case .failure(let error) = ScopeResolver.resolve("nope", in: Self.scopes) else {
            Issue.record("there is no scope called nope")
            return
        }
        #expect(error.code == .notFound)
        #expect(error.detail?.contains("acme") == true)
    }

    @Test func withoutAQueryTheCallersScopeWins() throws {
        let resolved = try ScopeResolver.resolve(nil, in: Self.scopes, callerScopeID: "id-scope",
                                                 callerCwd: "/Users/me/work/acme").get()
        #expect(resolved.slug == "scope")
    }

    @Test func withoutAQueryOrACallerTheWorkingDirectoryDecides() throws {
        let resolved = try ScopeResolver.resolve(nil, in: Self.scopes, callerCwd: "/Users/me/work/acme/web").get()
        #expect(resolved.slug == "acme")
    }

    @Test func aSingleScopeNeedsNoNaming() throws {
        let one = [Self.scope("only", path: "/tmp/only")]
        #expect(try ScopeResolver.resolve(nil, in: one, callerCwd: "/elsewhere").get().slug == "only")
    }

    @Test func severalScopesAndNoHintIsAQuestion() {
        guard case .failure(let error) = ScopeResolver.resolve(nil, in: Self.scopes, callerCwd: "/elsewhere") else {
            Issue.record("nothing says which scope")
            return
        }
        #expect(error.code == .badRequest)
        #expect(error.detail?.contains("--scope") == true)
    }

    @Test func noScopeAtAllSaysSo() {
        guard case .failure(let error) = ScopeResolver.resolve("acme", in: []) else {
            Issue.record("an empty Scope has no scope")
            return
        }
        #expect(error.code == .notFound)
    }

    @Test func aRepoMatchesExactlyThenBySuffix() throws {
        let acme = Self.scopes[0]
        #expect(try ScopeResolver.resolveRepo("api", in: acme).get() == "api")
        #expect(try ScopeResolver.resolveRepo("services/api", in: acme).get() == "services/api")
        #expect(try ScopeResolver.resolveRepo("/web/", in: acme).get() == "web")
        #expect(try ScopeResolver.resolveRepo(".", in: acme).get() == ".")
    }

    @Test func anUnknownRepoListsWhatThereIs() {
        guard case .failure(let error) = ScopeResolver.resolveRepo("database", in: Self.scopes[0]) else {
            Issue.record("no such repository")
            return
        }
        #expect(error.code == .notFound)
        #expect(error.detail?.contains("web") == true)
    }
}
