import Testing
import Foundation
@testable import ProcLensCore

/// Builds a KERN_PROCARGS2 blob.
func buildProcArgs(argc: Int32? = nil, exec: [UInt8], padding: Int = 3, args: [[UInt8]], env: [[UInt8]],
                   terminateEnv: Bool = true) -> [UInt8] {
    var out: [UInt8] = []
    withUnsafeBytes(of: argc ?? Int32(args.count)) { out.append(contentsOf: $0) }
    out += exec + [0] + [UInt8](repeating: 0, count: padding)
    for a in args { out += a + [0] }
    for e in env { out += e + [0] }
    if terminateEnv { out.append(0) }
    return out
}
private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

struct ProcArgsParserTests {
    @Test func wellFormed() throws {
        let blob = buildProcArgs(exec: b("/bin/sleep"), args: [b("sleep"), b("30")], env: [b("FOO=bar"), b("A=b=c")])
        let r = try ProcArgsParser.parse(blob)
        #expect(r.executablePath == "/bin/sleep")
        #expect(r.arguments == ["sleep", "30"])
        #expect(r.environment == ["FOO": "bar", "A": "b=c"])
    }

    @Test func missingEnvironment() throws {
        let blob = buildProcArgs(exec: b("/x"), args: [b("x")], env: [], terminateEnv: false)
        let r = try ProcArgsParser.parse(blob)
        #expect(r.arguments == ["x"])
        #expect(r.environment.isEmpty)
    }

    @Test func argcLargerThanAvailable() throws {
        let blob = buildProcArgs(argc: 5, exec: b("/x"), args: [b("x"), b("y")], env: [], terminateEnv: false)
        let r = try ProcArgsParser.parse(blob)
        #expect(r.arguments == ["x", "y"])
        #expect(r.environment.isEmpty)
    }

    @Test func argcLargerDoesNotEatEnvIntoArgs() throws {
        // argc=3 but only 2 args before the empty terminator: the empty string ends nothing, parse stays safe.
        let blob = buildProcArgs(argc: 3, exec: b("/x"), args: [b("x"), b("y")], env: [b("K=V")])
        let r = try ProcArgsParser.parse(blob)
        #expect(r.arguments.first == "x")
        #expect(r.arguments.count <= 3)
    }

    @Test func truncatedMidString() throws {
        var blob = buildProcArgs(exec: b("/bin/sleep"), args: [b("sleep"), b("30")], env: [b("FOO=bar")])
        blob.removeLast(6)  // cut inside the env entry / terminators
        let r = try ProcArgsParser.parse(blob)
        #expect(r.arguments == ["sleep", "30"])
        #expect(r.environment == ["FOO": ""])  // cut after "FOO", a bare key
    }

    @Test func truncatedInsideExecPath() throws {
        let blob = Array(buildProcArgs(exec: b("/bin/sleep"), args: [b("sleep")], env: []).prefix(9))
        let r = try ProcArgsParser.parse(blob)
        #expect(r.executablePath == "/bin/")
        #expect(r.arguments.isEmpty)
    }

    @Test func nonUTF8IsLossy() throws {
        let blob = buildProcArgs(exec: b("/x"), args: [[0x61, 0xFF, 0x62]], env: [[0x4B, 0x3D, 0xC3, 0x28]])
        let r = try ProcArgsParser.parse(blob)
        #expect(r.arguments == ["a\u{FFFD}b"])
        #expect(r.environment["K"] == "\u{FFFD}(")
    }

    @Test func tooShortThrows() {
        #expect(throws: ProcArgsParseError.tooShort) { try ProcArgsParser.parse([1, 0]) }
        #expect(throws: ProcArgsParseError.tooShort) { try ProcArgsParser.parse([]) }
    }

    @Test func zeroAndNegativeArgc() throws {
        let r0 = try ProcArgsParser.parse(buildProcArgs(argc: 0, exec: b("/x"), args: [], env: [b("A=1")]))
        #expect(r0.arguments.isEmpty)
        let rn = try ProcArgsParser.parse(buildProcArgs(argc: -4, exec: b("/x"), args: [b("x")], env: []))
        #expect(rn.arguments.isEmpty)
    }

    @Test func realFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "procargs-sleep", withExtension: "bin", subdirectory: "Fixtures"))
        let r = try ProcArgsParser.parse([UInt8](try Data(contentsOf: url)))
        #expect(r.executablePath == "/bin/sleep")
        #expect(r.arguments == ["/bin/sleep", "30"])
        // macOS withholds the environment of platform binaries from other processes: empty is expected.
        #expect(r.environment.isEmpty)
    }
}
