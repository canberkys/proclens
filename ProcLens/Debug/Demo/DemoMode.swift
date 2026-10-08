#if DEBUG
import AppKit
import Foundation
import ProcLensCore

/// Demo mode: `-ProcLensDemo 1` replaces the process, ports, launchd and host-total sources with the synthetic
/// machine in `DemoWorld`, so screenshots never show anything from the real Mac. Debug builds only; none of this
/// is compiled into Release.
enum DemoMode {
    static let isActive: Bool = UserDefaults.standard.bool(forKey: "ProcLensDemo")

    static let processSource: DemoProcessSource = DemoProcessSource()

    static var physicalMemory: Double { Double(DemoWorld.physicalMemory) }

    // MARK: Collectors

    struct Collectors {
        let cpu = DemoCollector<CPUSample>("cpu") { DemoWorld.cpuSample(at: $0) }
        let memory = DemoCollector<MemorySample>("memory") { DemoWorld.memorySample(at: $0) }
        let gpu = DemoCollector<GPUSample>("gpu") { DemoWorld.gpuSample(at: $0) }
        let disk = DemoCollector<DiskSample>("disk") { DemoWorld.diskSample(at: $0) }
        let network = DemoCollector<NetworkSample>("network") { DemoWorld.networkSample(at: $0) }
    }

    // MARK: Services

    @MainActor
    static func makeServices() -> AppServices {
        DemoWorld.prepare()
        let services = AppServices(ports: ListeningPortCollector(source: DemoFDSource(), cost: .everyN(2), negativeCacheRuns: 0),
                                   launchd: DemoLaunchd.service())
        let history = services.history
        services.historyWarmup = Task.detached { await backfill(history) }
        return services
    }

    /// Fills one hour of history (system totals + per-process top lists) ending now, so the History tab has a
    /// timeline from the first second.
    static func backfill(_ history: ProcessHistory) async {
        let wall = Date()
        let tNow = DemoWorld.now
        let step = 4.0
        var offset = -3_600.0
        var tick: UInt64 = 0
        while offset < -step {
            let snapshot = DemoWorld.snapshot(tick: tick, at: tNow + offset, instant: .now, withProcesses: true)
            await history.record(snapshot, at: wall.addingTimeInterval(offset))
            offset += step
            tick += 1
        }
    }

    /// The last 60 s of system totals, for the Performance graphs and the menu bar panel.
    static func seedGraphHistory() -> [SystemSnapshot] {
        let tNow = DemoWorld.now
        return (1...60).reversed().map { back in
            DemoWorld.snapshot(tick: 0, at: tNow - Double(back), instant: .now.advanced(by: .seconds(-back)), withProcesses: false)
        }
    }

    static var runningApps: [RunningAppInfo] {
        DemoWorld.prepare()
        return DemoWorld.apps.map { RunningAppInfo(pid: $0.pid, bundleIdentifier: $0.bundleID, localizedName: $0.name, isRegular: true) }
    }

    // MARK: Names and signatures

    static func userName(_ uid: uid_t) -> String { DemoWorld.userNames[uid] ?? String(uid) }

    static func signStatus(forPath path: String) -> CodeSignStatus {
        if DemoLaunchd.jobs.contains(where: { $0.arguments.first == path }) { return DemoLaunchd.signer(forProgram: path) }
        if path.hasPrefix("/opt/homebrew") { return .adHoc }
        if path.hasPrefix("/Users/demo") { return .adHoc }
        let thirdParty = ["/Applications/Slack.app", "/Applications/Figma.app", "/Applications/Visual Studio Code.app", "/Applications/Docker.app"]
        if thirdParty.contains(where: { path.hasPrefix($0) }) { return .developerID(teamID: "DEMOTEAM01", notarized: true) }
        return .apple
    }

    static func signerVendor(forPath path: String) -> String? { DemoLaunchd.signerName(forProgram: path) }

    // MARK: Icons

    private static let installedAppleApps: Set<String> = [
        "/Applications/Safari.app", "/Applications/Xcode.app", "/System/Applications/Mail.app", "/System/Applications/Music.app",
        "/System/Applications/Notes.app", "/System/Applications/Utilities/Terminal.app", "/System/Library/CoreServices/Finder.app",
    ]

    private static let brand: [String: (NSColor, String)] = [
        "Slack": (NSColor(red: 0.29, green: 0.08, blue: 0.29, alpha: 1), "#"),
        "Figma": (NSColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1), "F"),
        "Visual Studio Code": (NSColor(red: 0.0, green: 0.47, blue: 0.80, alpha: 1), "</>"),
        "Docker": (NSColor(red: 0.07, green: 0.56, blue: 0.93, alpha: 1), "D"),
        "Microsoft": (NSColor(red: 0.95, green: 0.35, blue: 0.14, alpha: 1), "M"),
        "GoogleSoftwareUpdate": (NSColor(red: 0.20, green: 0.52, blue: 0.96, alpha: 1), "G"),
    ]

    @MainActor private static var iconCache: [String: NSImage] = [:]

    @MainActor
    static func icon(forBundle bundlePath: String) -> NSImage? {
        if let cached = iconCache[bundlePath] { return cached }
        let image: NSImage
        if installedAppleApps.contains(bundlePath), FileManager.default.fileExists(atPath: bundlePath) {
            image = NSWorkspace.shared.icon(forFile: bundlePath)
        } else if let name = bundlePath.split(separator: "/").last?.dropLast(4),
                  let entry = brand.first(where: { name.hasPrefix($0.key) })?.value {
            image = synthesizedIcon(color: entry.0, glyph: entry.1)
        } else {
            return nil
        }
        iconCache[bundlePath] = image
        return image
    }

    @MainActor
    static func icon(forPID pid: pid_t) -> NSImage? {
        DemoWorld.apps.first { $0.pid == pid }.flatMap { icon(forBundle: $0.bundlePath) }
    }

    @MainActor
    static func icon(forExecutable path: String?) -> NSImage? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        return icon(forBundle: String(path[..<range.lowerBound]) + ".app")
    }

    private static func synthesizedIcon(color: NSColor, glyph: String) -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            let body = rect.insetBy(dx: 8, dy: 8)
            let path = NSBezierPath(roundedRect: body, xRadius: 28, yRadius: 28)
            NSGradient(starting: color.blended(withFraction: 0.25, of: .white) ?? color, ending: color)?.draw(in: path, angle: -90)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: glyph.count > 1 ? 40 : 72, weight: .bold), .foregroundColor: NSColor.white,
            ]
            let size = (glyph as NSString).size(withAttributes: attrs)
            (glyph as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
            return true
        }
    }
}
#endif
