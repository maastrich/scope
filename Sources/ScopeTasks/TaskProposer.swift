import Foundation
import ScopeCore
import ScopeDrivers
import ScopeGit

/// What a repository's history says about its branch naming: recent branch names (remote and local) and
/// commit subjects. Gathered once per New Task sheet, given to the driver and to the fallback heuristics.
public struct BranchEvidence: Sendable, Equatable {
    /// Existing branch names without the remote part (`feat/login`, not `origin/feat/login`), most recently
    /// committed first, deduplicated. `HEAD` and the default branch are excluded.
    public var branches: [String]
    /// Subjects of the last commits of the default branch, newest first.
    public var commitSubjects: [String]
    /// The default branch (`main`), when known.
    public var defaultBranch: String?

    public init(branches: [String] = [], commitSubjects: [String] = [], defaultBranch: String? = nil) {
        self.branches = branches
        self.commitSubjects = commitSubjects
        self.defaultBranch = defaultBranch
    }

    /// How many remote / local branches are sampled.
    public static let branchSample = 40
    /// How many commit subjects are sampled.
    public static let commitSample = 30

    /// Conventional-Commit types, the prefixes a `<type>/<description>` branch convention uses.
    public static let conventionalTypes: Set<String> = ["feat", "fix", "chore", "docs", "refactor", "test", "perf", "ci", "build", "style", "revert"]

    /// Reads the evidence of every repo and merges it (branches of the first repo first).
    public static func gather(repos: [URL], registry: GitClientRegistry) async -> BranchEvidence {
        var merged = BranchEvidence()
        var seen = Set<String>()
        for repo in repos {
            let client = await registry.client(for: repo)
            let part = await gather(using: client)
            if merged.defaultBranch == nil { merged.defaultBranch = part.defaultBranch }
            for branch in part.branches where seen.insert(branch).inserted { merged.branches.append(branch) }
            merged.commitSubjects.append(contentsOf: part.commitSubjects)
        }
        merged.branches = Array(merged.branches.prefix(branchSample * 2))
        merged.commitSubjects = Array(merged.commitSubjects.prefix(commitSample * 2))
        return merged
    }

    /// `git branch -r` and `git branch` sorted by committer date, `git log` subjects; every failure yields an empty part.
    public static func gather(using client: GitClient) async -> BranchEvidence {
        let defaultBranch = await client.defaultBranch()
        var names: [String] = []
        for scope in ["-r", "--list"] {
            let args = ["branch", scope, "--sort=-committerdate", "--format=%(refname:short)"]
            guard let out = try? await client.output(args, timeout: .seconds(15)) else { continue }
            for line in out.split(separator: "\n").prefix(branchSample) {
                let raw = line.trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty, !raw.contains(" -> ") else { continue }
                names.append(raw)
            }
        }
        let logTarget = defaultBranch.map { name in ["log", "--no-merges", "-n", "\(commitSample)", "--format=%s", name] }
            ?? ["log", "--no-merges", "-n", "\(commitSample)", "--format=%s"]
        let subjects = ((try? await client.output(logTarget, timeout: .seconds(15))) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return BranchEvidence(branches: normalize(names, defaultBranch: defaultBranch), commitSubjects: subjects, defaultBranch: defaultBranch)
    }

    /// Strips `<remote>/`, drops `HEAD` and the default branch, deduplicates keeping the first occurrence.
    public static func normalize(_ names: [String], defaultBranch: String?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in names {
            var name = raw
            if name.hasPrefix("refs/remotes/") { name.removeFirst("refs/remotes/".count) }
            if name.hasPrefix("refs/heads/") { name.removeFirst("refs/heads/".count) }
            if let slash = name.firstIndex(of: "/"), ["origin", "upstream"].contains(String(name[..<slash])) {
                name = String(name[name.index(after: slash)...])
            }
            // `%(refname:short)` prints `origin` for `refs/remotes/origin/HEAD`.
            guard !name.isEmpty, name != "HEAD", !name.hasSuffix("/HEAD"), name != defaultBranch,
                  !["origin", "upstream"].contains(name) else { continue }
            if seen.insert(name).inserted { result.append(name) }
        }
        return result
    }

    /// `<prefix>/` counts among the branches (`feat` → 5, `mathis` → 3), the `scope` prefix excluded.
    public var prefixCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for branch in branches {
            guard let slash = branch.firstIndex(of: "/") else { continue }
            let prefix = String(branch[..<slash])
            guard !prefix.isEmpty, prefix != "scope" else { continue }
            counts[prefix, default: 0] += 1
        }
        return counts
    }

