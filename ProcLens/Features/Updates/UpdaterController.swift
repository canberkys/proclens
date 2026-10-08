import Foundation
import Observation
import Sparkle

/// Thin observable wrapper around Sparkle 2's standard updater (in-app install, EdDSA-verified, appcast on GitHub).
/// Sparkle runs its own daily schedule from `SUEnableAutomaticChecks` / `SUScheduledCheckInterval` in Info.plist
/// and shows its own native sheets. Nothing here talks to the network.
@MainActor @Observable
final class UpdaterController {
    static let shared = UpdaterController()

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private(set) var canCheckForUpdates = false
    private(set) var lastUpdateCheckDate: Date?

    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        didSet {
            guard automaticallyDownloadsUpdates != controller.updater.automaticallyDownloadsUpdates else { return }
            controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate

        observations.append(updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheckForUpdates = value }
        })
        observations.append(updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.lastUpdateCheckDate = self?.controller.updater.lastUpdateCheckDate }
        })
    }

    /// Explicit user action (app menu, Settings): Sparkle shows its own progress / result UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
