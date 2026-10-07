import Darwin
import Testing
@testable import ProcLensCore

struct ListeningPortCollectorTests {
    private func sample(_ pid: pid_t, restricted: Bool = false, name: String = "p") -> ProcessSample {
        ProcessSample(id: ProcessID(pid: pid, startTime: UInt64(pid) * 10), ppid: 1, uid: 501, name: name, path: nil,
                      threadCount: 1, isTranslated: false, cpu: 0, memory: 0, diskReadPerSec: 0, diskWritePerSec: 0,
                      energy: 0, isRestricted: restricted)
    }

    private func table(_ s: ProcessSample...) -> ProcessTable {
        ProcessTable(processes: Dictionary(uniqueKeysWithValues: s.map { ($0.id, $0) }))
    }

    private let any4: [UInt8] = [0, 0, 0, 0]
    private let lo4: [UInt8] = [127, 0, 0, 1]

    private func tcp(_ port: UInt16, state: Int32, addr: [UInt8], remotePort: UInt16 = 0) -> RawSocketInfo {
        RawSocketInfo(kind: .tcp, family: AF_INET, proto: IPPROTO_TCP, localAddress: addr, remoteAddress: any4,
                      localPort: port, remotePort: remotePort, tcpState: state)
    }

    private func udp(_ port: UInt16, remotePort: UInt16 = 0, remote: [UInt8] = [0, 0, 0, 0]) -> RawSocketInfo {
        RawSocketInfo(kind: .inet, family: AF_INET, proto: IPPROTO_UDP, localAddress: [0, 0, 0, 0],
                      remoteAddress: remote, localPort: port, remotePort: remotePort)
    }

    private func proc(sockets: [Int32: RawSocketInfo]) -> MockFDSource.Proc {
        var p = MockFDSource.Proc()
        p.fds = [FDEntry(fd: 0, type: .vnode)] + sockets.keys.sorted().map { FDEntry(fd: $0, type: .socket) }
        p.sockets = sockets
        return p
    }

    @Test func keepsListenAndBoundUDPDropsConnected() async {
        let src = MockFDSource([
            10: proc(sockets: [
                3: tcp(3000, state: 1, addr: lo4),                  // LISTEN loopback
                4: tcp(51000, state: 4, addr: lo4, remotePort: 443), // ESTABLISHED -> dropped
                5: udp(5353),                                        // bound UDP kept
                6: udp(0),                                           // ephemeral -> dropped
                7: udp(9999, remotePort: 53, remote: [8, 8, 8, 8]),  // connected UDP -> dropped
                8: tcp(8080, state: 1, addr: any4),                  // LISTEN any
            ]),
        ])
        let c = ListeningPortCollector(source: src)
        let ports = await c.scan(table: table(sample(10)))
        #expect(ports.map(\.port) == [3000, 5353, 8080])
        #expect(ports[0].proto == .tcp && ports[0].isLoopbackOnly && ports[0].address == "127.0.0.1")
        #expect(ports[1].proto == .udp && !ports[1].isLoopbackOnly && ports[1].address == "0.0.0.0")
        #expect(ports[2].address == "0.0.0.0" && !ports[2].isLoopbackOnly)
        #expect(ports[0].pid == 10 && ports[0].processID == ProcessID(pid: 10, startTime: 100))
    }

    @Test func ipv6Listener() async {
        var s = tcp(4000, state: 1, addr: [UInt8](repeating: 0, count: 16))
        s.isIPv6 = true; s.family = AF_INET6
        var loop = [UInt8](repeating: 0, count: 16); loop[15] = 1
        var l = tcp(4001, state: 1, addr: loop); l.isIPv6 = true; l.family = AF_INET6
        let c = ListeningPortCollector(source: MockFDSource([7: proc(sockets: [3: s, 4: l])]))
        let ports = await c.scan(table: table(sample(7)))
        #expect(ports.map(\.address) == ["::", "::1"])
        #expect(ports.map(\.isLoopbackOnly) == [false, true])
    }

    @Test func restrictedSkippedAndHelperMerged() async {
        let src = MockFDSource([
            1: proc(sockets: [3: tcp(22, state: 1, addr: any4)]),
            2: proc(sockets: [3: tcp(2222, state: 1, addr: any4)]),
        ])
        let c = ListeningPortCollector(source: src)
        let t = table(sample(1, restricted: true, name: "sshd"), sample(2))
        #expect(await c.scan(table: t).map(\.port) == [2222])
        #expect(src.listCalls[1] == nil)

        let helper = ListeningPort(port: 22, proto: .tcp, address: "0.0.0.0", isLoopbackOnly: false, pid: 1,
                                   processID: ProcessID(pid: 1, startTime: 10))
        await c.setHelperPorts([helper, helper])
        #expect(await c.scan(table: t).map(\.port) == [22, 2222])
    }

    @Test func noSocketProcessesAreCachedThenRechecked() async {
        let src = MockFDSource([5: proc(sockets: [:]), 6: proc(sockets: [3: tcp(1234, state: 1, addr: any4)])])
        let c = ListeningPortCollector(source: src, negativeCacheRuns: 3)
        let t = table(sample(5), sample(6))
        for _ in 0..<3 { _ = await c.scan(table: t) }
        #expect(src.listCalls[5] == 1)      // run 1 scanned, runs 2-3 skipped
        #expect(src.listCalls[6] == 3)      // socket owners are always re-read
        _ = await c.scan(table: t)          // run 4: cache expired
        #expect(src.listCalls[5] == 2)
    }

    @Test func unreadableProcessIsCached() async {
        var denied = MockFDSource.Proc(); denied.listError = EPERM
        let src = MockFDSource([9: denied])
        let c = ListeningPortCollector(source: src, negativeCacheRuns: 5)
        for _ in 0..<4 { _ = await c.scan(table: table(sample(9))) }
        #expect(src.listCalls[9] == 1)
    }

    @Test func sampleUsesSuppliedTable() async throws {
        let src = MockFDSource([4: proc(sockets: [3: tcp(5000, state: 1, addr: lo4)])])
        let c = ListeningPortCollector(source: src)
        #expect(try await c.sample(at: .now).isEmpty)
        await c.update(table: table(sample(4)))
        #expect(try await c.sample(at: .now).map(\.port) == [5000])
        #expect(c.cost == .everyN(2))
    }

    @Test func liveListenerOwnedBySelfIsFound() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(fd, 1)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: addr.sin_port)

        // Real table from the live process collector.
        let pc = ProcessCollector(source: LiveProcessSource())
        let clock = ContinuousClock()
        _ = try await pc.sample(at: clock.now)
        let live = try await pc.sample(at: clock.now.advanced(by: .seconds(1)))
        let ports = await ListeningPortCollector().scan(table: live)
        print("Live listening ports (\(ports.count)): " + ports.prefix(12).map { "\($0.proto.rawValue)/\($0.address):\($0.port) pid \($0.pid)" }.joined(separator: ", "))
        let mine = ports.first { $0.pid == getpid() && $0.port == port }
        #expect(mine != nil)
        #expect(mine?.isLoopbackOnly == true)
    }
}
