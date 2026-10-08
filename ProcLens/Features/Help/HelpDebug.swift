#if DEBUG
import AppKit
import SwiftUI

/// Debug-only hooks (launch arguments), all render offscreen and quit:
///   -ProcLensHelpSnapshot <png> [-ProcLensHelpTopic <id>]   the Help window
///   -ProcLensNotesSnapshot <png>                             the Release Notes window
///   -ProcLensUpdateSnapshot <png> [-ProcLensUpdateStub available|uptodate|none|error]   the update window with a stubbed result
///   -ProcLensUpdateCheckLog 1                                runs the real check once, prints `UPDATECHECK <outcome>` and quits
enum HelpDebug {
    @MainActor
    static func scheduleIfRequested() {
        let d = UserDefaults.standard
        if let path = d.string(forKey: "ProcLensHelpSnapshot") {
            if let topic = d.string(forKey: "ProcLensHelpTopic") { d.set(topic, forKey: HelpNavigation.topicKey) }
            render(HelpView(), size: CGSize(width: 860, height: 600), to: path)
        } else if let path = d.string(forKey: "ProcLensNotesSnapshot") {
            render(ReleaseNotesView(), size: CGSize(width: 560, height: 480), to: path)
        } else if let path = d.string(forKey: "ProcLensUpdateSnapshot") {
            let release = ReleaseInfo(tag: "v0.2.0", url: URL(string: "https://github.com/canberkys/proclens/releases/tag/v0.2.0")!,
                                      notes: "## What's new\n- Menu bar and Help\n- Update check\n- Faster Details tree", published: Date())
            let outcome: UpdateOutcome = switch d.string(forKey: "ProcLensUpdateStub") ?? "available" {
            case "uptodate": .upToDate(current: UpdateChecker.currentVersion)
            case "none": .noReleases
            case "error": .failed("Could not reach GitHub. Check your internet connection and try again.")
            default: .available(release)
            }
            render(UpdateWindow(stubbed: outcome), size: CGSize(width: 400, height: 420), to: path)
        } else if d.bool(forKey: "ProcLensUpdateCheckLog") {
            Task { @MainActor in
                let checker = UpdateChecker(defaults: UserDefaults(suiteName: "ProcLensUpdateDebug")!)
                await checker.checkNow()
                print("UPDATECHECK \(String(describing: checker.outcome)) lastChecked=\(String(describing: checker.lastChecked))")
                fflush(stdout)
                exit(0)
            }
        }
    }

    @MainActor
    private static func render<V: View>(_ view: V, size: CGSize, to path: String) {
        let host = NSHostingView(rootView: view.frame(width: size.width).fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: size.height, alignment: .top).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = host
        window.alphaValue = 0.01
        window.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(2) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
#endif
