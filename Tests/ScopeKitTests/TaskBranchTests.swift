import Foundation
import Testing
@testable import ScopeGit

@Suite struct TaskBranchTests {
    @Test func defaultPrefixAndSlug() {
        #expect(TaskBranch.name(prefix: "scope", taskName: "Auth Refresh (v2)!") == "scope/auth-refresh-v2")
    }

    @Test func diacriticsAreFolded() {
        #expect(TaskBranch.name(prefix: "scope", taskName: "Éléphant à l'école") == "scope/elephant-a-l-ecole")
    }

    @Test func emptyPrefixGivesBareSlug() {
        #expect(TaskBranch.name(prefix: "", taskName: "hello world") == "hello-world")
        #expect(TaskBranch.name(prefix: "  /  ", taskName: "hello world") == "hello-world")
    }

    @Test func prefixComponentsAreSlugified() {
        #expect(TaskBranch.name(prefix: "Mathis P/wip", taskName: "Fix login") == "mathis-p/wip/fix-login")
        #expect(TaskBranch.name(prefix: "/scope/", taskName: "x") == "scope/x")
    }

    @Test func emptyTaskNameFallsBack() {
        #expect(TaskBranch.name(prefix: "scope", taskName: "") == "scope/task")
        #expect(TaskBranch.name(prefix: "scope", taskName: "!!!") == "scope/task")
        #expect(TaskBranch.slug(for: "   ") == TaskBranch.fallbackSlug)
    }

    @Test func slugIsGitRefSafe() {
        let name = TaskBranch.name(prefix: "scope", taskName: "weird..name  ~^:?*[\\ end.lock")
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-/")
        #expect(name.allSatisfy { allowed.contains($0) })
        #expect(!name.contains(".."))
        #expect(!name.hasSuffix("/"))
    }
}
