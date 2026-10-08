#if DEBUG
import Darwin
import Foundation
import ProcLensCore

/// Synthetic machine used by demo mode (`-ProcLensDemo 1`, Debug builds only). Everything here is invented:
/// generic app names, a fake user "demo", smooth time-varying load. It exists so README screenshots can be taken on
/// a Mac whose real process list must not be shown. Nothing in this file reads the host.
///
/// All values are pure functions of time `t` (seconds relative to `DemoWorld.epoch`), built from a few sines, so the
/// same curves feed the live collectors, the pre-filled 60 s graphs and the back-filled history.
struct DemoWave: Sendable {
    var phase: (Double, Double, Double)
    var rate: (Double, Double, Double)
    static let amplitude = (0.55, 0.3, 0.1)

    /// Multiplier around 1.0, never below 0.1.
    func factor(_ t: Double) -> Double {
        1 + Self.amplitude.0 * sin(rate.0 * t + phase.0) + Self.amplitude.1 * sin(rate.1 * t + phase.1)
            + Self.amplitude.2 * sin(rate.2 * t + phase.2)
    }

    /// Integral of `factor` from 0 to t (closed form), so cumulative counters stay consistent with the rate.
    func integral(_ t: Double) -> Double {
        t - Self.amplitude.0 / rate.0 * (cos(rate.0 * t + phase.0) - cos(phase.0))
            - Self.amplitude.1 / rate.1 * (cos(rate.1 * t + phase.1) - cos(phase.1))
            - Self.amplitude.2 / rate.2 * (cos(rate.2 * t + phase.2) - cos(phase.2))
    }
}

struct DemoProc: Sendable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let name: String
    let path: String?
    let argv: [String]
    let restricted: Bool
    /// Mean CPU in cores (1.0 = one full core).
    let cpu: Double
    let memory: Double
    let threads: Int32
    let startTime: UInt64
    /// Mean disk bytes per second (read + write).
    let disk: Double
    let wave: DemoWave
    var id: ProcessID { ProcessID(pid: pid, startTime: startTime) }
    var startAbs: UInt64 { startTime &* 1000 }

    func cpuNow(_ t: Double) -> Double {
        if restricted { return 0 }
        return cpu * wave.factor(t) + DemoWorld.burst(t) * DemoWorld.burstCores(for: name)
    }
    func memoryNow(_ t: Double) -> UInt64 {
        restricted ? 0 : UInt64(memory * (1 + 0.025 * sin(0.05 * t + wave.phase.1) + 0.01 * sin(0.4 * t + wave.phase.0)))
    }
    func diskNow(_ t: Double) -> Double { restricted ? 0 : disk * wave.factor(t) }
}

struct DemoListener: Sendable {
    let port: UInt16
    let pid: pid_t
    let loopbackOnly: Bool
}

enum DemoWorld {
    /// Reference instant: t = 0.
    static let epoch = Date()
    static let coreCount = 16
    static let efficiencyCores = 4
    static let physicalMemory: UInt64 = 48 << 30
    static let userID: uid_t = 501
    static let userName = "demo"
    static let userNames: [uid_t: String] = [
        0: "root", 501: "demo", 88: "_windowserver", 202: "_coreaudiod", 261: "_hidd", 65: "_mdnsresponder",
        214: "_timed", 205: "_locationd", 222: "_networkd",
    ]

    static var now: Double { Date().timeIntervalSince(epoch) }

    /// Three past "builds" (seconds relative to launch) that push the machine over 80%. Shape is a smooth bump, 0...1.
    private static let bursts: [(center: Double, width: Double, peak: Double)] = [(-2_760, 55, 1.0), (-1_620, 70, 0.97), (-540, 50, 0.93)]
    static func burst(_ t: Double) -> Double {
        var b = 0.0
        for burst in bursts where abs(t - burst.center) < burst.width * 4 {
            let x = (t - burst.center) / burst.width
            b = max(b, burst.peak * exp(-x * x))
        }
        return b
    }
    /// Extra cores a process burns at burst = 1.
    static func burstCores(for name: String) -> Double {
        switch name {
        case "swift-frontend": 5.5
        case "Xcode", "SourceKitService": 0.8
        case "XCBBuildService": 1.0
        default: 0
        }
    }
    /// Seconds-ago of the middle burst (for `-ProcLensHistoryAt`).
    static let pinnedBurstAgo = 1_620.0

    struct App: Sendable {
        let pid: pid_t
        let name: String
        let bundleID: String
        let bundlePath: String
    }

