import Foundation
import ScopeCore
import ScopeTasks
import Testing

@Suite("Pull request references")
struct PullRequestReferenceTests {
    @Test("a GitHub pull request URL is recognised in a sentence")
    func urlInProse() {
        let reference = PullRequestReference.detect(in: "rebase la pr https://github.com/acme-devops/acme-front/pull/6613 stp")
        #expect(reference?.number == 6613)
        #expect(reference?.host == "github.com")
        #expect(reference?.owner == "acme-devops")
        #expect(reference?.repo == "acme-front")
        #expect(reference?.isBare == false)
        #expect(reference?.label == "acme-devops/acme-front#6613")
    }

    @Test("the shapes GitHub links out with all resolve to the same reference")
    func urlVariants() {
        let variants = [
            "https://github.com/acme/front/pull/12",
            "http://github.com/acme/front/pull/12",
            "https://www.github.com/acme/front/pull/12/files",
            "github.com/acme/front/pull/12",
            "https://github.com/acme/front/pull/12#discussion_r123",
            "https://github.com/acme/front/pull/12/commits/0ff1ce0",
            "<https://github.com/acme/front/pull/12>",
        ]
        for variant in variants {
            let reference = PullRequestReference.detect(in: variant)
            #expect(reference?.number == 12, "\(variant)")
            #expect(reference?.owner == "acme", "\(variant)")
            #expect(reference?.repo == "front", "\(variant)")
        }
    }

    @Test("an Enterprise host works, and .git is stripped")
    func enterpriseHost() {
        let reference = PullRequestReference.detect(in: "https://git.acme.internal/team/api.git/pull/7")
        #expect(reference?.host == "git.acme.internal")
        #expect(reference?.repo == "api")
        #expect(reference?.number == 7)
    }

    @Test("owner/repo#123 and a bare #123")
    func shorthands() {
        let shorthand = PullRequestReference.detect(in: "port the fix from acme/front#88 please")
        #expect(shorthand?.number == 88)
        #expect(shorthand?.owner == "acme")
        #expect(shorthand?.repo == "front")

        let bare = PullRequestReference.detect(in: "review #4211 and merge it")
        #expect(bare?.number == 4211)
        #expect(bare?.isBare == true)
        #expect(bare?.owner == nil)
    }

    @Test("issues, discussions and plain numbers are not pull requests")
    func falsePositives() {
        #expect(PullRequestReference.detect(in: "https://github.com/acme/front/issues/6613") == nil)
        #expect(PullRequestReference.detect(in: "https://github.com/acme/front/discussions/17") == nil)
        #expect(PullRequestReference.detect(in: "bump the timeout to 6613 ms") == nil)
        #expect(PullRequestReference.detect(in: "the colour is #ff8800") == nil)
        #expect(PullRequestReference.detect(in: "add a rate limiter to the checkout API") == nil)
    }

    @Test("a reference matches the remote it names, and only that one")
    func remoteMatching() {
        let reference = PullRequestReference.detect(in: "https://github.com/acme-devops/acme-front/pull/6613")!
        #expect(reference.matches(RemoteInfo(remote: "git@github.com:acme-devops/acme-front.git")))
        #expect(reference.matches(RemoteInfo(remote: "https://github.com/ACME-DevOps/Acme-Front")))
        #expect(!reference.matches(RemoteInfo(remote: "git@github.com:acme-devops/acme-api.git")))
        #expect(!reference.matches(RemoteInfo(remote: "git@github.com:someone/acme-front.git")))
        #expect(!reference.matches(RemoteInfo(remote: "git@gitlab.com:acme-devops/acme-front.git")))
        #expect(!reference.matches(nil))
    }

    @Test("a reference given on purpose may be a plain number")
    func explicitReference() {
        #expect(PullRequestReference.parse("123") == PullRequestReference(number: 123))
        #expect(PullRequestReference.parse(" #123 ") == PullRequestReference(number: 123))
        #expect(PullRequestReference.parse("acme/front#88") == PullRequestReference(number: 88, owner: "acme", repo: "front"))
        #expect(PullRequestReference.parse("https://github.com/acme/front/pull/12")?.number == 12)
        #expect(PullRequestReference.parse("0") == nil)
        #expect(PullRequestReference.parse("the login one") == nil)
    }

