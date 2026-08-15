import XCTest
@testable import ClipdMac
import ClipdCore

final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "clipd-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDefaultsAreSensibleOnFirstRun() {
        let settings = AppSettings(defaults: defaults)
        // Forever, because silently deleting a new user's history is worse
        // than keeping too much.
        XCTAssertEqual(settings.retention, .forever)
        XCTAssertTrue(settings.autoClearEnabled)
        XCTAssertEqual(settings.ignoredBundleIDs, AppSettings.seedIgnored)
    }

    func testTheSeedListCoversTheManagersWeMeasured() {
        // Apple's Passwords.app sets no concealed marker at all, so the
        // deny-list is the only thing standing between it and the database.
        XCTAssertTrue(AppSettings.seedIgnored.contains("com.apple.passwords"))
        XCTAssertTrue(AppSettings.seedIgnored.contains("com.apple.keychainaccess"))
        XCTAssertTrue(AppSettings.seedIgnored.contains("com.bitwarden.desktop"))
        XCTAssertTrue(AppSettings.seedIgnored.contains("com.1password.1password"))
    }

    func testValuesPersistAcrossInstances() {
        let first = AppSettings(defaults: defaults)
        first.retention = .week
        first.autoClearEnabled = false
        first.addIgnored("com.example.secret")

        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.retention, .week)
        XCTAssertFalse(second.autoClearEnabled)
        XCTAssertTrue(second.ignoredBundleIDs.contains("com.example.secret"))
    }

    func testIgnoredIdsAreStoredLowercased() {
        let settings = AppSettings(defaults: defaults)
        settings.addIgnored("COM.Example.MixedCase")
        // Bundle ids are case insensitive on macOS. A deny-list that misses
        // on capitalisation is a silent password leak.
        XCTAssertTrue(settings.ignoredBundleIDs.contains("com.example.mixedcase"))
        XCTAssertTrue(settings.captureSettings.deniedBundleIDs.contains("com.example.mixedcase"))
    }

    func testRemovingAnIgnoredAppWorks() {
        let settings = AppSettings(defaults: defaults)
        settings.addIgnored("com.example.secret")
        settings.removeIgnored("com.example.secret")
        XCTAssertFalse(settings.ignoredBundleIDs.contains("com.example.secret"))
    }

    func testTheSeedEntriesCanBeRemovedButTheListNeverGoesEmptySilently() {
        let settings = AppSettings(defaults: defaults)
        for id in AppSettings.seedIgnored { settings.removeIgnored(id) }
        // The user is allowed to empty it deliberately. What must not happen
        // is it emptying itself, so an emptied list must persist as empty
        // rather than being re-seeded on the next launch.
        XCTAssertTrue(settings.ignoredBundleIDs.isEmpty)
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.ignoredBundleIDs.isEmpty)
    }

    func testCaptureSettingsReflectTheCurrentList() {
        let settings = AppSettings(defaults: defaults)
        settings.addIgnored("com.example.secret")
        XCTAssertTrue(settings.captureSettings.deniedBundleIDs.contains("com.example.secret"))
    }

    func testChangesFireTheCallback() {
        let settings = AppSettings(defaults: defaults)
        var fired = 0
        settings.onChange = { fired += 1 }
        settings.retention = .day
        settings.autoClearEnabled = false
        settings.addIgnored("com.example.one")
        settings.removeIgnored("com.example.one")
        // The watcher rebuilds its capture settings from this, so a change
        // that does not fire means the new ignore takes effect only after a
        // restart, which the user would read as the setting not working.
        XCTAssertEqual(fired, 4)
    }

    func testAGarbageStoredPolicyFallsBackRatherThanCrashing() {
        defaults.set("not-a-real-policy", forKey: "clipd.retention")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.retention, .forever)
    }
}
