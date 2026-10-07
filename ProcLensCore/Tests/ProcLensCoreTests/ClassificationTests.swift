import Foundation
import Testing
import Darwin
@testable import ProcLensCore

struct ClassificationTests {
    private func sample(pid: pid_t, ppid: pid_t = 1, uid: uid_t = 501, name: String = "proc",
                        path: String? = nil) -> ProcessSample {
        ProcessSample(id: ProcessID(pid: pid, startTime: 1_000), ppid: ppid, uid: uid, name: name,
                      path: path, threadCount: 1, isTranslated: false, cpu: 0, memory: 0,
                      diskReadPerSec: 0, diskWritePerSec: 0, energy: 0, isRestricted: false)
    }

    private func runningApp(_ pid: pid_t, regular: Bool = true) -> RunningAppInfo {
        RunningAppInfo(pid: pid, bundleIdentifier: nil, localizedName: nil, isRegular: regular)
    }

    private let names = DaemonNameMap(entries: [
        .init(name: "sysdaemon", title: "System Daemon", origin: "system", section: "Core"),
        .init(name: "userhelper", title: "User Helper", origin: "user", section: "User"),
    ])

    // MARK: ProcessGrouper rules

    @Test func regularAppGroupsAsApps() {
        let grouper = ProcessGrouper(apps: [runningApp(100)], names: names)
        #expect(grouper.group(for: sample(pid: 100, name: "Safari")) == .apps)
    }

    @Test func nonRegularAppIsNotApps() {
        let grouper = ProcessGrouper(apps: [runningApp(100, regular: false)], names: names)
        #expect(grouper.group(for: sample(pid: 100, name: "agent", path: "/Applications/Agent.app/Contents/MacOS/agent")) == .background)
    }

    @Test func rootAndRoleAccountsAreSystem() {
        let grouper = ProcessGrouper(apps: [], names: names)
        #expect(grouper.group(for: sample(pid: 5, uid: 0, name: "anything")) == .system)
        #expect(grouper.group(for: sample(pid: 88, uid: 88, name: "_windowserver")) == .system)
        #expect(grouper.group(for: sample(pid: 6, uid: 499, name: "x")) == .system)
        #expect(grouper.group(for: sample(pid: 7, uid: 500, name: "x")) == .background)
    }

    @Test func systemPathsAreSystem() {
        let grouper = ProcessGrouper(apps: [], names: names)
        #expect(grouper.group(for: sample(pid: 10, name: "a", path: "/System/Library/CoreServices/Finder")) == .system)
        #expect(grouper.group(for: sample(pid: 11, name: "b", path: "/usr/libexec/trustd")) == .system)
        #expect(grouper.group(for: sample(pid: 12, name: "c", path: "/usr/sbin/cron")) == .system)
        #expect(grouper.group(for: sample(pid: 13, name: "d", path: "/sbin/launchd")) == .system)
        #expect(grouper.group(for: sample(pid: 14, name: "e", path: "/usr/local/bin/tool")) == .background)
    }

    @Test func systemOriginNameIsSystem() {
        let grouper = ProcessGrouper(apps: [], names: names)
        #expect(grouper.group(for: sample(pid: 20, name: "sysdaemon", path: "/opt/x/sysdaemon")) == .system)
    }

    @Test func otherProcessesAreBackground() {
        let grouper = ProcessGrouper(apps: [], names: names)
        #expect(grouper.group(for: sample(pid: 30, name: "userhelper", path: "/Applications/X.app/helper")) == .background)
    }

    @Test func appRuleWinsOverSystemRules() {
        // A regular app running as root is still an app (rule a precedes rule b).
        let grouper = ProcessGrouper(apps: [runningApp(40)], names: names)
        #expect(grouper.group(for: sample(pid: 40, uid: 0, name: "App", path: "/System/Applications/App")) == .apps)
    }

    // MARK: groupApps

    @Test func childMapsToApp() {
        let grouper = ProcessGrouper(apps: [runningApp(100)], names: names)
        let appProc = sample(pid: 100, ppid: 1, name: "Safari")
        let child = sample(pid: 101, ppid: 100, name: "Safari Web Content")
        let owners = grouper.groupApps([appProc, child])
        #expect(owners[child.id] == appProc.id)
        #expect(owners[appProc.id] == nil)
    }

    @Test func grandchildMapsToApp() {
        let grouper = ProcessGrouper(apps: [runningApp(100)], names: names)
        let appProc = sample(pid: 100, ppid: 1, name: "Safari")
        let child = sample(pid: 101, ppid: 100, name: "helper")
        let grandchild = sample(pid: 102, ppid: 101, name: "renderer")
        let owners = grouper.groupApps([appProc, child, grandchild])
        #expect(owners[grandchild.id] == appProc.id)
        #expect(owners[child.id] == appProc.id)
    }

    @Test func nearestAppAncestorWins() {
        let grouper = ProcessGrouper(apps: [runningApp(100), runningApp(200)], names: names)
        let outer = sample(pid: 100, ppid: 1, name: "Outer")
        let inner = sample(pid: 200, ppid: 100, name: "Inner")
        let leaf = sample(pid: 300, ppid: 200, name: "leaf")
        let owners = grouper.groupApps([outer, inner, leaf])
        #expect(owners[leaf.id] == inner.id)
        #expect(owners[inner.id] == outer.id)
    }

