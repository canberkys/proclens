import Foundation
import Testing
@testable import ProcLensCore

@Suite struct BackgroundItemsTests {
    // The fixture follows the documented layout of `sfltool dumpbtm`; real output needs root and is produced by
    // the helper. Re-validate against a real dump once the helper runs signed.
    @Test func parsesDump() throws {
        let items = BackgroundItemsParser.parse(try launchdFixture("btm-dump"))
        #expect(items.count == 4)

        let app = items[0]
        #expect(app.name == "Example Sync")
        #expect(app.uid == 501)
        #expect(app.type == .app)
        #expect(app.developerName == "Example Software, Inc.")
        #expect(app.teamIdentifier == "ABCDE12345")
        #expect(app.url == "/Applications/Example Sync.app")
        #expect(app.bundleIdentifier == "com.example.sync")
        #expect(app.isEnabled && app.isAllowed && app.isVisible && app.isNotified)
        #expect(app.identifier == "2.com.example.sync")

        let login = items[1]
        #expect(login.type == .loginItem)
        #expect(!login.isEnabled)
        #expect(login.isAllowed)
        #expect(login.parentIdentifier == "2.com.example.sync")

        let legacy = items[2]
        #expect(legacy.type == .legacyAgent)
        #expect(legacy.developerName == nil)
        #expect(legacy.teamIdentifier == nil)
        #expect(legacy.isEnabled)
        #expect(!legacy.isAllowed)
        #expect(!legacy.isVisible)
        #expect(legacy.executablePath == "/Users/test/Library/Application Support/Example/updater")

        let daemon = items[3]
        #expect(daemon.uid == 0)
        #expect(daemon.type == .legacyDaemon)
        #expect(daemon.url == "/Library/LaunchDaemons/com.example.sync.helper.plist")
    }

    @Test func embeddedListsAreNotItems() {
        let text = " #1:\n Name: A\n Identifier: 1.a\n Embedded Item Identifiers:\n   #1: 2.b\n   #2: 3.c\n"
        #expect(BackgroundItemsParser.parse(text).count == 1)
    }

    @Test func emptyAndGarbageInput() {
        #expect(BackgroundItemsParser.parse("").isEmpty)
        #expect(BackgroundItemsParser.parse("sfltool: must be run as root\n").isEmpty)
    }

    @Test func unknownTypeIsKept() {
        let text = " #1:\n Name: X\n Type: hologram (0x99)\n"
        let item = BackgroundItemsParser.parse(text).first
        #expect(item?.type == .unknown("hologram (0x99)"))
    }

    @Test func ownLoginItemStatusDoesNotCrash() {
        _ = OwnLoginItem().status
    }
}
