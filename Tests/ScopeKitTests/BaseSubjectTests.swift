import Testing
import ScopeCore
@testable import ScopeTasks

@Suite struct BaseSubjectTests {
    private let root = "/work/acme"
    private let repos = ["api", "infra", "web"]

    private func taskRepo(_ path: String, task: String = "refresh") -> TaskRepo {
        TaskRepo(repoRelativePath: path, sandboxPath: "/home/sandboxes/acme/\(task)/\(path)", branch: "scope/\(task)")
    }

    private func resolve(pin: String? = nil, selectedRepo: String? = nil, threadDirectory: String? = nil,
                         taskRepos: [TaskRepo] = [], deltaFocus: String? = nil, recent: String? = nil) -> BaseSubject? {
        BaseSubjectResolver.resolve(BaseSubjectInput(scopeRoot: root, repos: repos, pin: pin, selectedRepo: selectedRepo,
                                                     threadDirectory: threadDirectory, taskRepos: taskRepos,
                                                     deltaFocus: deltaFocus, recent: recent))
    }

    @Test func scopeWithNothingSelectedShowsItsFirstRepository() {
        #expect(resolve() == BaseSubject(repo: "api", reason: .first))
    }

    @Test func scopeWithoutRepositoriesHasNoSubject() {
        #expect(BaseSubjectResolver.resolve(BaseSubjectInput(scopeRoot: root, repos: [])) == nil)
    }

    @Test func scopeReturnsToTheRepositoryItLastShowed() {
        #expect(resolve(recent: "web") == BaseSubject(repo: "web", reason: .recent))
    }

    @Test func selectedRepoRowIsShown() {
        #expect(resolve(selectedRepo: "infra", recent: "web") == BaseSubject(repo: "infra", reason: .selection))
    }

    @Test func taskShowsItsFirstRepository() {
        #expect(resolve(taskRepos: [taskRepo("web"), taskRepo("api")], recent: "infra") == BaseSubject(repo: "web", reason: .task))
    }

    @Test func threadInASandboxShowsTheRepositoryItIsAWorktreeOf() {
        let task = [taskRepo("api"), taskRepo("web")]
        let subject = resolve(threadDirectory: "/home/sandboxes/acme/refresh/web/src/auth", taskRepos: task)
        #expect(subject == BaseSubject(repo: "web", reason: .thread))
    }

    @Test func threadAtTheRootOfAMultiRepoTaskFallsBackToTheTask() {
        let task = [taskRepo("api"), taskRepo("web")]
        #expect(resolve(threadDirectory: "/home/sandboxes/acme/refresh", taskRepos: task) == BaseSubject(repo: "api", reason: .task))
    }

    @Test func looseThreadThatMovedIntoARepositoryShowsIt() {
        #expect(resolve(threadDirectory: "/work/acme/infra/terraform") == BaseSubject(repo: "infra", reason: .thread))
    }

    @Test func looseThreadAtTheScopeRootIsInsideNoRepository() {
        #expect(resolve(threadDirectory: "/work/acme", recent: "web") == BaseSubject(repo: "web", reason: .recent))
    }

    @Test func aSiblingWithTheSamePrefixIsNotTheRepository() {
        #expect(resolve(threadDirectory: "/work/acme/api-gateway") == BaseSubject(repo: "api", reason: .first))
    }

    @Test func deltaFocusWinsOverTheTaskOrderOnceTheThreadSaysNothing() {
        let task = [taskRepo("api"), taskRepo("web")]
        #expect(resolve(taskRepos: task, deltaFocus: "web") == BaseSubject(repo: "web", reason: .delta))
    }

    @Test func deltaFocusOutsideTheTaskIsIgnored() {
        #expect(resolve(taskRepos: [taskRepo("api")], deltaFocus: "web") == BaseSubject(repo: "api", reason: .task))
    }

    @Test func pinWinsOverEverything() {
        let task = [taskRepo("api"), taskRepo("web")]
        let subject = resolve(pin: "infra", selectedRepo: "web", threadDirectory: "/home/sandboxes/acme/refresh/web",
                              taskRepos: task, deltaFocus: "web")
        #expect(subject == BaseSubject(repo: "infra", reason: .pinned))
    }

    @Test func pinOnARepositoryTheScopeNoLongerHasFallsThrough() {
        #expect(resolve(pin: "gone", taskRepos: [taskRepo("web")]) == BaseSubject(repo: "web", reason: .task))
    }

    @Test func repoScopeUsesTheDotKey() {
        let input = BaseSubjectInput(scopeRoot: "/work/solo", repos: [""], threadDirectory: "/work/solo/src")
        #expect(BaseSubjectResolver.resolve(input) == BaseSubject(repo: ".", reason: .thread))
    }

    @Test func nestedRepositoryIsPreferredToItsParent() {
        let input = BaseSubjectInput(scopeRoot: root, repos: ["libs", "libs/ui"], threadDirectory: "/work/acme/libs/ui/src")
        #expect(BaseSubjectResolver.resolve(input) == BaseSubject(repo: "libs/ui", reason: .thread))
    }

    @Test func contextKeysAreDistinctPerKind() {
        let id = "0123456789ab"
        let keys = [BaseContext.task(TaskID(rawValue: id)!).key, BaseContext.thread(ThreadID(rawValue: id)!).key]
        #expect(keys == ["task:\(id)", "thread:\(id)"])
    }
}