    /// `true` when at least 3 branches use Conventional-Commit types as prefixes (`feat/…`, `fix/…`).
    public var usesTypePrefixes: Bool {
        prefixCounts.filter { Self.conventionalTypes.contains($0.key) }.values.reduce(0, +) >= 3
    }

    /// The prefix at least 3 branches share (the most frequent), if any.
    public var dominantPrefix: String? {
        let counts = prefixCounts
        guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value >= 3 else { return nil }
        return best.key
    }

    /// `true` when most sampled commit subjects look like `type(scope): …` / `type: …`.
    public var usesConventionalCommits: Bool {
        guard !commitSubjects.isEmpty else { return false }
        let matching = commitSubjects.filter { subject in
            guard let colon = subject.firstIndex(of: ":") else { return false }
            var head = String(subject[..<colon])
            if head.hasSuffix("!") { head.removeLast() }
            if let paren = head.firstIndex(of: "(") { head = String(head[..<paren]) }
            return Self.conventionalTypes.contains(head)
        }
        return matching.count * 2 >= commitSubjects.count
    }
}

/// What the New Task sheet needs to create a task from a prompt: a short title, the sandbox folder name and
/// the branch. Produced by `TaskProposer` (driver, or the fallback heuristics).
public struct TaskProposal: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Suggested by the driver's headless run (`name` is the driver's display name).
        case driver(name: String)
        /// Derived from the prompt (`reason` says why the driver did not answer, nil when it was not asked).
        case derived(reason: String?)
    }

    /// At most `TaskProposer.titleLimit` characters.
    public var title: String
    /// Worktree folder name (a slug).
    public var slug: String
    /// Branch name; never `scope/…`.
    public var branch: String
    /// Relative paths of the repositories the task is about, as the driver read the request; always a subset
    /// of the candidates it was given. Empty when it named none — the sheet's own matching then stands.
    public var repos: [String]
    /// A pull request the driver recognised in the request (through `gh`, or from the prompt's own words).
    /// Only the reference: the caller resolves it, so a model's claim never becomes a checkout on its own.
    public var pullRequest: PullRequestReference?
    public var source: Source

    public init(title: String, slug: String, branch: String, repos: [String] = [],
                pullRequest: PullRequestReference? = nil, source: Source) {
        self.title = title
        self.slug = slug
        self.branch = branch
        self.repos = repos
        self.pullRequest = pullRequest
        self.source = source
    }

    public var isDerived: Bool { if case .derived = source { return true } else { return false } }
}

/// Proposes `{title, slug, branch, repos, pull request}` for a task request (spec: the driver decides the
/// branch name, following the repo's own convention; `scope/` is never used).
///
/// - Level 1: a **microsession** — the driver's `headlessLight` argv (its light model, with a read-only tool
///   allowlist) or, absent that, its `headless` argv — run with a strict-JSON meta-prompt carrying the
///   request, the branch evidence and the scope's repositories. Because the microsession has tools, it can
///   resolve a pull request the request only alludes to ("the auth PR on front") with `gh pr list`; it
///   answers with the *reference*, and the caller resolves it. The answer is validated
///   (`git check-ref-format`), sanitised and made unique; repository paths it invented are dropped.
/// - Level 0 (`fallback`): title from the first line of the prompt, slug from the title, branch from the
///   repo's dominant prefix, or `feat/` / `fix/` inferred from the request, or the bare slug.
public struct TaskProposer: Sendable {
    /// `git check-ref-format --branch <name>` or an equivalent; `true` when the name is acceptable.
    public typealias RefValidator = @Sendable (String) async -> Bool

