import Foundation
import Testing
import ScopeCore
@testable import ScopeTasks

@Suite struct TaskProjectionTests {
    private var task: TaskRecord {
        TaskRecord(
            scopeID: ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10"), scopeRoot: "/s/acme", scopeSlug: "acme", scopeName: "Acme",
            name: "Auth", slug: "auth", branch: "scope/auth", root: "/h/sandboxes/acme/auth",
            repos: [TaskRepo(repoRelativePath: "api", sandboxPath: "/h/sandboxes/acme/auth/api", branch: "scope/auth")],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test func purposeLinesForTaskAndOtherRepos() {
        let summaries = [
            RepoContextSummary(path: "api", purpose: "The backend.", stack: ["node", "typescript"], setup: "pnpm install", test: "pnpm test"),
            RepoContextSummary(path: "web/", purpose: "The front.", stack: ["node"]),
            RepoContextSummary(path: "docs"),   // no purpose: name only
        ]
        let md = TaskProjection.agentsMarkdown(task: task, otherRepos: ["web", "docs"], scopeName: "Acme", repoSummaries: summaries)
        #expect(md.contains("""
        - **api** — sandbox: `/h/sandboxes/acme/auth/api` (branch `scope/auth`)
          - Purpose: The backend.
          - Stack: node, typescript
          - Setup: `pnpm install`
          - Test: `pnpm test`
        """))
        #expect(md.contains("## Other repositories of the scope\n\nNot part of this task. Ask before adding one to the task.\n\n- docs\n- **web** — The front.\n"))
        #expect(md.hasPrefix(TaskProjection.generatedMarker))
    }

    @Test func withoutSummariesOutputIsUnchanged() {
        let md = TaskProjection.agentsMarkdown(task: task, otherRepos: ["web"], scopeName: "Acme")
        #expect(md.contains("- **api** — sandbox: `/h/sandboxes/acme/auth/api` (branch `scope/auth`)\n\n## Other"))
        #expect(md.contains("\n- web\n") && !md.contains("Purpose:"))
    }
}
