import AppKit
import SwiftUI
import ProcLensCore

/// Presentation helpers shared by the Startup and Services tabs.
enum LaunchdPresentation {
    static let helperMissingMessage = "Requires the ProcLens helper. Install it in Settings > Helper (signed builds only)."

    /// Plain-English name when the label or program matches `DaemonNameMap`, else the label.
    static func displayName(for item: LaunchdItem) -> String {
        let map = DaemonNameMap.shared
        var candidates = [item.label]
        if item.isInterpreterLaunch {
            // Never name a script job after its interpreter ("Bash Shell", "Python 3 Interpreter").
            if !item.effectiveProgram.hasPrefix("inline") {
                let base = (item.effectiveProgram as NSString).lastPathComponent
                candidates.append(base)
                candidates.append((base as NSString).deletingPathExtension)
            }
        } else {
            if !item.program.isEmpty { candidates.append((item.program as NSString).lastPathComponent) }
            if let last = item.label.split(separator: ".").last { candidates.append(String(last)) }
        }
        for candidate in candidates {
            if let entry = map.entry(for: candidate) { return entry.title }
        }
        return item.label
    }

    static func typeLabel(_ scope: LaunchdScope) -> String {
        switch scope {
        case .userAgent: "User agent"
        case .globalAgent, .appleAgent: "Global agent"
        case .globalDaemon, .appleDaemon: "Daemon"
        }
    }

    static func vendor(for item: LaunchdItem) -> String { item.vendor ?? "Other" }

    /// Throws a clear error before calling Core when a system-domain change needs a missing helper.
    static func preflight(_ item: LaunchdItem, helper: HelperClient) throws {
        if !item.isEditable { throw LaunchdError.readOnlyItem(item.label) }
        if item.domain.isSystem, helper.registrationStatus() != .enabled {
            throw LaunchdError.invalidArgument(helperMissingMessage)
        }
    }

    @MainActor static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// App icon for a job: the owning .app bundle when it can be resolved, else a generic executable icon.
@MainActor
enum LaunchdIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: LaunchdItem) -> NSImage {
        let key = item.id
        if let hit = cache[key] { return hit }
        let image = resolve(item)
        cache[key] = image
        return image
    }

    private static func resolve(_ item: LaunchdItem) -> NSImage {
        let workspace = NSWorkspace.shared
        for path in [item.program, item.bundleProgram ?? ""] where !path.isEmpty {
            if let range = path.range(of: ".app/") ?? path.range(of: ".app", options: [.backwards, .anchored]) {
                let app = String(path[..<range.upperBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let appPath = "/" + app
                if FileManager.default.fileExists(atPath: appPath) { return sized(workspace.icon(forFile: appPath)) }
            }
        }
        for id in item.associatedBundleIdentifiers {
            if let url = workspace.urlForApplication(withBundleIdentifier: id) { return sized(workspace.icon(forFile: url.path)) }
        }
        return sized(workspace.icon(for: .unixExecutable))
    }

    private static func sized(_ image: NSImage) -> NSImage {
        let copy = (image.copy() as? NSImage) ?? image
        copy.size = NSSize(width: 20, height: 20)
        return copy
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Lock shown on system-domain items.
struct LockBadge: View {
    let item: LaunchdItem

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help(item.isApple ? "Part of macOS: read-only" : "System domain: changes need the ProcLens helper")
            .accessibilityLabel(item.isApple ? "Read-only system item" : "System domain, needs helper")
    }
}

/// Shown when system-domain items are listed but the helper is not enabled.
struct HelperBanner: View {
    let helperEnabled: Bool

    var body: some View {
        if !helperEnabled {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("Items with a lock are in the system domain. Changing them needs the ProcLens helper.")
                    .font(.callout)
                Spacer()
                SettingsLink { Text("Helper settings") }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1))
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }
}

/// Read-only viewer for a plist, pretty-printed as XML.
struct PlistViewerSheet: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = "Loading…"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text((path as NSString).lastPathComponent).font(.headline)
                Spacer()
                Button("Copy") { LaunchdPresentation.copy(text) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(16)
        .frame(width: 640, height: 480)
        .task {
            text = await Task.detached { Self.render(path) }.value
        }
    }

    nonisolated static func render(_ path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "Could not read \(path)." }
        do {
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let xml = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            return String(decoding: xml, as: UTF8.self)
        } catch {
            return "Not a valid property list: \(error.localizedDescription)\n\n" + String(decoding: data.prefix(20_000), as: UTF8.self)
        }
    }
}
