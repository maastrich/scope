import Foundation
import Testing
@testable import ScopeCore
@testable import ScopeTasks

@Suite struct ListeningProcessesTests {
    /// `lsof -nP -iTCP:4310 -iTCP:4311 -sTCP:LISTEN -F pcn`, as macOS prints it: a dual-stack server has one `n`
    /// line per family, and a process may hold two ports of the block.
    static let fixture = """
    p5120
    cpython3.12
    f3
    n*:4310
    p5340
    cnode
    f21
    n127.0.0.1:4311
    f22
    n[::1]:4311
    f23
    n*:4312
    p5400
    cScope Debug
    f9
    n*:*
    """

    @Test func parsesFieldOutputOnePairPerPortAndPid() {
        let entries = ListeningProcesses.parse(Self.fixture)
        #expect(entries == [
            .init(pid: 5120, command: "python3.12", port: 4310),
            .init(pid: 5340, command: "node", port: 4311),
            .init(pid: 5340, command: "node", port: 4312),
        ])
    }

    @Test func emptyAndForeignOutputGiveNothing() {
        #expect(ListeningProcesses.parse("").isEmpty)
        #expect(ListeningProcesses.parse("COMMAND PID USER\npython3 5120 me\n").isEmpty)
        #expect(ListeningProcesses.parse("n*:4310\n").isEmpty, "a name before any pid belongs to nobody")
    }

    @Test func portOfANetworkName() {
        #expect(ListeningProcesses.port(in: "*:4310") == 4310)
        #expect(ListeningProcesses.port(in: "[::1]:4311") == 4311)
        #expect(ListeningProcesses.port(in: "127.0.0.1:4312->127.0.0.1:50000") == 4312)
        #expect(ListeningProcesses.port(in: "*:*") == nil)
        #expect(ListeningProcesses.port(in: "/tmp/scope.sock") == nil)
    }

    @Test func lsofArgumentsSelectEveryPortInOneCall() {
        #expect(ListeningProcesses.lsofArguments(ports: [4311, 4310]) == ["-nP", "-iTCP:4310", "-iTCP:4311", "-sTCP:LISTEN", "-F", "pcn"])
    }

    @Test func foldsEntriesIntoOneLinePerProcess() {
        let entries = ListeningProcesses.parse(Self.fixture)
        let lines: [pid_t: String] = [5120: "python3 -m http.server 4310", 5340: "  "]
        let processes = ListeningProcesses.processes(entries, commandLine: { lines[$0] }, owner: { $0 == 5120 ? "thread-a" : nil })
        #expect(processes == [
            .init(pid: 5120, ports: [4310], commandLine: "python3 -m http.server 4310", threadID: "thread-a"),
            .init(pid: 5340, ports: [4311, 4312], commandLine: "node", threadID: nil),
        ])
    }

    @Test func ownerReadsTheEnvironmentThenWalksTheAncestors() {
        let parents: [pid_t: pid_t] = [900: 800, 800: 700, 700: 1]
        let threads: [pid_t: String] = [700: "shell-thread"]
        #expect(ListeningProcesses.owner(of: 900, threads: threads, environment: { _ in ["SCOPE_THREAD": "env-thread"] },
                                         parent: { parents[$0] }) == "env-thread")
        #expect(ListeningProcesses.owner(of: 900, threads: threads, environment: { _ in [:] }, parent: { parents[$0] }) == "shell-thread")
        #expect(ListeningProcesses.owner(of: 700, threads: threads, environment: { _ in [:] }, parent: { parents[$0] }) == "shell-thread",
                "a thread's own shell belongs to the thread")
        #expect(ListeningProcesses.owner(of: 900, threads: [:], environment: { _ in [:] }, parent: { parents[$0] }) == nil)
    }

    @Test func ownerWalkStopsOnACycleOrAMissingParent() {
        let cyclic: [pid_t: pid_t] = [900: 800, 800: 900]
        #expect(ListeningProcesses.owner(of: 900, threads: [1: "init"], environment: { _ in [:] }, parent: { cyclic[$0] }) == nil)
        #expect(ListeningProcesses.owner(of: 900, threads: [:], environment: { _ in [:] }, parent: { _ in nil }) == nil)
    }

    @Test func commandLineNamesTheProgramWithoutItsPath() {
        #expect(ListeningProcesses.commandLine(arguments: ["/opt/homebrew/bin/python3", "-m", "http.server", "4310"]) == "python3 -m http.server 4310")
        #expect(ListeningProcesses.commandLine(arguments: ["node"]) == "node")
        #expect(ListeningProcesses.commandLine(arguments: []) == "")
    }

    @Test func setupCommandsComeFromTheLogHeaders() {
        let log = """
        [api] copied .env from the base checkout
        [api] $ pnpm install
        progress 1/3
        [api] done
        [web] $ pnpm install
        [web] failed: exit 1
        [docs] $ make deps
        """
        #expect(SetupLog.commands(in: log) == ["pnpm install", "make deps"])
        #expect(SetupLog.commands(in: "").isEmpty)
    }

    @Test func ownProcessArgumentsAndParentAreReadable() {
        let me = getpid()
        #expect(!ProcessSweep.arguments(me).isEmpty)
        #expect(ProcessSweep.parent(of: me) == getppid())
        #expect(ProcessSweep.arguments(pid_t(Int32.max)).isEmpty)
        #expect(ProcessSweep.parent(of: pid_t(Int32.max)) == nil)
    }
}
