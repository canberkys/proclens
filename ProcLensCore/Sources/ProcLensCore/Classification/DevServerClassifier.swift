import Foundation

public struct DevServerMatch: Sendable, Hashable {
    public enum Category: String, Sendable, Hashable { case web, database, runtime, container, unknown }

    public var framework: String
    public var category: Category
    /// 0...100.
    public var confidence: Int

    public init(framework: String, category: Category, confidence: Int) {
        self.framework = framework
        self.category = category
        self.confidence = confidence
    }
}

/// Classifies a listening port + its process as a dev server / database / runtime from data rules in
/// `dev-server-rules.json` (adapted from simple-dev-server-viewer, MIT; see `THIRD_PARTY_NOTICES.md`).
///
/// Rule order: first matching `needle` (case-insensitive substring of `name + " " + commandLine`) wins,
/// then port fallbacks, then the default. Rules are ordered most-specific first in the JSON.
public struct DevServerClassifier: Sendable {
    public struct Rule: Sendable, Decodable, Hashable {
        public var needle: String
        public var framework: String
        public var category: String
        public var confidence: Int
        /// Match only as a whole token (`bun` must not hit `bundle`).
        public var word: Bool?
    }

    public struct PortFallback: Sendable, Decodable, Hashable {
        public var ports: [Int]?
        public var range: [Int]?
        public var label: String
        public var category: String
        public var confidence: Int

        func matches(_ port: Int) -> Bool {
            if let ports, ports.contains(port) { return true }
            if let range, range.count == 2, port >= range[0], port <= range[1] { return true }
            return false
        }
    }

    public struct Default: Sendable, Decodable, Hashable {
        public var label: String
        public var confidence: Int
    }

    private struct File: Decodable {
        var rules: [Rule]
        var portFallbacks: [PortFallback]
        var `default`: Default
        var httpPorts: [Int]?
    }

    /// Loaded once from the module bundle; empty rules (everything "Unknown listener") on failure.
    public static let shared: DevServerClassifier = load()

    private let rules: [(needle: String, rule: Rule)]

    private let fallbacks: [PortFallback]
    private let defaultMatch: Default
    private let httpPorts: Set<Int>

    public init(rules: [Rule], portFallbacks: [PortFallback], default: Default, httpPorts: [Int] = []) {
        self.rules = rules.map { ($0.needle.lowercased(), $0) }
        self.fallbacks = portFallbacks
        self.defaultMatch = `default`
        self.httpPorts = Set(httpPorts)
    }

    /// `processName` is the process short name; `commandLine` is argv joined with spaces (may be empty).
    public func classify(port: ListeningPort, processName: String, commandLine: String) -> DevServerMatch {
        classify(port: Int(port.port), processName: processName, commandLine: commandLine)
    }

    public func classify(port: Int, processName: String, commandLine: String) -> DevServerMatch {
        let haystack = (processName + " " + commandLine).lowercased()
        var tokens: Set<Substring>?
        for (needle, rule) in rules {
            if rule.word == true {
                if tokens == nil {
                    tokens = Set(haystack.split { !($0.isLetter || $0.isNumber || $0 == "_") })
                }
                guard tokens!.contains(Substring(needle)) else { continue }
            } else if !haystack.contains(needle) {
                continue
            }
            return DevServerMatch(framework: rule.framework, category: Self.category(rule.category),
                                  confidence: rule.confidence)
        }
        for fb in fallbacks where fb.matches(port) {
            return DevServerMatch(framework: fb.label, category: Self.category(fb.category), confidence: fb.confidence)
        }
        return DevServerMatch(framework: defaultMatch.label, category: .unknown, confidence: defaultMatch.confidence)
    }

    /// Heuristic for the "Open in browser" action: TCP only, and either a web-category match or a
    /// common dev HTTP port. Databases are never offered.
    public func isLikelyHTTP(port: ListeningPort, match: DevServerMatch) -> Bool {
        guard port.proto == .tcp else { return false }
        switch match.category {
        case .database: return false
        case .web: return true
        default: return httpPorts.contains(Int(port.port))
        }
    }

    private static func category(_ raw: String) -> DevServerMatch.Category {
        DevServerMatch.Category(rawValue: raw) ?? .unknown
    }

    private static func load() -> DevServerClassifier {
        guard let url = Bundle.module.url(forResource: "dev-server-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return DevServerClassifier(rules: [], portFallbacks: [], default: Default(label: "Unknown listener", confidence: 20))
        }
        return DevServerClassifier(rules: file.rules, portFallbacks: file.portFallbacks, default: file.default,
                                   httpPorts: file.httpPorts ?? [])
    }
}
