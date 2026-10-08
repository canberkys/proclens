import Foundation
import ProcLensHelperProtocol
import Security

/// Accepts only clients signed with our identifier and our team (`setCodeSigningRequirement`, macOS 13+).
///
/// Team ID: `HelperConstants.teamIDPlaceholder` is replaced by `scripts/release.sh` with the Developer ID team
/// (`sed -i '' "s/TEAMID_PLACEHOLDER/$TEAM_ID/" ProcLensCore/Sources/ProcLensHelperProtocol/HelperConstants.swift`
/// before building, restored afterwards). If it is still the placeholder, the helper falls back to the team
/// of its own signature, which is the same team as the app in a Developer ID build. If neither is available
/// (ad-hoc / unsigned build) it refuses every connection: fail closed.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service = HelperService()
    private let requirement: String?

    override init() {
        requirement = Self.resolveRequirement()
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        newConnection.setCodeSigningRequirement(requirement)
        newConnection.exportedInterface = NSXPCInterface(with: (any ProcLensHelperXPC).self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }

    static func resolveRequirement() -> String? {
        let configured = HelperConstants.teamIDPlaceholder
        let team = HelperConstants.isValidTeamID(configured) ? configured : ownTeamID()
        guard let team, HelperConstants.isValidTeamID(team) else { return nil }
        return HelperConstants.clientRequirement(teamID: team)
    }

    /// Team identifier of this executable's own signature.
    static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
