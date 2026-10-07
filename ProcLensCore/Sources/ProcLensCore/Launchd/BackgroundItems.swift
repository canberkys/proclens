import Foundation
import ServiceManagement

// MARK: - Our own login item (SMAppService)

public enum LoginItemStatus: Sendable, Hashable {
    case notRegistered, enabled, requiresApproval, notFound

    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }
}

/// "Launch ProcLens at login" via `SMAppService.mainApp` (the only login item an app may manage for itself).
public struct OwnLoginItem: Sendable {
    public init() {}
    public var status: LoginItemStatus { LoginItemStatus(SMAppService.mainApp.status) }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
    public static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

// MARK: - Background Task Management database (sfltool dumpbtm)

public enum BackgroundItemType: Sendable, Hashable {
    case app, loginItem, agent, daemon, legacyAgent, legacyDaemon, developer, unknown(String)

    init(raw: String) {
        let text = raw.lowercased()
        // "legacy daemon (0x10008)", "login item (0x4)", "app (0x2)", ...
        let words = text.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? text
        switch words {
        case "app": self = .app
        case "login item": self = .loginItem
        case "agent": self = .agent
        case "daemon": self = .daemon
        case "legacy agent": self = .legacyAgent
        case "legacy daemon": self = .legacyDaemon
        case "developer": self = .developer
        default: self = .unknown(raw)
        }
    }

    public var title: String {
        switch self {
        case .app: "App"
        case .loginItem: "Login item"
        case .agent: "Agent"
        case .daemon: "Daemon"
        case .legacyAgent: "Legacy agent"
        case .legacyDaemon: "Legacy daemon"
        case .developer: "Developer"
        case .unknown(let raw): raw
        }
    }
}

/// One entry of the BTM database.
public struct BackgroundItem: Sendable, Hashable, Identifiable {
    public var id: String { uuid ?? "\(uid ?? -1)/\(identifier ?? name)" }
    public var uuid: String?
    /// Owning user record (`Records for UID 501`); -2 / nil for the shared record.
    public var uid: Int?
    public var name: String
    public var developerName: String?
    public var teamIdentifier: String?
    public var type: BackgroundItemType
    public var typeRaw: String
    public var identifier: String?
    /// `URL:` decoded to a filesystem path when it is a file URL.
    public var url: String?
    public var executablePath: String?
    public var bundleIdentifier: String?
    public var parentIdentifier: String?
    public var disposition: Set<String>
    public var isEnabled: Bool { disposition.contains("enabled") }
    /// The user has allowed it in System Settings > Login Items & Extensions.
    public var isAllowed: Bool { disposition.contains("allowed") }
    public var isVisible: Bool { disposition.contains("visible") }
    public var isNotified: Bool { disposition.contains("notified") }
}

/// Parses `sfltool dumpbtm` (needs root: produced by the helper). The format is not documented and has changed
/// between macOS releases, so the parser reads generic `Key: value` lines per `#N:` item and ignores what it
/// does not know.
public enum BackgroundItemsParser {
    public static func parse(_ output: String) -> [BackgroundItem] {
        var items: [BackgroundItem] = []
        var currentUID: Int?
        var fields: [String: String]?

        func flush() {
            guard let f = fields else { return }
            fields = nil
            let name = f["name"] ?? ""
            let identifier = f["identifier"]
            guard !name.isEmpty || identifier != nil else { return }
            let typeRaw = f["type"] ?? ""
            items.append(BackgroundItem(
                uuid: f["uuid"], uid: currentUID,
                name: name.isEmpty ? (identifier ?? "") : name,
                developerName: clean(f["developer name"]), teamIdentifier: clean(f["team identifier"]),
                type: BackgroundItemType(raw: typeRaw), typeRaw: typeRaw,
                identifier: identifier, url: f["url"].map(pathFromURL),
                executablePath: clean(f["executable path"]),
                bundleIdentifier: clean(f["bundle identifier"]), parentIdentifier: clean(f["parent identifier"]),
                disposition: dispositionTokens(f["disposition"])
            ))
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Records for UID") {
                flush()
                let rest = trimmed.dropFirst("Records for UID".count).trimmingCharacters(in: .whitespaces)
                currentUID = Int(rest.split(whereSeparator: { $0 == " " || $0 == ":" }).first ?? "")
                continue
            }
            if isItemHeader(trimmed) {
                flush()
                fields = [:]
                continue
            }
            guard fields != nil, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Keys are short words; skip nested list rows such as "#1: 16.com.foo".
            guard !key.isEmpty, !key.hasPrefix("#"), key.count <= 32, fields?[key] == nil else { continue }
            fields?[key] = value
        }
        flush()
        return items
    }

    /// `#1:` with nothing after the colon (embedded item lists look like `#1: 16.com.example`).
    private static func isItemHeader(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("#"), trimmed.hasSuffix(":") else { return false }
        return Int(trimmed.dropFirst().dropLast()) != nil
    }

    private static func clean(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "(null)", value != "Unknown Developer", value != "none" else { return nil }
        return value
    }

    static func dispositionTokens(_ value: String?) -> Set<String> {
        guard let value, let open = value.firstIndex(of: "["), let close = value.firstIndex(of: "]"), open < close else { return [] }
        return Set(value[value.index(after: open)..<close]
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    static func pathFromURL(_ value: String) -> String {
        guard value.hasPrefix("file://"), let url = URL(string: value) else { return value }
        let path = url.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
