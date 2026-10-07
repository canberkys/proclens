import Foundation

/// Result of a finished subprocess.
public struct SubprocessResult: Sendable, Hashable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
}

public enum SubprocessError: Error, Sendable, Hashable {
    case launchFailed(String)
}

/// Blocking `Process` wrapper with a timeout. Output pipes are drained concurrently (no pipe-full deadlock).
/// Call from a background thread / queue only; never from the sampling path.
public enum SubprocessRunner {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func store(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func take() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    public static func run(executable: String, arguments: [String], timeout: TimeInterval,
                           maxOutputBytes: Int = 32 * 1024 * 1024) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { throw SubprocessError.launchFailed(error.localizedDescription) }

        let outSink = Sink(), errSink = Sink()
        let group = DispatchGroup()
        for (pipe, sink) in [(outPipe, outSink), (errPipe, errSink)] {
            group.enter()
            DispatchQueue.global().async {
                var collected = Data()
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if collected.count < maxOutputBytes { collected.append(chunk) }
                }
                sink.store(collected)
                group.leave()
            }
        }

        let timedOut = Flag()
        let pid = process.processIdentifier
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        group.wait()

        return SubprocessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outSink.take(), as: UTF8.self),
            stderr: String(decoding: errSink.take(), as: UTF8.self),
            timedOut: timedOut.get()
        )
    }
}
