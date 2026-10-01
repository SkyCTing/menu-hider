import XCTest

@testable import MenuHider

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private var feed: FakeReleaseFeed!
    private var settings: Settings!
    private var scheduler: ManualScheduler!
    private var suiteName: String!
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        feed = FakeReleaseFeed()
        scheduler = ManualScheduler()
        suiteName = "UpdateCheckerTests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeChecker(current: String = "1.0.0") -> UpdateChecker {
        UpdateChecker(
            feed: feed, settings: settings, scheduler: scheduler, currentVersion: current, now: { self.now })
    }

    private func makeRelease(_ tag: String) -> Release {
        Release(
            version: ReleaseVersion(tag)!,
            pageURL: URL(string: "https://example.com/\(tag)")!,
            notes: "notes",
            assets: [
                ReleaseAsset(
                    name: "MenuHider-\(tag.dropFirst()).zip", url: URL(string: "https://example.com/a.zip")!,
                    byteCount: 1)
            ])
    }

    // MARK: - Which releases are offered

    func testANewerReleaseIsOffered() async {
        feed.result = .success(makeRelease("v1.0.1"))
        let checker = makeChecker()

        let outcome = await checker.checkForUser()

        XCTAssertEqual(outcome, .available(makeRelease("v1.0.1")))
        XCTAssertEqual(checker.available?.version.description, "1.0.1")
    }

    func testTheRunningVersionIsNotOffered() async {
        feed.result = .success(makeRelease("v1.0.0"))
        let checker = makeChecker()

        let outcome = await checker.checkForUser()

        XCTAssertEqual(outcome, .upToDate)
        XCTAssertNil(checker.available)
    }

    func testAnOlderReleaseIsNeverOfferedAsAnUpdate() async {
        // The `latest` endpoint orders by creation date, not by version, so a patch on an older line
        // can come back — offering it would be a silent downgrade.
        feed.result = .success(makeRelease("v0.9.0"))
        let checker = makeChecker()

        let outcome = await checker.checkForUser()
        XCTAssertEqual(outcome, .upToDate)
    }

    func testASkippedVersionStaysQuiet() async {
        feed.result = .success(makeRelease("v1.0.1"))
        settings.skippedUpdateVersion = "1.0.1"
        let checker = makeChecker()

        let outcome = await checker.checkForUser()
        XCTAssertEqual(outcome, .upToDate)
        XCTAssertNil(checker.available)
    }

    func testANewerReleaseStillArrivesAfterASkip() async {
        feed.result = .success(makeRelease("v1.0.1"))
        settings.skippedUpdateVersion = "1.0.1"
        let checker = makeChecker()

        feed.result = .success(makeRelease("v1.0.2"))

        let outcome = await checker.checkForUser()
        XCTAssertEqual(outcome, .available(makeRelease("v1.0.2")))
    }

    func testSkippingForgetsTheOfferedRelease() async {
        feed.result = .success(makeRelease("v1.0.1"))
        let checker = makeChecker()
        _ = await checker.checkForUser()

        checker.skip()

        XCTAssertNil(checker.available)
        XCTAssertEqual(settings.skippedUpdateVersion, "1.0.1")
    }

    // MARK: - When it checks

    func testTheFirstSightingIsAnnouncedOnce() async {
        feed.result = .success(makeRelease("v1.0.1"))
        let checker = makeChecker()
        var announcements: [String] = []
        checker.onFirstSighting = { announcements.append($0.version.description) }

        _ = await checker.checkForUser()
        _ = await checker.checkForUser()

        XCTAssertEqual(announcements, ["1.0.1"], "the check runs daily, the alert does not")
    }

    func testTheDailyCheckRunsOnceEveryTwentyFourHours() async {
        settings.updateCheckLastAt = now
        let checker = makeChecker()

        checker.check()
        XCTAssertEqual(feed.requestCount, 0, "a check from an hour ago is not repeated on launch")

        now = now.addingTimeInterval(UpdateChecker.checkInterval + 60)
        checker.check()
        await waitUntil { feed.requestCount == 1 }
    }

    func testTheTimerArmsTheNextCheck() async {
        feed.result = .success(makeRelease("v1.0.0"))
        let checker = makeChecker()

        checker.check()
        await waitUntil { !scheduler.live.isEmpty }

        XCTAssertEqual(scheduler.live.map(\.seconds), [UpdateChecker.checkInterval])
        XCTAssertEqual(settings.updateCheckLastAt, now, "the check is stamped so the next launch skips it")
    }

    func testAClockThatMovedBackwardsDoesNotWedgeTheCheck() async {
        settings.updateCheckLastAt = now.addingTimeInterval(60 * 60 * 24 * 3)
        let checker = makeChecker()

        checker.check()

        await waitUntil { feed.requestCount == 1 }
    }

    func testSwitchingTheCheckOffStopsItAsking() async {
        let checker = makeChecker()

        checker.isEnabled = false
        checker.check(force: false)

        XCTAssertEqual(feed.requestCount, 0)
        XCTAssertTrue(scheduler.live.isEmpty, "and no timer is left armed")
    }

    func testTheMenuCanAlwaysAskRegardlessOfTheSwitch() async {
        feed.result = .success(makeRelease("v1.0.0"))
        let checker = makeChecker()
        checker.isEnabled = false

        _ = await checker.checkForUser()

        XCTAssertEqual(feed.requestCount, 1)
    }

    // MARK: - Failures

    func testBeingOfflineStaysQuiet() async {
        feed.result = .failure(UpdateError.offline)
        let checker = makeChecker()

        let outcome = await checker.checkForUser()
        XCTAssertEqual(outcome, .failed(.offline))
        XCTAssertNil(checker.lastError, "a shared rate limit or a dead network are not the user's problem")
    }

    func testBeingRateLimitedStaysQuiet() async {
        feed.result = .failure(UpdateError.rateLimited)
        let checker = makeChecker()

        _ = await checker.checkForUser()

        XCTAssertNil(checker.lastError)
    }

    func testARealFailureIsReported() async {
        feed.result = .failure(UpdateError.http(500))
        let checker = makeChecker()

        _ = await checker.checkForUser()

        XCTAssertEqual(checker.lastError, .http(500))
    }

    func testTheMenuCanAskAgainAfterAFailure() async {
        feed.result = .failure(UpdateError.http(500))
        let checker = makeChecker()
        _ = await checker.checkForUser()

        feed.result = .success(makeRelease("v1.0.1"))

        let outcome = await checker.checkForUser()
        XCTAssertEqual(outcome, .available(makeRelease("v1.0.1")))
        XCTAssertNil(checker.lastError)
    }

    /// `check()` runs its work in a Task; this lets the main actor run it before asserting.
    private func waitUntil(
        _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("the expected state never arrived", file: file, line: line)
    }
}
