import AppKit
import Foundation
import ScopeControl
import ScopeCore
import ScopeTasks
import WebKit

/// Before/after (`scope_browser_compare`, the pane's Compare): the same route on the base branch's server — a
/// secondary worktree of the task — and on the task's own, each in a fresh view of the task's agent store at one
/// viewport, diffed pixel by pixel.
extension AppModel {
    static let compareSize = CGSize(width: 1280, height: 800)

    /// The two servers to compare when none is named: a port a secondary worktree serves on the left, a port the
    /// task's own sandbox serves on the right. `nil` with what is missing.
    func comparePorts(of task: TaskState, before: Int?, after: Int?) -> Result<(before: Int, after: Int), ControlError> {
        let block = task.record.portBlock
        let ports = task.listeningPorts + task.otherPorts
        let secondary = Set(task.activeSandboxes.filter(\.isSecondary).map(\.sandboxKey))
        let left = before.map { BrowserText.port($0, block: block) }
            ?? ports.first { task.portWorktrees[$0].map(secondary.contains) ?? false }
        let right = after.map { BrowserText.port($0, block: block) }
            ?? ports.first { port in port != left && task.portWorktrees[port].map { !secondary.contains($0) } ?? false }
            ?? ports.first { $0 != left }
        guard let left, let right else {
            let worktree = task.activeSandboxes.first(where: \.isSecondary)
            return .failure(.badRequest(
                "two servers are needed to compare",
                detail: (worktree == nil
                         ? "Add the base branch beside the task: `scope task branch add base-main --from main`, then start its dev server "
                         : "Start the dev server of \(worktree!.sandboxKey) ")
                    + "on another port of the block (\(block.map { "\($0.base + 1)…\($0.base + $0.size - 1)" } ?? "SCOPE_PORT + 1")), "
                    + "the task's own on $SCOPE_PORT — or name them with before and after."))
        }
        return .success((left, right))
    }

