import Foundation
import Testing
@testable import ProcLensCore

@Suite struct InterpreterLaunchTests {
    private func item(label: String, args: [String], scope: LaunchdScope = .userAgent, path: String? = nil) throws -> LaunchdItem {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": label, "ProgramArguments": args], format: .xml, options: 0)
        let result = LaunchdPlistScanner.parse(data: data, path: path ?? "/Users/x/Library/LaunchAgents/\(label).plist", scope: scope, uid: 501)
        return try result.get()
    }

    @Test func bashScriptAgent() throws {
        let i = try item(label: "com.canberk.backup", args: ["/bin/bash", "-l", "/Users/x/bin/backup.sh", "--daily"])
        #expect(i.isInterpreterLaunch)
        #expect(i.effectiveProgram == "/Users/x/bin/backup.sh")
        #expect(i.vendor == "Canberk")
        #expect(!i.isApple)
        #expect(i.signablePath == nil)
    }

    @Test func inlineShellCommand() throws {
        let i = try item(label: "org.example.tick", args: ["/bin/zsh", "-c", "echo hi"])
        #expect(i.effectiveProgram == "inline command")
        #expect(i.vendor == "Example")
    }

    @Test func pythonAgent() throws {
        let i = try item(label: "local.sync", args: ["/usr/bin/python3", "/Users/x/sync.py"])
        #expect(i.effectiveProgram == "/Users/x/sync.py")
        #expect(i.vendor != "Apple")
    }

    @Test func envNode() throws {
        let i = try item(label: "com.foo.server", args: ["/usr/bin/env", "node", "server.js"])
        #expect(i.interpreterLaunch?.interpreter == "node")
        #expect(i.effectiveProgram == "server.js")
        #expect(i.vendor == "Foo")
    }

    @Test func openApp() throws {
        let i = try item(label: "com.bar.launcher", args: ["/usr/bin/open", "-a", "Bar"])
        #expect(i.effectiveProgram == "Bar")
        #expect(i.vendor == "Bar")
    }

    @Test func realBinaryIsNotInterpreter() throws {
        let i = try item(label: "com.foo.daemon", args: ["/Applications/Foo.app/Contents/MacOS/food"])
        #expect(!i.isInterpreterLaunch)
        #expect(i.vendor == "Foo")
        #expect(i.signablePath != nil)
    }

    @Test func appleOnlyBySystemPathOrLabel() throws {
        let sys = try item(label: "org.example.x", args: ["/bin/sh", "/a.sh"], scope: .appleAgent)
        #expect(sys.isApple && sys.vendor == "Apple")
        let labelled = try item(label: "com.apple.thing", args: ["/bin/sh", "/a.sh"], scope: .globalDaemon)
        #expect(labelled.isApple)
        let user = try item(label: "com.me.x", args: ["/bin/sh", "/a.sh"], scope: .globalDaemon)
        #expect(!user.isApple && user.vendor != "Apple")
    }

    @Test func scanSignsScriptsAsUnsigned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proclens-interp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.me.s", "ProgramArguments": ["/bin/sh", "/a.sh"]], format: .xml, options: 0)
        try data.write(to: root.appendingPathComponent("com.me.s.plist"))
        let scanner = LaunchdPlistScanner(directories: [LaunchdDirectory(url: root, scope: .userAgent)], uid: 501,
                                          signer: { _ in .apple })
        let result = await scanner.scanAndSign()
        #expect(result.items.first?.signing == .unsigned)
    }
}
