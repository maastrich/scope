import AppKit
import Carbon.HIToolbox
import Observation
import ScopeCore

/// The system-wide chords (spec §7): one opens the quick panel, one brings the window up or hides the app. Both
/// fire while another app is frontmost, which is the point.
///
/// Carbon's `RegisterEventHotKey`, not `NSEvent.addGlobalMonitorForEvents`: the monitor needs the Accessibility
/// (Input Monitoring) permission and only *watches* the key — the frontmost app still receives it. A registered
/// hotkey needs no permission at all for a plain chord, and the system swallows the keystroke. The API is old but not
/// deprecated, and it is what every launcher uses.
///
/// `eventHotKeyExistsErr` only says this process holds the chord twice; a chord another app holds registers without
/// a word, and the press then goes to whichever registered last (checked: a script registering ⌥Space beside the
/// running app got `noErr`). So a launcher on ⌥Space — or the installed Scope next to a Debug build — is not
/// something Settings can report; it is something the user sees when the chord does not come to Scope.
@MainActor
@Observable
final class GlobalHotkeys {
    static let shared = GlobalHotkeys()

    enum Slot: UInt32, CaseIterable {
        case quickPanel = 1
        case toggleWindow = 2
    }

    enum Status: Equatable {
        /// No chord set.
        case off
        case registered(KeyChord)
        /// Registered twice by this process — a bug, not something the user did.
        case taken(KeyChord)
        /// The system refused it for another reason (the OSStatus).
        case failed(KeyChord, Int32)
    }

    private(set) var status: [Slot: Status] = [:]

    @ObservationIgnored private var refs: [Slot: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var actions: [Slot: () -> Void] = [:]
    @ObservationIgnored private var observing = false

    /// The four-char signature the hotkey ids carry; the handler checks it before acting.
    private static let signature: OSType = 0x5343_4F50 // 'SCOP'

    /// Registers the chords of `preferences` and follows them as they change in Settings.
    func start(model: AppModel, actions: [Slot: () -> Void]) {
        self.actions = actions
        installHandler()
        guard !observing else { return }
        observing = true
        follow(model)
    }

    private func follow(_ model: AppModel) {
        withObservationTracking {
            apply(quickPanel: model.config.preferences.quickPanelHotkey,
                  toggleWindow: model.config.preferences.toggleWindowHotkey)
        } onChange: {
            Task { @MainActor [weak self] in self?.follow(model) }
        }
    }

    private func apply(quickPanel: KeyChord?, toggleWindow: KeyChord?) {
        set(.quickPanel, to: quickPanel)
        set(.toggleWindow, to: toggleWindow)
    }

    /// Re-registers `slot` when its chord changed; a chord no system-wide hotkey can be made of counts as none.
    private func set(_ slot: Slot, to chord: KeyChord?) {
        let wanted = chord.flatMap { $0.isUsableSystemWide ? $0 : nil }
        if case .registered(let current)? = status[slot], current == wanted { return }
        if case .taken(let current)? = status[slot], current == wanted { return }
        if case .failed(let current, _)? = status[slot], current == wanted { return }
        unregister(slot)
        guard let wanted else {
            status[slot] = .off
            return
        }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        let result = RegisterEventHotKey(UInt32(wanted.keyCode), wanted.modifiers.carbonFlags, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if result == noErr, let ref {
            refs[slot] = ref
            status[slot] = .registered(wanted)
        } else if result == OSStatus(eventHotKeyExistsErr) {
            status[slot] = .taken(wanted)
            Log.app.error("hotkey \(wanted.description, privacy: .public) registered twice")
        } else {
            status[slot] = .failed(wanted, result)
            Log.app.error("hotkey \(wanted.description, privacy: .public) refused: \(result, privacy: .public)")
        }
    }

    private func unregister(_ slot: Slot) {
        if let ref = refs.removeValue(forKey: slot) { UnregisterEventHotKey(ref) }
    }

    /// The pressed-hotkey handler, once. Carbon calls it on the main thread, from the run loop.
    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotkeys.signature else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { GlobalHotkeys.shared.fire(id.id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire(_ raw: UInt32) {
        guard let slot = Slot(rawValue: raw), let action = actions[slot] else { return }
        Usage.register("hotkey.\(slot)", label: slot == .quickPanel ? "Quick panel hotkey" : "Window hotkey")
        Usage.record(.shortcut, "hotkey.\(slot)", source: .keyboard)
        Usage.attributed(action)
    }
}