    /// Longest accepted title.
    public static let titleLimit = 60
    /// Default headless timeout.
    public static let defaultTimeout: Duration = .seconds(30)
    /// Timeout for a microsession that may run tools (`gh pr list` against the network).
    public static let microsessionTimeout: Duration = .seconds(90)

    /// The driver asked for a proposal; nil (or a profile without `headless`) means fallback only.
    public var profile: DriverProfile?
    public var runner: any HeadlessRunner
    /// `SCOPE_HOME`, for the `{home}` placeholder.
    public var home: URL
    public var timeout: Duration
    public var validateRef: RefValidator

    public init(
        profile: DriverProfile?, runner: any HeadlessRunner, home: URL,
        timeout: Duration = TaskProposer.defaultTimeout,
        validateRef: @escaping RefValidator = { TaskProposer.isPlausibleRefName($0) }
    ) {
        self.profile = profile
        self.runner = runner
        self.home = home
        self.timeout = timeout
        self.validateRef = validateRef
    }

    /// A `RefValidator` backed by `git check-ref-format --branch` run through `client`.
    public static func gitRefValidator(client: GitClient) -> RefValidator {
        { name in
            guard isPlausibleRefName(name) else { return false }
            let result = try? await client.run(["check-ref-format", "--branch", name], timeout: .seconds(10), allowFailure: true)
            return result?.succeeded ?? false
        }
    }

    // MARK: - Level 1

    /// Asks the driver, then validates. Falls back to `fallback` (with the reason in `source`) when the profile
    /// has no `headless` argv, the run fails or times out, or the answer is unusable.
    ///
    /// - Parameters:
    ///   - prompt: the user's request.
    ///   - evidence: see `BranchEvidence.gather`.
    ///   - cwd: where the driver runs (the first repo's base checkout; read-only use).
    ///   - scopeRoot: `{scope}` placeholder.
    ///   - takenSlugs: task slugs already used in the scope (and folders under `sandboxes/<scope>/`).
    ///   - candidates: the scope's repositories, so the answer can name the ones the task is about.
    public func propose(prompt: String, evidence: BranchEvidence, cwd: URL, scopeRoot: URL,
                        takenSlugs: Set<String>, candidates: [RepoCandidate] = []) async -> TaskProposal {
        guard let profile, let microsession = profile.microsession, !microsession.isEmpty else {
            return Self.fallback(prompt: prompt, evidence: evidence, takenSlugs: takenSlugs, reason: nil)
        }
        let values = PlaceholderValues(
            threadID: "task-proposal", cwd: cwd.path, scope: scopeRoot.path, home: home.path,
            prompt: Self.metaPrompt(request: prompt, evidence: evidence, candidates: candidates)
        )
        let argv: [String]
        do { argv = try values.expand(microsession) } catch {
            return Self.fallback(prompt: prompt, evidence: evidence, takenSlugs: takenSlugs, reason: "headless argv: \(String(describing: error))")
        }
        let result: ProcessResult
        do {
            result = try await runner.run(argv: argv, cwd: cwd, timeout: timeout)
        } catch SubprocessError.timedOut {
            return Self.fallback(prompt: prompt, evidence: evidence, takenSlugs: takenSlugs, reason: "\(profile.name) did not answer within \(Int(timeout.components.seconds)) s")
        } catch {
            return Self.fallback(prompt: prompt, evidence: evidence, takenSlugs: takenSlugs, reason: String(describing: error))
        }
        if Task.isCancelled {
            return Self.fallback(prompt: prompt, evidence: evidence, takenSlugs: takenSlugs, reason: "cancelled")
        }
        guard result.succeeded else {
            let text = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.fallback(prompt: prompt, evidence: evidence, takenSlugs: takenSlugs, reason: text.isEmpty ? "\(profile.name) exited \(result.exitCode)" : text)
        }
        return await finalize(output: result.stdoutText, driverName: profile.name, prompt: prompt,
                              evidence: evidence, takenSlugs: takenSlugs, candidates: candidates)
    }

