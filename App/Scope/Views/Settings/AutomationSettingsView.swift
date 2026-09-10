import AppKit
import ScopeControl
import ScopeCore
import ScopeDrivers
import SwiftUI

/// Settings ▸ Automation: what agents may ask Scope to do, and the `scope` command line tool.
///
/// The two live together on purpose. The command line and the MCP server are the same door, and this pane
/// is where the user decides how far it opens.
struct AutomationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var installMessage: String?
    @State private var installFailure: String?

    var body: some View {
        Form {
            Section("Command line") {
                LabeledContent("Inside a thread") {
                    Text("`scope` is already on the PATH")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Your own terminal") {
                    HStack(spacing: 8) {
                        Text(linkState)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(isInstalled ? "Reinstall" : "Install") { install() }
                            .controlSize(.small)
                            .disabled(toolPath == nil)
                    }
                }
                if let installFailure {
                    Text(installFailure)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let installMessage {
                    Text(installMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // One literal, not a `+` chain: only a literal is read as Markdown, so the code spans render.
                Text("""
                    `scope list`, `scope thread new`, `scope task new`. `scope mcp` speaks MCP on stdio, so an \
                    agent can drive Scope with the same commands.
                    """)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Agents") {
                Toggle("Let agents drive Scope", isOn: automation(\.agentsMayDrive))
                Text("Requests from a thread Scope is running. Your own terminal is always allowed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Stepper(value: automation(\.maxDepth), in: 0...5) {
                    LabeledContent("Depth ceiling", value: depthCaption)
                }
                Text("A thread you opened is at depth 0. The ceiling is how far a chain of agents opening "
                     + "agents may go.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Opening a thread", selection: automation(\.threads)) {
                    ForEach(AutomationSettings.Approval.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Creating a task", selection: automation(\.tasks)) {
                    ForEach(AutomationSettings.Approval.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("A task writes a branch and one worktree per repository, which is why it asks by default.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Socket") {
                LabeledContent("Path") {
                    Text(model.env.socketPath)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("The socket is 0600 in your Scope home: every program running as you can drive Scope "
                     + "through it, exactly as the driver hooks always could.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Bindings

    private func automation<Value>(_ keyPath: WritableKeyPath<AutomationSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.config.preferences.automationSettings[keyPath: keyPath] },
            set: { value in
                model.updatePreferences { preferences in
                    var settings = preferences.automationSettings
                    settings[keyPath: keyPath] = value
                    preferences.automation = settings
                }
            }
        )
    }

    private var depthCaption: String {
        let depth = model.config.preferences.automationSettings.maxDepth
        return switch depth {
        case 0: "0 — agents may not open threads"
        case 1: "1 — an agent may open a thread, that thread may not"
        default: "\(depth) generations"
        }
    }

    // MARK: Install

    private var toolPath: String? { ScopeCLILocator.embedded(in: Bundle.main.bundleURL) }

    private var destination: CLIInstaller.Destination {
        CLIInstaller.preferredDestination(home: model.env.home)
    }

    private var isInstalled: Bool {
        guard let toolPath else { return false }
        if case .installed = CLIInstaller.state(of: destination, toolPath: toolPath) { return true }
        return false
    }

    private var linkState: String {
        guard let toolPath else { return "not in this build" }
        return switch CLIInstaller.state(of: destination, toolPath: toolPath) {
        case .installed(let link): link
        case .foreign(let link, _): "\(link) (not Scope's)"
        case .absent: "not installed"
        }
    }

    private func install() {
        guard let toolPath else { return }
        installFailure = nil
        do {
            let link = try CLIInstaller.install(toolPath: toolPath, to: destination)
            installMessage = [
                "Linked \(link).",
                CLIInstaller.pathAdvice(for: destination),
            ].compactMap { $0 }.joined(separator: "\n")
        } catch let error as ControlError {
            installMessage = nil
            installFailure = error.description
        } catch {
            installMessage = nil
            installFailure = String(describing: error)
        }
    }
}
