import XCTest
@testable import LiquidNotch

/// The one-time support card (11-11): a week and five launches, then once, ever.
final class SupportTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    func testAWeekAndFiveLaunches() {
        XCTAssertTrue(Support.due(firstLaunch: daysAgo(7), launches: 5, shown: false, now: now))
        XCTAssertTrue(Support.due(firstLaunch: daysAgo(30), launches: 40, shown: false, now: now))
    }

    func testNotBeforeAWeek() {
        XCTAssertFalse(Support.due(firstLaunch: daysAgo(6.9), launches: 50, shown: false, now: now))
    }

    func testNotForSomeoneWhoBarelyUsesIt() {
        XCTAssertFalse(Support.due(firstLaunch: daysAgo(60), launches: 4, shown: false, now: now))
    }

    func testOnceEver() {
        XCTAssertFalse(Support.due(firstLaunch: daysAgo(60), launches: 50, shown: true, now: now))
    }

    func testNoFirstLaunchYetIsNotDue() {
        XCTAssertFalse(Support.due(firstLaunch: nil, launches: 50, shown: false, now: now))
    }

    /// The first launch is dated once; existing users (no date yet) start their week at this launch.
    func testLaunchesAreCountedAndTheFirstIsDatedOnce() {
        let d = UserDefaults(suiteName: "support-test-\(UUID().uuidString)")!
        Support.recordLaunch(d, now: daysAgo(10))
        for _ in 0..<4 { Support.recordLaunch(d, now: now) }
        XCTAssertEqual(d.object(forKey: Support.firstLaunchKey) as? Date, daysAgo(10))
        XCTAssertEqual(d.integer(forKey: Support.launchesKey), 5)
        XCTAssertTrue(Support.isDue(d, now: now))
        d.set(true, forKey: Support.shownKey)
        XCTAssertFalse(Support.isDue(d, now: now))
    }
}
