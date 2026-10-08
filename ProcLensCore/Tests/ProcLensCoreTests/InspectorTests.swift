import Darwin
import Foundation
import Testing
@testable import ProcLensCore

struct AddressFormatterTests {
    @Test func ipv4() {
        #expect(AddressFormatter.string([192, 168, 1, 10]) == "192.168.1.10")
        #expect(AddressFormatter.isLoopback([127, 0, 0, 1]))
        #expect(!AddressFormatter.isLoopback([10, 0, 0, 1]))
    }

    @Test func ipv6() {
        var loop = [UInt8](repeating: 0, count: 16); loop[15] = 1
        #expect(AddressFormatter.string(loop) == "::1")
        #expect(AddressFormatter.isLoopback(loop))
        #expect(AddressFormatter.string([UInt8](repeating: 0, count: 16)) == "::")
        let fe80: [UInt8] = [0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        #expect(AddressFormatter.string(fe80) == "fe80::1")
        #expect(!AddressFormatter.isLoopback(fe80))
    }

    @Test func v4Mapped() {
        let mapped: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1]
        #expect(AddressFormatter.string(mapped) == "127.0.0.1")
        #expect(AddressFormatter.isLoopback(mapped))
        let mapped2: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 8, 8, 8, 8]
        #expect(AddressFormatter.string(mapped2) == "8.8.8.8")
        #expect(!AddressFormatter.isLoopback(mapped2))
    }

    @Test func endpoints() {
        #expect(AddressFormatter.endpoint(address: [127, 0, 0, 1], port: 3000) == "127.0.0.1:3000")
        #expect(AddressFormatter.endpoint(address: [0, 0, 0, 0], port: 80) == "*:80")
        var loop = [UInt8](repeating: 0, count: 16); loop[15] = 1
        #expect(AddressFormatter.endpoint(address: loop, port: 8080) == "[::1]:8080")
    }
}

struct FileDescriptorInspectorTests {
    @Test func parsesAllKinds() async throws {
        var p = MockFDSource.Proc()
        p.fds = [
            FDEntry(fd: 5, type: .socket), FDEntry(fd: 0, type: .vnode), FDEntry(fd: 1, type: .vnode),
            FDEntry(fd: 3, type: .pipe), FDEntry(fd: 4, type: .kqueue), FDEntry(fd: 6, type: .socket),
            FDEntry(fd: 7, type: .socket), FDEntry(fd: 8, type: .other(9)), FDEntry(fd: 9, type: .vnode),
        ]
        p.vnodes[0] = RawVnodeInfo(path: "/dev/null", openFlags: UInt32(FREAD))
        p.vnodes[1] = RawVnodeInfo(path: "/tmp/out.log", openFlags: UInt32(FREAD | FWRITE))
        p.pipes[3] = RawPipeInfo(handle: 0xabc, peerHandle: 0xdef)
        p.sockets[5] = RawSocketInfo(kind: .tcp, family: AF_INET, proto: IPPROTO_TCP, localAddress: [127, 0, 0, 1],
                                     remoteAddress: [10, 0, 0, 2], localPort: 51000, remotePort: 443, tcpState: 4)
        p.sockets[6] = RawSocketInfo(kind: .inet, family: AF_INET6, proto: IPPROTO_UDP, isIPv6: true,
                                     localAddress: [UInt8](repeating: 0, count: 16),
                                     remoteAddress: [UInt8](repeating: 0, count: 16), localPort: 5353)
        p.sockets[7] = RawSocketInfo(kind: .unix, family: AF_UNIX, proto: 0, unixPath: "/var/run/x.sock")
        // fd 9: vnode info unreadable -> .other
        let inspector = FileDescriptorInspector(source: MockFDSource([42: p]))
        let d = try await inspector.descriptors(pid: 42)

        #expect(d.map(\.fd) == [0, 1, 3, 4, 5, 6, 7, 8, 9])
        #expect(d[0].kind == .file && d[0].path == "/dev/null" && d[0].mode == "r")
        #expect(d[1].mode == "rw")
        #expect(d[2].kind == .pipe && d[2].detail == "pipe 0xabc, peer 0xdef")
        #expect(d[3].kind == .kqueue)
        let tcp = try #require(d[4].socket)
        #expect(d[4].kind == .tcpSocket && tcp.local == "127.0.0.1:51000" && tcp.remote == "10.0.0.2:443")
        #expect(tcp.state == .established && tcp.family == .ipv4 && tcp.proto == .tcp)
        let udp = try #require(d[5].socket)
        #expect(d[5].kind == .udpSocket && udp.local == "*:5353" && udp.remote == "*:*" && udp.family == .ipv6)
        #expect(d[6].kind == .unixSocket && d[6].path == "/var/run/x.sock")
        #expect(d[7].kind == .other)
        #expect(d[8].kind == .other)
    }

