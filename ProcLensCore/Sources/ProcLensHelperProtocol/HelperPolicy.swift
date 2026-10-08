import Foundation

/// `launchctl` verbs the helper will run. Anything else is rejected before a process is spawned.
public enum HelperLaunchctlVerb: String, Codable, Sendable, CaseIterable {
    case enable, disable, bootstrap, bootout, kickstart
    /// `kickstart -k`: kill the running instance first, then start.
    case kickstartKill
    case kill
}

/// A system-domain launchctl request. The helper turns it into argv itself (never a shell string).
public struct HelperLaunchctlRequest: Codable, Sendable, Hashable {
    public var verb: HelperLaunchctlVerb
    /// Job label (all verbs except `bootstrap`, where it is optional).
    public var label: String?
    /// Absolute plist path (`bootstrap` only; must live in /Library/LaunchDaemons).
    public var plistPath: String?
    /// Signal number (`kill` only).
    public var signal: Int32?

    public init(verb: HelperLaunchctlVerb, label: String? = nil, plistPath: String? = nil, signal: Int32? = nil) {
        self.verb = verb; self.label = label; self.plistPath = plistPath; self.signal = signal
    }
}

/// Pure validation shared by the helper (enforcement) and the app (early rejection, unit tests).
public enum HelperPolicy {
    public static let launchctlPath = "/bin/launchctl"
    public static let sfltoolPath = "/usr/bin/sfltool"
    public static let allowedPlistDirectory = "/Library/LaunchDaemons"
    public static let maxPIDsPerRequest = 8_192
    /// Signals the app may send through the helper: HUP, INT, QUIT, KILL, TERM, STOP, CONT, USR1, USR2.
    public static let allowedSignals: Set<Int32> = [1, 2, 3, 9, 15, 17, 19, 30, 31]
    /// Labels the helper never touches: Apple's own jobs and the helper itself.
    public static let protectedLabelPrefixes = ["com.apple."]
    public static let protectedLabels: Set<String> = [HelperConstants.machServiceName]

    /// Processes the helper never signals, even if asked: ending them takes down the session or the kernel.
    /// Mirrors `ProtectionPolicy` in the app (defense in depth: the root helper enforces it independently).
    public static let criticalProcessNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "logd", "opendirectoryd",
        "securityd", "UserEventAgent", "configd", "mds", "coreservicesd", "syslogd", "notifyd",
        "diskarbitrationd", "powerd", "cfprefsd", "distnoted", "trustd",
    ]

    public static func validateTarget(name: String) throws {
        guard !criticalProcessNames.contains(name) else {
            throw HelperFailure(code: .forbidden, message: "\(name) is critical to macOS and cannot be signalled.")
        }
    }

    // MARK: Signals

    public static func validateSignal(pid: Int32, signal: Int32, helperPID: Int32) throws {
        guard pid > 1 else { throw HelperFailure(code: .forbidden, message: "Refusing to signal pid \(pid).") }
        guard pid != helperPID else { throw HelperFailure(code: .forbidden, message: "Refusing to signal the helper itself.") }
        guard allowedSignals.contains(signal) else {
            throw HelperFailure(code: .forbidden, message: "Signal \(signal) is not allowed.")
        }
    }

    public static func validatePIDs(_ pids: [Int32]) throws {
        guard pids.count <= maxPIDsPerRequest else {
            throw HelperFailure(code: .badRequest, message: "Too many pids (\(pids.count)).")
        }
        guard pids.allSatisfy({ $0 >= 0 }) else {
            throw HelperFailure(code: .badRequest, message: "Negative pid.")
        }
    }

    // MARK: launchctl

    /// Reverse-DNS-ish label: letters, digits, `.`, `_`, `-`, `+`, `@`; 1...255 chars; no leading dash or slash.
    public static func isValidLabel(_ label: String) -> Bool {
        guard (1...255).contains(label.utf8.count), let first = label.unicodeScalars.first,
              first != "-", first != "." else { return false }
        return label.unicodeScalars.allSatisfy { s in
            (s.value < 128) && (CharacterSet.alphanumerics.contains(s) || "._-+@".unicodeScalars.contains(s))
        }
    }

    public static func isProtectedLabel(_ label: String) -> Bool {
        protectedLabels.contains(label) || protectedLabelPrefixes.contains { label.hasPrefix($0) }
    }

    /// Absolute, `..`-free, `.plist` file directly inside /Library/LaunchDaemons.
    public static func isAllowedPlistPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0"), path.hasSuffix(".plist") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains(".") else { return false }
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().path == allowedPlistDirectory
            && isValidLabel(url.deletingPathExtension().lastPathComponent)
    }

    /// Builds the exact argv for `/bin/launchctl`. Throws `.forbidden`/`.badRequest` for anything outside the allowlist.
    public static func launchctlArguments(for request: HelperLaunchctlRequest) throws -> [String] {
        func requireLabel() throws -> String {
            guard let label = request.label, isValidLabel(label) else {
                throw HelperFailure(code: .badRequest, message: "Invalid or missing job label.")
            }
            guard !isProtectedLabel(label) else {
                throw HelperFailure(code: .forbidden, message: "\(label) is protected and cannot be changed.")
            }
            return label
        }
        switch request.verb {
        case .enable, .disable, .bootout, .kickstart, .kickstartKill:
            let target = "system/\(try requireLabel())"
            switch request.verb {
            case .enable: return ["enable", target]
            case .disable: return ["disable", target]
            case .bootout: return ["bootout", target]
            case .kickstart: return ["kickstart", target]
            default: return ["kickstart", "-k", target]
            }
        case .kill:
            let target = "system/\(try requireLabel())"
            guard let signal = request.signal, allowedSignals.contains(signal) else {
                throw HelperFailure(code: .forbidden, message: "Signal \(request.signal.map(String.init) ?? "nil") is not allowed.")
            }
            return ["kill", String(signal), target]
        case .bootstrap:
            guard let path = request.plistPath, isAllowedPlistPath(path) else {
                throw HelperFailure(code: .forbidden, message: "Plist must be a file in \(allowedPlistDirectory).")
            }
            let label = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            guard !isProtectedLabel(label) else {
                throw HelperFailure(code: .forbidden, message: "\(label) is protected and cannot be changed.")
            }
            return ["bootstrap", "system", path]
        }
    }
}
