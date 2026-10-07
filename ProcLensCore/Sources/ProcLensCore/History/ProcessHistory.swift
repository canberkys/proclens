import Foundation

/// One hour of history in a bounded amount of memory (in-memory only; nothing is written to disk,
/// history starts empty at every launch).
///
/// Tiers:
/// - System totals: every snapshot for the last 10 minutes (`fineWindow`), then one averaged point
///   (plus the peak, used by `spikes`) per 10 s bucket for the last hour (`totalWindow`).
/// - Processes: per 10 s bucket only the top 20 by CPU and top 20 by memory (union, at most 40 entries
///   of ~32 bytes). Names are interned. There is never a per-process series for the whole table;
///   `series(for:)` stitches a process's points from the buckets whose top lists it entered.
///
/// While a bucket is open, one small accumulator entry per live process (~1,000 x ~80 B, transient)
/// is kept to compute CPU means and memory peaks; it is discarded at every bucket boundary.
/// `estimatedMemoryBytes()` reports the footprint (about 0.6 MB for 1 h at ~1,050 processes).
public actor ProcessHistory {
    public static let fineWindow: TimeInterval = 600
    public static let totalWindow: TimeInterval = 3600
    public static let bucketLength: TimeInterval = 10
    public static let topCount = 20

    struct FinePoint: Sendable {
        var time: Double
        var values: MetricVector
    }

    struct Entry: Sendable {
        var pid: Int32
        var nameIndex: UInt32
        var startTime: UInt64
        var memory: UInt64
        var cpu: Float
    }

    struct Bucket: Sendable {
        var start: Double
        var average: MetricVector
        var peak: MetricVector
        var entries: [Entry]
    }

    struct ProcessAccumulator {
        var cpuSum: Double
        var ticks: Int32
        var memoryPeak: UInt64
        var name: String
    }

    struct SystemAccumulator {
        var sum = MetricVector()
        var peak = MetricVector()
        var counts = [Int](repeating: 0, count: HistoryMetric.allCases.count)
        var isEmpty: Bool { counts.allSatisfy { $0 == 0 } }
    }

    private var fine: [FinePoint] = []
    private var coarse: [Bucket] = []
    private var currentKey: Int?
    private var systemAcc = SystemAccumulator()
    private var processAcc: [ProcessID: ProcessAccumulator] = [:]
    private var names: [String] = []
    private var nameIndex: [String: UInt32] = [:]
    private var lastTime = -Double.infinity

    public init() {}

    // MARK: - Recording

    /// Feeds one snapshot. `date` is the wall-clock time of the tick; times going backwards are ignored.
    public func record(_ snapshot: SystemSnapshot, at date: Date = Date()) {
        let t = date.timeIntervalSince1970
        guard t > lastTime else { return }
        lastTime = t

        let key = Int((t / Self.bucketLength).rounded(.down))
        if let current = currentKey, current != key { finalizeBucket(key: current) }
        currentKey = key

        let values = MetricVector(snapshot: snapshot)
        fine.append(FinePoint(time: t, values: values))
        let fineCutoff = t - Self.fineWindow
        if let first = fine.first, first.time < fineCutoff {
            let drop = fine.prefix { $0.time < fineCutoff }.count
            fine.removeFirst(drop)
        }

        for (i, metric) in HistoryMetric.allCases.enumerated() {
            let v = values[metric]
            guard !v.isNaN else { continue }
            systemAcc.sum[metric] = (systemAcc.sum[metric].isNaN ? 0 : systemAcc.sum[metric]) + v
            systemAcc.peak[metric] = systemAcc.peak[metric].isNaN ? v : max(systemAcc.peak[metric], v)
            systemAcc.counts[i] += 1
        }

        if let table = snapshot.processes {
            for (id, p) in table.processes {
                if var acc = processAcc[id] {
                    acc.cpuSum += p.cpu
                    acc.ticks += 1
                    acc.memoryPeak = max(acc.memoryPeak, p.memory)
                    processAcc[id] = acc
                } else {
                    processAcc[id] = ProcessAccumulator(cpuSum: p.cpu, ticks: 1, memoryPeak: p.memory, name: p.name)
                }
            }
        }
    }

    private func finalizeBucket(key: Int) {
        if let bucket = makeBucket(key: key) {
            coarse.append(bucket)
            let cutoff = lastTime - Self.totalWindow
            let drop = coarse.prefix { $0.start + Self.bucketLength <= cutoff }.count
            if drop > 0 { coarse.removeFirst(drop) }
        }
        systemAcc = SystemAccumulator()
        processAcc.removeAll(keepingCapacity: true)
        if names.count > 4096 { compactNames() }
    }

    /// Builds a bucket from the open accumulators without changing them (interns names only when needed).
    private func makeBucket(key: Int) -> Bucket? {
        guard !systemAcc.isEmpty || !processAcc.isEmpty else { return nil }
        var average = MetricVector()
        for (i, metric) in HistoryMetric.allCases.enumerated() where systemAcc.counts[i] > 0 {
            average[metric] = systemAcc.sum[metric] / Double(systemAcc.counts[i])
        }

        var ranked = Array(processAcc)
        let n = Self.topCount
        var picked: [ProcessID: ProcessAccumulator] = [:]
        if ranked.count <= 2 * n {
            for (id, acc) in ranked { picked[id] = acc }
        } else {
            ranked.sort { $0.value.cpuSum / Double($0.value.ticks) > $1.value.cpuSum / Double($1.value.ticks) }
            for (id, acc) in ranked.prefix(n) { picked[id] = acc }
            ranked.sort { $0.value.memoryPeak > $1.value.memoryPeak }
            for (id, acc) in ranked.prefix(n) { picked[id] = acc }
        }
        var entries: [Entry] = []
        entries.reserveCapacity(picked.count)
        for (id, acc) in picked {
            entries.append(Entry(pid: id.pid, nameIndex: intern(acc.name), startTime: id.startTime,
                                 memory: acc.memoryPeak, cpu: Float(acc.cpuSum / Double(acc.ticks))))
        }
        return Bucket(start: Double(key) * Self.bucketLength, average: average, peak: systemAcc.peak, entries: entries)
    }

    private func intern(_ name: String) -> UInt32 {
        if let i = nameIndex[name] { return i }
        let i = UInt32(names.count)
        names.append(name)
        nameIndex[name] = i
        return i
    }

    /// Drops names no stored bucket references any more.
    private func compactNames() {
        let old = names
        names = []
        nameIndex = [:]
        for b in coarse.indices {
            for e in coarse[b].entries.indices {
                coarse[b].entries[e].nameIndex = intern(old[Int(coarse[b].entries[e].nameIndex)])
            }
        }
    }

    /// Finalized buckets plus the open one (so "what spiked just now?" works).
    private func allBuckets() -> [Bucket] {
        guard let key = currentKey, let open = makeBucket(key: key) else { return coarse }
        return coarse + [open]
    }

    // MARK: - Queries

    /// System series, oldest first. Points older than 10 minutes are 10 s bucket means. `range == nil` returns everything.
    public func systemSeries(metric: HistoryMetric, range: ClosedRange<Date>? = nil) -> [(Date, Double)] {
        let lo = range?.lowerBound.timeIntervalSince1970 ?? -.infinity
        let hi = range?.upperBound.timeIntervalSince1970 ?? .infinity
        var out: [(Date, Double)] = []
        let fineStart = fine.first?.time ?? .infinity
        for b in coarse where b.start < fineStart && b.start >= lo && b.start <= hi {
            let v = b.average[metric]
            if !v.isNaN { out.append((Date(timeIntervalSince1970: b.start), v)) }
        }
        for p in fine where p.time >= lo && p.time <= hi {
            let v = p.values[metric]
            if !v.isNaN { out.append((Date(timeIntervalSince1970: p.time), v)) }
        }
        return out
    }

    /// Start times of the 10 s buckets in `range` whose peak was at or above `threshold`
    /// (cpu/gpu 0...1, memory/disk/network in bytes or bytes/s). Pair with `topProcesses(at:by:)`.
    public func spikes(metric: HistoryMetric, threshold: Double, in range: ClosedRange<Date>? = nil) -> [Date] {
        let lo = range?.lowerBound.timeIntervalSince1970 ?? -.infinity
        let hi = range?.upperBound.timeIntervalSince1970 ?? .infinity
        return allBuckets().compactMap { b in
            let v = b.peak[metric]
            guard !v.isNaN, v >= threshold, b.start + Self.bucketLength > lo, b.start <= hi else { return nil }
            return Date(timeIntervalSince1970: b.start)
        }
    }

    /// Top 20 processes of the bucket nearest to `date` ("what spiked at 14:32?"), sorted by `sort`.
    public func topProcesses(at date: Date, by sort: HistoryProcessSort) -> [HistoryProcessEntry] {
        let t = date.timeIntervalSince1970
        let buckets = allBuckets()
        guard let bucket = buckets.min(by: { distance(t, to: $0) < distance(t, to: $1) }) else { return [] }
        var entries = bucket.entries.map(publicEntry)
        switch sort {
        case .cpu: entries.sort { ($0.cpu, $1.id) > ($1.cpu, $0.id) }
        case .memory: entries.sort { ($0.memory, $1.id) > ($1.memory, $0.id) }
        }
        return Array(entries.prefix(Self.topCount))
    }

    /// Points of one process, from every bucket whose top lists it entered. Empty if it never did.
    public func series(for id: ProcessID) -> [HistoryProcessPoint] {
        var out: [HistoryProcessPoint] = []
        for b in allBuckets() {
            if let e = b.entries.first(where: { $0.pid == id.pid && $0.startTime == id.startTime }) {
                out.append(HistoryProcessPoint(date: Date(timeIntervalSince1970: b.start), cpu: Double(e.cpu), memory: e.memory))
            }
        }
        return out
    }

    /// Date range currently covered (oldest point to newest), nil when empty.
    public func coveredRange() -> ClosedRange<Date>? {
        let first = [coarse.first?.start, fine.first?.time].compactMap { $0 }.min()
        guard let first, lastTime.isFinite else { return nil }
        return Date(timeIntervalSince1970: first)...Date(timeIntervalSince1970: lastTime)
    }

    private func distance(_ t: Double, to b: Bucket) -> Double {
        if t < b.start { return b.start - t }
        // Buckets are half-open [start, start + 10): a time on the boundary belongs to the later bucket.
        if t >= b.start + Self.bucketLength { return t - (b.start + Self.bucketLength) + 1e-6 }
        return 0
    }

    private func publicEntry(_ e: Entry) -> HistoryProcessEntry {
        HistoryProcessEntry(id: ProcessID(pid: e.pid, startTime: e.startTime), name: names[Int(e.nameIndex)],
                            cpu: Double(e.cpu), memory: e.memory)
    }

    // MARK: - Footprint

    /// Estimated resident bytes (element strides x counts, names, open accumulators with a 1.5x hash-table factor).
    public func estimatedMemoryBytes() -> Int {
        var bytes = fine.capacity * MemoryLayout<FinePoint>.stride
        bytes += coarse.capacity * MemoryLayout<Bucket>.stride
        for b in coarse { bytes += b.entries.capacity * MemoryLayout<Entry>.stride }
        for n in names { bytes += MemoryLayout<String>.stride + n.utf8.count + 32 }
        bytes += nameIndex.count * (MemoryLayout<String>.stride + MemoryLayout<UInt32>.stride) * 3 / 2
        let accStride = MemoryLayout<ProcessID>.stride + MemoryLayout<ProcessAccumulator>.stride
        bytes += processAcc.capacity * accStride * 3 / 2
        return bytes
    }
}
