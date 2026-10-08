#if DEBUG
import AppKit
import ProcLensCore
import SwiftUI

/// Debug-only launch arguments, both render/run offscreen and quit:
///   -ProcLensFeedbackSnapshot <png>   the Report an Issue form (filled in, diagnostics expanded)
///   -ProcLensFeedbackStub <url>       sends one report to a local stub instead of the real relay and prints the outcome
enum FeedbackDebug {
    @MainActor
    static func scheduleIfRequested(model: AppModel) {
        let d = UserDefaults.standard
        if let stub = d.string(forKey: "ProcLensFeedbackStub"), let url = URL(string: stub) {
            Task {
                let client = FeedbackClient(relayURL: url)
                let diag = FeedbackDiagnostics.text(interval: model.interval, helper: model.services.helper.registrationStatus())
                do {
                    let c = try await client.send(kind: .feature, title: "Stub \"title\" é", description: "Line 1\nLine 2", diagnostics: diag)
                    print("FEEDBACK-STUB OK number=\(c.number.map(String.init) ?? "nil") url=\(c.url?.absoluteString ?? "nil")")
                } catch {
                    print("FEEDBACK-STUB FAIL \((error as? FeedbackClient.Failure)?.message ?? "\(error)")")
                }
                exit(0)
            }
        } else if let path = d.string(forKey: "ProcLensFeedbackSnapshot") {
            let view = FeedbackView(previewTitle: "Quick panel flickers when the Mac wakes",
                                    previewDetails: "After waking from sleep the menu bar panel shows stale numbers for a few seconds.",
                                    expanded: true)
                .environment(model)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 528, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.alphaValue = 0.01
            window.orderFrontRegardless()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                host.layoutSubtreeIfNeeded()
                let size = host.fittingSize
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(2) }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                exit(0)
            }
        }
    }
}
#endif
