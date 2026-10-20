import ScopeAdapters
import ScopeCore
import ScopeTasks
import SwiftUI

/// The Plan card: what the agent means to do and where it is, live. Closed, `3/7 steps · Running the tests`; open,
/// one block per live thread that has a plan — the plan's title, then one row per step in the agent's own words,
/// the current one in primary ink, done ones struck — read from the todo list and plan-mode output its hooks report
/// (`AgentPlan`). A mission task puts its milestones first, the level above: the current one opens on the steps of
/// the thread doing it.
///
/// `activity` is not observed; the turn revision moves when a plan does, so a `TodoWrite` redraws the rows within
/// the second. Under Reduce Motion nothing animates.
struct PlanCard: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var onNatural: (Double) -> Void

    var body: some View {
        let task = model.currentTask
        CollapsibleSection(section: .plan, bodyHeight: bodyHeight, onNatural: onNatural) {
            if let task { summary(task) }
        } actions: {
            EmptyView()
        } content: {
            if let task { content(task) }
        }
    }

    @ViewBuilder
    private func summary(_ task: TaskState) -> some View {
        let plans = plans(of: task)
        if let mission = task.record.mission, !mission.milestones.isEmpty {
            let (reached, total) = mission.progress
            let step = plans.first?.plan.currentStep.map { " · \($0.label)" } ?? ""
            Text("\(reached)/\(total) milestones\(step)")
        } else if let first = plans.first {
            Text(first.plan.headline)
        } else {
            Text("no plan yet").foregroundStyle(Ink.tertiary)
        }
    }

    @ViewBuilder
    private func content(_ task: TaskState) -> some View {
        let plans = plans(of: task)
        let mission = task.record.mission
        if plans.isEmpty, mission?.milestones.isEmpty ?? true {
            CardEmptyState(title: "No plan yet",
                           detail: "The agent's todo list and plan-mode output appear here as it works.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let mission, !mission.milestones.isEmpty {
                    milestones(task, mission: mission)
                } else {
                    ForEach(plans, id: \.session.id) { entry in
                        ThreadPlanBlock(title: plans.count > 1 ? model.displayTitle(for: entry.session) : nil, plan: entry.plan)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    /// The milestones as the mission checklist draws them; under the first one not reached, the plans of the
    /// threads doing it — its child task's when it has one, this task's otherwise.
    @ViewBuilder
    private func milestones(_ task: TaskState, mission: Mission) -> some View {
        let current = mission.next?.id
        ForEach(Array(mission.milestones.enumerated()), id: \.element.id) { index, milestone in
            MilestoneRow(task: task, number: index + 1, milestone: milestone)
            if milestone.id == current {
                let doing = milestone.task.flatMap(model.task).map(plans(of:)) ?? []
                let plans = doing.isEmpty ? plans(of: task) : doing
                if plans.isEmpty {
                    Text("No steps yet for this milestone.")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.leading, 20)
                        .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(plans, id: \.session.id) { entry in
                            ThreadPlanBlock(title: plans.count > 1 ? model.displayTitle(for: entry.session) : nil, plan: entry.plan)
                        }
                    }
                    .padding(.leading, 20)
                    .padding(.bottom, 4)
                }
            }
        }
    }

    /// The live threads of `task` that have a plan, the ones at work first, the freshest plan next.
    private func plans(of task: TaskState) -> [(session: ThreadSession, plan: AgentPlan)] {
        model.threads(in: task.id)
            .filter(\.isAlive)
            // Read here so the card redraws when a plan moves (`ThreadSession.setActivity` bumps the revision).
            .map { session -> (ThreadSession, AgentPlan?, Int) in (session, session.activity.plan, session.turnRevision) }
            .compactMap { session, plan, _ in plan.map { (session: session, plan: $0) } }
            .sorted { lhs, rhs in
                if lhs.session.isWorking != rhs.session.isWorking { return lhs.session.isWorking }
                return lhs.plan.updatedAt > rhs.plan.updatedAt
            }
    }
}

/// One thread's plan: the thread's title as a group label when the card holds several, the plan's title, then the
/// steps, folded after `shortCount` rows with *Show all N*.
private struct ThreadPlanBlock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String?
    let plan: AgentPlan
    @State private var showAll = false

    static let shortCount = 8

    var body: some View {
        let steps = plan.steps
        let current = plan.currentStep
        VStack(alignment: .leading, spacing: 0) {
            if let title { CardGroupLabel(title, count: plan.total) }
            if let planTitle = plan.title {
                Text(planTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(2)
                    .padding(.top, title == nil ? 4 : 2)
                    .padding(.bottom, 3)
            }
            if steps.isEmpty {
                Text("No steps listed.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .padding(.vertical, 3)
            }
            ForEach(Array((showAll ? steps : Array(steps.prefix(Self.shortCount))).enumerated()), id: \.offset) { _, step in
                PlanStepRow(step: step, isCurrent: step == current)
            }
            if steps.count > Self.shortCount {
                Button(showAll ? "Show fewer" : "Show all \(steps.count)") { showAll.toggle() }
                    .buttonStyle(.plain)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .padding(.top, 2)
                    .padding(.leading, 24)
                    .usageID("plan.show-all", label: "Show every step of the plan")
            }
        }
        .padding(.bottom, 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: steps)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title.map { "Plan of \($0)" } ?? "Plan")
        .accessibilityValue(plan.headline)
    }
}

/// One step: a glyph for its state (`circle` pending, `circle.dotted` in the accent while it runs,
/// `checkmark.circle.fill` done), its text in the agent's words — the active form while it runs — the current one
/// in primary ink, the others secondary, the done ones struck. The density of a todo box, not of a settings list.
private struct PlanStepRow: View {
    let step: AgentPlan.Step
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: step.status == .inProgress ? .semibold : .regular))
                .foregroundStyle(color)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(step.label)
                .font(.system(size: 12, weight: isCurrent ? .medium : .regular))
                .foregroundStyle(ink)
                .strikethrough(step.status == .completed, color: Ink.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .help(step.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.label)
        .accessibilityValue(status)
    }

    private var symbol: String {
        switch step.status {
        case .pending: "circle"
        case .inProgress: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch step.status {
        case .pending: Ink.tertiary
        case .inProgress: Color.accentColor
        case .completed: ThreadStateStyle.done
        }
    }

    private var ink: Color {
        switch step.status {
        case .completed: Ink.tertiary
        default: isCurrent ? Ink.primary : Ink.secondary
        }
    }

    private var status: String {
        switch step.status {
        case .pending: "pending"
        case .inProgress: "in progress"
        case .completed: "done"
        }
    }
}
