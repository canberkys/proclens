import Foundation

/// Best-effort owner/vendor name for a launchd job or background item. Heuristic only.
public enum VendorGuess {
    private static let applePrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/bin/", "/sbin/",
                                        "/Library/Apple/", "/System/Cryptexes/"]
    private static let tlds: Set<String> = ["com", "org", "net", "io", "app", "dev", "co", "me", "de", "fr", "uk",
                                            "jp", "cn", "ru", "ch", "nl", "tv", "ai"]
    private static let genericSecond: Set<String> = ["github", "homebrew", "mxcl", "user", "local", "startup"]

    public static func guess(label: String, program: String?, trustProgramPrefix: Bool = true) -> String? {
        if label.hasPrefix("com.apple.") { return "Apple" }
        if let program, !program.isEmpty {
            if trustProgramPrefix, applePrefixes.contains(where: { program.hasPrefix($0) }) { return "Apple" }
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

    /// "Developer ID Application: Forcepoint LLC (ABCDE12345)" -> "Forcepoint LLC".
    /// Apple-issued certificates map to "Apple". Nil when the name carries no usable vendor.
    public static func vendorName(fromCertificateCommonName cn: String) -> String? {
        var name = cn.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("Software Signing") || name.hasPrefix("Apple Mac OS Application Signing")
            || name.hasPrefix("Apple Code Signing") { return "Apple" }
        for prefix in ["Developer ID Application:", "Developer ID Installer:", "Apple Development:",
                       "Apple Distribution:", "Mac Developer:", "3rd Party Mac Developer Application:",
                       "Mac App Store:"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            let team = name[open.upperBound...].dropLast()
            if team.count == 10, team.allSatisfy({ $0.isUppercase || $0.isNumber }) {
                name = String(name[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }
        return name.isEmpty ? nil : name
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
