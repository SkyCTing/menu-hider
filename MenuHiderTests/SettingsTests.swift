import XCTest

@testable import MenuHider

final class SettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The pre-two-zone key is reused for the right zone: its old value was geometrically the same
    /// set, so an update must read it rather than start from nothing.
    func testLegacyHiddenKeyIsReadAsTheRightZone() {
        defaults.set(["com.example.old"], forKey: "hiddenBundleIDs")

        let settings = Settings(defaults: defaults)

        XCTAssertEqual(settings.hiddenRightBundleIDs, ["com.example.old"])
        XCTAssertEqual(settings.zones.right, ["com.example.old"])
    }

    func testZonesRoundTripThroughTheirOwnKeys() {
        let settings = Settings(defaults: defaults)

        settings.zones = HiddenSet.Zones(left: ["l"], right: ["r"])

        XCTAssertEqual(settings.hiddenLeftBundleIDs, ["l"])
        XCTAssertEqual(settings.hiddenRightBundleIDs, ["r"])
        XCTAssertEqual(
            Settings(defaults: defaults).zones, HiddenSet.Zones(left: ["l"], right: ["r"]))
    }

    func testMissingKeysMeanEmptyZones() {
        let settings = Settings(defaults: defaults)

        XCTAssertEqual(settings.zones, HiddenSet.Zones())
        XCTAssertTrue(settings.zones.isEmpty)
    }

    func testAutoHideDefaultsToTenSeconds() {
        XCTAssertEqual(Settings(defaults: defaults).autoHideSeconds, 10)
    }
}
