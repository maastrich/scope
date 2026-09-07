import AppKit

/// Finder / default-app integration through `NSWorkspace`.
@MainActor
enum Reveal {
    /// Opens a Finder window with the item selected (a folder is selected inside its parent).
    static func inFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens the item with its default application (a folder opens in Finder).
    static func withDefaultApp(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens URLs with a specific application, looked up by bundle identifier.
    static func open(_ urls: [URL], withAppBundleID bundleID: String, activate: Bool = true) async throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.promptsUserIfNeeded = true
        _ = try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration)
    }
}

/// Clipboard helpers for the "Copy Path" / "Copy SCOPE_THREAD" menu items.
@MainActor
enum Pasteboard {
    /// Replaces the general pasteboard content with `string`.
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Copies a file system path (no `file://` scheme, no trailing slash).
    static func copyPath(_ url: URL) {
        copy(url.standardizedFileURL.path)
    }
}
