import Foundation
import Testing
@testable import ScopeDrivers

@Suite("ModelLabel")
struct ModelLabelTests {
    @Test("a model id reads as its family and version")
    func names() {
        #expect(ModelLabel.name("claude-fable-5-1") == "Fable 5.1")
        #expect(ModelLabel.name("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelLabel.name("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(ModelLabel.name("haiku") == "Haiku")
        #expect(ModelLabel.name("opus[1m]") == "Opus [1m]")
        #expect(ModelLabel.name("gpt-5-codex") == "Gpt 5 codex")
        #expect(ModelLabel.name("  ") == nil)
        #expect(ModelLabel.name(nil) == nil)
    }

    @Test("the line prefers what the driver reported and adds the driver and its version when known")
    func line() {
        #expect(ModelLabel.line(model: "claude-fable-5-1", reportedName: "Fable 5.1", driver: "Claude Code", driverVersion: "2.1.47")
                == "Fable 5.1 · Claude Code 2.1.47")
        #expect(ModelLabel.line(model: "claude-opus-5-5", reportedName: nil, driver: "Claude Code", driverVersion: nil)
                == "Opus 5.5 · Claude Code")
        #expect(ModelLabel.line(model: nil, reportedName: "Fable 5.1", driver: nil, driverVersion: nil) == "Fable 5.1")
        #expect(ModelLabel.line(model: nil, reportedName: nil, driver: "Shell", driverVersion: nil) == nil)
    }
}