    @Test func listFailurePropagates() async {
        var p = MockFDSource.Proc(); p.listError = EPERM
        let inspector = FileDescriptorInspector(source: MockFDSource([1: p]))
        await #expect(throws: SourceError.self) { _ = try await inspector.descriptors(pid: 1) }
    }

    @Test func liveOwnPIDSeesCreatedFile() async throws {
        let path = NSTemporaryDirectory() + "proclens-fd-\(UUID().uuidString).txt"
        let handle = try #require(FileHandle(forWritingAtPath: { FileManager.default.createFile(atPath: path, contents: Data()); return path }()))
        defer { try? handle.close(); try? FileManager.default.removeItem(atPath: path) }

        let d = try await FileDescriptorInspector().descriptors(pid: getpid())
        let resolved = path.withCString { realpath($0, nil).map { String(cString: $0) } } ?? path
        let match = d.first { $0.path == resolved || $0.path == path }
        #expect(match != nil)
        #expect(match?.kind == .file)
        #expect(match?.mode == "w")
    }

    @Test func liveSocketsOfOwnPIDDecode() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(fd, 1) == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: addr.sin_port)

        let d = try await FileDescriptorInspector().descriptors(pid: getpid())
        let me = try #require(d.first { $0.fd == fd })
        #expect(me.kind == .tcpSocket)
        #expect(me.socket?.state == .listen)
        #expect(me.socket?.local == "127.0.0.1:\(port)")
        #expect(me.socket?.localPort == port)
    }
}

struct LoadedImagesInspectorTests {
    struct MockRegions: RegionSource {
        var regions: [MemoryRegion]
        func region(pid: pid_t, atOrAfter address: UInt64) throws -> MemoryRegion? {
            regions.first { $0.address >= address }
        }
    }

    @Test func uniquePathsAndExecutable() async throws {
        let src = MockRegions(regions: [
            MemoryRegion(address: 0x1000, size: 0x1000, protection: 5, path: "/usr/bin/foo"),
            MemoryRegion(address: 0x2000, size: 0x1000, protection: 3, path: "/usr/bin/foo"),
            MemoryRegion(address: 0x3000, size: 0x1000, protection: 3, path: ""),
            MemoryRegion(address: 0x4000, size: 0x2000, protection: 3, path: "/tmp/data.bin"),
        ])
        let images = try await LoadedImagesInspector(source: src).images(pid: 1)
        #expect(images.map(\.path) == ["/usr/bin/foo", "/tmp/data.bin"])
        #expect(images[0].regionCount == 2 && images[0].totalSize == 0x2000 && images[0].isExecutable)
        #expect(images[0].baseAddress == 0x1000)
        #expect(!images[1].isExecutable)
    }

    @Test func zeroSizeRegionTerminates() async throws {
        let src = MockRegions(regions: [MemoryRegion(address: 0, size: 0, protection: 5, path: "/x")])
        let images = try await LoadedImagesInspector(source: src).images(pid: 1)
        #expect(images.count == 1)
    }

    @Test func liveOwnProcessListsExecutable() async throws {
        let images = try await LoadedImagesInspector().images(pid: getpid())
        #expect(!images.isEmpty)
        #expect(images.contains { $0.isExecutable })
    }
}

struct SigningDetailsTests {
    @Test func appleBinaryDetails() async throws {
        let d = try #require(await CodeSignatureInspector().details(forPath: "/bin/ls"))
        #expect(d.status == .apple)
        #expect(d.identifier == "com.apple.ls")
        #expect(!d.certificateChain.isEmpty)
    }

    @Test func missingFileIsNil() async {
        #expect(await CodeSignatureInspector().details(forPath: "/nonexistent/zzz") == nil)
    }

    @Test func entitlementsConversion() {
        let v = EntitlementValue(any: ["a": true, "b": "x", "c": [1, 2], "d": 3] as [String: Any])
        guard case .dictionary(let d) = v else { Issue.record("not dict"); return }
        #expect(d["a"] == .bool(true))
        #expect(d["b"] == .string("x"))
        #expect(d["c"] == .array([.number(1), .number(2)]))
        #expect(d["d"] == .number(3))
    }
}