    /// Parses and validates a driver answer (public for tests and for callers with their own runner).
    public func finalize(output: String, driverName: String, prompt: String, evidence: BranchEvidence,
                         takenSlugs: Set<String>, candidates: [RepoCandidate] = []) async -> TaskProposal {
        let raw: RawProposal
        do { raw = try Self.parse(output: output) } catch {
            return Self.fallback(prompt: prompt, evidence: evidence, takenSlugs: takenSlugs, reason: String(describing: error))
        }
        let fallback = Self.fallback(prompt: prompt, evidence: evidence, takenSlugs: takenSlugs, reason: nil)
        let title = Self.cleanTitle(raw.title ?? "").flatMap { $0.isEmpty ? nil : $0 } ?? fallback.title

        var branch = (raw.branch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.hasPrefix("scope/") { branch.removeFirst("scope/".count) }
        if branch.isEmpty { branch = fallback.branch }
        var accepted = await validateRef(branch)
        if !accepted {
            branch = Self.sanitizeBranch(branch)
            accepted = branch.isEmpty ? false : await validateRef(branch)
        }
        if !accepted { branch = fallback.branch }
        branch = Self.uniqueBranch(branch, existing: evidence.branches)

        let slugSource = (raw.slug ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = SlugAllocator.unique(base: slugSource.isEmpty ? TaskBranch.slug(for: title) : TaskBranch.slug(for: slugSource), taken: takenSlugs)
        return TaskProposal(title: title, slug: slug, branch: branch,
                            repos: Self.knownRepos(raw.repos ?? [], among: candidates),
                            pullRequest: Self.reference(from: raw.pullRequest),
                            source: .driver(name: driverName))
    }

    /// Keeps the answered paths that are really repositories of the scope, in the candidates' own order.
    /// A path the driver invented is dropped rather than corrected: a worktree in the wrong place is worse
    /// than one repository missing from the selection.
    static func knownRepos(_ answered: [String], among candidates: [RepoCandidate]) -> [String] {
        guard !candidates.isEmpty else { return [] }
        let wanted = Set(answered.map { TaskRepo.normalize($0).lowercased() })
        guard !wanted.isEmpty else { return [] }
        return candidates.map(\.path).filter { wanted.contains(TaskRepo.normalize($0).lowercased()) }
    }

    /// The pull request the driver answered with: its number, and the repository when it gave one. The number
    /// alone is enough — the caller resolves the reference against the scope's remotes.
    static func reference(from raw: RawPullRequest?) -> PullRequestReference? {
        guard let raw, let number = raw.number, number > 0 else { return nil }
        guard let full = raw.repo?.trimmingCharacters(in: .whitespacesAndNewlines), !full.isEmpty else {
            return PullRequestReference(number: number)
        }
        // `owner/repo`, or a whole URL the driver pasted back.
        if let detected = PullRequestReference.detect(in: "\(full)#\(number)") { return detected }
        return PullRequestReference(number: number)
    }

    /// The strict-JSON meta-prompt. `candidates` are the scope's repositories; when they are given, the
    /// answer is asked for the ones the task is about and for any pull request the request refers to.
    public static func metaPrompt(request: String, evidence: BranchEvidence, candidates: [RepoCandidate] = []) -> String {
        let branches = evidence.branches.prefix(BranchEvidence.branchSample)
        let branchList = branches.isEmpty ? "(none yet)" : branches.map { "- \($0)" }.joined(separator: "\n")
        let commits = evidence.commitSubjects.prefix(BranchEvidence.commitSample)
        let commitList = commits.isEmpty ? "(none)" : commits.map { "- \($0)" }.joined(separator: "\n")
        let repoList = candidates.isEmpty ? "(unknown)" : candidates.map { candidate in
            let remote = candidate.remote.map { " — remote \($0.fullName)" } ?? ""
            return "- \(candidate.path) (\(candidate.name))\(remote)"
        }.joined(separator: "\n")
        return """
        You are preparing a task in this workspace: naming its git branch, and working out which repositories \
        it touches. Read only — never create, modify, push or comment on anything. Answer with a single \
        JSON object and nothing else: no prose, no markdown fences, no comments.

        Required JSON shape:
        {"title": "string, at most \(titleLimit) characters, plain words, no trailing period", \
        "slug": "string, kebab-case, at most 48 characters: the worktree folder name", \
        "branch": "string: the branch name", \
        "repos": ["the paths, copied exactly from the repository list below, that the task touches"], \
        "pull_request": {"number": 123, "repo": "owner/repo"} or null}

        Rules for "branch":
        - Follow the SAME convention as the existing branch names below: prefixes (feat/, fix/, chore/, <user>/ …), \
        separators, casing and typical length. Match what the repository already does, not what you prefer.
        - If no convention is visible, use `<type>/<short-kebab-description>` where <type> is the Conventional-Commit \
        type inferred from the request (feat, fix, chore, docs, refactor, test, perf, ci, build).
        - Never use a `scope/` prefix. Never reuse an existing branch name. No spaces, no uppercase unless the \
        existing names use it. Keep it short (under 50 characters).

        Rules for "repos":
        - Only paths from the list below, copied character for character. Never invent one.
        - Name the repositories the work actually happens in. When the request says nothing about where, \
        answer with an empty list rather than guessing.

        Rules for "pull_request":
        - Non-null only when the request is about an EXISTING pull request — named outright, or described \
        ("the auth refresh PR on front", "my open PR about the sidebar").
        - Nothing in the request suggests an existing pull request? Answer null and run no command at all: \
        every tool call keeps someone waiting in front of a dialog.
        - If you have `gh`, use it to find the number: `gh pr list --repo <owner/repo> --search <terms> \
        --json number,title,headRefName`, or `gh pr view <number> --repo <owner/repo> --json number,title,headRefName`. \
        Read-only subcommands only.
        - Answer with the number and its `owner/repo`. Do not guess a number you have not seen, and do not \
        report the branch: the caller resolves the pull request itself.
        - A request to open new work is not a pull request. Leave it null.

        Task request:
        \(request.trimmingCharacters(in: .whitespacesAndNewlines))

        Repositories of this workspace (path, folder name, remote):
        \(repoList)

        Default branch: \(evidence.defaultBranch ?? "(unknown)")

        Existing branch names, most recent first:
        \(branchList)

        Recent commit subjects (\(evidence.usesConventionalCommits ? "Conventional Commits" : "free-form")):
        \(commitList)
        """
    }

    /// The JSON object the driver returns.
    public struct RawProposal: Codable, Sendable, Equatable {
        public var title: String?
        public var slug: String?
        public var branch: String?
        public var repos: [String]?
        public var pullRequest: RawPullRequest?

        enum CodingKeys: String, CodingKey {
            case title, slug, branch, repos
            case pullRequest = "pull_request"
        }
    }

    /// The `pull_request` member: a number, and the repository it belongs to when the driver knows it.
    public struct RawPullRequest: Codable, Sendable, Equatable {
        public var number: Int?
        public var repo: String?

        public init(number: Int? = nil, repo: String? = nil) {
            self.number = number
            self.repo = repo
        }
    }

    /// Why an answer was unusable.
    public enum ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        case driverFailed(String)
        case notJSON(String)
        case missingBranch

        public var description: String {
            switch self {
            case .driverFailed(let message): "driver failed: \(message)"
            case .notJSON(let text): "driver output is not JSON: \(text.prefix(120))"
            case .missingBranch: "driver answered without a branch"
            }
        }
    }

    /// Unwraps envelopes / fences (`HeadlessOutput`) and decodes `{title, slug, branch}`.
    public static func parse(output: String) throws -> RawProposal {
        let text: String
        do { text = try HeadlessOutput.extractJSONObject(from: output) }
        catch HeadlessError.driverReportedError(let message) { throw ParseError.driverFailed(message) }
        guard !text.isEmpty else { throw ParseError.notJSON("") }
        guard let raw = try? JSONDecoder().decode(RawProposal.self, from: Data(text.utf8)) else { throw ParseError.notJSON(text) }
        let branch = raw.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A pull request answer carries no branch to invent — the pull request has one already.
        guard !branch.isEmpty || reference(from: raw.pullRequest) != nil else { throw ParseError.missingBranch }
        return raw
    }

    // MARK: - Level 0

    /// Title from the first line of the prompt, slug from the title, branch from the evidence (dominant prefix
    /// shared by ≥ 3 branches, or `feat/` / `fix/` when the request reads like one, else the bare slug).
    public static func fallback(prompt: String, evidence: BranchEvidence, takenSlugs: Set<String>, reason: String? = nil) -> TaskProposal {
        let title = cleanTitle(firstLine(of: prompt)) ?? "Task"
        let base = TaskBranch.slug(for: title)
        let slug = SlugAllocator.unique(base: base, taken: takenSlugs)
        let type = inferredType(from: prompt)
        let branchBase: String
        if evidence.usesTypePrefixes {
            branchBase = "\(type ?? "feat")/\(base)"
        } else if let prefix = evidence.dominantPrefix {
            branchBase = "\(prefix)/\(base)"
        } else if let type {
            branchBase = "\(type)/\(base)"
        } else {
            branchBase = base
        }
        return TaskProposal(title: title, slug: slug, branch: uniqueBranch(branchBase, existing: evidence.branches), source: .derived(reason: reason))
    }

    /// `feat` / `fix` when the request contains the matching keywords, nil otherwise.
    public static func inferredType(from prompt: String) -> String? {
        let words = Set(prompt.lowercased().split { !$0.isLetter }.map(String.init))
        let fixWords: Set<String> = ["fix", "fixes", "bug", "bugs", "crash", "crashes", "broken", "regression", "error", "errors", "fails", "failing", "failure", "hotfix", "repair", "incorrect", "wrong"]
        let featWords: Set<String> = ["add", "adds", "implement", "create", "support", "new", "feature", "introduce", "allow", "enable", "integrate", "expose", "provide"]
        if !words.isDisjoint(with: fixWords) { return "fix" }
        if !words.isDisjoint(with: featWords) { return "feat" }
        return nil
    }

    // MARK: - Helpers

    /// The first non-empty line, without a leading `#`, bullet or quote marker.
    static func firstLine(of prompt: String) -> String {
        for raw in prompt.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "#-*>•".contains(first) { line.removeFirst(); line = line.trimmingCharacters(in: .whitespaces) }
            if !line.isEmpty { return line }
        }
        return ""
    }

