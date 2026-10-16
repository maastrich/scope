import SwiftUI
import ScopeCore

/// The schedules of one scope (the scope settings sheet) or of the chosen scope (Settings ▸ Automation ▸ Schedules):
/// one row each — name, rule, target, next fire, last run — with pause, run now, edit and remove at hand, and
/// *Add Schedule…*, which offers the two examples. Everything is stored on the scope's declaration in `config.json`.
struct ScheduleListEditor: View {
    @Environment(AppModel.self) private var model
    let scopeID: ScopeID
    @State private var editing: ScheduleDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if schedules.isEmpty {
                Text("No scheduled prompt yet. A schedule sends a prompt to the orchestrator — or opens a task — every hour, "
                     + "every day, on weekdays or once a week; the reply lands in the Inbox.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(schedules) { schedule in
                ScheduleRowView(scopeID: scopeID, schedule: schedule) { editing = ScheduleDraft(schedule, scopeID: scopeID) }
            }
            HStack(spacing: 8) {
                Button("Add Schedule…") { editing = ScheduleDraft(scopeID: scopeID) }
                    .buttonStyle(.scopeSecondary)
                    .usageID("schedule-add", label: "Add a schedule")
                Menu("Start from an example") {
                    ForEach(Schedule.examples()) { example in
                        Button(example.name) { editing = ScheduleDraft(example, scopeID: scopeID, isNew: true) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
                .usageID("schedule-example", label: "Start a schedule from an example")
            }
            .padding(.top, 4)
        }
        .sheet(item: $editing) { draft in
            ScheduleEditorSheet(draft: draft)
        }
    }

    private var schedules: [Schedule] { model.scope(scopeID)?.declaration.schedules ?? [] }
}

private struct ScheduleRowView: View {
    @Environment(AppModel.self) private var model
    let scopeID: ScopeID
    let schedule: Schedule
    var onEdit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: schedule.enabled ? "clock" : "pause.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(schedule.enabled ? Ink.secondary : Ink.tertiary)
                .frame(width: 14, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(schedule.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(schedule.enabled ? Ink.primary : Ink.secondary)
                        .lineLimit(1)
                    if !schedule.enabled {
                        Text("paused")
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
                Text(caption)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                action("play", "Run now", id: "schedule-run") { model.fireSchedule(schedule, in: scopeID) }
                    .disabled(model.runningSchedules.contains(schedule.id))
                action(schedule.enabled ? "pause" : "play.circle", schedule.enabled ? "Pause" : "Resume", id: "schedule-toggle") {
                    model.setSchedule(schedule.id, in: scopeID, enabled: !schedule.enabled)
                }
                action("pencil", "Edit", id: "schedule-edit") { onEdit() }
                action("trash", "Remove", id: "schedule-remove") { model.removeSchedule(schedule.id, from: scopeID) }
            }
            .buttonStyle(.iconTight)
            .foregroundStyle(Ink.secondary)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Fill.hover : .clear, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .onHover { hovering = $0 }
        .help(schedule.prompt)
    }

    /// `daily at 09:00 · orchestrator · next Fri 09:00 · last run Thu 09:00: replied — all green`
    private var caption: String {
        var parts = [schedule.rule.description(), schedule.target.description]
        if schedule.enabled, let next = Scheduler.nextFire(schedule.rule, after: .now) {
            parts.append("next " + next.formatted(date: .abbreviated, time: .shortened))
        }
        if let run = schedule.lastRun {
            var last = "last run " + run.at.formatted(date: .abbreviated, time: .shortened) + ": " + outcome(run)
            if let summary = run.summary { last += " — " + summary }
            parts.append(last)
        }
        return parts.joined(separator: " · ")
    }

    private func outcome(_ run: ScheduleRun) -> String {
        switch run.outcome {
        case .replied: "replied"
        case .noReply: model.runningSchedules.contains(schedule.id) ? "waiting for the reply" : "no reply"
        case .failed: "did not run"
        }
    }

    private func action(_ symbol: String, _ help: String, id: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 16, height: 16)
        }
        .help(help)
        .accessibilityLabel("\(help) \(schedule.name)")
        .usageID(id, label: help)
    }
}

/// What the editor sheet works on: a copy of a schedule, or a fresh one, bound to its scope.
struct ScheduleDraft: Identifiable {
    var schedule: Schedule
    var scopeID: ScopeID
    var isNew: Bool

    var id: String { schedule.id }

    init(scopeID: ScopeID) {
        schedule = Schedule(name: "", rule: .daily(hour: 9), prompt: "", target: .orchestrator)
        self.scopeID = scopeID
        isNew = true
    }

    init(_ schedule: Schedule, scopeID: ScopeID, isNew: Bool = false) {
        self.schedule = schedule
        self.scopeID = scopeID
        self.isNew = isNew
    }
}

/// Name, rule, target and prompt of one schedule. Saved as a whole on *Save*; nothing applies live, a half-typed
/// prompt is not a prompt.
struct ScheduleEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScheduleDraft
    private enum Field { case name, prompt, model }
    @FocusState private var focus: Field?

