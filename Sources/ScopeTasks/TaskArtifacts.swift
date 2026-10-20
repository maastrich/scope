import Foundation
import ScopeAdapters
import ScopeCore
import ScopeGit

/// What a task produced besides its diff, gathered for the inspector's Artifacts card: its report, the files its
/// threads wrote where git does not look, the pages they published, and its checkpoints.
///
/// Pure: nothing here touches the disk or runs git. The caller lists the candidates first (`writtenCandidates`),
/// asks git and the filesystem about them, then hands the answers back as `Probe` closures. The tests drive both
/// with dictionaries.
public struct TaskArtifacts: Sendable, Equatable {
    /// One thread's contribution: who it is and what its driver reported.
    public struct Thread: Sendable, Equatable {
        public var id: String
        public var title: String
        public var activity: ThreadActivity

        public init(id: String, title: String, activity: ThreadActivity) {
            self.id = id
            self.title = title
            self.activity = activity
        }
    }

    /// What the filesystem says of a file, as the caller measured it.
    public struct FileFacts: Sendable, Equatable {
        public var bytes: Int
        public var modifiedAt: Date?

        public init(bytes: Int, modifiedAt: Date? = nil) {
            self.bytes = bytes
            self.modifiedAt = modifiedAt
        }
    }

    /// The report: `REPORT.md` at the task root or in a sandbox, or the file the record declares (`deliverable`).
    public struct Report: Sendable, Equatable {
        /// Absolute.
        public var path: String
        /// As shown: the file name, behind its sandbox for a task of several (`api/docs/study.md`).
        public var name: String
        /// The record names it (`--deliverable`), as opposed to the `REPORT.md` looked for anyway.
        public var isDeclared: Bool
        public var bytes: Int
        public var modifiedAt: Date?
        /// Lines added to it since the last checkpoint, when the caller could ask git.
        public var additions: Int?

        public init(path: String, name: String, isDeclared: Bool, bytes: Int, modifiedAt: Date? = nil, additions: Int? = nil) {
            self.path = path
            self.name = name
            self.isDeclared = isDeclared
            self.bytes = bytes
            self.modifiedAt = modifiedAt
            self.additions = additions
        }
    }

    /// Why a written file is not in the diff.
    public enum Placement: String, Sendable, Equatable {
        /// Under no sandbox of the task: `/tmp`, the user's home, the task root of a task of several repositories.
        case outsideSandboxes
        /// Under a sandbox, in a folder git ignores (or `.git` itself).
        case ignored
        /// An image or a PDF: in the diff as a binary at best, never readable there.
        case binary
    }

    /// A file a thread wrote outside the diff. Identified by its path: the same file written twice is one row.
    public struct WrittenFile: Sendable, Equatable, Identifiable {
        public var id: String { path }
        /// Absolute.
        public var path: String
        /// As shown: relative to the sandbox or the task root it lies in, else the whole path.
        public var name: String
        public var placement: Placement
        /// The tool that wrote it last (`Write`, `Edit`, `Bash`).
        public var tool: String
        public var threadID: String
        public var threadTitle: String
        /// The turn's rank in its thread, 1 for the first; the open turn counts as the next one.
        public var turn: Int
        /// When the last write was reported.
        public var at: Date
        /// `nil` when the file is gone (or was never created: a failed write).
        public var facts: FileFacts?

        public var exists: Bool { facts != nil }
        public var isImage: Bool { ImageFiles.isImage(path) }

        public init(path: String, name: String, placement: Placement, tool: String, threadID: String, threadTitle: String,
                    turn: Int, at: Date, facts: FileFacts? = nil) {
            self.path = path
            self.name = name
            self.placement = placement
            self.tool = tool
            self.threadID = threadID
            self.threadTitle = threadTitle
            self.turn = turn
            self.at = at
            self.facts = facts
        }
    }

    /// A page the agent said it published: an `https://` link in one of its answers.
    public struct Page: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable {
            /// A claude.ai artifact.
            case artifact
            case pullRequest
            case issue
            case commit
            case other
        }

        public var id: String { url }
        public var url: String
        public var kind: Kind
        /// `Pull request #79`, `Artifact abc12345`, or the page's host and last path piece.
        public var title: String
        public var host: String
        public var threadID: String
        public var turn: Int
        public var at: Date

        public init(url: String, kind: Kind, title: String, host: String, threadID: String, turn: Int, at: Date) {
            self.url = url
            self.kind = kind
            self.title = title
            self.host = host
            self.threadID = threadID
            self.turn = turn
            self.at = at
        }

