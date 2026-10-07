import Foundation
import ProcLensHelperProtocol
import ServiceManagement

public enum HelperRegistrationStatus: Sendable, Hashable {
    case notRegistered, enabled, requiresApproval, notFound
}

public enum HelperClientError: Error, Sendable, Hashable, LocalizedError {
    case notInstalled
    case connectionFailed(String)
    case versionMismatch(helper: Int, app: Int)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "The ProcLens helper is not installed or not approved."
        case .connectionFailed(let message): "Could not reach the ProcLens helper: \(message)"
        case .versionMismatch(let helper, let app): "Helper protocol \(helper) does not match app protocol \(app); reinstall the helper."
        }
    }
}

/// App side of the privileged helper: `SMAppService.daemon` registration plus a typed XPC client.
///
/// Cannot be exercised end to end without a Developer ID signed app + helper that the user approved in
/// System Settings > Login Items; the encoding and allowlist logic it relies on is unit-tested in
/// `ProcLensHelperProtocol`.
public actor HelperClient: PrivilegedLaunchdActions {
    public static let shared = HelperClient()

    private var connection: NSXPCConnection?
    private var verified = false

    public init() {}

    // MARK: - Registration

    private nonisolated var service: SMAppService { SMAppService.daemon(plistName: HelperConstants.daemonPlistName) }

    public nonisolated func registrationStatus() -> HelperRegistrationStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    /// Registers the daemon. The user must then approve it in System Settings > Login Items.
    public func register() throws {
        try service.register()
    }

    public func unregister() async throws {
        invalidate()
        try await service.unregister()
    }

    public nonisolated func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: - Connection

    private func makeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: (any ProcLensHelperXPC).self)
        connection.invalidationHandler = { [weak self] in Task { await self?.connectionDropped() } }
        connection.interruptionHandler = { [weak self] in Task { await self?.connectionDropped() } }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func connectionDropped() {
        connection = nil
        verified = false
    }

    public func invalidate() {
        connection?.invalidate()
        connectionDropped()
    }

    /// One request/response round trip. `body` receives the remote proxy and a reply-completion.
    private func call<T: Codable & Sendable>(
        _: T.Type,
        _ body: @Sendable (any ProcLensHelperXPC, @escaping @Sendable (Data) -> Void) -> Void
    ) async throws -> T {
        guard registrationStatus() == .enabled else { throw HelperClientError.notInstalled }
        let connection = makeConnection()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                once.resume(throwing: HelperClientError.connectionFailed(error.localizedDescription))
            }) as? any ProcLensHelperXPC else {
                once.resume(throwing: HelperClientError.connectionFailed("No remote proxy"))
                return
            }
            body(proxy) { once.resume(returning: $0) }
        }
        return try HelperCodec.decode(HelperReply<T>.self, from: data).unwrap()
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, any Error>?
        init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = continuation }
        func resume(returning data: Data) { take()?.resume(returning: data) }
        func resume(throwing error: any Error) { take()?.resume(throwing: error) }
        private func take() -> CheckedContinuation<Data, any Error>? {
            lock.lock(); defer { lock.unlock() }
            defer { continuation = nil }
            return continuation
        }
    }

    // MARK: - Typed API

    public func helperVersion() async throws -> HelperVersionInfo {
        try await call(HelperVersionInfo.self) { proxy, reply in proxy.helperVersion(reply: reply) }
    }

    /// Throws when the helper speaks a different protocol version; cached per connection.
    public func ensureCompatible() async throws {
        if verified { return }
        let info = try await helperVersion()
        guard info.protocolVersion == HelperConstants.protocolVersion else {
            throw HelperClientError.versionMismatch(helper: info.protocolVersion, app: HelperConstants.protocolVersion)
        }
        verified = true
    }

    public func readRusage(pids: [Int32]) async throws -> [HelperRusage] {
        try HelperPolicy.validatePIDs(pids)
        try await ensureCompatible()
        let request = HelperCodec.encode(HelperPIDRequest(pids: pids))
        return try await call([HelperRusage].self) { proxy, reply in proxy.readRusage(request: request, reply: reply) }
    }

    public func readProcessInfo(pids: [Int32]) async throws -> [HelperProcessInfo] {
        try HelperPolicy.validatePIDs(pids)
        try await ensureCompatible()
        let request = HelperCodec.encode(HelperPIDRequest(pids: pids))
        return try await call([HelperProcessInfo].self) { proxy, reply in proxy.readProcessInfo(request: request, reply: reply) }
    }

    public func listListeningSockets(pids: [Int32] = []) async throws -> [HelperListeningSocket] {
        try HelperPolicy.validatePIDs(pids)
        try await ensureCompatible()
        let request = HelperCodec.encode(HelperPIDRequest(pids: pids))
        return try await call([HelperListeningSocket].self) { proxy, reply in
            proxy.listListeningSockets(request: request, reply: reply)
        }
    }

    /// Signals a root-owned process. `process.startTime` guards against pid reuse.
    public func signalProcess(pid: Int32, signal: Int32, expectedStartTime: UInt64) async throws {
        try HelperPolicy.validateSignal(pid: pid, signal: signal, helperPID: 0)
        try await ensureCompatible()
        let request = HelperCodec.encode(HelperSignalRequest(pid: pid, signal: signal, expectedStartTime: expectedStartTime))
        _ = try await call(HelperEmpty.self) { proxy, reply in proxy.signalProcess(request: request, reply: reply) }
    }

    /// `sfltool dumpbtm` as root, parsed.
    public func backgroundItems() async throws -> [BackgroundItem] {
        try await ensureCompatible()
        let output = try await call(HelperCommandOutput.self) { proxy, reply in proxy.dumpBTM(reply: reply) }
        guard output.exitStatus == 0 else { throw LaunchdError.commandFailed(status: output.exitStatus, message: output.stderr) }
        return BackgroundItemsParser.parse(output.stdout)
    }

    // MARK: - PrivilegedLaunchdActions

    public func performSystemAction(_ action: LaunchdAction, label: String, plistPath: String?) async throws {
        var signal: Int32?
        if case .kill(let value) = action { signal = value }
        let request = HelperLaunchctlRequest(verb: action.helperVerb, label: label, plistPath: plistPath, signal: signal)
        _ = try HelperPolicy.launchctlArguments(for: request) // reject early with the same rules the helper applies
        try await ensureCompatible()
        let data = HelperCodec.encode(request)
        let output = try await call(HelperCommandOutput.self) { proxy, reply in proxy.launchctl(request: data, reply: reply) }
        guard output.exitStatus == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LaunchdError.commandFailed(status: output.exitStatus, message: message)
        }
    }
}
