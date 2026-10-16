import Foundation
import ScopeCore
import Testing
@testable import ScopeControl

/// `scope config get|set`: the allowlist, the values it accepts and the answers it gives.
@Suite struct ConfigKeyTests {
    @Test func getListsEveryKeyOrOne() throws {
        let settings = AutomationSettings(maxAgentTasks: 12, maxAgentThreads: 24)
        guard case .action(let all, .configGet) = try ConfigKey.get(ConfigGetParams(), in: settings).get() else {
            Issue.record("a listing")
            return
        }
        #expect(all.message == "automation.maxAgentTasks = 12\nautomation.maxAgentThreads = 24")
        guard case .action(let one, _) = try ConfigKey.get(ConfigGetParams(key: "Automation.MaxAgentThreads"), in: settings).get() else {
            Issue.record("one key")
            return
        }
        #expect(one.message == "automation.maxAgentThreads = 24")
    }

    @Test func setChangesOnlyItsKey() throws {
        let settings = AutomationSettings(maxAgentTasks: 12, maxAgentThreads: 24)
        let change = try ConfigKey.set(ConfigSetParams(key: "automation.maxAgentTasks", value: "40"), in: settings).get()
        #expect(change.settings.maxAgentTasks == 40)
        #expect(change.settings.maxAgentThreads == 24)
        guard case .action(let answer, .configSet) = change.answer else {
            Issue.record("an action answer")
            return
        }
        #expect(answer.message == "automation.maxAgentTasks = 40 (was 12)")
    }

    @Test func anUnknownKeyOrABadValueIsRefused() {
        let settings = AutomationSettings()
        for params in [ConfigSetParams(key: "automation.agentsMayDrive", value: "true"),
                       ConfigSetParams(key: "automation.maxAgentTasks", value: "lots"),
                       ConfigSetParams(key: "automation.maxAgentTasks", value: "0"),
                       ConfigSetParams(key: "automation.maxAgentTasks", value: "\(AutomationSettings.budgetRange.upperBound + 1)")] {
            guard case .failure(let error) = ConfigKey.set(params, in: settings) else {
                Issue.record("\(params) should be refused")
                continue
            }
            #expect(error.code == .badRequest)
        }
    }
}
