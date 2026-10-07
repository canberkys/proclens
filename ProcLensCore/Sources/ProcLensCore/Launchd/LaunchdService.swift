// Command set (enable, disable, bootstrap, bootout, kickstart, kill, print-disabled, list) follows
// Sean10000/LaunchManager (commit edd75d922a54c10da0d638779471e93a1dece377), MIT License,
// Copyright (c) 2026 Shi-Cheng Ma: LaunchManager/Services/LaunchctlService.swift. The AppleScript privilege path
// was replaced by `PrivilegedLaunchdActions` (our helper).

import Foundation
import ProcLensHelperProtocol

public enum LaunchdAction: Sendable, Hashable {
    case enable, disable, bootstrap, bootout, kickstart
    /// `kickstart -k`: kill and restart.
    case restart
    case kill(signal: Int32)

    public var helperVerb: HelperLaunchctlVerb {
        switch self {
        case .enable: .enable
        case .disable: .disable
        case .bootstrap: .bootstrap
        case .bootout: .bootout
        case .kickstart: .kickstart
        case .restart: .kickstartKill
        case .kill: .kill
        }
    }
}

/// System-domain launchd actions, implemented by the privileged helper (`HelperClient`).
public protocol PrivilegedLaunchdActions: Sendable {
    func performSystemAction(_ action: LaunchdAction, label: String, plistPath: String?) async throws
}

/// Used until the helper is installed.
public struct UnavailablePrivilegedActions: PrivilegedLaunchdActions {
    public init() {}
    public func performSystemAction(_ action: LaunchdAction, label: String, plistPath: String?) async throws {
        throw LaunchdError.helperRequired
    }
}

/// Reads and changes launchd jobs. Everything here runs on demand (tab open, refresh, user action).
public actor LaunchdService {
    private let scanner: LaunchdPlistScanner
    private let runner: any LaunchctlRunning
    private let privileged: any PrivilegedLaunchdActions
    private let uid: uid_t

    public init(
        scanner: LaunchdPlistScanner = LaunchdPlistScanner(),
        runner: any LaunchctlRunning = ProcessLaunchctlRunner(),
        privileged: any PrivilegedLaunchdActions = UnavailablePrivilegedActions(),
        uid: uid_t = getuid()
    ) {
        self.scanner = scanner
        self.runner = runner
        self.privileged = privileged
        self.uid = uid
    }

    public var guiDomain: LaunchdDomain { .gui(uid) }

    // MARK: - Reading

    public func items() async -> [LaunchdItemStatus] {
        await snapshot().items
    }

    /// Plist scan merged with `launchctl list`, `print system` and both override databases.
    public func snapshot() async -> LaunchdSnapshot {
        let scan = await scanner.scanAndSign()
        var warnings: [String] = []

        async let guiList = capture("launchctl list") { LaunchctlPrintParser.parseList(try await self.runner.runChecked(["list"])) }
        async let guiOverrides = capture("print-disabled gui") {
            LaunchctlPrintParser.parseOverrides(try await self.runner.runChecked(["print-disabled", "gui/\(self.uid)"]))
        }
        async let systemOverrides = capture("print-disabled system") {
            LaunchctlPrintParser.parseOverrides(try await self.runner.runChecked(["print-disabled", "system"]))
        }
        // The services table of the system domain is readable without root.
        async let systemServices = capture("print system") {
            LaunchctlPrintParser.parseDomainServices(try await self.runner.runChecked(["print", "system"], timeout: 20))
        }

        let gui = await guiList, guiOver = await guiOverrides, sysOver = await systemOverrides, sys = await systemServices
        for failure in [gui.error, guiOver.error, sysOver.error, sys.error].compactMap({ $0 }) { warnings.append(failure) }

        let guiByLabel = Dictionary(gui.value?.map { ($0.label, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let sysByLabel = Dictionary(sys.value?.map { ($0.label, $0) } ?? [], uniquingKeysWith: { first, _ in first })

        let merged = scan.items.map { item -> LaunchdItemStatus in
            let overrides = (item.domain.isSystem ? sysOver.value : guiOver.value) ?? [:]
            let entry = (item.domain.isSystem ? sysByLabel : guiByLabel)[item.label]
            return Self.merge(item: item, override: overrides[item.label], entry: entry)
        }
        return LaunchdSnapshot(items: merged, invalid: scan.invalid, warnings: warnings)
    }

    /// Pure merge rule: the override database wins over the plist's `Disabled` key; present in the
    /// domain's service table means loaded.
    static func merge(item: LaunchdItem, override: Bool?, entry: LaunchctlListEntry?) -> LaunchdItemStatus {
        LaunchdItemStatus(
            item: item,
            isEnabled: override.map { !$0 } ?? !item.plistDisabled,
            isLoaded: entry != nil,
            pid: entry?.pid,
            lastExitStatus: entry?.status
        )
    }

    /// `launchctl print <domain>/<label>` for the detail pane.
    public func serviceInfo(for item: LaunchdItem) async throws -> LaunchctlServiceInfo? {
        let output = try await runner.runChecked(["print", item.domain.target(label: item.label)], timeout: 15)
        return LaunchctlPrintParser.parseService(output)
    }

    private struct Captured<T: Sendable>: Sendable {
        var value: T?
        var error: String?
    }

    private func capture<T: Sendable>(_ what: String, _ body: @Sendable () async throws -> T) async -> Captured<T> {
        do { return Captured(value: try await body(), error: nil) } catch {
            return Captured(value: nil, error: "\(what): \(error.localizedDescription)")
        }
    }

    // MARK: - Actions

    public func enable(_ item: LaunchdItem) async throws { try await perform(.enable, on: item) }
    public func disable(_ item: LaunchdItem) async throws { try await perform(.disable, on: item) }
    public func bootstrap(_ item: LaunchdItem) async throws { try await perform(.bootstrap, on: item) }
    public func bootout(_ item: LaunchdItem) async throws { try await perform(.bootout, on: item) }
    public func kickstart(_ item: LaunchdItem, killRunning: Bool = false) async throws {
        try await perform(killRunning ? .restart : .kickstart, on: item)
    }
    public func kill(_ item: LaunchdItem, signal: Int32 = SIGTERM) async throws { try await perform(.kill(signal: signal), on: item) }

    /// argv for the gui domain (`launchctl <this>`), nil when invalid.
    static func arguments(for action: LaunchdAction, item: LaunchdItem, uid: uid_t) throws -> [String] {
        let target = LaunchdDomain.gui(uid).target(label: item.label)
        switch action {
        case .enable: return ["enable", target]
        case .disable: return ["disable", target]
        case .bootout: return ["bootout", target]
        case .kickstart: return ["kickstart", target]
        case .restart: return ["kickstart", "-k", target]
        case .bootstrap: return ["bootstrap", "gui/\(uid)", item.plistPath]
        case .kill(let signal):
            guard (1...31).contains(signal) else { throw LaunchdError.invalidArgument("Invalid signal \(signal).") }
            return ["kill", String(signal), target]
        }
    }

    public func perform(_ action: LaunchdAction, on item: LaunchdItem) async throws {
        guard item.scope.isEditable else { throw LaunchdError.readOnlyItem(item.label) }
        if item.domain.isSystem {
            try await privileged.performSystemAction(
                action, label: item.label, plistPath: action == .bootstrap ? item.plistPath : nil)
        } else {
            _ = try await runner.runChecked(Self.arguments(for: action, item: item, uid: uid), timeout: 15)
        }
    }
}
