import AppKit
import Observation
import ProcLensCore

/// State of one inspector window. Everything is fetched once on open and again on Refresh; nothing here is tied to
/// the sampler tick (the header's CPU/memory text is the only live value and lives in its own small view).
@Observable @MainActor
final class InspectorModel {
    enum Load<T> {
        case loading
        case loaded(T)
        /// `needsHelper`: the data is out of reach for an unprivileged app (EPERM / restricted process).
        case failed(String, needsHelper: Bool)
    }

    let id: ProcessID
    let app: AppModel
    private(set) var sample: ProcessSample
    private(set) var args: Load<ProcArgs> = .loading
    private(set) var descriptors: Load<[OpenDescriptor]> = .loading
    private(set) var images: Load<[LoadedImage]> = .loading
    private(set) var signing: Load<SigningDetails?> = .loading
    private(set) var parentName: String?
    private(set) var updated: Date?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let fdInspector = FileDescriptorInspector()
    @ObservationIgnored private let imageInspector = LoadedImagesInspector()

    init(sample: ProcessSample, app: AppModel) {
        self.sample = sample
        id = sample.id
        self.app = app
        refresh()
    }

    var isRestricted: Bool { sample.isRestricted }

    func refresh() {
        generation += 1
        let gen = generation
        let pid = id.pid
        if let live = app.latest?.processes?.processes[id] ?? app.liveProcess(pid: pid).flatMap({ $0.id == id ? $0 : nil }) {
            sample = live
        }
        parentName = app.latest?.processes?.processes.values.first { $0.pid == sample.ppid }?.name
        args = .loading
        descriptors = .loading
        images = .loading
        signing = .loading
        let restricted = sample.isRestricted
        let path = sample.path

        let id = self.id
        Task { [weak self, app] in
            let result: Load<ProcArgs>
            do { result = .loaded(try await app.arguments(for: id)) }
            catch { result = Self.failure(error, restricted: restricted) }
            guard let self, gen == self.generation else { return }
            self.args = result
        }
        Task { [weak self, fdInspector] in
            let result: Load<[OpenDescriptor]>
            do { result = .loaded(try await fdInspector.descriptors(pid: pid)) }
            catch { result = Self.failure(error, restricted: restricted) }
            guard let self, gen == self.generation else { return }
            self.descriptors = result
        }
        Task { [weak self, imageInspector] in
            let result: Load<[LoadedImage]>
            do { result = .loaded(try await imageInspector.images(pid: pid)) }
            catch { result = Self.failure(error, restricted: restricted) }
            guard let self, gen == self.generation else { return }
            self.images = result
        }
        Task { [weak self] in
            let result: Load<SigningDetails?>
            if let path {
                result = .loaded(await CodeSignatureInspector.shared.details(forPath: path))
            } else {
                result = .failed("The executable path is not readable.", needsHelper: restricted)
            }
            guard let self, gen == self.generation else { return }
            self.signing = result
            self.updated = Date()
        }
    }

    private static func failure<T>(_ error: Error, restricted: Bool) -> Load<T> {
        if let e = error as? SourceError {
            if e.isGone { return .failed("The process has exited.", needsHelper: false) }
            if e.isDenied { return .failed("macOS does not let ProcLens read this process.", needsHelper: true) }
            return .failed("\(e.call) failed: \(String(cString: strerror(e.errno))).", needsHelper: restricted)
        }
        return .failed(restricted ? "macOS does not let ProcLens read this process." : "Not available.", needsHelper: restricted)
    }

    // MARK: Derived text

    var userName: String {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        if getpwuid_r(sample.uid, &pwd, &buffer, buffer.count, &result) == 0, result != nil {
            return String(cString: pwd.pw_name)
        }
        return String(sample.uid)
    }

    var startText: String {
        let date = Date(timeIntervalSince1970: Double(id.startTime) / 1_000_000)
        return date.formatted(date: .abbreviated, time: .standard)
    }

    var archText: String {
        if sample.isRestricted { return "—" }
        if sample.isTranslated { return "Intel (Rosetta)" }
        #if arch(arm64)
        return "Apple silicon"
        #else
        return "Intel"
        #endif
    }

    var commandLine: String? {
        guard case .loaded(let a) = args else { return nil }
        return a.arguments.isEmpty ? a.executablePath : a.arguments.joined(separator: " ")
    }

    /// Environment as sorted key/value rows.
    var environment: [KeyValue] {
        guard case .loaded(let a) = args else { return [] }
        return a.environment.map { KeyValue(key: $0.key, value: $0.value) }.sorted { $0.key < $1.key }
    }

    struct KeyValue: Identifiable, Hashable {
        let key: String
        let value: String
        var id: String { key }
    }

    struct DescriptorRow: Identifiable {
        enum Group: String, CaseIterable, Identifiable {
            case all = "All", files = "Files", sockets = "Sockets", other = "Pipes & other"
            var id: String { rawValue }
        }
        let id: Int32
        let type: String
        let group: Group
        let name: String
        let remote: String
        let state: String
        let mode: String
    }

    var descriptorRows: [DescriptorRow] {
        guard case .loaded(let all) = descriptors else { return [] }
        return all.map { d in
            let s = d.socket
            switch d.kind {
            case .file: return DescriptorRow(id: d.fd, type: "File", group: .files, name: d.path ?? "", remote: "", state: "", mode: d.mode ?? "")
            case .directory: return DescriptorRow(id: d.fd, type: "Directory", group: .files, name: d.path ?? "", remote: "", state: "", mode: d.mode ?? "")
            case .tcpSocket: return DescriptorRow(id: d.fd, type: "TCP", group: .sockets, name: s?.local ?? "", remote: s?.remote ?? "", state: s?.state?.label ?? "", mode: "")
            case .udpSocket: return DescriptorRow(id: d.fd, type: "UDP", group: .sockets, name: s?.local ?? "", remote: s?.remote ?? "", state: "", mode: "")
            case .unixSocket: return DescriptorRow(id: d.fd, type: "Unix socket", group: .sockets, name: s?.local ?? "", remote: s?.remote ?? "", state: "", mode: "")
            case .pipe: return DescriptorRow(id: d.fd, type: "Pipe", group: .other, name: d.detail ?? "", remote: "", state: "", mode: "")
            case .kqueue: return DescriptorRow(id: d.fd, type: "kqueue", group: .other, name: "", remote: "", state: "", mode: "")
            case .other: return DescriptorRow(id: d.fd, type: "Other", group: .other, name: d.detail ?? "", remote: "", state: "", mode: "")
            }
        }
    }

    static func entitlementRows(_ details: SigningDetails) -> [KeyValue] {
        details.entitlements.map { KeyValue(key: $0.key, value: $0.value.description) }.sorted { $0.key < $1.key }
    }
}
