import Testing
@testable import ProcLensCore

struct SemanticVersionTests {
    @Test func parsesTagsAndShortForms() {
        #expect(SemanticVersion("v1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(SemanticVersion("1.2") == SemanticVersion(major: 1, minor: 2, patch: 0))
        #expect(SemanticVersion("2") == SemanticVersion(major: 2))
        #expect(SemanticVersion(" 1.0.0+build5 ") == SemanticVersion(major: 1))
        #expect(SemanticVersion("1.0.0-beta.1")?.prerelease == ["beta", "1"])
    }

    @Test func rejectsGarbage() {
        for s in ["", "v", "a.b.c", "1.2.3.4", "1..2", "1.2.x", "1.0.0-", "-1.0.0", "١.٢"] {
            #expect(SemanticVersion(s) == nil, "\(s)")
        }
    }

    @Test func ordersNumerically() {
        #expect(SemanticVersion.isNewer("v0.10.0", than: "0.9.9"))
        #expect(SemanticVersion.isNewer("1.0.1", than: "1.0.0"))
        #expect(!SemanticVersion.isNewer("1.0.0", than: "1.0.0"))
        #expect(!SemanticVersion.isNewer("0.1.0", than: "0.1.1"))
        #expect(!SemanticVersion.isNewer("v1.0", than: "1.0.0"))
    }

    @Test func prereleaseSortsBeforeRelease() {
        #expect(SemanticVersion.isNewer("1.0.0", than: "1.0.0-rc.1"))
        #expect(!SemanticVersion.isNewer("1.0.0-rc.1", than: "1.0.0"))
        #expect(SemanticVersion.isNewer("1.0.0-rc.2", than: "1.0.0-rc.1"))
        #expect(SemanticVersion.isNewer("1.0.0-rc.10", than: "1.0.0-rc.2"))
        #expect(SemanticVersion.isNewer("1.0.0-beta", than: "1.0.0-alpha"))
        #expect(SemanticVersion.isNewer("1.0.0-1", than: "1.0.0-alpha") == false)
    }

    @Test func unparseableIsNeverNewer() {
        #expect(!SemanticVersion.isNewer("latest", than: "1.0.0"))
        #expect(!SemanticVersion.isNewer("2.0.0", than: "?"))
    }
}
