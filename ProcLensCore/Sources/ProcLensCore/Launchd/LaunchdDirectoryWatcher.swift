// Adapted from Sean10000/LaunchManager (commit edd75d922a54c10da0d638779471e93a1dece377), MIT License,
// Copyright (c) 2026 Shi-Cheng Ma: LaunchManager/Services/DirectoryWatcher.swift.
// Changes: AsyncStream instead of a callback, own serial queue instead of main, FSEvents latency does the
// debouncing, Sendable context box, stream torn down when the consumer stops iterating.

import CoreServices
import Foundation

/// Change notifications for launchd plist directories (FSEvents, file-level, coalesced).
public enum LaunchdDirectoryWatcher {
    private final class Box: @unchecked Sendable {
        let continuation: AsyncStream<Void>.Continuation
        /// Resolved directories we care about; events elsewhere under a watched ancestor are ignored.
        let prefixes: [String]
        init(_ continuation: AsyncStream<Void>.Continuation, prefixes: [String]) {
            self.continuation = continuation
            self.prefixes = prefixes
        }
    }

    /// Emits `()` after changes settle. Non-existent directories are watched from their closest existing ancestor.
    /// Cancel the consuming task (or stop iterating) to stop watching.
    public static func changes(in directories: [URL], latency: TimeInterval = 0.5) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let queue = DispatchQueue(label: "com.canberkki.ProcLens.launchd-watcher", qos: .utility)
            let targets = directories.map { resolved($0) }
            let box = Box(continuation, prefixes: targets)
            let paths = Set(directories.map { realPath(existingAncestor(of: $0)) }).sorted()
            guard !paths.isEmpty else { continuation.finish(); return }

            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passRetained(box).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
                guard let info else { return }
                let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
                let reported = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                let relevant = reported.prefix(count).contains { path in
                    box.prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
                }
                if relevant { box.continuation.yield(()) }
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
            guard let stream = FSEventStreamCreate(
                nil, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
            ) else {
                Unmanaged<Box>.fromOpaque(context.info!).release()
                continuation.finish()
                return
            }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)

            // The stream is not Sendable; it is only touched here and on `queue` during teardown.
            nonisolated(unsafe) let owned = stream
            let info = context.info!
            nonisolated(unsafe) let infoPtr = info
            continuation.onTermination = { _ in
                queue.async {
                    FSEventStreamStop(owned)
                    FSEventStreamInvalidate(owned)
                    FSEventStreamRelease(owned)
                    Unmanaged<Box>.fromOpaque(infoPtr).release()
                }
            }
        }
    }

    /// Real path of `url`, also when the directory itself does not exist yet.
    private static func resolved(_ url: URL) -> String {
        let ancestor = existingAncestor(of: url)
        let base = realPath(ancestor)
        let rest = String(url.standardizedFileURL.path.dropFirst(ancestor.standardizedFileURL.path.count))
        return base == "/" ? rest : base + rest
    }

    /// `realpath(3)`: unlike `URL.resolvingSymlinksInPath` it keeps `/private/var`, which is what FSEvents reports.
    private static func realPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url.standardizedFileURL.path }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func existingAncestor(of url: URL) -> URL {
        var current = url
        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
            current = current.deletingLastPathComponent()
        }
        return current
    }
}
