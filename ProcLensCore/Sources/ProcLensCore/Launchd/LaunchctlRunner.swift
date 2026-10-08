import Foundation
import ProcLensHelperProtocol

public struct LaunchctlOutput: Sendable, Hashable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs `/bin/launchctl` (or a mock). On-demand only, never on the sampling path.
public protocol LaunchctlRunning: Sendable {
    /// Returns the output for any exit status; throws only when the process cannot run or times out.
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> LaunchctlOutput
}

extension LaunchctlRunning {
    public func run(_ arguments: [String]) async throws -> LaunchctlOutput {
        try await run(arguments, timeout: 10)
    }

    /// Like `run`, but a non-zero exit becomes `LaunchdError.commandFailed`.
    public func runChecked(_ arguments: [String], timeout: TimeInterval = 10) async throws -> String {
        let out = try await run(arguments, timeout: timeout)
        guard out.status == 0 else {
            let message = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LaunchdError.commandFailed(status: out.status, message: message.isEmpty
                ? out.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : message)
        }
        return out.stdout
    }
}

public struct ProcessLaunchctlRunner: LaunchctlRunning {
    public var executable: String
    public init(executable: String = HelperPolicy.launchctlPath) { self.executable = executable }

    public func run(_ arguments: [String], timeout: TimeInterval) async throws -> LaunchctlOutput {
        let executable = executable
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try SubprocessRunner.run(executable: executable, arguments: arguments, timeout: timeout)
                    if result.timedOut {
                        continuation.resume(throwing: LaunchdError.timedOut)
                    } else {
                        continuation.resume(returning: LaunchctlOutput(status: result.status, stdout: result.stdout, stderr: result.stderr))
                    }
                } catch SubprocessError.launchFailed(let message) {
                    continuation.resume(throwing: LaunchdError.launchFailed(message))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
