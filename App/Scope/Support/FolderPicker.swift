import AppKit

/// `NSOpenPanel` configured for picking scope folders (folders only, multiple selection).
@MainActor
enum FolderPicker {
    private static func makePanel(startingAt directory: URL?) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        panel.showsHiddenFiles = false
        panel.prompt = "Add Scope"
        panel.message = "Choose one or more folders to declare as scopes"
        if let directory {
            panel.directoryURL = directory
        }
        return panel
    }

    /// Shows the panel as a sheet on the key window when there is one, app-modal otherwise.
    /// Returns the chosen folders, or an empty array when the user cancels.
    static func chooseFolders(startingAt directory: URL? = nil) async -> [URL] {
        let panel = makePanel(startingAt: directory)
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        return response == .OK ? panel.urls : []
    }
}
