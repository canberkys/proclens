import Darwin

/// Enumerates listening TCP and bound UDP sockets of all accessible processes.
///
/// Per process: `PROC_PIDLISTFDS`, then `PROC_PIDFDSOCKETINFO` for socket fds only. To stay cheap
/// (target < 3 ms for ~1,000 processes) it
/// - skips processes flagged `isRestricted` (the Phase 2 helper supplies those via `setHelperPorts`),
/// - remembers, per `ProcessID`, that a process had no sockets / could not be read, and skips it
///   for `negativeCacheRuns` runs,
/// - drops cache entries of processes that left the table.
public actor ListeningPortCollector: Collector {
    public typealias Sample = [ListeningPort]

    public nonisolated let id = CollectorID("listening-ports")
    public nonisolated let cost: CollectorCost

    private let source: any FDSource
    private let negativeCacheRuns: Int
    private var table = ProcessTable(processes: [:])
    private var runCounter = 0
    /// ProcessID -> run number until which the process is skipped.
    private var skipUntil: [ProcessID: Int] = [:]
    private var helperPorts: [ListeningPort] = []

    public init(source: any FDSource = LiveFDSource(), cost: CollectorCost = .everyN(2), negativeCacheRuns: Int = 5) {
        self.source = source
        self.cost = cost
        self.negativeCacheRuns = max(0, negativeCacheRuns)
    }

    /// Latest process table (feed from the process collector's tick). Used by `sample(at:)`.
    public func update(table: ProcessTable) {
        self.table = table
    }

    /// Results gathered by the privileged helper for restricted processes. Replaces the previous set.
    public func setHelperPorts(_ ports: [ListeningPort]) {
        helperPorts = ports
    }

    public func sample(at instant: ContinuousClock.Instant) async throws -> [ListeningPort] {
        scan(table)
    }

    /// On-demand scan of an explicit table.
    public func scan(table: ProcessTable) -> [ListeningPort] {
        scan(table)
    }

    public func reset() {
        skipUntil.removeAll()
    }

    private func scan(_ table: ProcessTable) -> [ListeningPort] {
        runCounter += 1
        let run = runCounter
        var found: [ListeningPort] = []
        let ids = table.processes.keys

        for pid in ids {
            guard let sample = table.processes[pid], !sample.isRestricted, sample.pid > 0 else { continue }
            if let until = skipUntil[pid], until > run { continue }

            guard let entries = try? source.listFDs(pid: sample.pid) else {
                skipUntil[pid] = run + negativeCacheRuns
                continue
            }
            var hadSocket = false
            for entry in entries where entry.type == .socket {
                hadSocket = true
                guard let raw = try? source.socketInfo(pid: sample.pid, fd: entry.fd),
                      let port = Self.listening(raw, pid: sample.pid, processID: pid) else { continue }
                found.append(port)
            }
            if hadSocket {
                skipUntil.removeValue(forKey: pid)
            } else {
                skipUntil[pid] = run + negativeCacheRuns
            }
        }

        if skipUntil.count > table.processes.count {
            skipUntil = skipUntil.filter { table.processes[$0.key] != nil }
        }

        var seen = Set<String>()
        found = found.filter { seen.insert($0.id).inserted }
        for p in helperPorts where seen.insert(p.id).inserted { found.append(p) }

        found.sort { ($0.port, $0.proto.rawValue, $0.pid) < ($1.port, $1.proto.rawValue, $1.pid) }
        return found
    }

    /// Converts a raw socket to a `ListeningPort` if it is TCP LISTEN or a bound, unconnected UDP socket.
    static func listening(_ raw: RawSocketInfo, pid: pid_t, processID: ProcessID) -> ListeningPort? {
        guard raw.localPort != 0 else { return nil }
        let proto: ListeningPort.TransportProtocol
        switch raw.kind {
        case .tcp:
            guard raw.tcpState == TCPState.listen.rawValue else { return nil }
            proto = .tcp
        case .inet:
            guard raw.proto == IPPROTO_UDP, raw.remotePort == 0,
                  raw.remoteAddress.isEmpty || AddressFormatter.isUnspecified(raw.remoteAddress) else { return nil }
            proto = .udp
        default:
            return nil
        }
        let address = raw.localAddress.isEmpty
            ? (raw.isIPv6 ? "::" : "0.0.0.0") : AddressFormatter.string(raw.localAddress)
        return ListeningPort(port: raw.localPort, proto: proto, address: address,
                             isLoopbackOnly: AddressFormatter.isLoopback(raw.localAddress),
                             pid: pid, processID: processID)
    }
}
