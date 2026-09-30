import XCTest

@testable import MenuHider

final class MenuExtrasTests: XCTestCase {
    func testPositionsPairItemsWithIDsInLoadOrder() {
        let positions = MenuExtras.positions(
            points: [CGPoint(x: 1410, y: 3), CGPoint(x: 1279, y: 3)],
            loadedIDs: ["com.apple.menuextra.vpn", "com.apple.menuextra.TimeMachine"])
        XCTAssertEqual(
            positions,
            [
                MenuBarItemPosition(bundleID: "com.apple.menuextra.vpn", x: 1410, y: 3),
                MenuBarItemPosition(bundleID: "com.apple.menuextra.TimeMachine", x: 1279, y: 3),
            ])
    }

    func testLoadOrderSortsByHandleAndSkipsUnloaded() {
        let handles: [String: Int32] = [
            "com.apple.menuextra.TimeMachine": 6,
            "com.apple.menuextra.vpn": 5,
            "com.apple.menuextra.eject": 0,
            "com.apple.menuextra.airport": -8,
        ]
        XCTAssertEqual(
            MenuExtras.loadOrder(handles: handles), ["com.apple.menuextra.vpn", "com.apple.menuextra.TimeMachine"])
    }

    func testIsExtraRecognisesMenuExtraIDsOnly() {
        XCTAssertTrue(MenuExtras.isExtra("com.apple.menuextra.TimeMachine"))
        XCTAssertFalse(MenuExtras.isExtra("com.raycast.macos"))
        XCTAssertFalse(MenuExtras.isExtra("com.apple.systemuiserver"))
    }
}
