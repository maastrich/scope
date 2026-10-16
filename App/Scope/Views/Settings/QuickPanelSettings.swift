import AppKit
import SwiftUI
import ScopeCore

/// Settings › General › Anywhere: the two system-wide chords and where the quick panel lands.
struct QuickPanelSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsSection("Anywhere") {
            SettingsRow("Open the quick panel") {
                HotkeyRecorder(chord: preference(\.quickPanelHotkey), status: GlobalHotkeys.shared.status[.quickPanel])
                    .usageID("quick-panel-hotkey", label: "Quick panel hotkey")
            }
            SettingsRow("Show or hide Scope") {
                HotkeyRecorder(chord: preference(\.toggleWindowHotkey), status: GlobalHotkeys.shared.status[.toggleWindow])
                    .usageID("toggle-window-hotkey", label: "Show or hide Scope hotkey")
            }
            SettingsRow("The panel opens on") {
                ScopePicker("The panel opens on", selection: preference(\.quickPanelLanding),
                            title: model.config.preferences.quickPanelLanding.title) {
                    ForEach(QuickPanel.Landing.allCases, id: \.self) { landing in
                        Text(landing.title).tag(landing)
                    }
                }
                .usageID("quick-panel-landing", label: "The panel opens on")
            }
            Text("The chords work while another app is in front and need no permission. macOS does not say when another app holds the same chord: if a press never reaches Scope, pick another one. The quick panel asks a scope's orchestrator (⌃1…9 picks the scope) or answers what is in the Inbox, without bringing the window up. The menu bar item opens it too.")
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.config.preferences[keyPath: keyPath] },
            set: { value in model.updatePreferences { $0[keyPath: keyPath] = value } }
        )
    }
}

/// A chord as a button: click, press the keys, done. Esc gives up, ⌫ clears the chord (no hotkey), a click
/// elsewhere gives up. While recording, a local monitor takes every key before the window does, so ⌘W or ⌘, become
/// the chord rather than closing the window.
struct HotkeyRecorder: View {
    @Binding var chord: KeyChord?
    var status: GlobalHotkeys.Status?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(recording ? Ink.tertiary : (chord == nil ? Ink.tertiary : Ink.primary))
                        .lineLimit(1)
                    if !recording, chord != nil {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Ink.tertiary)
                            .opacity(hovering ? 1 : 0)
                            .onTapGesture { chord = nil }
                            .help("Remove the shortcut")
                    }
                }
                .frame(minWidth: 94)
                .scopeFieldBox(focused: recording)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(recording ? "Recording a shortcut" : "Shortcut: \(label)")
            if let caption {
                Text(caption)
                    .font(.scopeCaption)
                    .foregroundStyle(ThreadStateStyle.waiting)
                    .lineLimit(1)
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording { return "Press keys…" }
        return chord?.description ?? "None"
    }

    private var caption: String? {
        switch status {
        case .taken: return "registered twice"
        case .failed(_, let code): return "refused by the system (\(code))"
        case .off, .registered, nil:
            if let chord, !chord.isUsableSystemWide { return "needs a modifier" }
            return nil
        }
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            // Only plain values leave the event here: the closure runs on the main thread, where the state lives.
            let type = event.type
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers ?? ""
            let swallowed = MainActor.assumeIsolated {
                guard type == .keyDown else {
                    stop()
                    return false
                }
                record(keyCode: keyCode, flags: flags, characters: characters)
                return true
            }
            return swallowed ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func record(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String) {
        if keyCode == 53, flags.isEmpty {
            stop()
            return
        }
        if keyCode == 51, flags.isEmpty {
            chord = nil
            stop()
            return
        }
        var modifiers = KeyChord.Modifiers()
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        // The layout's own character names a letter key (É on a French keyboard, not E); the table names the rest.
        let printable = characters.unicodeScalars.first.map { $0.properties.isAlphabetic || $0.properties.numericType != nil || ($0.value > 32 && $0.value < 127) } == true
        let name = KeyChord.keyName(keyCode) ?? (printable ? characters.uppercased() : nil)
        guard let name else { return }
        let candidate = KeyChord(keyCode: keyCode, modifiers: modifiers, key: name)
        // A bare letter would steal the key from every app: wait for a chord that can be a hotkey.
        guard candidate.isUsableSystemWide else { return }
        chord = candidate
        stop()
    }
}
