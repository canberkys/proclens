import Foundation
import ProcLensCore

/// A published GitHub release, reduced to what the update window shows.
struct ReleaseInfo: Sendable, Equatable {
    let tag: String
    let url: URL
    let notes: String
    let published: Date?
}

enum UpdateOutcome: Sendable, Equatable {
    case upToDate(current: String)
    case available(ReleaseInfo)
    case noReleases
    case failed(String)
}

/// Opt-in, dependency-free update check against the GitHub releases API. This is the only code in ProcLens
/// that talks to the network, and it never runs unless the user asks (menu / Settings) or enabled the
/// automatic daily check. No auto-install: "Download" opens the release page in the browser.
@MainActor @Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/canberkys/proclens/releases/latest")!
    static let autoKey = "updateAutoCheck"
    static let lastCheckedKey = "updateLastChecked"
    static let skippedKey = "updateSkippedVersion"
    static let interval: TimeInterval = 24 * 3600

    private(set) var isChecking = false
    /// Result of the latest check in this session (nil before any).
    private(set) var outcome: UpdateOutcome?
    private(set) var lastChecked: Date?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: @Sendable () async -> UpdateOutcome

    init(defaults: UserDefaults = .standard, fetch: (@Sendable () async -> UpdateOutcome)? = nil) {
        self.defaults = defaults
        self.fetch = fetch ?? { await UpdateChecker.fetchLatest() }
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
    }

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var automaticEnabled: Bool {
        get { defaults.bool(forKey: Self.autoKey) }
        set {
            defaults.set(newValue, forKey: Self.autoKey)
            if newValue { startAutomatic() } else { stopAutomatic() }
        }
    }

    var skippedVersion: String? { defaults.string(forKey: Self.skippedKey) }

    func skip(_ release: ReleaseInfo) {
        defaults.set(release.tag, forKey: Self.skippedKey)
    }

    /// An available release that the user has not skipped (what Settings advertises).
    var pendingRelease: ReleaseInfo? {
        guard case .available(let r) = outcome, r.tag != skippedVersion else { return nil }
        return r
    }

    /// Explicit user action: always runs, ignores the skipped version.
    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        let result = await fetch()
        isChecking = false
        outcome = result
        switch result {
        case .failed: break  // a failed check does not count as "checked"
        default:
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Self.lastCheckedKey)
        }
    }

    // MARK: - Automatic (off by default)

    /// Call once at launch. Does nothing unless the user turned automatic checks on.
    func startAutomatic() {
        guard automaticEnabled else { return }
        checkIfDue()
        timer?.invalidate()
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopAutomatic() {
        timer?.invalidate()
        timer = nil
    }

    private func checkIfDue() {
        guard automaticEnabled else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < Self.interval { return }
        Task { await checkNow() }
    }

    // MARK: - Network

    nonisolated static func fetchLatest(current: String = currentVersion,
                                        session: URLSession = .shared) async -> UpdateOutcome {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 10)
        request.setValue("ProcLens/\(current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return interpret(status: status, data: data, current: current)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotFindHost, .cannotConnectToHost:
                return .failed("Could not reach GitHub. Check your internet connection and try again.")
            case .timedOut:
                return .failed("GitHub did not answer in time. Try again later.")
            default:
                return .failed("The update check failed (\(error.localizedDescription)).")
            }
        } catch {
            return .failed("The update check failed (\(error.localizedDescription)).")
        }
    }

    /// Pure and testable: maps an HTTP status and body to an outcome.
    nonisolated static func interpret(status: Int, data: Data, current: String) -> UpdateOutcome {
        switch status {
        case 404:
            return .noReleases
        case 200:
            struct Payload: Decodable {
                let tag_name: String
                let html_url: URL
                let body: String?
                let published_at: String?
            }
            guard let p = try? JSONDecoder().decode(Payload.self, from: data) else {
                return .failed("GitHub sent a response ProcLens could not read.")
            }
            guard SemanticVersion(p.tag_name) != nil else {
                return .failed("The latest release has an unexpected version tag (\(p.tag_name)).")
            }
            if SemanticVersion.isNewer(p.tag_name, than: current) {
                let date = p.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
                return .available(ReleaseInfo(tag: p.tag_name, url: p.html_url, notes: p.body ?? "", published: date))
            }
            return .upToDate(current: current)
        case 403, 429:
            return .failed("GitHub is limiting requests right now. Try again in a little while.")
        default:
            return .failed("GitHub answered with status \(status).")
        }
    }
}
