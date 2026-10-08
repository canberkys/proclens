// Adapted from Sean10000/LaunchManager (commit edd75d922a54c10da0d638779471e93a1dece377), MIT License,
// Copyright (c) 2026 Shi-Cheng Ma: LaunchManager/Services/PlistService.swift (scanAll, scanDirectory, parsePlist).
// Changes: value-type scanner with injectable directories, per-file failure reasons, many more keys,
// read-only Apple scopes, vendor guess and async signing; the plist writing/cloning/privilege code was dropped.

import Foundation

public struct LaunchdDirectory: Sendable, Hashable {
    public var url: URL
    public var scope: LaunchdScope
    public init(url: URL, scope: LaunchdScope) {
        self.url = url
        self.scope = scope
    }

    /// The five standard locations (plus the Safari cryptex agents directory when present).
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [LaunchdDirectory] {
        var dirs = [
            LaunchdDirectory(url: home.appendingPathComponent("Library/LaunchAgents"), scope: .userAgent),
            LaunchdDirectory(url: URL(fileURLWithPath: "/Library/LaunchAgents"), scope: .globalAgent),
            LaunchdDirectory(url: URL(fileURLWithPath: "/Library/LaunchDaemons"), scope: .globalDaemon),
            LaunchdDirectory(url: URL(fileURLWithPath: "/System/Library/LaunchAgents"), scope: .appleAgent),
            LaunchdDirectory(url: URL(fileURLWithPath: "/System/Library/LaunchDaemons"), scope: .appleDaemon),
        ]
        let cryptexAgents = URL(fileURLWithPath: "/System/Cryptexes/App/System/Library/LaunchAgents")
        if FileManager.default.fileExists(atPath: cryptexAgents.path) {
            dirs.append(LaunchdDirectory(url: cryptexAgents, scope: .appleAgent))
        }
        return dirs
    }
}

/// Reads launchd plists from disk. Pure file IO: call off the main thread, on demand (tab open / refresh).
public struct LaunchdPlistScanner: Sendable {
    public typealias Signer = @Sendable (String) async -> CodeSignStatus

    public var directories: [LaunchdDirectory]
    public var uid: uid_t
    private let signer: Signer

    public init(
        directories: [LaunchdDirectory] = LaunchdDirectory.standard(),
        uid: uid_t = getuid(),
        signer: @escaping Signer = { await CodeSignatureInspector.shared.status(forPath: $0) }
    ) {
        self.directories = directories
        self.uid = uid
        self.signer = signer
    }

    /// Synchronous scan; `signing` is left nil.
    public func scan() -> LaunchdScanResult {
        var items: [LaunchdItem] = []
        var invalid: [InvalidLaunchdPlist] = []
        for dir in directories {
            let result = scanDirectory(dir)
            items += result.items
            invalid += result.invalid
        }
        items.sort { ($0.label.lowercased(), $0.plistPath) < ($1.label.lowercased(), $1.plistPath) }
        invalid.sort { $0.path < $1.path }
        return LaunchdScanResult(items: items, invalid: invalid)
    }

    /// Scan, then fill `signing` for each distinct program path (cached by `CodeSignatureInspector`).
    public func scanAndSign() async -> LaunchdScanResult {
        var result = scan()
        var statusByPath: [String: CodeSignStatus] = [:]
        for index in result.items.indices {
            if result.items[index].isInterpreterLaunch { result.items[index].signing = .unsigned; continue }
            guard let program = result.items[index].signablePath else { continue }
            if let cached = statusByPath[program] {
                result.items[index].signing = cached
            } else {
                let status = await signer(program)
                statusByPath[program] = status
                result.items[index].signing = status
            }
        }
        return result
    }

