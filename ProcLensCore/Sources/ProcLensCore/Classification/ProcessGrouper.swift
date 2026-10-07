import Darwin

/// Assigns each process to a Task Manager style group (apps, background, system).
public struct ProcessGrouper: Sendable {
    private static let maxAncestorDepth = 32
    private static let systemPathPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]

    private let appPIDs: Set<pid_t>
    private let names: DaemonNameMap

    public init(apps: [RunningAppInfo], names: DaemonNameMap = .shared) {
        self.appPIDs = Set(apps.filter(\.isRegular).map(\.pid))
        self.names = names
    }

    /// Rules, in order: regular GUI app → `.apps`; root or role account (uid < 500) → `.system`;
    /// system binary path → `.system`; system origin in the name map → `.system`; else `.background`.
    public func group(for p: ProcessSample) -> ProcessGroup {
        if appPIDs.contains(p.pid) { return .apps }
        if p.uid < 500 { return .system }
        if let path = p.path, Self.systemPathPrefixes.contains(where: { path.hasPrefix($0) }) {
            return .system
        }
        if names.isSystemOrigin(p.name) { return .system }
        return .background
    }

    /// Maps each process to the `.apps` process among its ancestors (nearest one wins).
    /// Processes with no app ancestor are omitted. The app itself is not mapped to itself.
    public func groupApps(_ processes: [ProcessSample]) -> [ProcessID: ProcessID] {
        var byPID: [pid_t: ProcessSample] = [:]
        byPID.reserveCapacity(processes.count)
        for p in processes { byPID[p.pid] = p }

        var owners: [ProcessID: ProcessID] = [:]
        for p in processes {
            var visited: Set<pid_t> = [p.pid]
            var parentPID = p.ppid
            var depth = 0
            while depth < Self.maxAncestorDepth {
                guard visited.insert(parentPID).inserted, let parent = byPID[parentPID] else { break }
                if group(for: parent) == .apps {
                    owners[p.id] = parent.id
                    break
                }
                parentPID = parent.ppid
                depth += 1
            }
        }
        return owners
    }
}
