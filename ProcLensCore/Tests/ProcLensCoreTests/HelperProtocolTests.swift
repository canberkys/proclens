import Foundation
import ProcLensHelperProtocol
import Testing
@testable import ProcLensCore

@Suite struct HelperProtocolTests {
    private func failure(_ body: () throws -> Void) -> HelperFailure? {
        do { try body(); return nil } catch { return error as? HelperFailure }
    }

    @Test func signalPolicy() {
        #expect(failure { try HelperPolicy.validateSignal(pid: 0, signal: 15, helperPID: 500) }?.code == .forbidden)
        #expect(failure { try HelperPolicy.validateSignal(pid: 1, signal: 9, helperPID: 500) }?.code == .forbidden)
        #expect(failure { try HelperPolicy.validateSignal(pid: -5, signal: 9, helperPID: 500) }?.code == .forbidden)
        #expect(failure { try HelperPolicy.validateSignal(pid: 500, signal: 9, helperPID: 500) }?.code == .forbidden)
        #expect(failure { try HelperPolicy.validateSignal(pid: 600, signal: 11, helperPID: 500) }?.code == .forbidden)
        #expect(failure { try HelperPolicy.validateSignal(pid: 600, signal: 9, helperPID: 500) } == nil)
        #expect(failure { try HelperPolicy.validateSignal(pid: 600, signal: 19, helperPID: 500) } == nil)
    }

    @Test func pidListLimits() {
        #expect(failure { try HelperPolicy.validatePIDs([1, 2, 3]) } == nil)
        #expect(failure { try HelperPolicy.validatePIDs([-1]) }?.code == .badRequest)
        #expect(failure { try HelperPolicy.validatePIDs(Array(repeating: 5, count: HelperPolicy.maxPIDsPerRequest + 1)) }?.code == .badRequest)
    }

    @Test func labelValidation() {
        #expect(HelperPolicy.isValidLabel("com.example.helper-1_a+b@c"))
        for bad in ["", "-flag", ".hidden", "a b", "a/b", "a;rm", "a\nb", "é.label", String(repeating: "a", count: 256)] {
            #expect(!HelperPolicy.isValidLabel(bad), "\(bad)")
        }
    }

    @Test func launchctlArgumentsAllowlist() throws {
        func args(_ verb: HelperLaunchctlVerb, label: String? = "com.example.d", path: String? = nil, signal: Int32? = nil) throws -> [String] {
            try HelperPolicy.launchctlArguments(for: HelperLaunchctlRequest(verb: verb, label: label, plistPath: path, signal: signal))
        }
        #expect(try args(.enable) == ["enable", "system/com.example.d"])
        #expect(try args(.disable) == ["disable", "system/com.example.d"])
        #expect(try args(.bootout) == ["bootout", "system/com.example.d"])
        #expect(try args(.kickstart) == ["kickstart", "system/com.example.d"])
        #expect(try args(.kickstartKill) == ["kickstart", "-k", "system/com.example.d"])
        #expect(try args(.kill, signal: 15) == ["kill", "15", "system/com.example.d"])
        #expect(try args(.bootstrap, label: nil, path: "/Library/LaunchDaemons/com.example.d.plist")
                == ["bootstrap", "system", "/Library/LaunchDaemons/com.example.d.plist"])