    struct Built: Sendable {
        var processes: [DemoProc]
        var apps: [App]
        var listeners: [DemoListener]
        var byPID: [pid_t: DemoProc]
        var byID: [ProcessID: DemoProc]
    }

    private static let built = build()
    static var processes: [DemoProc] { built.processes }
    static var apps: [App] { built.apps }
    static var listeners: [DemoListener] { built.listeners }
    static var byPID: [pid_t: DemoProc] { built.byPID }
    static var byID: [ProcessID: DemoProc] { built.byID }
    static func prepare() { _ = built }

    // MARK: - Build

    private struct RNG {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
        mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
    }

    private static func build() -> Built {
        var rng = RNG(state: 0xC0FFEE)
        var list: [DemoProc] = []
        var apps: [App] = []
        var listeners: [DemoListener] = []
        var used: Set<pid_t> = []
        let base = epoch.timeIntervalSince1970

        func freshPID(_ lo: Int, _ hi: Int) -> pid_t {
            while true {
                let p = pid_t(lo + Int(rng.next() * Double(hi - lo)))
                if used.insert(p).inserted { return p }
            }
        }

        @discardableResult
        func add(_ name: String, path: String?, argv: [String]? = nil, pid: pid_t? = nil, ppid: pid_t = 1,
                 uid: uid_t = 501, mb: Double, cpu: Double, threads: Int32 = 4, age: Double = 6 * 3600,
                 disk: Double = 0, restricted: Bool = false, pids: ClosedRange<Int> = 700...9_000) -> pid_t {
            let p = pid ?? freshPID(pids.lowerBound, pids.upperBound)
            used.insert(p)
            let wave = DemoWave(
                phase: (rng.range(0, 6.28), rng.range(0, 6.28), rng.range(0, 6.28)),
                rate: (rng.range(0.002, 0.005), rng.range(0.006, 0.012), rng.range(0.012, 0.022)))
            let start = UInt64((base - age - rng.range(0, 600)) * 1_000_000)
            list.append(DemoProc(pid: p, ppid: ppid, uid: uid, name: name, path: path, argv: argv ?? [path ?? name],
                                 restricted: restricted, cpu: cpu, memory: mb * 1_048_576, threads: threads,
                                 startTime: start, disk: disk, wave: wave))
            return p
        }

        func app(_ name: String, bundle: String, id: String, exe: String? = nil, dir: String = "/Applications",
                 mb: Double, cpu: Double, threads: Int32, age: Double = 5 * 3600, disk: Double = 0) -> pid_t {
            let bundlePath = "\(dir)/\(bundle).app"
            let p = add(exe ?? name, path: "\(bundlePath)/Contents/MacOS/\(exe ?? name)", mb: mb, cpu: cpu,
                        threads: threads, age: age, disk: disk, pids: 900...12_000)
            apps.append(App(pid: p, name: name, bundleID: id, bundlePath: bundlePath))
            return p
        }

        // Kernel and launchd.
        add("kernel_task", path: nil, pid: 0, ppid: 0, uid: 0, mb: 780, cpu: 0.05, threads: 410, age: 4 * 86400)
        add("launchd", path: "/sbin/launchd", pid: 1, ppid: 0, uid: 0, mb: 14, cpu: 0.003, threads: 6, age: 4 * 86400,
            restricted: true)

        // Root daemons (not readable without the helper).
        let rootDaemons = [
            "logd", "UserEventAgent", "uninstalld", "fseventsd", "mds", "configd", "powerd", "notifyd",
            "diskarbitrationd", "opendirectoryd", "securityd", "trustd", "apsd", "bluetoothd", "airportd", "thermalmonitord",
            "kernelmanagerd", "watchdogd", "syspolicyd", "amfid", "cryptexd", "diskmanagementd", "launchservicesd",
            "KernelEventAgent", "wifianalyticsd", "usbd", "symptomsd", "networkserviceproxy", "ocspd", "smd", "tccd",
            "systemstats", "coreduetd", "bootinstalld", "mobileassetd", "storagekitd", "apfsd", "dasd", "powerlogd",
            "endpointd", "sysmond", "nesessionmanager", "cloudpaird", "softwareupdated", "installd", "xpcroleaccountd",
        ]
        for n in rootDaemons {
            add(n, path: nil, ppid: 1, uid: 0, mb: 0, cpu: 0, threads: 0, age: 2 * 3600, restricted: true, pids: 90...760)
        }
        add("mds_stores", path: nil, ppid: 1, uid: 0, mb: 0, cpu: 0, threads: 0, age: 2 * 3600, restricted: true, pids: 90...760)
        add("WindowServer", path: nil, ppid: 1, uid: 88, mb: 0, cpu: 0, threads: 0, age: 2 * 3600, restricted: true, pids: 90...760)
        add("coreaudiod", path: nil, ppid: 1, uid: 202, mb: 0, cpu: 0, threads: 0, age: 2 * 3600, restricted: true, pids: 90...760)
        add("hidd", path: nil, ppid: 1, uid: 261, mb: 0, cpu: 0, threads: 0, age: 2 * 3600, restricted: true, pids: 90...760)
        add("mDNSResponder", path: nil, ppid: 1, uid: 65, mb: 0, cpu: 0, threads: 0, age: 2 * 3600, restricted: true, pids: 90...760)
        add("timed", path: nil, ppid: 1, uid: 214, mb: 0, cpu: 0, threads: 0, age: 2 * 3600, restricted: true, pids: 90...760)
        add("locationd", path: nil, ppid: 1, uid: 205, mb: 0, cpu: 0, threads: 0, age: 2 * 3600, restricted: true, pids: 90...760)
        add("com.docker.vmnetd", path: nil, ppid: 1, uid: 0, mb: 0, cpu: 0, threads: 0, age: 30 * 3600, restricted: true, pids: 90...760)

        // Readable per-user system agents (system paths, so they land in "System processes").
        let coreServices = "/System/Library/CoreServices"
        let agents: [(String, String, Double, Double, Int32)] = [
            ("Dock", "\(coreServices)/Dock.app/Contents/MacOS/Dock", 96, 0.012, 11),
            ("SystemUIServer", "\(coreServices)/SystemUIServer.app/Contents/MacOS/SystemUIServer", 58, 0.004, 7),
            ("ControlCenter", "\(coreServices)/ControlCenter.app/Contents/MacOS/ControlCenter", 74, 0.006, 9),
            ("NotificationCenter", "\(coreServices)/NotificationCenter.app/Contents/MacOS/NotificationCenter", 52, 0.002, 6),
            ("loginwindow", "\(coreServices)/loginwindow.app/Contents/MacOS/loginwindow", 41, 0.001, 5),
            ("Spotlight", "\(coreServices)/Spotlight.app/Contents/MacOS/Spotlight", 88, 0.003, 8),
            ("WindowManager", "\(coreServices)/WindowManager.app/Contents/MacOS/WindowManager", 33, 0.001, 5),
            ("TextInputMenuAgent", "\(coreServices)/TextInputMenuAgent.app/Contents/MacOS/TextInputMenuAgent", 28, 0.0005, 4),
            ("universalaccessd", "/System/Library/CoreServices/universalaccessd", 24, 0.001, 4),
            ("sharingd", "/usr/libexec/sharingd", 38, 0.003, 7),
            ("rapportd", "/usr/libexec/rapportd", 21, 0.002, 6),
            ("imagent", "/System/Library/PrivateFrameworks/IMCore.framework/imagent.app/Contents/MacOS/imagent", 29, 0.001, 5),
            ("identityservicesd", "/System/Library/PrivateFrameworks/IDSCore.framework/identityservicesd.app/Contents/MacOS/identityservicesd", 44, 0.002, 7),
            ("akd", "/System/Library/PrivateFrameworks/AuthKit.framework/Support/akd", 19, 0.0005, 4),
            ("cloudd", "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd", 62, 0.004, 9),
            ("bird", "/System/Library/PrivateFrameworks/CloudDocsDaemon.framework/Versions/A/Support/bird", 47, 0.003, 8),
            ("photolibraryd", "/System/Library/PrivateFrameworks/PhotoLibraryServices.framework/Versions/A/Support/photolibraryd", 88, 0.006, 9),
            ("mediaanalysisd", "/System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd", 120, 0.012, 6),
            ("corespotlightd", "/System/Library/Frameworks/CoreSpotlight.framework/Versions/A/Support/corespotlightd", 36, 0.002, 5),
            ("secd", "/System/Library/Frameworks/Security.framework/Versions/A/Resources/secd", 14, 0.0005, 4),
            ("accountsd", "/System/Library/Frameworks/Accounts.framework/Versions/A/Support/accountsd", 17, 0.0005, 4),
            ("assistantd", "/System/Library/PrivateFrameworks/AssistantServices.framework/Versions/A/Support/assistantd", 26, 0.001, 5),
            ("suggestd", "/System/Library/PrivateFrameworks/CoreSuggestions.framework/Versions/A/Support/suggestd", 54, 0.002, 6),
            ("parsecd", "/System/Library/PrivateFrameworks/Parsec.framework/Versions/A/parsecd", 22, 0.0005, 4),
            ("cfprefsd", "/usr/sbin/cfprefsd", 11, 0.001, 4),
            ("distnoted", "/usr/sbin/distnoted", 7, 0.0005, 3),
            ("pboard", "/usr/sbin/pbd", 6, 0.0003, 3),
            ("useractivityd", "/System/Library/PrivateFrameworks/UserActivity.framework/Agents/useractivityd", 15, 0.0005, 4),
            ("routined", "/usr/libexec/routined", 31, 0.001, 5),
            ("lsd", "/usr/libexec/lsd", 20, 0.001, 5),
            ("nsurlsessiond", "/usr/libexec/nsurlsessiond", 27, 0.003, 7),
            ("contactsd", "/System/Library/Frameworks/Contacts.framework/Support/contactsd", 25, 0.001, 5),
            ("callservicesd", "/System/Library/Frameworks/CallKit.framework/Support/callservicesd", 18, 0.0005, 4),
            ("coreservicesd", "/System/Library/Frameworks/CoreServices.framework/Versions/A/Support/coreservicesd", 16, 0.0008, 4),
            ("tipsd", "/System/Library/PrivateFrameworks/Tips.framework/Versions/A/Resources/tipsd", 33, 0.0005, 4),
            ("quicklookd", "/System/Library/Frameworks/QuickLook.framework/Versions/A/Resources/quicklookd.app/Contents/MacOS/quicklookd", 29, 0.0005, 4),
            ("AMPDeviceDiscoveryAgent", "/System/Library/PrivateFrameworks/MediaDevices.framework/Versions/A/Resources/AMPDeviceDiscoveryAgent", 12, 0.0003, 3),
            ("AMPLibraryAgent", "/System/Library/PrivateFrameworks/AMPLibrary.framework/Versions/A/Resources/AMPLibraryAgent.app/Contents/MacOS/AMPLibraryAgent", 41, 0.0006, 5),
            ("usernoted", "/System/Library/PrivateFrameworks/UserNotificationsCore.framework/Support/usernoted", 24, 0.001, 5),
            ("ViewBridgeAuxiliary", "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/ViewBridgeAuxiliary.xpc/Contents/MacOS/ViewBridgeAuxiliary", 21, 0.0004, 4),
            ("com.apple.hiservices-xpcservice", "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Versions/A/XPCServices/com.apple.hiservices-xpcservice.xpc/Contents/MacOS/com.apple.hiservices-xpcservice", 9, 0.0003, 3),
            ("pkd", "/usr/libexec/pkd", 18, 0.0004, 4),
            ("chronod", "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/chronod", 39, 0.001, 5),
            ("homed", "/System/Library/PrivateFrameworks/HomeKitDaemon.framework/Support/homed", 28, 0.0006, 5),
            ("sociallayerd", "/System/Library/PrivateFrameworks/SocialLayer.framework/Support/sociallayerd", 23, 0.0004, 4),
            ("ScreenTimeAgent", "/System/Library/PrivateFrameworks/ScreenTimeCore.framework/Versions/A/Resources/ScreenTimeAgent", 19, 0.0005, 4),
            ("trustd", "/usr/libexec/trustd", 24, 0.002, 4),
        ]
        for (n, p, mb, cpu, thr) in agents {
            add(n, path: p, mb: mb, cpu: cpu, threads: thr, age: 2.5 * 3600, pids: 300...2_600)
        }

        // Apps.
        _ = app("Finder", bundle: "Finder", id: "com.apple.finder", dir: coreServices, mb: 118, cpu: 0.008, threads: 9, age: 2 * 86400)

        let safari = app("Safari", bundle: "Safari", id: "com.apple.Safari", mb: 412, cpu: 0.05, threads: 31, age: 7 * 3600, disk: 40_000)
        let wk = "/Applications/Safari.app/Contents/XPCServices"
        for (mb, cpu) in [(380.0, 0.06), (260.0, 0.018), (210.0, 0.012), (155.0, 0.008), (120.0, 0.004)] {
            add("Safari Web Content", path: "\(wk)/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
                ppid: safari, mb: mb, cpu: cpu, threads: 9, age: 6 * 3600, disk: 4_000)
        }
        add("Safari Networking", path: "\(wk)/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking",
            ppid: safari, mb: 84, cpu: 0.012, threads: 14, age: 7 * 3600, disk: 20_000)
        add("Safari Graphics and Media", path: "\(wk)/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
            ppid: safari, mb: 96, cpu: 0.02, threads: 12, age: 7 * 3600)

        let xcode = app("Xcode", bundle: "Xcode", id: "com.apple.dt.Xcode", mb: 2_140, cpu: 0.16, threads: 74, age: 3 * 3600, disk: 380_000)
        let xc = "/Applications/Xcode.app/Contents"
        add("SourceKitService", path: "\(xc)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitd.framework/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService",
            ppid: xcode, mb: 1_380, cpu: 0.11, threads: 22, age: 3 * 3600, disk: 90_000)
        add("XCBBuildService", path: "\(xc)/SharedFrameworks/XCBuild.framework/PlugIns/XCBBuildServiceModule.xcbbuildservice/Contents/MacOS/XCBBuildService",
            ppid: xcode, mb: 318, cpu: 0.03, threads: 18, age: 3 * 3600)
        add("swift-frontend", path: "\(xc)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
            ppid: xcode, mb: 940, cpu: 0.62, threads: 7, age: 600, disk: 1_900_000)
        add("swift-frontend", path: "\(xc)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
            ppid: xcode, mb: 710, cpu: 0.44, threads: 6, age: 600, disk: 1_200_000)
        add("IBAgent-iOS", path: "\(xc)/Developer/Library/PrivateFrameworks/IDEInterfaceBuilderKit.framework/Resources/IBAgent-iOS",
            ppid: xcode, mb: 176, cpu: 0.006, threads: 5, age: 2 * 3600)
        add("lldb-rpc-server", path: "\(xc)/SharedFrameworks/LLDBRPC.framework/Versions/A/Resources/lldb-rpc-server",
            ppid: xcode, mb: 142, cpu: 0.004, threads: 8, age: 1800)

        let mail = app("Mail", bundle: "Mail", id: "com.apple.mail", dir: "/System/Applications", mb: 326, cpu: 0.012, threads: 19, age: 20 * 3600, disk: 12_000)
        add("Mail Web Content", path: "/System/Applications/Mail.app/Contents/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
            ppid: mail, mb: 112, cpu: 0.003, threads: 8, age: 20 * 3600)

        let music = app("Music", bundle: "Music", id: "com.apple.Music", dir: "/System/Applications", mb: 486, cpu: 0.045, threads: 36, age: 9 * 3600, disk: 25_000)
        add("Music Web Content", path: "/System/Applications/Music.app/Contents/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
            ppid: music, mb: 138, cpu: 0.01, threads: 8, age: 9 * 3600)

        _ = app("Notes", bundle: "Notes", id: "com.apple.Notes", dir: "/System/Applications", mb: 162, cpu: 0.004, threads: 14, age: 11 * 3600)

        let slack = app("Slack", bundle: "Slack", id: "com.tinyspeck.slackmacgap", mb: 396, cpu: 0.05, threads: 34, age: 8 * 3600, disk: 15_000)
        let sl = "/Applications/Slack.app/Contents/Frameworks/Slack Helper"
        add("Slack Helper (GPU)", path: "\(sl) (GPU).app/Contents/MacOS/Slack Helper (GPU)", ppid: slack, mb: 214, cpu: 0.035, threads: 14, age: 8 * 3600)
        add("Slack Helper (Renderer)", path: "\(sl) (Renderer).app/Contents/MacOS/Slack Helper (Renderer)", ppid: slack, mb: 468, cpu: 0.04, threads: 20, age: 8 * 3600)
        add("Slack Helper (Renderer)", path: "\(sl) (Renderer).app/Contents/MacOS/Slack Helper (Renderer)", ppid: slack, mb: 236, cpu: 0.012, threads: 16, age: 8 * 3600)
        add("Slack Helper", path: "\(sl).app/Contents/MacOS/Slack Helper", ppid: slack, mb: 82, cpu: 0.005, threads: 9, age: 8 * 3600)

        let figma = app("Figma", bundle: "Figma", id: "com.figma.Desktop", mb: 548, cpu: 0.07, threads: 38, age: 4 * 3600, disk: 30_000)
        let fg = "/Applications/Figma.app/Contents/Frameworks/Figma Helper"
        add("Figma Helper (GPU)", path: "\(fg) (GPU).app/Contents/MacOS/Figma Helper (GPU)", ppid: figma, mb: 312, cpu: 0.06, threads: 15, age: 4 * 3600)
        add("Figma Helper (Renderer)", path: "\(fg) (Renderer).app/Contents/MacOS/Figma Helper (Renderer)", ppid: figma, mb: 702, cpu: 0.09, threads: 24, age: 4 * 3600)
        add("Figma Helper", path: "\(fg).app/Contents/MacOS/Figma Helper", ppid: figma, mb: 74, cpu: 0.004, threads: 9, age: 4 * 3600)
        add("figma_agent", path: "/Users/demo/Library/Application Support/Figma/FigmaAgent.app/Contents/MacOS/figma_agent",
            mb: 38, cpu: 0.002, threads: 6, age: 30 * 3600)

        let code = app("Visual Studio Code", bundle: "Visual Studio Code", id: "com.microsoft.VSCode", exe: "Code",
                       mb: 318, cpu: 0.04, threads: 30, age: 6 * 3600, disk: 55_000)
        let cd = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper"
        add("Code Helper (GPU)", path: "\(cd) (GPU).app/Contents/MacOS/Code Helper (GPU)", ppid: code, mb: 186, cpu: 0.03, threads: 14, age: 6 * 3600)
        add("Code Helper (Renderer)", path: "\(cd) (Renderer).app/Contents/MacOS/Code Helper (Renderer)", ppid: code, mb: 612, cpu: 0.07, threads: 22, age: 6 * 3600)
        let ext = add("Code Helper (Plugin)", path: "\(cd) (Plugin).app/Contents/MacOS/Code Helper (Plugin)", ppid: code, mb: 448, cpu: 0.05, threads: 18, age: 6 * 3600, disk: 20_000)
        add("Code Helper", path: "\(cd).app/Contents/MacOS/Code Helper", ppid: code, mb: 92, cpu: 0.006, threads: 10, age: 6 * 3600)
        let tsserver = add("node", path: "/opt/homebrew/Cellar/node/22.11.0/bin/node",
            argv: ["/opt/homebrew/Cellar/node/22.11.0/bin/node", "/Users/demo/projects/webapp/node_modules/typescript/lib/tsserver.js", "--useInferredProjectPerProjectRoot"],
            ppid: ext, mb: 524, cpu: 0.08, threads: 11, age: 5 * 3600, disk: 30_000)

        // Terminal with three dev servers.
        let terminal = app("Terminal", bundle: "Terminal", id: "com.apple.Terminal", dir: "/System/Applications/Utilities", mb: 128, cpu: 0.006, threads: 12, age: 10 * 3600)
        let nodeBin = "/opt/homebrew/Cellar/node/22.11.0/bin/node"
        func shell(_ cwd: String) -> pid_t {
            let l = add("login", path: "/usr/bin/login", argv: ["login", "-pf", "demo"], ppid: terminal, mb: 3, cpu: 0.0001, threads: 2, age: 5 * 3600, restricted: false, pids: 12_000...40_000)
            return add("zsh", path: "/bin/zsh", argv: ["-zsh"], ppid: l, mb: 9, cpu: 0.0003, threads: 2, age: 5 * 3600, pids: 12_000...40_000)
        }
        let z1 = shell("webapp"), z2 = shell("webapp"), z3 = shell("api")
        _ = shell("home")
        let vite = add("node", path: nodeBin,
                       argv: [nodeBin, "/Users/demo/projects/webapp/node_modules/.bin/vite", "--port", "5173"],
                       ppid: z1, mb: 262, cpu: 0.035, threads: 12, age: 4 * 3600, disk: 18_000, pids: 12_000...40_000)
        let next = add("next-server (v14.2.3)", path: nodeBin, argv: ["next-server (v14.2.3)"],
                       ppid: z2, mb: 486, cpu: 0.06, threads: 14, age: 2 * 3600, disk: 25_000, pids: 12_000...40_000)
        let djangoPY = "/opt/homebrew/Cellar/python@3.12/3.12.7/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
        let djParent = add("python3", path: djangoPY, argv: ["python3", "manage.py", "runserver", "8000"],
                           ppid: z3, mb: 96, cpu: 0.004, threads: 2, age: 90 * 60, pids: 12_000...40_000)
        let django = add("python3", path: djangoPY, argv: ["python3", "manage.py", "runserver", "8000"],
                         ppid: djParent, mb: 142, cpu: 0.02, threads: 5, age: 90 * 60, disk: 8_000, pids: 12_000...40_000)

        // Databases and containers (background processes owned by launchd).
        let pgBin = "/opt/homebrew/opt/postgresql@16/bin/postgres"
        let pg = add("postgres", path: pgBin, argv: [pgBin, "-D", "/opt/homebrew/var/postgresql@16"], mb: 38, cpu: 0.002, threads: 3, age: 28 * 3600, pids: 1_000...3_000)
        for role in ["checkpointer", "background writer", "walwriter", "autovacuum launcher", "logical replication launcher"] {
            add("postgres", path: pgBin, argv: ["postgres: \(role)"], ppid: pg, mb: role == "checkpointer" ? 61 : 18,
                cpu: role == "background writer" ? 0.004 : 0.001, threads: 2, age: 28 * 3600,
                disk: role == "checkpointer" ? 70_000 : 5_000, pids: 1_000...3_000)
        }
        let redis = add("redis-server", path: "/opt/homebrew/opt/redis/bin/redis-server", argv: ["/opt/homebrew/opt/redis/bin/redis-server *:6379"],
                        mb: 21, cpu: 0.006, threads: 4, age: 28 * 3600, pids: 1_000...3_000)
        add("com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
            mb: 184, cpu: 0.018, threads: 41, age: 30 * 3600, disk: 12_000, pids: 1_000...3_000)
        add("com.docker.virtualization", path: "/Applications/Docker.app/Contents/MacOS/com.docker.virtualization",
            argv: ["com.docker.virtualization", "--kernel", "/Applications/Docker.app/Contents/Resources/linuxkit/kernel"],
            mb: 3_260, cpu: 0.085, threads: 28, age: 30 * 3600, disk: 140_000, pids: 1_000...3_000)
        add("ssh-agent", path: "/usr/bin/ssh-agent", argv: ["/usr/bin/ssh-agent", "-l"], mb: 2, cpu: 0.0001, threads: 2, age: 2 * 86400, pids: 300...2_600)

        let tools: [(String, String, Double, Double)] = [
            ("esbuild", "/Users/demo/projects/webapp/node_modules/@esbuild/darwin-arm64/bin/esbuild", 64, 0.012),
            ("watchman", "/opt/homebrew/bin/watchman", 41, 0.004), ("gopls", "/Users/demo/go/bin/gopls", 212, 0.02),
            ("rust-analyzer", "/Users/demo/.cargo/bin/rust-analyzer", 486, 0.03), ("eslint_d", "/opt/homebrew/bin/node", 118, 0.006),
            ("prettierd", "/opt/homebrew/bin/node", 74, 0.002), ("tailwindcss", "/Users/demo/projects/webapp/node_modules/.bin/tailwindcss", 96, 0.01),
            ("sccache", "/opt/homebrew/bin/sccache", 28, 0.001), ("sync-helper", "/usr/local/libexec/sync-helper", 12, 0.0005),
            ("update-agent", "/Users/demo/Library/Application Support/Updater/update-agent", 22, 0.0008),
            ("crash-reporter", "/Users/demo/Library/Application Support/CrashReporter/crash-reporter", 17, 0.0004),
            ("backupd-helper", "/Users/demo/scripts/backupd-helper", 9, 0.0003), ("ollama", "/opt/homebrew/bin/ollama", 148, 0.004),
            ("mkcert-daemon", "/opt/homebrew/bin/mkcert", 14, 0.0002), ("direnv", "/opt/homebrew/bin/direnv", 6, 0.0001),
            ("fswatch", "/opt/homebrew/bin/fswatch", 8, 0.0006), ("tmux", "/opt/homebrew/bin/tmux", 15, 0.0008),
            ("syncthing", "/opt/homebrew/bin/syncthing", 124, 0.008),
        ]
        for (n, p, mb, cpu) in tools {
            add(n, path: p, mb: mb, cpu: cpu, threads: 6, age: 4 * 3600, disk: cpu * 200_000, pids: 4_000...30_000)
        }

        let controlCenter = list.first { $0.name == "ControlCenter" }!.pid
        func pidOf(_ name: String) -> pid_t { list.first { $0.name == name }!.pid }
        listeners = [
            DemoListener(port: 3000, pid: next, loopbackOnly: false),
            DemoListener(port: 5173, pid: vite, loopbackOnly: true),
            DemoListener(port: 5432, pid: pg, loopbackOnly: true),
            DemoListener(port: 6379, pid: redis, loopbackOnly: true),
            DemoListener(port: 7000, pid: controlCenter, loopbackOnly: false),
            DemoListener(port: 8000, pid: django, loopbackOnly: true),
            DemoListener(port: 5000, pid: controlCenter, loopbackOnly: false),
            DemoListener(port: 8080, pid: pidOf("com.docker.backend"), loopbackOnly: true),
            DemoListener(port: 9229, pid: tsserver, loopbackOnly: true),
            DemoListener(port: 11434, pid: pidOf("ollama"), loopbackOnly: true),
            DemoListener(port: 49152, pid: pidOf("rapportd"), loopbackOnly: false),
        ]
        return Built(processes: list, apps: apps, listeners: listeners,
                     byPID: Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0) }),
                     byID: Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) }))
    }

    // MARK: - Time series

    static func sampleTable(at t: Double) -> ProcessTable {
        prepare()
        var out: [ProcessID: ProcessSample] = [:]
        out.reserveCapacity(processes.count)
        for p in processes {
            let cpu = p.cpuNow(t)
            let disk = p.diskNow(t)
            out[p.id] = ProcessSample(
                id: p.id, ppid: p.ppid, uid: p.uid, name: p.name, path: p.restricted ? nil : p.path,
                threadCount: p.threads, isTranslated: false, cpu: cpu, memory: p.memoryNow(t),
                diskReadPerSec: disk * 0.7, diskWritePerSec: disk * 0.3,
                energy: p.restricted ? 0 : 100 * cpu + 0.05 * (40 + 500 * cpu), isRestricted: p.restricted)
        }
        return ProcessTable(processes: out)
    }

    /// Cores consumed by processes the app could not read (WindowServer, mds_stores, ...), so the machine total is
    /// higher than the sum of visible rows, as on a real Mac.
    private static let hiddenWave = DemoWave(phase: (1.1, 2.3, 0.4), rate: (0.06, 0.22, 0.6))

    static func cpuSample(at t: Double) -> CPUSample {
        prepare()
        let baseline = 0.22 + 0.045 * sin(0.0042 * t + 0.6) + 0.025 * sin(0.013 * t + 2.0) + 0.008 * sin(0.05 * t)
        let b = burst(t)
        let target = min(0.95, baseline + b * (0.93 - baseline))
        var raw: [Double] = []
        for i in 0..<coreCount {
            let efficiency = i < efficiencyCores
            let w = 1 + 0.35 * sin(0.03 * t + Double(i) * 1.7) + 0.15 * sin(0.09 * t + Double(i) * 0.9)
            raw.append(max(0.02, (efficiency ? 1.25 : 0.9) * w))
        }
        let mean = raw.reduce(0, +) / Double(raw.count)
        let scale = target / mean
        return CPUSample(cores: (0..<coreCount).map { i in
            let load = min(0.98, raw[i] * scale)
            return CPUCoreSample(index: i, kind: i < efficiencyCores ? .efficiency : .performance,
                                 user: load * 0.74, system: load * 0.26)
        })
    }

    static func memorySample(at t: Double) -> MemorySample {
        prepare()
        var app: UInt64 = 0
        for p in processes { app += p.memoryNow(t) }
        let gb = Double(1 << 30)
        let drift = 1 + 0.02 * sin(0.04 * t)
        return MemorySample(total: physicalMemory, app: app + UInt64(1.2 * gb * drift), wired: UInt64(2.4 * gb),
                            compressed: UInt64(1.3 * gb * drift), cached: UInt64(9.2 * gb), swapUsed: UInt64(0.6 * gb),
                            pressure: .normal)
    }

    static func gpuSample(at t: Double) -> GPUSample {
        let u = 0.11 + 0.07 * sin(0.11 * t + 0.5) + 0.05 * sin(0.4 * t) + 0.03 * sin(0.8 * t)
        return GPUSample(devices: [GPUDeviceSample(name: "Apple M3 Max", utilization: max(0.01, u))])
    }

    private static let diskWave = DemoWave(phase: (0.7, 2.0, 4.1), rate: (0.08, 0.2, 0.6))
    private static let diskWriteWave = DemoWave(phase: (3.1, 0.2, 1.4), rate: (0.09, 0.26, 0.7))
    private static let netDownWave = DemoWave(phase: (2.2, 5.1, 0.9), rate: (0.07, 0.19, 0.55))
    private static let netUpWave = DemoWave(phase: (4.4, 1.0, 3.3), rate: (0.08, 0.23, 0.65))

    static func diskSample(at t: Double) -> DiskSample {
        let r = diskWave.factor(t), w = diskWriteWave.factor(t)
        return DiskSample(readPerSec: 5.5e6 * r * r, writePerSec: 2.4e6 * w * w)
    }

    static func networkSample(at t: Double) -> NetworkSample {
        let d = netDownWave.factor(t), u = netUpWave.factor(t)
        return NetworkSample(interfaces: [NetworkInterfaceSample(name: "en0", receivedPerSec: 1.9e6 * d * d, sentPerSec: 3.2e5 * u * u)])
    }

    /// A complete system snapshot at wall-clock offset `t`. `instant` is its ContinuousClock position.
    static func snapshot(tick: UInt64, at t: Double, instant: ContinuousClock.Instant, withProcesses: Bool) -> SystemSnapshot {
        SystemSnapshot(tick: tick, instant: instant, cpu: cpuSample(at: t), memory: memorySample(at: t),
                       processes: withProcesses ? sampleTable(at: t) : nil, gpu: gpuSample(at: t),
                       disk: diskSample(at: t), network: networkSample(at: t))
    }
}
#endif