    func scanDirectory(_ directory: LaunchdDirectory) -> LaunchdScanResult {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return LaunchdScanResult() }
        var result = LaunchdScanResult()
        for url in contents where url.pathExtension == "plist" {
            switch Self.parse(at: url, scope: directory.scope, uid: uid) {
            case .success(let item): result.items.append(item)
            case .failure(let failure):
                result.invalid.append(InvalidLaunchdPlist(path: url.path, scope: directory.scope, reason: failure.reason))
            }
        }
        return result
    }

    // MARK: - Parsing

    public struct ParseFailure: Error, Sendable, Hashable { public var reason: String }

    public static func parse(at url: URL, scope: LaunchdScope, uid: uid_t) -> Result<LaunchdItem, ParseFailure> {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            return .failure(ParseFailure(reason: "Unreadable: \(error.localizedDescription)"))
        }
        return parse(data: data, path: url.path, scope: scope, uid: uid)
    }

    public static func parse(data: Data, path: String, scope: LaunchdScope, uid: uid_t) -> Result<LaunchdItem, ParseFailure> {
        let raw: Any
        do { raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) } catch {
            return .failure(ParseFailure(reason: "Not a valid property list"))
        }
        guard let dict = raw as? [String: Any] else {
            return .failure(ParseFailure(reason: "Root is not a dictionary"))
        }
        guard let label = dict["Label"] as? String, !label.isEmpty else {
            return .failure(ParseFailure(reason: "Missing Label"))
        }

        var arguments = (dict["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        if arguments.isEmpty, let program = dict["Program"] as? String { arguments = [program] }
        let program = (dict["Program"] as? String) ?? arguments.first ?? ""

        let keepAlive: LaunchdKeepAlive
        switch dict["KeepAlive"] {
        case let flag as Bool: keepAlive = flag ? .always : .never
        case is [String: Any]: keepAlive = .conditional
        default: keepAlive = .never
        }

        let associated: [String]
        if let list = dict["AssociatedBundleIdentifiers"] as? [Any] {
            associated = list.compactMap { $0 as? String }
        } else if let one = dict["AssociatedBundleIdentifiers"] as? String {
            associated = [one]
        } else {
            associated = []
        }

        let bundleProgram = dict["BundleProgram"] as? String
        var item = LaunchdItem(
            label: label,
            plistPath: path,
            scope: scope,
            domain: scope.domain(uid: uid),
            program: program,
            programArguments: arguments,
            bundleProgram: bundleProgram,
            runAtLoad: dict["RunAtLoad"] as? Bool ?? false,
            keepAlive: keepAlive,
            plistDisabled: dict["Disabled"] as? Bool ?? false,
            startInterval: dict["StartInterval"] as? Int,
            calendarIntervals: calendarIntervals(dict["StartCalendarInterval"]),
            watchPaths: (dict["WatchPaths"] as? [Any])?.compactMap { $0 as? String } ?? [],
            queueDirectories: (dict["QueueDirectories"] as? [Any])?.compactMap { $0 as? String } ?? [],
            machServices: ((dict["MachServices"] as? [String: Any])?.keys.sorted()) ?? [],
            hasSockets: dict["Sockets"] != nil,
            standardOutPath: dict["StandardOutPath"] as? String,
            standardErrorPath: dict["StandardErrorPath"] as? String,
            workingDirectory: dict["WorkingDirectory"] as? String,
            userName: dict["UserName"] as? String,
            associatedBundleIdentifiers: associated,
            vendor: nil,
            signing: nil
        )
        if item.isApple {
            item.vendor = "Apple"
        } else if item.isInterpreterLaunch {
            // The interpreter (/bin/bash, python3...) says nothing about the owner; use the script path and label.
            let script = item.effectiveProgram
            item.vendor = VendorGuess.guess(label: label, program: script.hasPrefix("/") ? script : nil, trustProgramPrefix: false)
        } else {
            item.vendor = VendorGuess.guess(label: label, program: program.isEmpty ? bundleProgram : program)
        }
        return .success(item)
    }

    private static func calendarIntervals(_ value: Any?) -> [LaunchdCalendarInterval] {
        let dicts: [[String: Any]]
        if let one = value as? [String: Any] { dicts = [one] }
        else if let many = value as? [Any] { dicts = many.compactMap { $0 as? [String: Any] } }
        else { return [] }
        return dicts.map {
            LaunchdCalendarInterval(minute: $0["Minute"] as? Int, hour: $0["Hour"] as? Int, day: $0["Day"] as? Int,
                                    weekday: $0["Weekday"] as? Int, month: $0["Month"] as? Int)
        }
    }
}