    /// Collapses whitespace, strips trailing punctuation, capitalises the first letter and cuts at a word
    /// boundary under `titleLimit`. Nil for an empty result.
    public static func cleanTitle(_ text: String) -> String? {
        var title = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = title.last, ".:;,!".contains(last) { title.removeLast() }
        guard !title.isEmpty else { return nil }
        if title.count > titleLimit {
            var cut = String(title.prefix(titleLimit))
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= titleLimit / 2 {
                cut = String(cut[..<space])
            }
            while let last = cut.last, ".:;,!- ".contains(last) { cut.removeLast() }
            title = cut
        }
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    /// Slugifies every `/` component (`Feat/Add Login!` → `feat/add-login`); empty components are dropped.
    public static func sanitizeBranch(_ name: String) -> String {
        name.split(separator: "/").map { slugify(String($0), fallback: "") }.filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// `name`, or `name-2`, `name-3`… when `existing` already has it (case-insensitively).
    public static func uniqueBranch(_ name: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var counter = 2
        while taken.contains("\(name)-\(counter)".lowercased()) { counter += 1 }
        return "\(name)-\(counter)"
    }

    /// The `git check-ref-format --branch` rules that matter for names a driver would produce: no empty or
    /// dot-leading component, no `..`, `@{`, `.lock` suffix, control or ` ~^:?*[\` characters, no leading /
    /// trailing `/`, `.` or `-`, not `@`.
    public static func isPlausibleRefName(_ name: String) -> Bool {
        guard !name.isEmpty, name != "@", !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasPrefix("-"),
              !name.hasSuffix("."), !name.contains(".."), !name.contains("@{"), !name.contains("//")
        else { return false }
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || " ~^:?*[\\".unicodeScalars.contains(scalar) { return false }
        }
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component.hasPrefix(".") || component.hasSuffix(".lock") { return false }
        }
        return true
    }
}
