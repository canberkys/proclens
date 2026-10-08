import Darwin
@testable import ProcLensCore

final class MockFDSource: FDSource, @unchecked Sendable {
    struct Proc {
        var fds: [FDEntry] = []
        var vnodes: [Int32: RawVnodeInfo] = [:]
        var sockets: [Int32: RawSocketInfo] = [:]
        var pipes: [Int32: RawPipeInfo] = [:]
        var listError: Int32?
    }

    private let lock = NSLock()
    private var procs: [pid_t: Proc]
    private var _listCalls: [pid_t: Int] = [:]

    init(_ procs: [pid_t: Proc]) { self.procs = procs }

    var listCalls: [pid_t: Int] { lock.withLock { _listCalls } }

    func listFDs(pid: pid_t) throws -> [FDEntry] {
        try lock.withLock {
            _listCalls[pid, default: 0] += 1
            guard let p = procs[pid] else { throw SourceError("list", errno: ESRCH) }
            if let e = p.listError { throw SourceError("list", errno: e) }
            return p.fds
        }
    }
    func vnodeInfo(pid: pid_t, fd: Int32) throws -> RawVnodeInfo {
        guard let v = lock.withLock({ procs[pid]?.vnodes[fd] }) else { throw SourceError("vnode", errno: EBADF) }
        return v
    }
    func socketInfo(pid: pid_t, fd: Int32) throws -> RawSocketInfo {
        guard let v = lock.withLock({ procs[pid]?.sockets[fd] }) else { throw SourceError("socket", errno: EBADF) }
        return v
    }
    func pipeInfo(pid: pid_t, fd: Int32) throws -> RawPipeInfo {
        guard let v = lock.withLock({ procs[pid]?.pipes[fd] }) else { throw SourceError("pipe", errno: EBADF) }
        return v
    }
}

import Foundation
