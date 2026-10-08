import Foundation
import Observation
import ProcLensCore
import Security

/// Registration state of the privileged helper plus the "is this a signed build" check.
@Observable @MainActor
final class HelperStatusModel {
    private(set) var status: HelperRegistrationStatus = .notRegistered
    private(set) var busy = false
    var errorMessage: String?
    let isSignedBuild: Bool

    @ObservationIgnored private var helper: HelperClient?

    init() { isSignedBuild = Self.hasTeamIdentifier() }

    func bind(_ helper: HelperClient) {
        self.helper = helper
        refresh()
    }

    func refresh() {
        guard let helper else { return }
        status = helper.registrationStatus()
    }

    var isEnabled: Bool { status == .enabled }

    var statusTitle: String {
        switch status {
        case .notRegistered: "Not installed"
        case .requiresApproval: "Requires approval"
        case .enabled: "Enabled"
        // SMAppService reports .notFound for a daemon that was never registered, so treat it as "not installed".
        case .notFound: "Not installed"
        }
    }

    var canInstall: Bool { isSignedBuild && !busy && (status == .notRegistered || status == .notFound) }
    var canUninstall: Bool { !busy && (status == .enabled || status == .requiresApproval) }

    func install() {
        guard let helper, canInstall else { return }
        busy = true; errorMessage = nil
        Task {
            do { try await helper.register() } catch { errorMessage = error.localizedDescription }
            busy = false
            refresh()
        }
    }

    func uninstall() {
        guard let helper, canUninstall else { return }
        busy = true; errorMessage = nil
        Task {
            do { try await helper.unregister() } catch { errorMessage = error.localizedDescription }
            busy = false
            refresh()
        }
    }

    func openApprovalSettings() { helper?.openApprovalSettings() }

    /// True when the running app is signed with a Team ID (Developer ID / development signing).
    nonisolated static func hasTeamIdentifier() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return (dict[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false
    }
}
