import Foundation
import Testing
@testable import ProcLensCore

func launchdFixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/launchd"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct LaunchctlParsersTests {
    @Test func parsesList() throws {
        let entries = LaunchctlPrintParser.parseList(try launchdFixture("list"))
        #expect(entries.count == 5)
        #expect(entries[0] == LaunchctlListEntry(label: "com.apple.SafariHistoryServiceAgent", pid: nil, status: 0))
        #expect(entries.first { $0.label == "com.apple.Finder" }?.pid == 1599)
    }

    @Test func listKeepsNegativeStatusAndSkipsGarbage() {
        let text = "PID\tStatus\tLabel\n-\t-9\tcom.example.killed\nnot a row\n123\t1\tcom.example.running\n"
        let entries = LaunchctlPrintParser.parseList(text)
        #expect(entries.map(\.label) == ["com.example.killed", "com.example.running"])
        #expect(entries[0].status == -9)
        #expect(entries[1].pid == 123)
    }

    @Test func parsesDomainServicesTable() throws {
        let entries = LaunchctlPrintParser.parseDomainServices(try launchdFixture("print-system-domain"))
        #expect(entries.count == 30)
        let lskdd = try #require(entries.first { $0.label == "com.apple.lskdd" })
        #expect(lskdd.pid == 29821)
        #expect(lskdd.status == nil)
        let wifi = try #require(entries.first { $0.label == "com.apple.wifiFirmwareLoader" })
        #expect(wifi.pid == nil)
        #expect(wifi.status == 1)
    }

    @Test func parsesOverridesBothFormats() throws {
        let overrides = LaunchctlPrintParser.parseOverrides(try launchdFixture("print-disabled-gui"))
        #expect(overrides["com.example.updater"] == true)
        #expect(overrides["com.example.helper.enabled"] == false)
        #expect(overrides["com.example.legacydisabled"] == true)
        #expect(overrides["com.example.legacyformat"] == false)
        let disabled = LaunchctlPrintParser.parseDisabledLabels(try launchdFixture("print-disabled-gui"))
        #expect(disabled == ["com.example.updater", "com.apple.ManagedClientAgent.enrollagent", "com.example.legacydisabled"])
    }

    @Test func parsesRunningGuiService() throws {
        let info = try #require(LaunchctlPrintParser.parseService(try launchdFixture("print-gui-finder")))
        #expect(info.target.hasSuffix("/com.apple.Finder"))
        #expect(info.state == .running)
        #expect(info.pid == 1599)
        #expect(info.runs == 1)
        #expect(info.neverExited)
        #expect(info.lastExitCode == nil)
        #expect(info.program == "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
        #expect(info.path == "/System/Library/LaunchAgents/com.apple.Finder.plist")
        #expect(info.type == "LaunchAgent")
        #expect(info.bundleID == "com.apple.finder")
        #expect(info.domain?.hasPrefix("gui/") == true)
        #expect(info.immediateReason == "non-ipc demand")
    }

    @Test func parsesNotRunningService() throws {
        let info = try #require(LaunchctlPrintParser.parseService(try launchdFixture("print-gui-notrunning")))
        #expect(info.state == .notRunning)
        #expect(info.pid == nil)
        #expect(info.runs == 0)
        #expect(info.neverExited)
    }

    @Test func parsesSystemServiceWithArguments() throws {
        let info = try #require(LaunchctlPrintParser.parseService(try launchdFixture("print-system-securityd")))
        #expect(info.target == "system/com.apple.securityd")
        #expect(info.domain == "system")
        #expect(info.arguments == ["/usr/sbin/securityd", "-i"])
        #expect(info.program == "/usr/sbin/securityd")
        #expect(info.pid == 577)
    }

    @Test func parsesExitCode() throws {
        let info = try #require(LaunchctlPrintParser.parseService(try launchdFixture("print-gui-failed")))
        #expect(info.lastExitCode == 78)
        #expect(!info.neverExited)
        #expect(info.state == .notRunning)
    }

    @Test func rejectsGarbage() {
        #expect(LaunchctlPrintParser.parseService("Could not find service \"x\" in domain for system") == nil)
        #expect(LaunchctlPrintParser.parseDomainServices("nothing").isEmpty)
    }
}
