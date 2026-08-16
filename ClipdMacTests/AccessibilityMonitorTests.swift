import XCTest
@testable import ClipdMac

/// The permission itself cannot be granted by a test, and no test suite should
/// be allowed to grant it. What can be tested is the part that was actually
/// broken: noticing a change, and telling everyone once.
@MainActor
final class AccessibilityMonitorTests: XCTestCase {
    /// A probe under the test's control, standing in for AXIsProcessTrusted().
    private final class Probe {
        var value = false
        func read() -> Bool { value }
    }

    func testItStartsWithWhateverTheSystemSaysRightNow() {
        let probe = Probe()
        probe.value = true
        XCTAssertTrue(AccessibilityMonitor(probe: probe.read).isTrusted)

        probe.value = false
        XCTAssertFalse(AccessibilityMonitor(probe: probe.read).isTrusted)
    }

    /// The whole point of the type. Before this existed the app read the
    /// permission once at launch, so granting it changed nothing on screen and
    /// the app looked broken until it was quit and reopened.
    func testGrantingThePermissionIsNoticedWithNoRelaunch() {
        let probe = Probe()
        let monitor = AccessibilityMonitor(probe: probe.read)
        var reported: [Bool] = []
        monitor.onChange = { reported.append($0) }

        probe.value = true
        monitor.check()

        XCTAssertEqual(reported, [true])
        XCTAssertTrue(monitor.isTrusted)
    }

    /// The poll runs once a second for the life of the app. If it reported
    /// every tick, the menu would be rebuilt and the window relaid out sixty
    /// times a minute forever.
    func testItReportsOnlyChangesAndNotEveryCheck() {
        let probe = Probe()
        let monitor = AccessibilityMonitor(probe: probe.read)
        var changes = 0
        monitor.onChange = { _ in changes += 1 }

        for _ in 0..<5 { monitor.check() }
        XCTAssertEqual(changes, 0, "nothing moved, so nothing should have been reported")

        probe.value = true
        monitor.check()
        monitor.check()
        monitor.check()
        XCTAssertEqual(changes, 1, "one grant is one change, however often it is polled")
    }

    /// The permission can be taken away as well as given, from System Settings,
    /// while the app runs. The warning icon has to come back.
    func testRevokingThePermissionIsReportedToo() {
        let probe = Probe()
        probe.value = true
        let monitor = AccessibilityMonitor(probe: probe.read)
        var reported: [Bool] = []
        monitor.onChange = { reported.append($0) }

        probe.value = false
        monitor.check()
        probe.value = true
        monitor.check()

        XCTAssertEqual(reported, [false, true])
    }

    /// start() and stop() must be safe to call more than once. The app calls
    /// start() at launch, and a second timer would double every poll.
    func testStartingTwiceDoesNotLeaveTwoTimersRunning() {
        let probe = Probe()
        let monitor = AccessibilityMonitor(probe: probe.read)
        monitor.start()
        monitor.start()
        monitor.stop()
        monitor.stop()

        var changes = 0
        monitor.onChange = { _ in changes += 1 }
        probe.value = true
        monitor.check()
        XCTAssertEqual(changes, 1)
    }
}
