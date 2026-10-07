import Foundation

/// Rules as JSON in Application Support (`ProcLens/alert-rules.json`); the URL is injectable for tests.
public struct AlertRuleStore: Sendable {
    private struct File: Codable {
        var version: Int
        var rules: [AlertRule]
    }

    public let url: URL

    public init(url: URL = AlertRuleStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ProcLens", isDirectory: true).appendingPathComponent("alert-rules.json")
    }

    /// Missing file returns `[]`; a corrupt file throws (callers decide whether to overwrite it).
    public func load() throws -> [AlertRule] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(File.self, from: data).rules
    }

    public func save(_ rules: [AlertRule]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(version: 1, rules: rules)).write(to: url, options: .atomic)
    }
}
