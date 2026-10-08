import ProcLensCore

/// Code-signing lookups for the UI. Release builds go straight to `CodeSignatureInspector`; Debug builds in demo
/// mode (`-ProcLensDemo 1`) answer for the synthetic paths instead.
enum SigningLookup {
    static func status(forPath path: String) async -> CodeSignStatus {
        #if DEBUG
        if DemoMode.isActive { return DemoMode.signStatus(forPath: path) }
        #endif
        return await CodeSignatureInspector.shared.status(forPath: path)
    }

    static func details(forPath path: String) async -> SigningDetails? {
        #if DEBUG
        if DemoMode.isActive { return nil }
        #endif
        return await CodeSignatureInspector.shared.details(forPath: path)
    }
}
