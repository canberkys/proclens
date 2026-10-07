import Darwin

/// Decides whether a process may be ended. Every allowed action still needs confirmation.
///
/// The critical-name list is deliberately conservative: it covers only processes whose
/// termination would take down the session or the kernel. The `system` origin in
/// `DaemonNameMap` is used for grouping, not for refusing, because it is too broad and
/// includes agents the user can safely quit.
public struct ProtectionPolicy: Sendable {
    public enum Verdict: Sendable, Equatable {
        case allowed
        case needsConfirmation
        case refused(reason: String)
    }

    private static let criticalNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "logd", "opendirectoryd",
        "securityd", "UserEventAgent", "configd", "mds", "coreservicesd", "syslogd", "notifyd",
        "diskarbitrationd", "powerd", "cfprefsd", "distnoted", "trustd",
    ]

    public init() {}

    /// PID 0/1, critical system names and ProcLens itself are refused. Everything else
    /// needs confirmation.
    public func verdict(for p: ProcessSample, ownPID: pid_t = getpid()) -> Verdict {
        if p.pid == 0 || p.pid == 1 || Self.criticalNames.contains(p.name) {
            return .refused(reason: "\(p.name) is critical to macOS and cannot be ended.")
        }
        if p.pid == ownPID {
            return .refused(reason: "ProcLens can't end itself; use Quit.")
        }
        return .needsConfirmation
    }
}
