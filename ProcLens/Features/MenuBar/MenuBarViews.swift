import SwiftUI
import AppKit
import ProcLensCore

/// Template NSImage with recent CPU history as bars (+ optional percentage).
@MainActor
enum MenuBarGraph {
    static let barCount = 24

    static func image(cpu: [Double], showPercent: Bool) -> NSImage {
        let barW: CGFloat = 2, gap: CGFloat = 1, h: CGFloat = 16
        let graphW = CGFloat(barCount) * (barW + gap)
        let text = showPercent ? Format.percent(cpu.last ?? 0) : ""
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textW = showPercent ? ceil((text as NSString).size(withAttributes: attrs).width) + 4 : 0
        let size = NSSize(width: graphW + textW, height: h)
        let samples = Array(cpu.suffix(barCount))
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            let pad = barCount - samples.count
            for (i, v) in samples.enumerated() {
                let bh = max(1, CGFloat(min(1, max(0, v))) * h)
                NSRect(x: CGFloat(pad + i) * (barW + gap), y: 0, width: barW, height: bh).fill()
            }
            if showPercent {
                let s = (text as NSString).size(withAttributes: attrs)
                (text as NSString).draw(at: NSPoint(x: graphW + 4, y: (h - s.height) / 2), withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct MenuBarLabel: View {
    let model: AppModel
    @AppStorage("menuBarShowsPercent") private var showPercent = true

    var body: some View {
        let values = model.history.suffix(MenuBarGraph.barCount).map { $0.cpu?.total ?? 0 }
        Image(nsImage: MenuBarGraph.image(cpu: values, showPercent: showPercent))
            .accessibilityLabel("ProcLens CPU \(Format.percent(values.last ?? 0))")
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let cpu = model.latest?.cpu?.total
        let mem = model.latest?.memory.map { Double($0.used) / Double(max(1, $0.total)) }
        Text("CPU: \(cpu.map(Format.percent) ?? "–")")
        Text("Memory: \(mem.map(Format.percent) ?? "–")")
        Divider()
        Button("Open ProcLens") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("menuBarShowsPercent") private var showPercent = true

    var body: some View {
        Form {
            Picker("Sampling interval", selection: Binding(get: { model.interval }, set: { model.setInterval($0) })) {
                ForEach(SamplingInterval.allCases, id: \.self) { i in
                    Text("\(i.rawValue.formatted()) s").tag(i)
                }
            }
            Toggle("Show CPU percentage in menu bar", isOn: $showPercent)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
