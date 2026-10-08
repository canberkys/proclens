import AppKit
import Observation
import ProcLensCore
import SwiftUI

/// One listening socket joined with its process and classification.
struct PortRow: Identifiable, Hashable {
    var listener: ListeningPort
    var processName: String
    var path: String?
    var commandLine: String
    var match: DevServerMatch
    /// Classified by a process rule (not a port-range guess): web, runtime or database.
    var isDevServer: Bool
    var isHTTP: Bool

    var id: String { listener.id }
    var port: Int { Int(listener.port) }
    var pid: pid_t { listener.pid }

    /// `https` for 443/8443, otherwise `http`; nil when the listener is not likely HTTP.
    var url: URL? {
        guard isHTTP else { return nil }
        let scheme = (port == 443 || port == 8443) ? "https" : "http"
        return URL(string: "\(scheme)://localhost:\(port)")
    }

    var addressLabel: String {
        listener.isLoopbackOnly ? "localhost only" : (listener.address == "::" || listener.address == "0.0.0.0" ? "All interfaces" : listener.address)
    }

    var categoryLabel: String { match.category.rawValue.capitalized }

    /// Dev servers in the quick panel: web/runtime only.
    var isPanelDevServer: Bool { isDevServer && (match.category == .web || match.category == .runtime) }
}

extension DevServerMatch.Category {
    var color: Color {
        switch self {
        case .web: .blue
        case .database: .orange
        case .runtime: .green
        case .container: .purple
        case .unknown: .gray
        }
    }
}

/// Scans listening ports on demand. Polling is driven by the view that owns the visibility
/// (`start`/`stop` from onAppear/onDisappear); nothing runs while no view is shown.
@Observable @MainActor
final class PortsStore {
    private(set) var rows: [PortRow] = []
    private(set) var loaded = false

    @ObservationIgnored private var model: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var clients = 0
    /// argv per process (stable for the life of the process); bounded by the live listener set.
    @ObservationIgnored private var argvCache: [ProcessID: String] = [:]
    @ObservationIgnored private var classCache: [String: (DevServerMatch, Bool, Bool)] = [:]

    func start(model: AppModel) {
        self.model = model
        clients += 1
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        clients = max(0, clients - 1)
        guard clients == 0 else { return }
        task?.cancel()
        task = nil
    }

    func refresh() async {
        guard let model else { return }
        let ports = await model.services.scanPorts()
        let table = model.latest?.processes?.processes ?? model.services.lastProcessTable?.processes ?? [:]
        let classifier = DevServerClassifier.shared
        var out: [PortRow] = []
        out.reserveCapacity(ports.count)
        var live = Set<ProcessID>()
        for lp in ports {
            let sample = table[lp.processID]
            live.insert(lp.processID)
            if argvCache[lp.processID] == nil {
                let args = try? await model.arguments(for: lp.processID)
                argvCache[lp.processID] = args.map { $0.arguments.joined(separator: " ") } ?? ""
            }
            let cmd = argvCache[lp.processID] ?? ""
            let name = sample?.name ?? "PID \(lp.pid)"
            let key = lp.id + "|" + String(lp.processID.startTime)
            let cached: (DevServerMatch, Bool, Bool)
            if let c = classCache[key] {
                cached = c
            } else {
                let m = classifier.classify(port: lp, processName: name, commandLine: cmd,
                                            executablePath: sample?.path, uid: sample?.uid)
                let byRule = classifier.classify(port: Int(lp.port), processName: name, commandLine: cmd,
                                                 allowPortFallback: false)
                let dev = lp.proto == .tcp && [.web, .runtime, .database].contains(byRule.category)
                // Runtime dev servers (python -m http.server, node, ...) on TCP are offered "Open" even off the common ports.
                let http = classifier.isLikelyHTTP(port: lp, match: m)
                    || (dev && byRule.category != .database && lp.proto == .tcp)
                cached = (m, dev, http)
                classCache[key] = cached
            }
            out.append(PortRow(listener: lp, processName: name, path: sample?.path, commandLine: cmd,
                               match: cached.0, isDevServer: cached.1, isHTTP: cached.2))
        }
        argvCache = argvCache.filter { live.contains($0.key) }
        if classCache.count > 2000 { classCache.removeAll() }
        // IPv4 + IPv6 wildcard listeners of one process are one row; loopback-only only if every bind is.
        var merged: [String: PortRow] = [:]
        var order: [String] = []
        for r in out {
            let k = "\(r.listener.proto.rawValue):\(r.port):\(r.pid)"
            if var existing = merged[k] {
                existing.listener.isLoopbackOnly = existing.listener.isLoopbackOnly && r.listener.isLoopbackOnly
                if r.listener.address == "0.0.0.0" || r.listener.address == "::" { existing.listener.address = r.listener.address }
                merged[k] = existing
            } else {
                merged[k] = r
                order.append(k)
            }
        }
        out = order.compactMap { merged[$0] }
        out.sort { ($0.port, $0.listener.proto.rawValue, $0.pid) < ($1.port, $1.listener.proto.rawValue, $1.pid) }
        if out != rows { rows = out }
        loaded = true
    }
}
