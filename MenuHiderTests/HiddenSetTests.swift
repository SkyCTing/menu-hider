import XCTest

@testable import MenuHider

final class HiddenSetTests: XCTestCase {
    // MARK: - Partition

    func testPartitionSplitsItemsAroundTheTwoMarkers() {
        let items = [
            MenuBarItemPosition(bundleID: "left.one", x: 100),
            MenuBarItemPosition(bundleID: "left.two", x: 499),
            MenuBarItemPosition(bundleID: "at.boundary", x: 500),
            MenuBarItemPosition(bundleID: "right.one", x: 501),
            MenuBarItemPosition(bundleID: "right.two", x: 899),
            MenuBarItemPosition(bundleID: "at.toggle", x: 900),
            MenuBarItemPosition(bundleID: "parked", x: 1200),
        ]

        let zones = HiddenSet.partition(items: items, boundaryX: 500, rightX: 900)

        XCTAssertEqual(zones.left, ["left.one", "left.two"])
        XCTAssertEqual(zones.right, ["right.one", "right.two"])
    }

    func testItemExactlyAtAMarkerBelongsToNoZone() {
        let items = [
            MenuBarItemPosition(bundleID: "boundary", x: 500),
            MenuBarItemPosition(bundleID: "toggle", x: 900),
        ]

        let zones = HiddenSet.partition(items: items, boundaryX: 500, rightX: 900)

        XCTAssertEqual(zones, HiddenSet.Zones())
    }

    func testAnIconParkedRightOfTheToggleIsInNoZone() {
        let items = [
            MenuBarItemPosition(bundleID: "hidden", x: 300),
            MenuBarItemPosition(bundleID: "parked", x: 1200),
        ]

        let zones = HiddenSet.partition(items: items, boundaryX: 500, rightX: 900)

        XCTAssertEqual(zones.left, ["hidden"])
        XCTAssertEqual(zones.right, [])
    }

    func testAnIconParkedRightOfTheToggleKeepsItsAppOutOfTheLeftZone() {
        let items = [
            MenuBarItemPosition(bundleID: "app", x: 300),
            MenuBarItemPosition(bundleID: "app", x: 1200),
            MenuBarItemPosition(bundleID: "other", x: 400),
        ]

        let zones = HiddenSet.partition(items: items, boundaryX: 500, rightX: 900)

        XCTAssertEqual(zones.left, ["other"], "the parked icon wins over the app's icon in the left zone")
    }

    func testPartitionWithMultipleItemsPerAppPutsTheAppInBothZones() {
        let items = [
            MenuBarItemPosition(bundleID: "app", x: 100),
            MenuBarItemPosition(bundleID: "app", x: 700),
        ]

        let zones = HiddenSet.partition(items: items, boundaryX: 500, rightX: 900)

        XCTAssertEqual(zones.left, ["app"])
        XCTAssertEqual(zones.right, ["app"])
    }

    func testItemsFromAnotherDisplaysBarBelongToNoZone() {
        // The markers' bar in a three-display arrangement: 782..2702 across, sitting above the
        // primary display, which is why its y is negative.
        let bar = MarkerBar(minX: 782, maxX: 2702, minY: -1080, maxY: 0)
        let items = [
            MenuBarItemPosition(bundleID: "ours", x: 2000, y: -1075),
            MenuBarItemPosition(bundleID: "displayToTheLeft", x: 100, y: -1075),
            MenuBarItemPosition(bundleID: "barBelow", x: 1000, y: 5),
            MenuBarItemPosition(bundleID: "unplaced", x: -1, y: -1),
        ]

        let zones = HiddenSet.partition(items: items, boundaryX: 1957, rightX: 2168, bar: bar)

        XCTAssertEqual(zones.right, ["ours"], "only positions read from the markers' own bar count")
        XCTAssertEqual(zones.left, [])
    }

    func testWithoutABarReadingEveryItemIsPlaced() {
        let items = [
            MenuBarItemPosition(bundleID: "left", x: 100, y: 5),
            MenuBarItemPosition(bundleID: "right", x: 900, y: -1075),
        ]

        let zones = HiddenSet.partition(items: items, boundaryX: 500, rightX: 2000)

        XCTAssertEqual(zones.left, ["left"])
        XCTAssertEqual(zones.right, ["right"])
    }

    func testMissingTogglePutsEverythingRightOfTheBoundaryInTheRightZone() {
        let items = [
            MenuBarItemPosition(bundleID: "left", x: 100),
            MenuBarItemPosition(bundleID: "right", x: 900),
        ]

        let zones = HiddenSet.partition(items: items, boundaryX: 500, rightX: nil)

        XCTAssertEqual(zones.left, ["left"])
        XCTAssertEqual(zones.right, ["right"])
    }

    func testToggleLeftOfTheBoundaryFallsBackToTheBoundaryAlone() {
        let items = [
            MenuBarItemPosition(bundleID: "left", x: 100),
            MenuBarItemPosition(bundleID: "right", x: 900),
        ]

        let zones = HiddenSet.partition(items: items, boundaryX: 500, rightX: 200)

        XCTAssertEqual(zones.left, ["left"])
        XCTAssertEqual(zones.right, ["right"], "a » left of the | can park nothing")
    }

    // MARK: - Effective

    func testEffectiveHidesOnlyTheCollapsedZones() {
        let zones = HiddenSet.Zones(left: ["l"], right: ["r"])

        XCTAssertEqual(HiddenSet.effective(zones, leftRevealed: true, rightRevealed: true), [])
        XCTAssertEqual(HiddenSet.effective(zones, leftRevealed: true, rightRevealed: false), ["r"])
        XCTAssertEqual(HiddenSet.effective(zones, leftRevealed: false, rightRevealed: true), ["l"])
        XCTAssertEqual(HiddenSet.effective(zones, leftRevealed: false, rightRevealed: false), ["l", "r"])
    }

    func testEffectiveKeepsAnAppInBothZonesHiddenUntilBothAreRevealed() {
        let zones = HiddenSet.Zones(left: ["both"], right: ["both"])

        XCTAssertEqual(HiddenSet.effective(zones, leftRevealed: true, rightRevealed: false), ["both"])
        XCTAssertEqual(HiddenSet.effective(zones, leftRevealed: false, rightRevealed: true), ["both"])
        XCTAssertEqual(HiddenSet.effective(zones, leftRevealed: true, rightRevealed: true), [])
    }

    // MARK: - Allow list

    func testAllowListExcludesHiddenAndIncludesAlwaysAllowed() {
        let allowed = HiddenSet.allowList(
            running: ["a", "b", "c"],
            hidden: ["b"],
            alwaysAllowed: ["sys", "a"]
        )
        XCTAssertEqual(allowed, ["a", "c", "sys"])
    }

    func testAlwaysAllowedWinsOverHidden() {
        let allowed = HiddenSet.allowList(running: ["x"], hidden: ["x"], alwaysAllowed: ["x"])
        XCTAssertEqual(allowed, ["x"])
    }
}
