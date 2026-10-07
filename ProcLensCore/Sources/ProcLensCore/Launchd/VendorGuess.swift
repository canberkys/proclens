import Foundation

/// Best-effort owner/vendor name for a launchd job or background item. Heuristic only.
public enum VendorGuess {
    private static let applePrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/bin/", "/sbin/",
                                        "/Library/Apple/", "/System/Cryptexes/"]
    private static let tlds: Set<String> = ["com", "org", "net", "io", "app", "dev", "co", "me", "de", "fr", "uk",
                                            "jp", "cn", "ru", "ch", "nl", "tv", "ai"]
    private static let genericSecond: Set<String> = ["github", "homebrew", "mxcl", "user", "local", "startup"]

    public static func guess(label: String, program: String?) -> String? {
        if label.hasPrefix("com.apple.") { return "Apple" }
        if let program, !program.isEmpty {
            if applePrefixes.contains(where: { program.hasPrefix($0) }) { return "Apple" }
            if let app = appBundleName(in: program) { return app }
        }
        let parts = label.split(separator: ".").map(String.init)
        if parts.count >= 2, tlds.contains(parts[0].lowercased()) {
            let second = parts[1]
            if second.lowercased() == "github", parts.count >= 3 { return parts[2] }
            if !genericSecond.contains(second.lowercased()) { return display(second) }
        }
        if parts.count >= 2 { return display(parts[1]) }
        return nil
    }

    /// `/Applications/Foo Bar.app/Contents/...` -> `Foo Bar`.
    static func appBundleName(in path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil)
        else { return nil }
        let prefix = path[..<range.lowerBound]
        guard let name = prefix.split(separator: "/").last else { return nil }
        return String(name)
    }

    private static func display(_ component: String) -> String {
        guard let first = component.first else { return component }
        return first.uppercased() + component.dropFirst()
    }
}
