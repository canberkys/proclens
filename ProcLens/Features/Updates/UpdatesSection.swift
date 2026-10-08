import SwiftUI

/// Settings → Updates (Sparkle-backed).
struct UpdatesSection: View {
    @Bindable private var updater = UpdaterController.shared

    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
            Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
                .disabled(!updater.automaticallyChecksForUpdates)
            Text("Once a day at most, one request to the GitHub-hosted update feed. Updates are signed and verified before they install. Nothing else leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Last checked") {
                Text(updater.lastUpdateCheckDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    .foregroundStyle(.secondary)
            }
            Button("Check Now") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
