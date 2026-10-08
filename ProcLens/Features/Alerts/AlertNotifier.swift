import AppKit
import Foundation
import OSLog
import ProcLensCore
import UserNotifications

/// Turns `AlertEngine` events into user notifications. Started once at app launch via
/// `AlertNotifier.shared.start(services:)`. The engine already enforces per-rule cooldowns, so every event
/// received here is posted (one notification per rule episode).
@MainActor
final class AlertNotifier {
    static let shared = AlertNotifier()

    private static let categoryID = "com.canberkki.ProcLens.alert"
    private static let showActionID = "com.canberkki.ProcLens.alert.show"
    private let log = Logger(subsystem: "com.canberkki.ProcLens", category: "alerts")
    private let delegate = Delegate()
    private var services: AppServices?
    private var eventTask: Task<Void, Never>?
    private var authorizationRequested = false

    private var center: UNUserNotificationCenter? {
        // `UNUserNotificationCenter.current()` traps when the process is not an app bundle (tests, CLI hosts).
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    private init() {}

    /// Idempotent. Registers the notification category, starts consuming events and, if a rule is already
    /// enabled, asks for notification authorization.
    func start(services: AppServices) {
        guard eventTask == nil else { return }
        self.services = services
        if let center {
            center.delegate = delegate
            let show = UNNotificationAction(identifier: Self.showActionID, title: "Show in ProcLens", options: [.foreground])
            center.setNotificationCategories([
                UNNotificationCategory(identifier: Self.categoryID, actions: [show], intentIdentifiers: [])
            ])
        }
        let events = services.alerts.events
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        Task { [weak self] in
            let rules = await services.alerts.currentRules()
            self?.rulesChanged(rules)
        }
    }

    /// Call after rules were saved. Authorization is requested lazily, only once a rule is enabled.
    func rulesChanged(_ rules: [AlertRule]) {
        if rules.contains(where: \.isEnabled) { requestAuthorizationIfNeeded() }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested, let center else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ProcLensAlertSelfTest") { return }
        #endif
        authorizationRequested = true
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func handle(_ event: AlertEvent) {
        let text = Self.body(for: event)
        log.info("alert fired: \(event.ruleName, privacy: .public): \(text, privacy: .public)")
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ProcLensAlertSelfTest") {
            print("ALERTEVENT rule=\(event.ruleName) body=\(text)")
            fflush(stdout)
        }
        #endif
        guard let center else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = event.ruleName.isEmpty ? "ProcLens alert" : event.ruleName
        content.body = text
        content.categoryIdentifier = Self.categoryID
        content.sound = .default
        content.threadIdentifier = event.ruleID.uuidString
        // Same rule + process replaces the previous banner instead of stacking.
        let key = "\(event.ruleID.uuidString)-\(event.processID?.description ?? "system")"
        center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil)) { _ in }
    }

    /// "node is using 92% CPU for 60 s", "System CPU is at 91% for 60 s".
    static func body(for e: AlertEvent) -> String {
        let secs = Int(e.sustainedSeconds.rounded())
        let v = Int(e.value.rounded())
        let amount: String
        switch e.metric {
        case .cpu: amount = e.processName == nil ? "\(v)% CPU" : "\(v)% of a CPU core"
        case .memory: amount = v >= 1024 ? String(format: "%.1f GB memory", e.value / 1024) : "\(v) MB memory"
        case .energy: amount = "energy score \(v)"
        }
        let duration = secs > 0 ? " for \(secs) s" : ""
        if let name = e.processName { return "\(name) is using \(amount)\(duration)" }
        return "System \(amount) sustained\(duration)"
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            await MainActor.run { WindowOpener.showMainWindow() }
        }
    }
}
