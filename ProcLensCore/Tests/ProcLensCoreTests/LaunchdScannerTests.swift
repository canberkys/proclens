import Foundation
import Testing
@testable import ProcLensCore

@Suite struct LaunchdScannerTests {
    private func makeDirs() throws -> (root: URL, user: URL, daemons: URL, apple: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proclens-launchd-\(UUID().uuidString)")
        let user = root.appendingPathComponent("user"), daemons = root.appendingPathComponent("daemons"),
            apple = root.appendingPathComponent("apple")
        for dir in [user, daemons, apple] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return (root, user, daemons, apple)
    }

    private func write(_ dict: [String: Any], to dir: URL, name: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent(name))
    }

    @Test func scansAndClassifies() async throws {
        let d = try makeDirs()
        defer { try? FileManager.default.removeItem(at: d.root) }
        try write([
            "Label": "com.google.keystone.agent", "ProgramArguments": ["/Applications/Google Chrome.app/Contents/x", "--arg"],
            "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "StartInterval": 3600,
            "StandardOutPath": "/tmp/out.log", "StandardErrorPath": "/tmp/err.log",
            "StartCalendarInterval": ["Hour": 3, "Minute": 30],
        ], to: d.user, name: "com.google.keystone.agent.plist")
        try write(["Label": "org.example.daemon", "Program": "/usr/local/bin/exampled", "Disabled": true,
                   "KeepAlive": true, "WatchPaths": ["/tmp/a"]],
                  to: d.daemons, name: "org.example.daemon.plist")
        try write(["Label": "com.apple.fake", "Program": "/usr/libexec/fake"], to: d.apple, name: "com.apple.fake.plist")
        try Data("this is not a plist".utf8).write(to: d.user.appendingPathComponent("broken.plist"))
        try write(["Program": "/bin/true"], to: d.user, name: "nolabel.plist")
        try Data("ignored".utf8).write(to: d.user.appendingPathComponent("readme.txt"))

        let scanner = LaunchdPlistScanner(
            directories: [
                LaunchdDirectory(url: d.user, scope: .userAgent),
                LaunchdDirectory(url: d.daemons, scope: .globalDaemon),
                LaunchdDirectory(url: d.apple, scope: .appleAgent),
                LaunchdDirectory(url: d.root.appendingPathComponent("missing"), scope: .globalAgent),
            ],
            uid: 501,
            signer: { path in path.hasPrefix("/usr/local") ? .unsigned : .adHoc }
        )
        let result = await scanner.scanAndSign()
        #expect(result.items.map(\.label) == ["com.apple.fake", "com.google.keystone.agent", "org.example.daemon"])
        #expect(Set(result.invalid.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["broken.plist", "nolabel.plist"])
        #expect(result.invalid.first { $0.path.hasSuffix("nolabel.plist") }?.reason == "Missing Label")

        let agent = try #require(result.items.first { $0.label == "com.google.keystone.agent" })
        #expect(agent.domain == .gui(501))
        #expect(agent.program == "/Applications/Google Chrome.app/Contents/x")
        #expect(agent.programArguments.count == 2)
        #expect(agent.runAtLoad)
        #expect(agent.keepAlive == .conditional)
        #expect(agent.startInterval == 3600)
        #expect(agent.calendarIntervals == [LaunchdCalendarInterval(minute: 30, hour: 3)])
        #expect(agent.standardOutPath == "/tmp/out.log")
        #expect(agent.vendor == "Google Chrome")
        #expect(agent.signing == .adHoc)
        #expect(agent.isEditable)

        let daemon = try #require(result.items.first { $0.label == "org.example.daemon" })
        #expect(daemon.domain == .system)
        #expect(daemon.plistDisabled)
        #expect(daemon.keepAlive == .always)
        #expect(daemon.watchPaths == ["/tmp/a"])
        #expect(daemon.vendor == "Example")
        #expect(daemon.signing == .unsigned)
        #expect(daemon.scope.requiresHelper)

        let apple = try #require(result.items.first { $0.label == "com.apple.fake" })
        #expect(apple.isApple && !apple.isEditable)
        #expect(apple.vendor == "Apple")
    }

    @Test func scanWithoutSigningLeavesNil() throws {
        let d = try makeDirs()
        defer { try? FileManager.default.removeItem(at: d.root) }
        try write(["Label": "a.b.c", "Program": "/bin/true"], to: d.user, name: "a.b.c.plist")
        let result = LaunchdPlistScanner(directories: [LaunchdDirectory(url: d.user, scope: .userAgent)]).scan()
        #expect(result.items.count == 1)
        #expect(result.items[0].signing == nil)
    }

    @Test func vendorGuess() {
        #expect(VendorGuess.guess(label: "com.apple.foo", program: nil) == "Apple")
        #expect(VendorGuess.guess(label: "homebrew.mxcl.postgresql", program: "/opt/homebrew/bin/pg") != "Apple")
        #expect(VendorGuess.guess(label: "io.github.someone.tool", program: "/usr/local/bin/tool") == "someone")
        #expect(VendorGuess.guess(label: "com.microsoft.update", program: "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/x") == "Microsoft AutoUpdate")
        #expect(VendorGuess.guess(label: "nolabel", program: nil) == nil)
    }

    @Test func watcherReportsChanges() async throws {
        let d = try makeDirs()
        defer { try? FileManager.default.removeItem(at: d.root) }
        let stream = LaunchdDirectoryWatcher.changes(in: [d.user], latency: 0.2)
        let task = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(500))
        try write(["Label": "x.y", "Program": "/bin/true"], to: d.user, name: "x.y.plist")
        let timeout = Task { try await Task.sleep(for: .seconds(8)); task.cancel() }
        let got = await task.value
        timeout.cancel()
        #expect(got)
    }
}
