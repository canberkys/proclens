import AppKit
import SwiftUI

/// The "Check for Updates…" window: opens, runs the check, shows the result.
struct UpdateWindow: View {
    var checker: UpdateChecker = .shared
    /// Preview/testing: show this outcome instead of checking.
    var stubbed: UpdateOutcome?
    @Environment(\.dismiss) private var dismiss

    private var outcome: UpdateOutcome? { stubbed ?? checker.outcome }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
            content
        }
        .padding(24)
        .frame(width: 400)
        .task {
            if stubbed == nil { await checker.checkNow() }
        }
    }

    @ViewBuilder private var content: some View {
        if stubbed == nil && (checker.isChecking || outcome == nil) {
            ProgressView("Checking for updates…")
        } else if let outcome {
            switch outcome {
            case .upToDate(let current):
                message("ProcLens is up to date", "You have version \(current), the latest release.")
            case .noReleases:
                message("No releases published yet", "There is nothing to download at the moment. Check back later.")
            case .failed(let text):
                message("Could not check for updates", text)
                HStack {
                    Button("Try Again") { Task { await checker.checkNow() } }
                    Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            case .available(let release):
                available(release)
            }
            if !isActionable(outcome) {
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func isActionable(_ o: UpdateOutcome) -> Bool {
        switch o {
        case .available, .failed: true
        default: false
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func available(_ release: ReleaseInfo) -> some View {
        VStack(spacing: 12) {
            message("ProcLens \(release.tag) is available",
                    "You have version \(UpdateChecker.currentVersion)." + (release.published.map { " Published \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""))
            if !release.notes.isEmpty {
                ScrollView {
                    Text(Self.rendered(Self.excerpt(release.notes)))
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 140)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button("Skip This Version") { checker.skip(release); dismiss() }
                Button("Remind Me Later") { dismiss() }
                Button("Download") { NSWorkspace.shared.open(release.url); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Installed with Homebrew? Update with brew upgrade.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// GitHub release notes are Markdown: headings become bold lines, list items get bullets,
    /// inline **bold**/`code`/links are kept. Anything unparseable falls back to plain text.
    static func rendered(_ markdown: String) -> AttributedString {
        var out = AttributedString()
        for (i, raw) in markdown.components(separatedBy: .newlines).enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            var heading = false
            if line.hasPrefix("#") { line = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces); heading = true }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "•  " + line.dropFirst(2) }
            var part = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(line)
            if heading { part.font = .callout.bold() }
            if i > 0 { out += AttributedString("\n") }
            out += part
        }
        return out
    }

    /// First part of the release notes (trimmed).
    static func excerpt(_ notes: String, limit: Int = 900) -> String {
        let t = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= limit ? t : String(t.prefix(limit)) + "…"
    }
}

/// Settings → Updates.
struct UpdatesSection: View {
    @Environment(\.openWindow) private var openWindow
    private var checker: UpdateChecker { .shared }

    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { checker.automaticEnabled }, set: { checker.automaticEnabled = $0 }))
            Text("Once a day at most, a single request to GitHub. On by default; nothing else leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Last checked") {
                Text(checker.lastChecked.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    .foregroundStyle(.secondary)
            }
            if let r = checker.pendingRelease {
                LabeledContent("Available") { Text(r.tag).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Check Now") {
                    openWindow(id: "updates")
                    NSApp.activate(ignoringOtherApps: true)
                }
                if checker.isChecking { ProgressView().controlSize(.small) }
            }
        }
    }
}
