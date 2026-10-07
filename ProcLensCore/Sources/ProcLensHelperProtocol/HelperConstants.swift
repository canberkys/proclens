import Foundation

/// Names and versions shared by the app and the privileged helper.
public enum HelperConstants {
    /// Mach service the helper listens on (declared in the helper's launchd plist).
    public static let machServiceName = "com.canberkki.ProcLens.helper"
    /// File name of the launchd plist embedded at `Contents/Library/LaunchDaemons/` for `SMAppService.daemon(plistName:)`.
    public static let daemonPlistName = "com.canberkki.ProcLens.helper.plist"
    /// Code-signing identifier of the app (the only XPC client the helper accepts).
    public static let appIdentifier = "com.canberkki.ProcLens"
    /// Bumped whenever the XPC surface or wire format changes; the app refuses to talk to an older helper.
    public static let protocolVersion = 1
    /// Placeholder for the Developer ID team. The helper resolves the real team at runtime
    /// (its own signature) unless this constant was replaced at build time (see `scripts/release.sh`).
    public static let teamIDPlaceholder = "TEAMID_PLACEHOLDER"

    /// Code-signing requirement the helper imposes on XPC clients.
    /// Developer ID builds: anchor apple generic + our identifier + our team in the leaf certificate's OU.
    public static func clientRequirement(teamID: String) -> String {
        "anchor apple generic and identifier \"\(appIdentifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// True when `teamID` looks like a real 10-character Apple team identifier.
    public static func isValidTeamID(_ teamID: String) -> Bool {
        teamID.count == 10 && teamID.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
            && teamID != teamIDPlaceholder
    }
}