    @Test func cycleIsGuarded() {
        let grouper = ProcessGrouper(apps: [], names: names)
        // 10 and 11 are each other's parent; neither is an app.
        let a = sample(pid: 10, ppid: 11, name: "a")
        let b = sample(pid: 11, ppid: 10, name: "b")
        let owners = grouper.groupApps([a, b])
        #expect(owners.isEmpty)
    }

    @Test func selfParentCycleIsGuarded() {
        let grouper = ProcessGrouper(apps: [runningApp(100)], names: names)
        let selfLoop = sample(pid: 50, ppid: 50, name: "loop")
        #expect(grouper.groupApps([selfLoop]).isEmpty)
    }

    @Test func orphanOmitted() {
        let grouper = ProcessGrouper(apps: [runningApp(100)], names: names)
        let appProc = sample(pid: 100, ppid: 1, name: "Safari")
        // Parent 999 is not in the table; this process has no app ancestor.
        let orphan = sample(pid: 60, ppid: 999, name: "orphan")
        // Parent 1 (launchd) is not an app either.
        let daemon = sample(pid: 61, ppid: 1, name: "daemon")
        let owners = grouper.groupApps([appProc, orphan, daemon])
        #expect(owners[orphan.id] == nil)
        #expect(owners[daemon.id] == nil)
        #expect(owners.count == 0)
    }

    @Test func depthLimitStopsWalk() {
        let grouper = ProcessGrouper(apps: [runningApp(1000)], names: names)
        // Chain: 1000 (app) <- 1001 <- ... <- 1040. Depth 40 exceeds the 32-step limit.
        var processes = [sample(pid: 1000, ppid: 1, name: "App")]
        for pid in pid_t(1001)...pid_t(1040) {
            processes.append(sample(pid: pid, ppid: pid - 1, name: "p\(pid)"))
        }
        let owners = grouper.groupApps(processes)
        #expect(owners[ProcessID(pid: 1032, startTime: 1_000)] == ProcessID(pid: 1000, startTime: 1_000))
        #expect(owners[ProcessID(pid: 1040, startTime: 1_000)] == nil)
    }

    // MARK: DaemonNameMap

    @Test func sharedMapLoadsBundledEntries() {
        #expect(DaemonNameMap.shared.entry(for: "mds_stores")?.origin == "system")
        #expect(DaemonNameMap.shared.entry(for: "WINDOWSERVER")?.name == "WindowServer")
        #expect(DaemonNameMap.shared.isSystemOrigin("WindowServer"))
        #expect(DaemonNameMap.shared.isSystemOrigin("definitely-not-a-daemon") == false)
    }

    @Test func bundledFileHasAtLeast400Entries() throws {
        let url = try #require(DaemonNameMap.resourceURL)
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require(root["entries"] as? [[String: Any]])
        #expect(entries.count >= 400)
    }

    @Test func exactMatchBeatsCaseInsensitive() {
        let map = DaemonNameMap(entries: [
            .init(name: "Foo", title: "Upper", origin: "user", section: "s"),
            .init(name: "foo", title: "Lower", origin: "system", section: "s"),
        ])
        #expect(map.entry(for: "foo")?.title == "Lower")
        #expect(map.entry(for: "Foo")?.title == "Upper")
        #expect(map.entry(for: "FOO")?.title == "Upper")  // first case-insensitive hit
        #expect(map.entry(for: "bar") == nil)
    }

    // MARK: ProtectionPolicy

    @Test func pidZeroAndOneRefused() {
        let policy = ProtectionPolicy()
        #expect(policy.verdict(for: sample(pid: 0, name: "kernel_task"), ownPID: 999)
                == .refused(reason: "kernel_task is critical to macOS and cannot be ended."))
        #expect(policy.verdict(for: sample(pid: 1, name: "launchd"), ownPID: 999)
                == .refused(reason: "launchd is critical to macOS and cannot be ended."))
    }

    @Test func criticalNameRefusedEvenWithOtherPID() {
        let policy = ProtectionPolicy()
        #expect(policy.verdict(for: sample(pid: 321, name: "WindowServer"), ownPID: 999)
                == .refused(reason: "WindowServer is critical to macOS and cannot be ended."))
        #expect(policy.verdict(for: sample(pid: 322, name: "trustd"), ownPID: 999)
                == .refused(reason: "trustd is critical to macOS and cannot be ended."))
    }

    @Test func ownPIDRefused() {
        let policy = ProtectionPolicy()
        #expect(policy.verdict(for: sample(pid: 4242, name: "ProcLens"), ownPID: 4242)
                == .refused(reason: "ProcLens can't end itself; use Quit."))
    }

    @Test func ordinaryProcessNeedsConfirmation() {
        let policy = ProtectionPolicy()
        #expect(policy.verdict(for: sample(pid: 500, name: "Safari"), ownPID: 999) == .needsConfirmation)
    }

    @Test func defaultOwnPIDIsCurrentProcess() {
        let policy = ProtectionPolicy()
        #expect(policy.verdict(for: sample(pid: getpid(), name: "ProcLensTests")) == .refused(reason: "ProcLens can't end itself; use Quit."))
    }
}