        public var systemImage: String {
            switch kind {
            case .artifact: "globe"
            case .pullRequest: "arrow.triangle.pull"
            case .issue: "smallcircle.filled.circle"
            case .commit: "circle.dotted"
            case .other: "link"
            }
        }
    }

    public var report: Report?
    /// Newest write first.
    public var files: [WrittenFile]
    /// Newest mention first.
    public var pages: [Page]
    /// As given, oldest first (what `TaskState.checkpoints` holds).
    public var checkpoints: [TaskCheckpoint]

    public init(report: Report? = nil, files: [WrittenFile] = [], pages: [Page] = [], checkpoints: [TaskCheckpoint] = []) {
        self.report = report
        self.files = files
        self.pages = pages
        self.checkpoints = checkpoints
    }

    public static let empty = TaskArtifacts()

    /// Nothing but, at most, checkpoints.
    public var isEmpty: Bool { report == nil && files.isEmpty && pages.isEmpty && checkpoints.isEmpty }
    public var producedNothing: Bool { report == nil && files.isEmpty && pages.isEmpty }

    /// The newest image still on disk: what the card shows a thumbnail of.
    public var newestImage: WrittenFile? { files.first { $0.isImage && $0.exists } }

    /// The closed card's line: `REPORT.md · 3 files · 1 page`, else `4 checkpoints`, else `nothing yet`.
    public var summary: String {
        var parts: [String] = []
        if let report { parts.append(report.name) }
        if !files.isEmpty { parts.append("\(files.count) \(files.count == 1 ? "file" : "files")") }
        if !pages.isEmpty { parts.append("\(pages.count) \(pages.count == 1 ? "page" : "pages")") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if !checkpoints.isEmpty { return "\(checkpoints.count) \(checkpoints.count == 1 ? "checkpoint" : "checkpoints")" }
        return "nothing yet"
    }

    // MARK: Written files

    /// Tools whose target is the file they write.
    public static let writingTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// Extensions outside the diff whatever their folder: images (`ImageFiles.extensions`) and documents git keeps as blobs.
    public static let binaryExtensions: Set<String> = ImageFiles.extensions.union(["pdf"])

    /// One write a thread reported, before the filesystem was asked about it.
    public struct Write: Sendable, Equatable {
        /// Absolute, standardized.
        public var path: String
        public var tool: String
        public var threadID: String
        public var threadTitle: String
        public var turn: Int
        public var at: Date

        public init(path: String, tool: String, threadID: String, threadTitle: String, turn: Int, at: Date) {
            self.path = path
            self.tool = tool
            self.threadID = threadID
            self.threadTitle = threadTitle
            self.turn = turn
            self.at = at
        }
    }

    /// Every file the threads wrote, as their calls say: the targets of the writing tools, and what a `Bash` command
    /// redirected into (`> file`, `>> file`). Relative paths resolve from `cwd` (the task's thread cwd). A target
    /// the adapter cut (`…`) is dropped: half a path opens nothing. Newest first, one entry per path (its last write).
    public static func writtenCandidates(threads: [Thread], cwd: String) -> [Write] {
        var writes: [Write] = []
        for thread in threads {
            let activity = thread.activity
            var turns: [(number: Int, at: Date, calls: [ThreadActivity.Tool])] = activity.turns.enumerated().map {
                ($0.offset + 1, $0.element.endedAt, $0.element.calls ?? [])
            }
            if activity.inTurn || !activity.turnCalls.isEmpty {
                turns.append((activity.turns.count + 1, activity.turnStartedAt ?? .now, activity.turnCalls))
            }
            for turn in turns {
                for call in turn.calls {
                    for path in writtenPaths(of: call, cwd: cwd) {
                        writes.append(Write(path: path, tool: call.name, threadID: thread.id, threadTitle: thread.title,
                                            turn: turn.number, at: call.at))
                    }
                }
            }
        }
        return dedupe(writes.sorted { $0.at > $1.at })
    }

    /// The paths a call wrote, absolute: the target of a writing tool, the redirections of a `Bash` command.
    static func writtenPaths(of call: ThreadActivity.Tool, cwd: String) -> [String] {
        guard let target = call.target, !target.hasSuffix("…") else { return [] }
        if writingTools.contains(call.name) {
            return [resolve(target, cwd: cwd)].compactMap { $0 }
        }
        if call.name == "Bash" {
            return redirections(in: target).compactMap { resolve($0, cwd: cwd) }
        }
        return []
    }

    /// `> file` and `>> file` in a command line: the files a shell command clearly creates. A file descriptor
    /// (`2>`, `&>`), a device (`/dev/null`) and a process substitution are not files worth a row.
    static func redirections(in command: String) -> [String] {
        var found: [String] = []
        let scalars = Array(command)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == ">" else { index += 1; continue }
            // `2>` and `&>` name descriptors; `<(` / `>(` process substitutions.
            let before = index > 0 ? scalars[index - 1] : " "
            if before.isNumber || before == "&" || before == "<" { index += 1; continue }
            index += 1
            if index < scalars.count, scalars[index] == ">" { index += 1 }
            if index < scalars.count, scalars[index] == "(" { continue }
            while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 }
            guard index < scalars.count else { break }
            var token = ""
            if scalars[index] == "\"" || scalars[index] == "'" {
                let quote = scalars[index]
                index += 1
                while index < scalars.count, scalars[index] != quote { token.append(scalars[index]); index += 1 }
                index += 1
            } else {
                while index < scalars.count, !" \t;|&<>)".contains(scalars[index]) { token.append(scalars[index]); index += 1 }
            }
            guard !token.isEmpty, token != "&", !token.hasPrefix("/dev/"), !token.hasPrefix("$"), !token.contains("*") else { continue }
            found.append(token)
        }
        return found
    }

    /// `path` made absolute from `cwd` and standardized; `nil` for one that names nothing (a `~` of another user,
    /// an empty string).
    static func resolve(_ path: String, cwd: String) -> String? {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path == "~" || path.hasPrefix("~/") {
            path = NSHomeDirectory() + path.dropFirst()
        } else if path.hasPrefix("~") {
            return nil
        } else if !path.hasPrefix("/") {
            path = cwd + "/" + path
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Keeps the first of each path: the list comes newest first, so the last write.
    static func dedupe(_ writes: [Write]) -> [Write] {
        var seen = Set<String>()
        return writes.filter { seen.insert($0.path).inserted }
    }

    /// Where `path` stands against the task's worktrees: outside every sandbox, inside one but ignored (`isIgnored`
    /// says, from git; `.git` itself needs no asking), a binary, or `nil` when the diff has it.
    public static func placement(of path: String, sandboxes: [TaskRepo], isIgnored: (String) -> Bool) -> Placement? {
        let sandbox = sandboxes
            .map(\.sandboxURL.standardizedFileURL.path)
            .filter { path == $0 || path.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
        guard let sandbox else { return .outsideSandboxes }
        let relative = String(path.dropFirst(sandbox.count + 1))
        if relative == ".git" || relative.hasPrefix(".git/") { return .ignored }
        if isIgnored(path) { return .ignored }
        if binaryExtensions.contains((path as NSString).pathExtension.lowercased()) { return .binary }
        return nil
    }

    /// `path` as a row names it: relative to the sandbox it lies in (behind the sandbox's key for a task of several),
    /// to the task root, or whole.
    static func displayName(of path: String, record: TaskRecord) -> String {
        let sandboxes = record.activeSandboxes
        if let repo = sandboxes.filter({ path.hasPrefix($0.sandboxURL.standardizedFileURL.path + "/") })
            .max(by: { $0.sandboxPath.count < $1.sandboxPath.count }) {
            let relative = String(path.dropFirst(repo.sandboxURL.standardizedFileURL.path.count + 1))
            return sandboxes.count > 1 ? "\(repo.sandboxKey)/\(relative)" : relative
        }
        let root = record.rootURL.standardizedFileURL.path
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }

    // MARK: Published pages

    /// A mention of an `https://` link in a reply, with the turn it was said in.
    public struct Mention: Sendable, Equatable {
        public var url: String
        public var threadID: String
        public var turn: Int
        public var at: Date

        public init(url: String, threadID: String, turn: Int, at: Date) {
            self.url = url
            self.threadID = threadID
            self.turn = turn
            self.at = at
        }
    }

    /// The `https://` links in `text`, in order, trailing punctuation and Markdown closers dropped. A link the
    /// excerpt cut (`…` at its end) is left out: it would open the wrong page.
    public static func links(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let range = rest.range(of: "https://") {
            var end = range.upperBound
            while end < rest.endIndex, !rest[end].isWhitespace, !"<>\"'`()[]".contains(rest[end]) { end = rest.index(after: end) }
            var link = String(rest[range.lowerBound..<end])
            while let last = link.last, ".,;:!?*_".contains(last) { link.removeLast() }
            if link.count > "https://".count, !link.hasSuffix("…"), !link.contains("…") { found.append(link) }
            rest = rest[end...]
        }
        return found
    }

    /// Every link said in the threads' answers: each turn's `said` excerpt, and the last reply in full for the turn
    /// it closed. Newest first.
    public static func mentions(threads: [Thread]) -> [Mention] {
        var mentions: [Mention] = []
        for thread in threads {
            let activity = thread.activity
            for (index, turn) in activity.turns.enumerated() {
                for url in links(in: turn.said ?? "") {
                    mentions.append(Mention(url: url, threadID: thread.id, turn: index + 1, at: turn.endedAt))
                }
            }
            if let reply = activity.lastReply {
                // The reply belongs to the last closed turn whose window holds it, else to the open one.
                let turn = activity.turns.lastIndex { ($0.startedAt ?? .distantPast) <= reply.at && reply.at <= $0.endedAt }
                    .map { $0 + 1 } ?? activity.turns.count + (activity.inTurn ? 1 : 0)
                for url in links(in: reply.text) {
                    mentions.append(Mention(url: url, threadID: thread.id, turn: max(turn, 1), at: reply.at))
                }
            }
        }
        return mentions.sorted { $0.at > $1.at }
    }

    /// `mentions` folded into pages: one per URL (its newest mention), classified and titled.
    public static func pages(from mentions: [Mention]) -> [Page] {
        var seen = Set<String>()
        return mentions.compactMap { mention in
            let key = mention.url.hasSuffix("/") ? String(mention.url.dropLast()) : mention.url
            guard seen.insert(key).inserted, let components = URLComponents(string: mention.url), let host = components.host else {
                return nil
            }
            let (kind, title) = classify(host: host, path: components.path)
            return Page(url: mention.url, kind: kind, title: title, host: host, threadID: mention.threadID,
                        turn: mention.turn, at: mention.at)
        }
    }

    /// The kind and the title of a page from its host and path.
    static func classify(host: String, path: String) -> (Page.Kind, String) {
        let pieces = path.split(separator: "/").map(String.init)
        if host == "claude.ai" || host.hasSuffix(".claude.ai") {
            if let index = pieces.firstIndex(of: "artifact"), pieces.count > index + 1 {
                return (.artifact, "Artifact \(pieces[index + 1].prefix(8))")
            }
        }
        if host == "github.com", pieces.count >= 4 {
            let repo = "\(pieces[0])/\(pieces[1])"
            switch pieces[2] {
            case "pull": return (.pullRequest, "Pull request #\(pieces[3]) · \(repo)")
            case "issues": return (.issue, "Issue #\(pieces[3]) · \(repo)")
            case "commit": return (.commit, "Commit \(pieces[3].prefix(7)) · \(repo)")
            default: break
            }
        }
        let tail = pieces.last.map { $0.removingPercentEncoding ?? $0 }
        let title = tail.map { "\(host) · \($0)" } ?? host
        return (.other, title.count > 60 ? String(title.prefix(59)) + "…" : title)
    }

    // MARK: Report

    /// The report the task would show, by preference: the declared file, then `REPORT.md`, each looked for at the
    /// task root and in every sandbox (`TaskRecord.deliverableFolders`). `exists` says which of the candidates is on
    /// disk; the first found wins.
    public static func reportCandidates(record: TaskRecord) -> [(path: String, name: String, isDeclared: Bool)] {
        var candidates: [(String, String, Bool)] = []
        var seen = Set<String>()
        for name in record.deliverableNames {
            guard !name.hasPrefix("/"), !name.hasPrefix("~"), !name.split(separator: "/").contains("..") else { continue }
            for folder in record.deliverableFolders {
                let path = folder.url.appending(path: name).standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                let shown = folder.label.map { "\($0)/\(name)" } ?? name
                candidates.append((path, shown, name == record.deliverable))
            }
        }
        return candidates
    }

    // MARK: Assembly

    /// Everything, from what the caller measured: `facts` answers for every candidate path (nil when gone),
    /// `isIgnored` for a path under a sandbox, `reportAdditions` for the report found.
    public static func collect(record: TaskRecord, threads: [Thread], checkpoints: [TaskCheckpoint],
                               facts: (String) -> FileFacts?, isIgnored: (String) -> Bool,
                               reportAdditions: Int? = nil) -> TaskArtifacts {
        let cwd = record.threadCwd.standardizedFileURL.path
        let sandboxes = record.activeSandboxes
        var report: Report?
        for candidate in reportCandidates(record: record) {
            guard let found = facts(candidate.path) else { continue }
            report = Report(path: candidate.path, name: candidate.name, isDeclared: candidate.isDeclared, bytes: found.bytes,
                            modifiedAt: found.modifiedAt, additions: reportAdditions)
            break
        }
        let files: [WrittenFile] = writtenCandidates(threads: threads, cwd: cwd).compactMap { write in
            // The report has its own row.
            guard write.path != report?.path,
                  let placement = placement(of: write.path, sandboxes: sandboxes, isIgnored: isIgnored) else { return nil }
            return WrittenFile(path: write.path, name: displayName(of: write.path, record: record), placement: placement,
                               tool: write.tool, threadID: write.threadID, threadTitle: write.threadTitle, turn: write.turn,
                               at: write.at, facts: facts(write.path))
        }
        return TaskArtifacts(report: report, files: files, pages: pages(from: mentions(threads: threads)), checkpoints: checkpoints)
    }
}
