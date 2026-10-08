// Verbs and the `list` / `print-disabled` parsing approach follow Sean10000/LaunchManager
// (commit edd75d922a54c10da0d638779471e93a1dece377), MIT License, Copyright (c) 2026 Shi-Cheng Ma:
// LaunchManager/Services/LaunchctlService.swift (parseListOutput, parseDisabledLabels). Rewritten: typed results,
// both `enabled/disabled` and `true/false` override formats, `launchctl print` and domain-services parsing are new.

import Foundation

/// One row of `launchctl list` or of the `services = { }` block of `launchctl print <domain>`.
public struct LaunchctlListEntry: Sendable, Hashable {
    public var label: String
    public var pid: Int?
    /// Last exit status; negative means terminated by that signal. nil when the table shows `-`.
    public var status: Int?
}

public enum LaunchctlServiceState: Sendable, Hashable {
    case running
    case notRunning
    case other(String)

    init(_ text: String) {
        switch text {
        case "running": self = .running
        case "not running": self = .notRunning
        default: self = .other(text)
        }
    }
}

/// Fields of `launchctl print <domain>/<label>` that the UI shows.
public struct LaunchctlServiceInfo: Sendable, Hashable {
    public var target: String
    public var path: String?
    public var type: String?
    public var state: LaunchctlServiceState?
    public var pid: Int?
    /// nil together with `neverExited == true` means the job has not exited yet.
    public var lastExitCode: Int?
    public var neverExited: Bool
    public var program: String?
    public var arguments: [String] = []
    public var runs: Int?
    public var bundleID: String?
    public var domain: String?
    public var immediateReason: String?
}

public enum LaunchctlPrintParser {
    // MARK: launchctl list

    /// `PID<TAB>Status<TAB>Label` with a header row.
    public static func parseList(_ output: String) -> [LaunchctlListEntry] {
        var entries: [LaunchctlListEntry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count == 3 else { continue }
            let pidText = cols[0].trimmingCharacters(in: .whitespaces)
            let statusText = cols[1].trimmingCharacters(in: .whitespaces)
            let label = cols[2].trimmingCharacters(in: .whitespaces)
            if pidText == "PID" || label.isEmpty { continue }
            guard pidText == "-" || Int(pidText) != nil else { continue }
            entries.append(LaunchctlListEntry(label: label, pid: Int(pidText), status: Int(statusText)))
        }
        return entries
    }

    // MARK: launchctl print <domain>  (services block)

    /// Rows of the top-level `services = { ... }` block: `<pid> <status> <TAB>label`, pid 0 = not running.
    public static func parseDomainServices(_ output: String) -> [LaunchctlListEntry] {
        var entries: [LaunchctlListEntry] = []
        var inBlock = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if !inBlock {
                if line == "\tservices = {" { inBlock = true }
                continue
            }
            if line == "\t}" { break }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard cols.count == 2 else { continue }
            let numbers = cols[0].split(separator: " ").map(String.init)
            guard numbers.count == 2, let pid = Int(numbers[0]) else { continue }
            let label = cols[1].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            entries.append(LaunchctlListEntry(label: label, pid: pid > 0 ? pid : nil, status: Int(numbers[1])))
        }
        return entries
    }

    // MARK: launchctl print-disabled <domain>

    /// Override database: label -> `true` when disabled. Accepts `=> disabled|enabled` and `=> true|false`.
    public static func parseOverrides(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            guard let arrow = line.range(of: "=>") else { continue }
            let head = line[..<arrow.lowerBound]
            let tail = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            guard let open = head.firstIndex(of: "\""),
                  let close = head[head.index(after: open)...].lastIndex(of: "\"") else { continue }
            let label = String(head[head.index(after: open)..<close])
            guard !label.isEmpty else { continue }
            switch tail {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }

    /// Labels whose override says disabled.
    public static func parseDisabledLabels(_ output: String) -> Set<String> {
        Set(parseOverrides(output).filter(\.value).keys)
    }

    // MARK: launchctl print <domain>/<label>

    public static func parseService(_ output: String) -> LaunchctlServiceInfo? {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerIndex = lines.firstIndex(where: { $0.hasSuffix(" = {") && !$0.hasPrefix("\t") }) else { return nil }
        let target = String(lines[headerIndex].dropLast(" = {".count))
        lines = Array(lines[(headerIndex + 1)...])

        var info = LaunchctlServiceInfo(target: target, neverExited: false)
        var inArguments = false
        for line in lines {
            if line == "}" { break }
            guard line.hasPrefix("\t") else { continue }
            if inArguments {
                if line == "\t}" { inArguments = false } else if line.hasPrefix("\t\t") {
                    info.arguments.append(line.trimmingCharacters(in: .whitespaces))
                }
                continue
            }
            // Only direct children (one tab) of the service block.
            guard !line.hasPrefix("\t\t"), let eq = line.range(of: " = ") else {
                if line == "\targuments = {" { inArguments = true }
                continue
            }
            let key = line[line.index(after: line.startIndex)..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = String(line[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
            if value == "{" {
                if key == "arguments" { inArguments = true }
                continue
            }
            switch key {
            case "path": info.path = value
            case "type": info.type = value
            case "state": info.state = LaunchctlServiceState(value)
            case "program": info.program = value
            case "bundle id": info.bundleID = value
            case "pid": info.pid = Int(value)
            case "runs": info.runs = Int(value)
            case "immediate reason": info.immediateReason = value
            case "domain": info.domain = value.split(separator: " ").first.map(String.init)
            case "last exit code", "last exit status":
                if value.contains("never exited") { info.neverExited = true } else {
                    info.lastExitCode = Int(value.split(whereSeparator: { $0 == " " || $0 == ":" }).first ?? "")
                }
            default: break
            }
        }
        return info
    }
}
