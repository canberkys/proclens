import Foundation

/// Known macOS process names with a human title and origin, loaded from the bundled
/// `daemon-names.json` (MIT, from tanRdev/lucid-task-manager; see `THIRD_PARTY_NOTICES.md`).
public struct DaemonNameMap: Sendable {
    public struct Entry: Sendable, Codable, Hashable {
        public let name: String
        public let title: String
        public let origin: String
        public let section: String

        public init(name: String, title: String, origin: String, section: String) {
            self.name = name
            self.title = title
            self.origin = origin
            self.section = section
        }
    }

    /// Loaded once from the module bundle. Falls back to an empty map on any failure.
    public static let shared: DaemonNameMap = load()

    private let byName: [String: Entry]
    private let byLowercasedName: [String: Entry]

    public init(entries: [Entry]) {
        var exact: [String: Entry] = [:]
        var lower: [String: Entry] = [:]
        for entry in entries {
            // First occurrence wins, so duplicate names in the file do not overwrite.
            if exact[entry.name] == nil { exact[entry.name] = entry }
            let key = entry.name.lowercased()
            if lower[key] == nil { lower[key] = entry }
        }
        self.byName = exact
        self.byLowercasedName = lower
    }

    /// Exact name match first, then case-insensitive.
    public func entry(for processName: String) -> Entry? {
        byName[processName] ?? byLowercasedName[processName.lowercased()]
    }

    /// True when the process is a macOS system component (`origin == "system"`).
    public func isSystemOrigin(_ name: String) -> Bool {
        entry(for: name)?.origin == "system"
    }

    private struct File: Decodable {
        let entries: [Entry]
    }

    /// Location of the bundled file inside the ProcLensCore resource bundle.
    static var resourceURL: URL? {
        Bundle.module.url(forResource: "daemon-names", withExtension: "json")
    }

    private static func load() -> DaemonNameMap {
        guard let url = resourceURL,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            return DaemonNameMap(entries: [])
        }
        return DaemonNameMap(entries: file.entries)
    }
}
