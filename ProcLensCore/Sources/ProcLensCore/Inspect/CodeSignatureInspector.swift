import Darwin
import Foundation
import Security

/// Signing origin of a process' executable, as shown in the Details tab.
public enum CodeSignStatus: Sendable, Hashable {
    /// Signed by Apple as part of macOS (`anchor apple`).
    case apple
    /// Mac App Store distribution.
    case appStore(teamID: String?)
    /// Developer ID; `notarized` is true when the `notarized` requirement is satisfied.
    case developerID(teamID: String?, notarized: Bool)
    /// Valid signature but none of the above (ad-hoc, development, other CA).
    case adHoc
    case unsigned
    /// A signature is present but fails validation.
    case invalid
    /// Could not be checked (e.g. process vanished, path unreadable).
    case unknown

    public var label: String {
        switch self {
        case .apple: "Apple"
        case .appStore: "App Store"
        case .developerID(_, let notarized): notarized ? "Developer ID (notarized)" : "Developer ID"
        case .adHoc: "Ad-hoc"
        case .unsigned: "Unsigned"
        case .invalid: "Invalid"
        case .unknown: "—"
        }
    }
}

/// A value inside an entitlements plist (kept `Sendable`, unlike `Any`).
public indirect enum EntitlementValue: Sendable, Hashable, CustomStringConvertible {
    case bool(Bool)
    case string(String)
    case number(Double)
    case array([EntitlementValue])
    case dictionary([String: EntitlementValue])
    case other(String)

    init(any value: Any) {
        switch value {
        case let n as NSNumber:
            // CFBoolean bridges to NSNumber; distinguish by type id.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { EntitlementValue(any: $0) })
        case let d as [String: Any]: self = .dictionary(d.mapValues { EntitlementValue(any: $0) })
        default: self = .other(String(describing: value))
        }
    }

    public var description: String {
        switch self {
        case .bool(let b): b ? "true" : "false"
        case .string(let s): s
        case .number(let n): n == n.rounded() ? String(Int64(n)) : String(n)
        case .array(let a): "[" + a.map(\.description).joined(separator: ", ") + "]"
        case .dictionary(let d): "{" + d.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "}"
        case .other(let s): s
        }
    }
}

/// Full signing information for the Inspector tab.
public struct SigningDetails: Sendable, Hashable {
    public var status: CodeSignStatus
    public var identifier: String?
    public var teamID: String?
    /// Common names of the certificate chain, leaf first.
    public var certificateChain: [String]
    public var entitlements: [String: EntitlementValue]
    /// `CS_RUNTIME` flag (hardened runtime).
    public var hardenedRuntime: Bool
    public var notarized: Bool
}

/// On-demand signature checks (never on the sampling hot path), cached by path + mtime.
public actor CodeSignatureInspector {
    public static let shared = CodeSignatureInspector()

    private static let maxCacheEntries = 2_000

    private var cache: [String: (mtime: Date, status: CodeSignStatus)] = [:]

    public init() {}

    /// Status of the executable at `path`. Cached; re-checked when the file's mtime changes.
    public func status(forPath path: String) async -> CodeSignStatus {
        guard let mtime = modificationDate(atPath: path) else {
            return .unknown
        }
        if let cached = cache[path], cached.mtime == mtime {
            return cached.status
        }

        let result = Self.evaluate(path: path)

        if cache.count >= Self.maxCacheEntries {
            cache.removeAll(keepingCapacity: true)
        }
        cache[path] = (mtime: mtime, status: result)
        return result
    }

    /// Identifier, team, certificate chain, entitlements, hardened-runtime and notarization for the
    /// executable at `path`. Nil when the file can't be opened or is unsigned. Not cached (inspector use).
    public func details(forPath path: String) async -> SigningDetails? {
        var staticCodeRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCodeRef) == errSecSuccess,
              let code = staticCodeRef else { return nil }

        let signedStatus = await status(forPath: path)
        if signedStatus == .unsigned || signedStatus == .unknown { return nil }

        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation | kSecCSRequirementInformation))
        guard SecCodeCopySigningInformation(code, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }

        let certs = (info[kSecCodeInfoCertificates as String] as? [SecCertificate]) ?? []
        let chain = certs.compactMap { cert -> String? in
            var name: CFString?
            return SecCertificateCopyCommonName(cert, &name) == errSecSuccess ? name as String? : nil
        }
        let entitlements = (info[kSecCodeInfoEntitlementsDict as String] as? [String: Any])?
            .mapValues { EntitlementValue(any: $0) } ?? [:]
        let rawFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let notarized: Bool
        if case .developerID(_, let n) = signedStatus { notarized = n } else { notarized = Self.satisfies(code, requirement: "notarized") }

        return SigningDetails(
            status: signedStatus, identifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamID: info[kSecCodeInfoTeamIdentifier as String] as? String, certificateChain: chain,
            entitlements: entitlements, hardenedRuntime: rawFlags & SecCodeSignatureFlags.runtime.rawValue != 0,
            notarized: notarized)
    }

    // MARK: - Helpers

    private func modificationDate(atPath path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    /// Runs the blocking Security.framework checks. Pure function of the file on disk.
    private static func evaluate(path: String) -> CodeSignStatus {
        var staticCodeRef: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: path) as CFURL, [], &staticCodeRef
        )
        guard createStatus == errSecSuccess, let code = staticCodeRef else {
            return .unknown
        }

        let validityFlags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures))
        let validity = SecStaticCodeCheckValidity(code, validityFlags, nil)
        if validity == errSecCSUnsigned {
            return .unsigned
        }
        if validity != errSecSuccess {
            return .invalid
        }

        if satisfies(code, requirement: "anchor apple") {
            return .apple
        }

        if satisfies(code, requirement: "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists") {
            return .appStore(teamID: teamID(of: code))
        }

        if satisfies(code, requirement: "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists") {
            let notarized = satisfies(code, requirement: "notarized")
            return .developerID(teamID: teamID(of: code), notarized: notarized)
        }

        return .adHoc
    }

    /// True when `code` satisfies the given code requirement string.
    private static func satisfies(_ code: SecStaticCode, requirement text: String) -> Bool {
        var requirementRef: SecRequirement?
        let createStatus = SecRequirementCreateWithString(text as CFString, [], &requirementRef)
        guard createStatus == errSecSuccess, let requirement = requirementRef else {
            return false
        }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Team identifier from the signing information, if the signature carries one.
    private static func teamID(of code: SecStaticCode) -> String? {
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(code, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else {
            return nil
        }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
