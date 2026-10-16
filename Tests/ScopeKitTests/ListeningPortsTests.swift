import Darwin
import Foundation
import Testing
@testable import ScopeCore

@Suite struct ListeningPortsTests {
    /// A TCP socket bound and listening on `port`; closed by the caller.
    private func listen(on port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else { close(fd); return nil }
        return fd
    }

    @Test func findsTheProcessesOwnListenerAndNothingOutsideTheBlock() throws {
        let block = PortBlock(base: 41_230)
        var fd: Int32?
        var port = 0
        // The first free port of the block: another test or a dev server may hold one.
        for candidate in block.range {
            if let opened = listen(on: candidate) { fd = opened; port = candidate; break }
        }
        let opened = try #require(fd)
        defer { close(opened) }
        let me = getpid()
        let listeners = ListeningPorts.listeners(of: [me])
        #expect(listeners.contains(ListeningPorts.Listener(port: port, pid: me)))
        #expect(block.ports(in: listeners) == [port])
        #expect(PortBlock(base: 41_240).ports(in: listeners).isEmpty)
        close(opened)
        fd = nil
        #expect(!ListeningPorts.listeners(of: [me]).contains { $0.port == port })
    }

    @Test func blockFiltersAndDeduplicates() {
        let block = PortBlock(base: 41_000)
        let listeners = [ListeningPorts.Listener(port: 41_003, pid: 1), .init(port: 41_003, pid: 2), .init(port: 41_009, pid: 3),
                         .init(port: 41_010, pid: 4), .init(port: 3_000, pid: 5)]
        #expect(block.ports(in: listeners) == [41_003, 41_009])
        #expect(block.contains(41_000) && !block.contains(41_010))
        #expect(PortBlock.url(for: 41_003).absoluteString == "http://localhost:41003")
    }

    @Test func networkOrderPortIsDecoded() {
        #expect(ListeningPorts.port(fromNetworkOrder: Int32(UInt16(41_003).bigEndian)) == 41_003)
        #expect(ListeningPorts.port(fromNetworkOrder: 0) == nil)
    }

    @Test func aDeadPidHasNoPorts() {
        #expect(ListeningPorts.listeners(of: [pid_t(Int32.max)]).isEmpty)
    }
}
