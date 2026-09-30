import AppKit
import XCTest

@testable import MenuHider

/// Only the pure statics: instantiating the controller would create real status items.
@MainActor
final class StatusItemControllerTests: XCTestCase {
    private func route(
        _ type: NSEvent.EventType?,
        _ modifiers: NSEvent.ModifierFlags = [],
        left: Bool = false,
        revealed: Bool = false
    ) -> MarkerClick {
        StatusItemController.route(
            eventType: type, modifiers: modifiers, isLeftMarker: left, anyRevealed: revealed)
    }

    func testOneFingerClickOnTheToggleTogglesTheRightZone() {
        XCTAssertEqual(route(.leftMouseUp), .toggleRight)
        XCTAssertEqual(route(.leftMouseUp, [], revealed: true), .toggleRight)
    }

    func testTwoFingerTapTogglesTheLeftZoneWhileTheBarIsExpanded() {
        XCTAssertEqual(route(.rightMouseUp, [], revealed: true), .toggleLeft)
        XCTAssertEqual(route(.rightMouseUp, [], left: true, revealed: true), .toggleLeft)
    }

    func testTwoFingerTapOnABareBarOpensTheMenu() {
        XCTAssertEqual(route(.rightMouseUp), .menu)
        XCTAssertEqual(route(.rightMouseUp, [], left: true), .menu)
    }

    func testControlClickOpensTheMenuInEveryState() {
        XCTAssertEqual(route(.leftMouseUp, .control), .menu)
        XCTAssertEqual(route(.rightMouseUp, .control), .menu)
        XCTAssertEqual(route(.leftMouseUp, .control, left: true, revealed: true), .menu)
        XCTAssertEqual(route(.rightMouseUp, .control, revealed: true), .menu)
    }

    func testTheDividerIgnoresOneFingerClicks() {
        XCTAssertEqual(route(.leftMouseUp, [], left: true), .none)
        XCTAssertEqual(route(.leftMouseUp, [], left: true, revealed: true), .none)
    }

    func testUnrelatedModifiersDoNotSelectTheMenu() {
        XCTAssertEqual(route(.leftMouseUp, [.capsLock, .function, .numericPad]), .toggleRight)
    }

    func testNoEventReadsAsAPlainClick() {
        XCTAssertEqual(route(nil), .toggleRight, "AXPress and VoiceOver synthesise clicks with no event")
        XCTAssertEqual(route(nil, [], left: true), .none)
    }

    func testEveryStateHasItsOwnSymbol() {
        let states: [HidingController.State] = [.collapsed, .leftRevealed, .rightRevealed, .fullyRevealed]
        let names = states.map(StatusItemController.symbolName(for:))

        XCTAssertEqual(Set(names).count, states.count)
        XCTAssertEqual(
            Set(states.map(StatusItemController.description(for:))).count, states.count, "and its own description")
    }

    func testTheTwoExtremesKeepTheIconsTheyHadBeforeTheZonesWereSplit() {
        XCTAssertEqual(StatusItemController.symbolName(for: .collapsed), "chevron.left.2")
        XCTAssertEqual(StatusItemController.symbolName(for: .fullyRevealed), "chevron.right.2")
    }
}
