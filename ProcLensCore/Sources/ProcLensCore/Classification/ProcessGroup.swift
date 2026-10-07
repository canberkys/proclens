import Darwin

/// Windows Task Manager style top-level grouping.
public enum ProcessGroup: String, Sendable, CaseIterable, Codable {
    case apps, background, system
}

/// Facts about a GUI app, supplied by the app layer from `NSWorkspace.runningApplications`
/// so Core stays AppKit-free.
public struct RunningAppInfo: Sendable, Hashable {
    public let pid: pid_t
    public let bundleIdentifier: String?
    public let localizedName: String?
    /// `activationPolicy == .regular` (has a Dock icon).
    public let isRegular: Bool
    public init(pid: pid_t, bundleIdentifier: String?, localizedName: String?, isRegular: Bool) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.isRegular = isRegular
    }
}