        // Rejections
        #expect(throws: HelperFailure.self) { try args(.enable, label: nil) }
        #expect(throws: HelperFailure.self) { try args(.enable, label: "bad label") }
        #expect(throws: HelperFailure.self) { try args(.bootout, label: "com.apple.securityd") }
        #expect(throws: HelperFailure.self) { try args(.bootout, label: HelperConstants.machServiceName) }
        #expect(throws: HelperFailure.self) { try args(.kill, signal: nil) }
        #expect(throws: HelperFailure.self) { try args(.kill, signal: 11) }
        #expect(throws: HelperFailure.self) { try args(.bootstrap, label: nil, path: nil) }
        #expect(throws: HelperFailure.self) { try args(.bootstrap, label: nil, path: "/tmp/evil.plist") }
        #expect(throws: HelperFailure.self) { try args(.bootstrap, label: nil, path: "/Library/LaunchDaemons/../../tmp/x.plist") }
        #expect(throws: HelperFailure.self) { try args(.bootstrap, label: nil, path: "/Library/LaunchDaemons/sub/x.plist") }
        #expect(throws: HelperFailure.self) { try args(.bootstrap, label: nil, path: "/Library/LaunchDaemons/com.apple.x.plist") }
        #expect(throws: HelperFailure.self) { try args(.bootstrap, label: nil, path: "/Library/LaunchDaemons/x.txt") }
    }

    @Test func everyVerbIsCoveredByAllowlist() {
        // Adding a verb without argv rules must fail this test (and compile-fail the switch in HelperPolicy).
        #expect(Set(HelperLaunchctlVerb.allCases.map(\.rawValue))
                == ["enable", "disable", "bootstrap", "bootout", "kickstart", "kickstartKill", "kill"])
        for action in [LaunchdAction.enable, .disable, .bootstrap, .bootout, .kickstart, .restart, .kill(signal: 15)] {
            #expect(HelperLaunchctlVerb.allCases.contains(action.helperVerb))
        }
    }

    @Test func codecRoundTrip() throws {
        let request = HelperSignalRequest(pid: 42, signal: 15, expectedStartTime: 1_700_000_000_123_456)
        #expect(try HelperCodec.decode(HelperSignalRequest.self, from: HelperCodec.encode(request)) == request)

        let usage = HelperRusage(pid: 7, userTime: 1, systemTime: 2, physFootprint: 3, diskBytesRead: 4, diskBytesWritten: 5,
                                 billedEnergy: 6, interruptWakeups: 7, packageIdleWakeups: 8, startAbsTime: 9)
        let reply = HelperCodec.encodeReply([usage])
        #expect(try HelperCodec.decode(HelperReply<[HelperRusage]>.self, from: reply).unwrap() == [usage])

        let failed = HelperCodec.encodeFailure(HelperFailure(code: .processChanged, message: "gone"), as: HelperEmpty.self)
        #expect(throws: HelperFailure(code: .processChanged, message: "gone")) {
            try HelperCodec.decode(HelperReply<HelperEmpty>.self, from: failed).unwrap()
        }
        #expect(throws: HelperFailure.self) { try HelperCodec.decode(HelperSignalRequest.self, from: Data("nope".utf8)) }
    }

    @Test func clientRequirement() {
        let requirement = HelperConstants.clientRequirement(teamID: "ABCDE12345")
        #expect(requirement.contains("identifier \"com.canberkki.ProcLens\""))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
        #expect(requirement.hasPrefix("anchor apple generic"))
        #expect(HelperConstants.isValidTeamID("ABCDE12345"))
        #expect(!HelperConstants.isValidTeamID(HelperConstants.teamIDPlaceholder))
        #expect(!HelperConstants.isValidTeamID("abc"))
        #expect(!HelperConstants.isValidTeamID("ABCDE\" or 1"))
    }

    @Test func clientRefusesWithoutHelper() async {
        // Unit tests run unsigned and unregistered: the client must fail cleanly, not hang.
        let client = HelperClient()
        await #expect(throws: (any Error).self) { try await client.signalProcess(pid: 1, signal: 9, expectedStartTime: 0) }
        await #expect(throws: HelperClientError.notInstalled) { _ = try await client.helperVersion() }
    }

    @Test func subprocessRunnerHandlesLargeOutput() throws {
        let result = try SubprocessRunner.run(executable: "/usr/bin/yes", arguments: ["x"], timeout: 0.5, maxOutputBytes: 1024)
        #expect(result.timedOut)
    }
}

@Test func helperRefusesCriticalProcessNames() {
    #expect(throws: HelperFailure.self) { try HelperPolicy.validateTarget(name: "WindowServer") }
    #expect(throws: Never.self) { try HelperPolicy.validateTarget(name: "node") }
}