    func compareBrowser(_ params: BrowserParams, in task: TaskState) async -> Result<BrowserResult, ControlError> {
        let ports: (before: Int, after: Int)
        switch comparePorts(of: task, before: params.before, after: params.after) {
        case .failure(let error): return .failure(error)
        case .success(let pair): ports = pair
        }
        var path = params.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "/"
        if !path.hasPrefix("/") { path = "/" + path }
        guard let beforeURL = URL(string: "http://localhost:\(ports.before)\(path)"),
              let afterURL = URL(string: "http://localhost:\(ports.after)\(path)") else {
            return .failure(.badRequest("“\(path)” is not a path"))
        }
        let store = BrowserStoreID.agent(home: env.home, task: task.id.rawValue)
        async let left = capture(beforeURL, store: store, task: task)
        async let right = capture(afterURL, store: store, task: task)
        let images: (CGImage, CGImage)
        do {
            images = try await (left, right)
        } catch {
            return .failure(.failed("could not capture both sides", detail: String(describing: error)))
        }
        let width = Int(Self.compareSize.width), height = Int(Self.compareSize.height)
        guard let a = Self.rgba(images.0, width: width, height: height), let b = Self.rgba(images.1, width: width, height: height) else {
            return .failure(.failed("could not read the captures"))
        }
        let diff = ImageDiff.compare(a, b, width: width, height: height)
        let folder = ScopeHome.browserShotsURL(home: env.home, task: task.id.rawValue)
        let stamp = String(Int(Date.now.timeIntervalSince1970))
        let beforeFile = folder.appending(path: "compare-\(stamp)-before.jpg")
        let afterFile = folder.appending(path: "compare-\(stamp)-after.jpg")
        let sideFile = folder.appending(path: "compare-\(stamp).jpg")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.jpeg(images.0)?.write(to: beforeFile)
            try Self.jpeg(images.1)?.write(to: afterFile)
            guard let composite = Self.sideBySide(images.0, images.1, regions: diff.regions, width: width, height: height),
                  let data = Self.jpeg(composite, maxWidth: 1600) else {
                return .failure(.failed("could not draw the comparison"))
            }
            try data.write(to: sideFile)
        } catch {
            return .failure(.failed("could not write the comparison", detail: String(describing: error)))
        }
        let worktreeLabel: (Int) -> String? = { port in
            guard let key = task.portWorktrees[port], let scope = self.scope(task.scopeID) else { return task.portWorktrees[port] }
            return task.activeSandboxes.first { $0.sandboxKey == key }?.sandboxLabel(scopeName: scope.name) ?? key
        }
        let comparison = BrowserComparison(
            before: beforeURL.absoluteString, after: afterURL.absoluteString,
            beforeWorktree: worktreeLabel(ports.before), afterWorktree: worktreeLabel(ports.after),
            width: width, height: height, fraction: diff.fraction, regions: diff.regions,
            beforeImage: beforeFile.path, afterImage: afterFile.path)
        browser.setComparison(BrowserStore.Comparison(path: path, at: .now, result: comparison,
                                                      before: NSImage(cgImage: images.0, size: Self.compareSize),
                                                      after: NSImage(cgImage: images.1, size: Self.compareSize)),
                              of: task.id)
        var answer = BrowserResult(task: task.id.rawValue, slug: task.record.slug, action: .compare, url: afterURL.absoluteString,
                                   message: "compared \(path): \(comparison.summary)")
        answer.comparison = comparison
        answer.screenshot = sideFile.path
        answer.width = min(1600, width * 2 + Self.compareGap)
        answer.height = Int(Double(height) * Double(answer.width!) / Double(width * 2 + Self.compareGap))
        return .success(answer)
    }

    /// The pane's Compare button: the default pair on `/` of the shown tab's path, shown when done.
    func compareInPane(_ task: TaskState) {
        let path = currentBrowserTab?.url.flatMap { BrowserRoute.isLocal($0) ? $0.path : nil }.flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        Usage.click("browser.compare", label: "Compare the base branch and the task")
        browser.comparing.insert(task.id)
        Task {
            let result = await compareBrowser(BrowserParams(action: .compare, url: path), in: task)
            browser.comparing.remove(task.id)
            switch result {
            case .success:
                browser.showComparison(true, of: task.id)
                inspector.show(.browser)
            case .failure(let error):
                problems.warn("Nothing to compare yet", detail: error.description)
            }
        }
    }

    /// One side: a fresh view on the task's agent store at the compare viewport, loaded and captured.
    private func capture(_ url: URL, store: UUID, task: TaskState) async throws -> CGImage {
        let session = BrowserSession(taskID: task.id, storeID: store, url: nil, kind: .agent)
        defer { session.tearDown() }
        _ = session.webView
        session.webView.setFrameSize(Self.compareSize)
        let loaded = await session.loadAndWait(url, timeout: .seconds(20))
        if let failure = session.failure { throw BrowserSession.PageError.unreadable("\(url.absoluteString): \(failure.message)") }
        if !loaded { throw BrowserSession.PageError.unreadable("\(url.absoluteString) still loading after 20 s") }
        // Fonts and late layout settle a moment after the load event.
        try? await Task.sleep(for: .milliseconds(400))
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await session.webView.takeSnapshot(configuration: configuration)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw BrowserSession.PageError.unreadable("the snapshot of \(url.absoluteString) is empty")
        }
        return cgImage
    }

    static let compareGap = 16

    /// The image redrawn at `width` × `height`, as RGBA8 bytes (top row first).
    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// Before on the left, after on the right, the regions that differ outlined on the right.
    static func sideBySide(_ left: CGImage, _ right: CGImage, regions: [ImageDiff.Region], width: Int, height: Int) -> CGImage? {
        let total = width * 2 + compareGap
        guard let context = CGContext(data: nil, width: total, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: total, height: height))
        context.draw(left, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(right, in: CGRect(x: width + compareGap, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(red: 0.62, green: 0.36, blue: 0.05, alpha: 1))
        context.setLineWidth(3)
        for region in regions {
            // Regions are measured from the top; Core Graphics draws from the bottom.
            let rect = CGRect(x: width + compareGap + region.x, y: height - region.y - region.height, width: region.width, height: region.height)
            context.stroke(rect.insetBy(dx: -3, dy: -3))
        }
        return context.makeImage()
    }

    static func jpeg(_ image: CGImage, maxWidth: Int = 1280) -> Data? {
        let scale = min(1, Double(maxWidth) / Double(image.width))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }
}