    @Test("a reference given on its own, or asked to be worked on, is the start point", arguments: [
        ("#4211", 4211),
        ("https://github.com/acme/front/pull/12", 12),
        ("PR #4211 please", 4211),
        ("review #4211 and merge it", 4211),
        ("Review PR #4211", 4211),
        ("rebase la pr https://github.com/acme-devops/acme-front/pull/6613 stp", 6613),
        ("please fix the CI on acme/front#88", 88),
        ("can you take over https://github.com/acme/front/pull/12? the author left", 12),
        ("address the review comments on #42", 42),
        ("reprends la PR #31 et finis les tests", 31),
        ("Context: this follows #37.\nReview #40 before it ships.", 40),
        ("https://github.com/acme/front/pull/12\nfix the failing test", 12),
        ("#6613: address the review comments", 6613),
    ])
    func startPoints(prompt: String, number: Int) {
        #expect(PullRequestReference.startPoint(in: prompt)?.number == number, "\(prompt)")
    }

    @Test("a reference cited as context is not the start point", arguments: [
        // What happened: a long brief that cites a research note's pull request on its first line.
        """
        Wave 1 of the "Scope usage ideas" plan (context: docs/research/usage-ideas.md, #37). Two frictions met today.

        # C10: a pull request merely cited in a brief must not become the start point
        Fix the proposer so that a cited reference stays context.
        """,
        "fix the bug introduced in #37",
        "port the fix from acme/front#88 please",
        "add a rate limiter like the one in https://github.com/acme/api/pull/7",
        "see #37 for the research, then build the sidebar it describes",
        "The review of #37 found a race in the socket server; fix it.",
    ])
    func citations(prompt: String) {
        #expect(PullRequestReference.detect(in: prompt) != nil, "the reference is still found")
        #expect(PullRequestReference.startPoint(in: prompt) == nil, "\(prompt)")
    }

    @Test("a bare reference matches any remote — the caller restricts it to one repository")
    func bareMatchesAnything() {
        let bare = PullRequestReference.detect(in: "#4211")!
        #expect(bare.matches(RemoteInfo(remote: "git@github.com:acme/front.git")))
    }
}

@Suite("Task targets")
struct TaskTargetsTests {
    private let candidates = [
        RepoCandidate(path: "front", name: "front", remote: RemoteInfo(remote: "git@github.com:acme-devops/acme-front.git")),
        RepoCandidate(path: "api", name: "api", remote: RemoteInfo(remote: "git@github.com:acme-devops/checkout-api.git")),
        RepoCandidate(path: "packages/design-system", name: "design-system", remote: nil),
    ]

    @Test("a pull request URL resolves through the remote, not the folder name")
    func resolvesThroughRemote() {
        let reference = PullRequestReference.detect(in: "rebase https://github.com/acme-devops/acme-front/pull/6613")!
        #expect(TaskTargets.repo(for: reference, among: candidates)?.path == "front")
    }

    @Test("a pull request of a repository outside the scope resolves to nothing")
    func unknownRepository() {
        let reference = PullRequestReference.detect(in: "https://github.com/other/thing/pull/1")!
        #expect(TaskTargets.repo(for: reference, among: candidates) == nil)
    }

    @Test("a bare #123 only resolves when the scope holds a single repository")
    func bareNeedsASingleRepo() {
        let reference = PullRequestReference.detect(in: "look at #123")!
        #expect(TaskTargets.repo(for: reference, among: candidates) == nil)
        #expect(TaskTargets.repo(for: reference, among: [candidates[0]])?.path == "front")
    }

    @Test("repositories named in the prompt are found by name, path or remote")
    func reposNamedInPrompt() {
        #expect(TaskTargets.repos(namedIn: "fix the cart total in front", among: candidates) == ["front"])
        #expect(TaskTargets.repos(namedIn: "move the button into packages/design-system", among: candidates) == ["packages/design-system"])
        #expect(TaskTargets.repos(namedIn: "acme-devops/checkout-api is timing out", among: candidates) == ["api"])
        #expect(TaskTargets.repos(namedIn: "wire the api to the front", among: candidates) == ["front", "api"])
    }

    @Test("a name inside a longer word is not a mention")
    func noSubstringMatches() {
        #expect(TaskTargets.repos(namedIn: "the storefront is slow", among: candidates).isEmpty)
        #expect(TaskTargets.repos(namedIn: "rewrite the apiary importer", among: candidates).isEmpty)
        // A separator is a boundary: the full remote name still names the repo.
        #expect(TaskTargets.repos(namedIn: "acme-front is slow", among: candidates) == ["front"])
    }

    @Test("an existing branch named in the prompt is found, longest match first")
    func branchNamedInPrompt() {
        let branches = ["main", "feat/auth", "feat/auth-refresh", "chore/bump"]
        #expect(TaskTargets.branch(namedIn: "continue feat/auth-refresh", among: branches) == "feat/auth-refresh")
        #expect(TaskTargets.branch(namedIn: "back to feat/auth please", among: branches) == "feat/auth")
        #expect(TaskTargets.branch(namedIn: "add a login form", among: branches) == nil)
    }
}
