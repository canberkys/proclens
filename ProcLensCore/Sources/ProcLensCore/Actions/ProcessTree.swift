import Darwin

/// Parent/child view of a `ProcessTable`: stable ordering (start time, then pid), cycle-safe,
/// and robust against pid reuse (a "parent" that started after its child is not a parent).
public struct ProcessTree: Sendable {
    public let processes: [ProcessID: ProcessSample]
    /// Top-level processes (parent absent from the table, or part of a cycle), in stable order.
    public let roots: [ProcessID]
    private let childMap: [ProcessID: [ProcessID]]
    private let parentMap: [ProcessID: ProcessID]

    public init(table: ProcessTable) {
        let procs = table.processes
        func ordered(_ a: ProcessID, _ b: ProcessID) -> Bool {
            (a.startTime, a.pid) < (b.startTime, b.pid)
        }

        // Newest instance wins if two entries share a pid (a stale entry from a reused pid).
        var byPID: [pid_t: ProcessID] = [:]
        for id in procs.keys {
            if let existing = byPID[id.pid], existing.startTime >= id.startTime { continue }
            byPID[id.pid] = id
        }

        var candidates: [ProcessID: [ProcessID]] = [:]
        var rootCandidates: [ProcessID] = []
        for (id, p) in procs {
            if p.ppid != id.pid, let parent = byPID[p.ppid], parent.startTime <= id.startTime {
                candidates[parent, default: []].append(id)
            } else {
                rootCandidates.append(id)
            }
        }
        for key in candidates.keys { candidates[key]?.sort(by: ordered) }
        rootCandidates.sort(by: ordered)

        // Walk from the roots, then from whatever is left (cycles), recording only edges that
        // reach a not-yet-visited node, so every process appears exactly once.
        var visited = Set<ProcessID>()
        var children: [ProcessID: [ProcessID]] = [:]
        var parents: [ProcessID: ProcessID] = [:]
        var finalRoots: [ProcessID] = []

        func walk(from root: ProcessID) {
            var queue = [root]
            visited.insert(root)
            var head = 0
            while head < queue.count {
                let node = queue[head]; head += 1
                for child in candidates[node] ?? [] where visited.insert(child).inserted {
                    children[node, default: []].append(child)
                    parents[child] = node
                    queue.append(child)
                }
            }
        }

        for root in rootCandidates where !visited.contains(root) {
            finalRoots.append(root)
            walk(from: root)
        }
        if visited.count < procs.count {
            for id in procs.keys.sorted(by: ordered) where !visited.contains(id) {
                finalRoots.append(id)
                walk(from: id)
            }
        }
        finalRoots.sort(by: ordered)

        self.processes = procs
        self.roots = finalRoots
        self.childMap = children
        self.parentMap = parents
    }

    public func parent(of id: ProcessID) -> ProcessID? { parentMap[id] }

    /// Direct children, oldest first.
    public func children(of id: ProcessID) -> [ProcessID] { childMap[id] ?? [] }

    /// All descendants in breadth-first order (nearest first); excludes `id` itself.
    public func descendants(of id: ProcessID) -> [ProcessID] {
        var result: [ProcessID] = []
        var head = 0
        var queue = children(of: id)
        while head < queue.count {
            let node = queue[head]; head += 1
            result.append(node)
            queue.append(contentsOf: children(of: node))
        }
        return result
    }

    /// Pre-order flattening honoring `isExpanded` (for the UI list). Roots are always shown.
    public func flattened(isExpanded: (ProcessID) -> Bool) -> [(id: ProcessID, depth: Int)] {
        var out: [(ProcessID, Int)] = []
        var stack: [(ProcessID, Int)] = roots.reversed().map { ($0, 0) }
        while let (id, depth) = stack.popLast() {
            out.append((id, depth))
            if isExpanded(id) {
                for child in children(of: id).reversed() { stack.append((child, depth + 1)) }
            }
        }
        return out.map { (id: $0.0, depth: $0.1) }
    }
}