    init(draft: ScheduleDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        SheetChrome(title: draft.isNew ? "New Schedule" : "Edit Schedule") {
            SheetGroup {
                SheetRow("Name") {
                    TextField("Name", text: $draft.schedule.name, prompt: Text("Morning: PRs with red checks"))
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .name)
                        .scopeFieldBox(focused: focus == .name)
                        .usageID("schedule-name", label: "Schedule name")
                }
                SheetRow("When") {
                    HStack(spacing: 8) {
                        ScopePicker("Rule", selection: $draft.schedule.rule.kind, title: draft.schedule.rule.kind.title) {
                            ForEach(ScheduleRule.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .usageID("schedule-rule", label: "Schedule rule")
                        if draft.schedule.rule.kind == .weekly {
                            ScopePicker("Weekday", selection: $draft.schedule.rule.weekday,
                                        title: ScheduleRule.weekdayName(draft.schedule.rule.weekday)) {
                                ForEach(1...7, id: \.self) { Text(ScheduleRule.weekdayName($0)).tag($0) }
                            }
                            .usageID("schedule-weekday", label: "Schedule weekday")
                        }
                        if draft.schedule.rule.kind != .hourly {
                            Text("at")
                                .font(.scopeCaption)
                                .foregroundStyle(Ink.tertiary)
                            Text(String(format: "%02d", draft.schedule.rule.hour))
                                .font(.scopeValue)
                            ScopeStepper(value: draft.schedule.rule.hour, range: 0...23) { draft.schedule.rule.hour = $0 }
                                .usageID("schedule-hour", label: "Schedule hour")
                        } else {
                            Text("at minute")
                                .font(.scopeCaption)
                                .foregroundStyle(Ink.tertiary)
                        }
                        Text(":" + String(format: "%02d", draft.schedule.rule.minute))
                            .font(.scopeValue)
                        ScopeStepper(value: draft.schedule.rule.minute, range: 0...59) { draft.schedule.rule.minute = $0 }
                            .usageID("schedule-minute", label: "Schedule minute")
                    }
                }
                SheetRow("Send to") {
                    HStack(spacing: 8) {
                        ScopePicker("Target", selection: $draft.schedule.target.kind, title: draft.schedule.target.kind.title) {
                            ForEach(ScheduleTarget.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .usageID("schedule-target", label: "Schedule target")
                        if draft.schedule.target.kind == .newTask {
                            ScopePicker("Driver", selection: driverBinding, title: driverTitle) {
                                Text("Scope's usual driver").tag("")
                                ForEach(model.drivers.profiles.filter { $0.id != ResidentRole.terminalDriverID }, id: \.id) {
                                    Text($0.name).tag($0.id)
                                }
                            }
                            .usageID("schedule-driver", label: "Schedule driver")
                            TextField("Model", text: modelBinding, prompt: Text("default model"))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 140)
                                .focused($focus, equals: .model)
                                .scopeFieldBox(focused: focus == .model)
                                .usageID("schedule-model", label: "Schedule model")
                        }
                    }
                }
            }
            SheetGroup(caption: draft.schedule.target.kind == .orchestrator
                       ? "Typed into the scope's orchestrator as a message from Scope; its reply lands in the Inbox under “Schedule \(draft.schedule.name.isEmpty ? "…" : draft.schedule.name) ran”."
                       : "Opens a task with this prompt, on a branch of its own; the first thread's reply lands in the Inbox.") {
                SectionLabel(text: "Prompt")
                TextEditor(text: $draft.schedule.prompt)
                    .font(.scopeBody)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 96, maxHeight: 200)
                    .focused($focus, equals: .prompt)
                    .scopeTextBox(focused: focus == .prompt, inset: 2)
                    .usageID("schedule-prompt", label: "Schedule prompt")
            }
            SheetGroup {
                Toggle("Enabled", isOn: $draft.schedule.enabled)
                    .toggleStyle(.checkbox)
                    .font(.scopeBody)
                    .usageID("schedule-enabled", label: "Schedule enabled")
                if let next = draft.schedule.enabled ? Scheduler.nextFire(draft.schedule.rule, after: .now) : nil {
                    Text("Next: " + next.formatted(date: .complete, time: .shortened))
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                }
            }
        } notice: {
            EmptyView()
        } actions: {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.scopeSecondary)
                .keyboardShortcut(.cancelAction)
                .usageID("cancel", label: "Cancel")
            Button(draft.isNew ? "Add" : "Save") { save() }
                .buttonStyle(.scopePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .usageID("save", label: "Save the schedule")
        }
        .frame(width: 560)
        .onAppear { focus = draft.schedule.name.isEmpty ? .name : .prompt }
    }

    private var canSave: Bool {
        !draft.schedule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.schedule.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var driverBinding: Binding<String> {
        Binding(get: { draft.schedule.target.driver ?? "" }, set: { draft.schedule.target.driver = $0.isEmpty ? nil : $0 })
    }

    private var driverTitle: String {
        guard let id = draft.schedule.target.driver else { return "Scope's usual driver" }
        return model.drivers.profiles.first { $0.id == id }?.name ?? id
    }

    private var modelBinding: Binding<String> {
        Binding(get: { draft.schedule.target.model ?? "" }, set: { draft.schedule.target.model = $0.isEmpty ? nil : $0 })
    }

    private func save() {
        var schedule = draft.schedule
        schedule.name = schedule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        schedule.prompt = schedule.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        model.saveSchedule(schedule, in: draft.scopeID)
        dismiss()
    }
}
