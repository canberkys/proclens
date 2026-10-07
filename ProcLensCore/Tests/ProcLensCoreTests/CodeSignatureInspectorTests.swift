import Foundation
import Testing
@testable import ProcLensCore

struct CodeSignatureInspectorTests {
    @Test func finderIsApple() async {
        let inspector = CodeSignatureInspector()
        let status = await inspector.status(forPath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
        #expect(status == .apple)
    }

    @Test func binLsIsApple() async {
        let inspector = CodeSignatureInspector()
        let status = await inspector.status(forPath: "/bin/ls")
        #expect(status == .apple)
    }

    @Test func missingPathIsUnknown() async {
        let inspector = CodeSignatureInspector()
        let path = "/nonexistent/proclens-\(UUID().uuidString)/binary"
        let status = await inspector.status(forPath: path)
        #expect(status == .unknown)
    }

    @Test func unsignedScriptIsUnsigned() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proclens-codesign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("unsigned.sh")
        try "#!/bin/sh\necho hello\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let inspector = CodeSignatureInspector()
        let status = await inspector.status(forPath: script.path)
        #expect(status == .unsigned)
    }

    @Test func repeatedCallsReturnEqualResultsFromCache() async {
        let inspector = CodeSignatureInspector()
        let path = "/bin/ls"

        let clock = ContinuousClock()
        let first = await inspector.status(forPath: path)

        let start = clock.now
        let second = await inspector.status(forPath: path)
        let elapsed = start.duration(to: clock.now)

        #expect(first == second)
        // A cache hit only stats the file; it should be far below the cost of a full Security check.
        #expect(elapsed < .milliseconds(50))
    }

    /// Checks the first third-party Developer ID app found in /Applications. Skipped when none is installed.
    @Test func thirdPartyDeveloperIDAppIsDeveloperID() async {
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Slack.app/Contents/MacOS/Slack",
            "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
            "/Applications/iTerm.app/Contents/MacOS/iTerm2",
        ]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return
        }

        let inspector = CodeSignatureInspector()
        let status = await inspector.status(forPath: path)
        guard case .developerID(let teamID, _) = status else {
            Issue.record("Expected developerID for \(path), got \(status)")
            return
        }
        #expect(teamID != nil)
    }
}
