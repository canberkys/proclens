// Adapted from Sean10000/LaunchManager (commit edd75d922a54c10da0d638779471e93a1dece377), MIT License,
// Copyright (c) 2026 Shi-Cheng Ma: LaunchManager/Models/LaunchItem.swift and Models/InvalidPlist.swift.
// Changes: Sendable value types, domain/scope split by directory, read-only Apple scopes, extra plist keys,
// signing + vendor fields; UI (LocalizedStringKey/SwiftUI) and plist-writing parts dropped.

import Foundation

/// launchd domain a job lives in.
public enum LaunchdDomain: Sendable, Hashable, CustomStringConvertible {
    case gui(uid_t)
    case system

    /// `gui/501` or `system`, as accepted by `launchctl`.
    public var specifier: String {
        switch self {
        case .gui(let uid): "gui/\(uid)"
        case .system: "system"
        }
    }

    public var isSystem: Bool { self == .system }
    public var description: String { specifier }

    public func target(label: String) -> String { "\(specifier)/\(label)" }
}

/// Which plist directory an item came from.
public enum LaunchdScope: String, Sendable, Hashable, CaseIterable {
    /// `~/Library/LaunchAgents`
    case userAgent
    /// `/Library/LaunchAgents`
    case globalAgent
    /// `/Library/LaunchDaemons`
    case globalDaemon
    /// `/System/Library/LaunchAgents` (read-only, Apple)
    case appleAgent
    /// `/System/Library/LaunchDaemons` (read-only, Apple)
    case appleDaemon

    public var isApple: Bool { self == .appleAgent || self == .appleDaemon }
    public var isDaemon: Bool { self == .globalDaemon || self == .appleDaemon }
    /// Only non-Apple items can be changed.
    public var isEditable: Bool { !isApple }
    /// Changing this scope needs the privileged helper.
    public var requiresHelper: Bool { self == .globalDaemon }

    public func domain(uid: uid_t) -> LaunchdDomain { isDaemon ? .system : .gui(uid) }

    public var title: String {
        switch self {
        case .userAgent: "User Agents"
        case .globalAgent: "Global Agents"
        case .globalDaemon: "Global Daemons"
        case .appleAgent: "Apple Agents"
        case .appleDaemon: "Apple Daemons"
        }
    }
}

public struct LaunchdCalendarInterval: Sendable, Hashable {
    public var minute: Int?
    public var hour: Int?
    public var day: Int?
    public var weekday: Int?
    public var month: Int?
}

public enum LaunchdKeepAlive: Sendable, Hashable {
    case never
    case always
    /// A dictionary of conditions (SuccessfulExit, NetworkState, PathState, ...).
    case conditional
}

/// One launchd job description parsed from a plist.
public struct LaunchdItem: Sendable, Hashable, Identifiable {
    public var label: String
    public var plistPath: String
    public var scope: LaunchdScope
    public var domain: LaunchdDomain
    /// `Program`, else `ProgramArguments[0]`; empty when only `BundleProgram` is present.
    public var program: String
    /// Full argv (`ProgramArguments`), program included when given that way.
    public var programArguments: [String]
    /// `BundleProgram` (SMAppService-managed plists).
    public var bundleProgram: String?
    public var runAtLoad: Bool
    public var keepAlive: LaunchdKeepAlive
    /// The plist's own `Disabled` key (the override database may differ; see `LaunchdItemStatus.isEnabled`).
    public var plistDisabled: Bool
    public var startInterval: Int?
    public var calendarIntervals: [LaunchdCalendarInterval]
    public var watchPaths: [String]
    public var queueDirectories: [String]
    public var machServices: [String]
    public var hasSockets: Bool
    public var standardOutPath: String?
    public var standardErrorPath: String?
    public var workingDirectory: String?
    public var userName: String?
    public var associatedBundleIdentifiers: [String]
    /// Best-effort vendor/owner name (bundle id prefix, app bundle or Apple).
    public var vendor: String?
    /// Code signature of `program`; filled by `LaunchdPlistScanner.scanAndSign()`.
    public var signing: CodeSignStatus?

    public var id: String { plistPath }
    /// Part of macOS: lives under /System/Library or is labelled `com.apple.`.
    public var isApple: Bool { scope.isApple || label.hasPrefix("com.apple.") }
    public var isEditable: Bool { scope.isEditable }

    public var hasScheduleTrigger: Bool {
        startInterval != nil || !calendarIntervals.isEmpty || !watchPaths.isEmpty || !queueDirectories.isEmpty
    }

    /// Short human description of what starts the job.
    public var triggerSummary: String {
        var parts: [String] = []
        if runAtLoad { parts.append("At load") }
        if keepAlive != .never { parts.append(keepAlive == .always ? "Keep alive" : "Keep alive (conditional)") }
        if let startInterval { parts.append("Every \(startInterval) s") }
        if !calendarIntervals.isEmpty { parts.append("Calendar") }
        if !watchPaths.isEmpty { parts.append("Watch paths") }
        if !queueDirectories.isEmpty { parts.append("Queue directory") }
        if hasSockets || !machServices.isEmpty { parts.append("On demand") }
        return parts.isEmpty ? "On demand" : parts.joined(separator: ", ")
    }
}

/// A plist that could not be turned into a `LaunchdItem`.
public struct InvalidLaunchdPlist: Sendable, Hashable, Identifiable {
    public var path: String
    public var scope: LaunchdScope
    public var reason: String
    public var id: String { path }
}

public struct LaunchdScanResult: Sendable, Hashable {
    public var items: [LaunchdItem]
    public var invalid: [InvalidLaunchdPlist]
    public init(items: [LaunchdItem] = [], invalid: [InvalidLaunchdPlist] = []) {
        self.items = items
        self.invalid = invalid
    }
}

/// An item merged with live launchd state.
public struct LaunchdItemStatus: Sendable, Hashable, Identifiable {
    public var item: LaunchdItem
    /// Effective state: the override database wins over the plist's `Disabled` key.
    public var isEnabled: Bool
    public var isLoaded: Bool
    public var pid: Int?
    /// Last exit status as reported by `launchctl list` / `print system` (negative = killed by signal).
    public var lastExitStatus: Int?
    public var id: String { item.id }
    public var isRunning: Bool { pid != nil }

    public init(item: LaunchdItem, isEnabled: Bool, isLoaded: Bool, pid: Int?, lastExitStatus: Int?) {
        self.item = item
        self.isEnabled = isEnabled
        self.isLoaded = isLoaded
        self.pid = pid
        self.lastExitStatus = lastExitStatus
    }
}

public struct LaunchdSnapshot: Sendable {
    public var items: [LaunchdItemStatus]
    public var invalid: [InvalidLaunchdPlist]
    /// Non-fatal problems (a `launchctl` call failed, so state for some items is unknown).
    public var warnings: [String]
}

public enum LaunchdError: Error, Sendable, Hashable, LocalizedError {
    case helperRequired
    case readOnlyItem(String)
    case commandFailed(status: Int32, message: String)
    case timedOut
    case launchFailed(String)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .helperRequired: "Requires the ProcLens helper."
        case .readOnlyItem(let label): "\(label) is part of macOS and cannot be changed."
        case .commandFailed(let status, let message):
            message.isEmpty ? "launchctl failed (exit \(status))." : message
        case .timedOut: "launchctl timed out."
        case .launchFailed(let message): "Could not run launchctl: \(message)"
        case .invalidArgument(let message): message
        }
    }
}
