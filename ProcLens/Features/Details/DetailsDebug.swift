#if DEBUG
import AppKit
import Foundation
import ProcLensCore
import SwiftUI

/// Debug-only hooks for the Details tab and the inspector (launch arguments):
///   -ProcLensDetailsTree 1            start the Details tab in tree mode
///   -ProcLensDetailsSnapshot <png>    host the Details tab in an own window and snapshot it (needs no main window)
///   -ProcLensDetailsSearch <text>     initial search text
///   -ProcLensInspectProcess <name>    (demo mode) open the inspector for the first readable demo process of that name
///   -ProcLensInspectSelf 1            open the inspector for ProcLens' own pid
///   -ProcLensInspectTab <0-4>         initial inspector tab (General, Environment, Files, Images, Signing)
///   -ProcLensInspectSnapshot <png>    snapshot the inspector window after a few seconds, then quit
///   -ProcLensSelfTestTreeKill 1       spawn `sh -c 'sleep 600 & sleep 600 & wait'`, end its tree, prove all gone
@MainActor
enum DetailsDebug {
    private static var started = false

    /// Called once from `ProcessActionCenter.init`; needs no main window.
    static func scheduleIfRequested(model: AppModel, actions: ProcessActionCenter) {
        let d = UserDefaults.standard
        if let path = d.string(forKey: "ProcLensDetailsSnapshot") {
            Task { @MainActor in
                let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 720),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                w.contentView = NSHostingView(rootView: DetailsView().environment(model).environment(actions)
                    .frame(width: 1100, height: 720))
                w.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(d.double(forKey: "ProcLensSnapshotDelay") > 0 ? d.double(forKey: "ProcLensSnapshotDelay") : 6))
                if let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
            return
        }
        Task { @MainActor in await runIfRequested(model: model, actions: actions) }
    }

    private static func runIfRequested(model: AppModel, actions: ProcessActionCenter) async {
        let d = UserDefaults.standard
        guard !started else { return }
        if let name = d.string(forKey: "ProcLensInspectProcess"), DemoMode.isActive {
            started = true
            for _ in 0..<100 where model.latest?.processes == nil { try? await Task.sleep(for: .milliseconds(100)) }
            guard let table = model.latest?.processes,
                  let p = table.processes.values.first(where: { $0.name == name && !$0.isRestricted }) else { return }
            InspectorWindows.shared.show(p, model: model, actions: actions)
            if let path = d.string(forKey: "ProcLensInspectSnapshot") {
                try? await Task.sleep(for: .seconds(4))
                InspectorWindows.shared.snapshot(of: p.id, to: path)
                NSApp.terminate(nil)
            }
        } else if d.bool(forKey: "ProcLensInspectSelf") {
            started = true
            for _ in 0..<100 where model.latest?.processes == nil { try? await Task.sleep(for: .milliseconds(100)) }
            guard let me = model.liveProcess(pid: getpid()) else { return }
            InspectorWindows.shared.show(me, model: model, actions: actions)
            if let path = d.string(forKey: "ProcLensInspectSnapshot") {
                try? await Task.sleep(for: .seconds(4))
                InspectorWindows.shared.snapshot(of: me.id, to: path)
                NSApp.terminate(nil)
            }
        } else if d.bool(forKey: "ProcLensSelfTestTreeKill") {
            started = true
            await treeKillTest(model: model, actions: actions)
        }
    }

    private static func log(_ s: String) {
        print("SELFTEST \(s)")
        fflush(stdout)
    }

    private static func treeKillTest(model: AppModel, actions: ProcessActionCenter) async {
        for _ in 0..<100 where model.latest?.processes == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "sleep 600 & sleep 600 & wait"]
        do { try sh.run() } catch { log("spawn failed: \(error)"); NSApp.terminate(nil); return }
        let rootPID = sh.processIdentifier
        var rootID: ProcessID?
        var tree: ProcessTree?
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            guard let table = model.latest?.processes, let root = table.processes.values.first(where: { $0.pid == rootPID })
            else { continue }
            let t = ProcessTree(table: table)
            if t.descendants(of: root.id).count >= 2 { rootID = root.id; tree = t; break }
        }
        guard let rootID, let tree else { log("tree never appeared in the table"); NSApp.terminate(nil); return }
        let pids = [rootID.pid] + tree.descendants(of: rootID).map(\.pid)
        log("spawned tree pids=\(pids)")
        actions.requestEndTree(rootID)
        log("pending: \(actions.pendingTree.map { "\($0.root.name)(\($0.root.pid)) descendants=\($0.descendantCount)" } ?? "nil") message=\(actions.message ?? "nil")")
        actions.confirmTree()
        try? await Task.sleep(for: .seconds(2))
        // Reap our direct child so it is not a zombie, then probe every pid.
        sh.waitUntilExit()
        let alive = pids.filter { kill($0, 0) == 0 }
        log("after tree kill: alive=\(alive) allGone=\(alive.isEmpty) message=\(actions.message ?? "nil")")
        NSApp.terminate(nil)
    }
}
#endif
