import Foundation
import ScopeCore

extension AppModel {
    var hasInspectorTask: Bool { currentTask != nil }

    func isSectionOpen(_ section: InspectorSection) -> Bool {
        inspector.sections.isOpen(section, hasTask: hasInspectorTask)
    }

    /// A section has something to show: a task for the task's sections, a repository for the base's.
    func isSectionAvailable(_ section: InspectorSection) -> Bool {
        section.needsTask ? currentTask != nil : currentScope != nil && baseSubject() != nil
    }

    func setSection(_ section: InspectorSection, open: Bool) {
        guard isSectionOpen(section) != open else { return }
        inspector.sections.setOpen(section, open, hasTask: hasInspectorTask)
        // Opening the search is asking to type in it.
        if open, section == .search { inspector.requestFocus(.search) }
        persistUIState()
    }

    func toggleSection(_ section: InspectorSection) {
        setSection(section, open: !isSectionOpen(section))
    }

    /// ⌘D, ⇧⌘B, a task's menu, a notification: open the section — never close it — and give it the keyboard.
    func revealSection(_ section: InspectorSection) {
        inspectorShown = true
        // A request nothing can take now must not wait: it would take the keyboard from the terminal whenever the
        // section next appears.
        guard isSectionAvailable(section) else { return }
        setSection(section, open: true)
        inspector.requestFocus(section)
    }

    /// Selects a changed file and shows its diff in the viewer.
    func showDiff(_ ref: DeltaFileRef?) {
        delta.selectedFile = ref
        delta.focusedHunk = nil
        if ref != nil { inspector.show(.diff) }
    }
}
