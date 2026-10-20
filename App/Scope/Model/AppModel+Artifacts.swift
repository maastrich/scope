import AppKit
import Foundation
import ScopeAdapters
import ScopeCore
import ScopeGit
import ScopeTasks

/// The Artifacts card's data: what a task produced besides its diff (`TaskArtifacts`), measured off the main actor.
extension AppModel {
    /// Bytes of the report read for the card's preview: its opening, a few blocks.
    nonisolated static let reportPreviewBytes = 4096
    /// Blocks of the report the preview shows.
    nonisolated static let reportPreviewBlocks = 6
    /// Written paths probed per refresh: git is asked about each one under a sandbox, so the list is bounded.
    nonisolated static let artifactProbeLimit = 200

    /// Recomputes the task's artifacts: the paths its threads wrote and the report candidates come from the records
    /// (pure, on the main actor), then a detached task stats each file, asks git which ones it ignores and reads the
    /// report's head. A refresh already running is replaced: only the latest state is worth showing.
    func refreshArtifacts(of task: TaskState) async {
        task.artifactsJob?.cancel()
        let record = task.record
        let threads = threads(in: task.id).map {
            TaskArtifacts.Thread(id: $0.id.rawValue, title: displayTitle(for: $0), activity: $0.activity)
        }
        let checkpoints = task.checkpoints
        let git = env.git
        let job = Task { [weak self] in
            let measured = await Task.detached(priority: .utility) {
                await Self.measureArtifacts(record: record, threads: threads, checkpoints: checkpoints, git: git)
            }.value
            guard let self, !Task.isCancelled, let measured else { return }
            if task.artifacts != measured.artifacts { task.artifacts = measured.artifacts }
            if task.reportPreview != measured.preview { task.reportPreview = measured.preview }
        }
        task.artifactsJob = job
        await job.value
    }

    struct MeasuredArtifacts: Sendable, Equatable {
        var artifacts: TaskArtifacts
        var preview: MarkdownDocument?
    }

    /// Blocking I/O and git: never on the main actor.
    nonisolated static func measureArtifacts(record: TaskRecord, threads: [TaskArtifacts.Thread], checkpoints: [TaskCheckpoint],
                                             git: GitClientRegistry) async -> MeasuredArtifacts? {
        let cwd = record.threadCwd.standardizedFileURL.path
        var facts: [String: TaskArtifacts.FileFacts] = [:]
        func probe(_ path: String) {
            guard facts[path] == nil else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return }
            facts[path] = .init(bytes: (attributes[.size] as? Int) ?? 0, modifiedAt: attributes[.modificationDate] as? Date)
        }
        let reportCandidates = TaskArtifacts.reportCandidates(record: record)
        for candidate in reportCandidates { probe(candidate.path) }
        let report = reportCandidates.first { facts[$0.path] != nil }
        let writes = TaskArtifacts.writtenCandidates(threads: threads, cwd: cwd).prefix(artifactProbeLimit)
        for write in writes { probe(write.path) }
        if Task.isCancelled { return nil }

        // Which written files git ignores: one `check-ignore` per file under a sandbox. The exclude file of a
        // worktree counts (`.git/info/exclude`), which is where Scope puts the context file it writes.
        var ignored = Set<String>()
        for write in writes {
            guard let sandbox = record.sandbox(containing: write.path) else { continue }
            let client = await git.client(for: sandbox.sandboxURL)
            if let result = try? await client.run(["check-ignore", "-q", write.path], timeout: .seconds(10), allowFailure: true),
               result.succeeded {
                ignored.insert(write.path)
            }
            if Task.isCancelled { return nil }
        }

        // `+N` on the report: its lines added since the last checkpoint of the sandbox holding it. The file is often
        // untracked (a report is rarely committed), so the checkpoint's copy is written out and the two files are
        // compared directly rather than through the index.
        var additions: Int?
        if let report, let sandbox = record.sandbox(containing: report.path),
           let commit = checkpoints.last?.repos.first(where: { $0.repoRelativePath == sandbox.sandboxKey })?.commit {
            let client = await git.client(for: sandbox.sandboxURL)
            let relative = String(report.path.dropFirst(sandbox.sandboxURL.standardizedFileURL.path.count + 1))
            let copy = FileManager.default.temporaryDirectory.appending(path: "scope-report-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: copy) }
            if let shown = try? await client.run(["show", "\(commit):\(relative)"], timeout: .seconds(10), allowFailure: true) {
                // Absent from the checkpoint: every line is new.
                try? (shown.succeeded ? shown.stdout : Data()).write(to: copy)
                if let result = try? await client.run(["diff", "--numstat", "--no-index", "--", copy.path, report.path],
                                                      timeout: .seconds(10), allowFailure: true) {
                    additions = result.stdoutText.split(separator: "\n").first.flatMap { Int($0.split(separator: "\t").first ?? "") } ?? 0
                }
            }
        }

        var preview: MarkdownDocument?
        if let report, let handle = FileHandle(forReadingAtPath: report.path) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: reportPreviewBytes), var text = String(data: data, encoding: .utf8) ?? Self.lossy(data) {
                if data.count >= reportPreviewBytes, let cut = text.lastIndex(of: "\n") { text = String(text[..<cut]) }
                let document = MarkdownDocument.parse(text)
                preview = MarkdownDocument(blocks: Array(document.blocks.prefix(reportPreviewBlocks)))
            }
        }
        let artifacts = TaskArtifacts.collect(record: record, threads: threads, checkpoints: checkpoints,
                                              facts: { facts[$0] }, isIgnored: { ignored.contains($0) }, reportAdditions: additions)
        return MeasuredArtifacts(artifacts: artifacts, preview: preview)
    }

    /// A head cut inside a multi-byte character still decodes once the broken tail is dropped.
    private nonisolated static func lossy(_ data: Data) -> String? {
        for drop in 1...3 where data.count > drop {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) { return text }
        }
        return nil
    }

    /// *Read* on the report row: the file as it is now, in the reading column. Read off the main actor; the column
    /// opens once the text is in.
    func readReport(of task: TaskState) {
        guard let report = task.artifacts?.report else { return }
        Usage.click("task.read-report", label: "Read a task's report")
        let url = URL(fileURLWithPath: report.path)
        let title = "\(task.name) · \(report.name)"
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { BaseFileContent.load(url) }.value
            guard let self else { return }
            let markdown: String
            switch loaded {
            case .text(let text): markdown = text
            case .unavailable(let reason): markdown = "_\(reason)_"
            case .image, .loading: markdown = "_Not a text file._"
            }
            showReading(ReadingContent(kind: .report(task.id), title: title, at: report.modifiedAt, markdown: markdown,
                                       directory: url.deletingLastPathComponent().path, taskID: task.id, scopeID: task.scopeID))
        }
    }

    /// A row of *Files written this task*: the file in the viewer column — text or image alike (`PathPreview`). A
    /// file that is gone opens nothing; the row already says so.
    func openArtifactFile(_ file: TaskArtifacts.WrittenFile, of task: TaskState) {
        guard file.exists else { return }
        Usage.click("task.open-artifact", label: "Open a file written outside the diff")
        if !openFileLink(file.path, scope: task.scopeID, task: task, directory: task.record.threadCwd.path) {
            problems.warn("No file at \(file.name)", detail: "The file the agent wrote is no longer there.")
        }
    }

    /// A row of *Published*: the page in the browser.
    func openArtifactPage(_ page: TaskArtifacts.Page) {
        guard let url = URL(string: page.url) else { return }
        Usage.click("task.open-published", label: "Open a page the agent published")
        NSWorkspace.shared.open(url)
    }
}
