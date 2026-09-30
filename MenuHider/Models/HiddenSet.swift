import Foundation

struct MenuBarItemPosition: Equatable {
    let bundleID: String
    let x: CGFloat
    /// Accessibility's y, counted downward from the top of the primary display. Only used to tell
    /// one display's menu bar from another.
    var y: CGFloat = 0
}

/// The menu bar the markers are on, in the coordinates Accessibility reports item positions in:
/// x to the right, y downward from the top of the primary display. Every status item is drawn on
/// every display's menu bar, but an item's reported position belongs to whichever bar was laid out
/// last, so a scan mixes displays unless the items are filtered to this one. Both ranges are
/// half-open, so adjacent displays never claim the same coordinate.
struct MarkerBar: Equatable {
    var minX: CGFloat
    var maxX: CGFloat
    var minY: CGFloat
    var maxY: CGFloat

    func contains(x: CGFloat, y: CGFloat) -> Bool {
        x >= minX && x < maxX && y >= minY && y < maxY
    }
}

/// Pure logic for the three-region layout `[left zone] | [right zone] » [always visible]`.
/// The `|` opens the hidden area and the `»` closes it: the two zones flanking the `|` hide while
/// they are collapsed, and icons parked right of the `»` are never hidden.
enum HiddenSet {
    /// The two zones, by bundle id. An app with icons in both zones is in both sets: hiding is per
    /// app, so it hides whenever either of its zones is collapsed.
    struct Zones: Equatable {
        var left: Set<String> = []
        var right: Set<String> = []

        var all: Set<String> { left.union(right) }
        var isEmpty: Bool { left.isEmpty && right.isEmpty }
    }

    /// Items sitting exactly at an edge belong to no zone and count as visible; the `|` and the
    /// `»` are both at least 12 points wide, so a hidden item is always strictly inside anyway.
    ///
    /// `rightX` is nil while the `»` has no frame yet, and a `»` left of the `|` reads as a
    /// misconfiguration: both fall back to the boundary alone deciding, with no parked region.
    static func partition(
        items: [MenuBarItemPosition], boundaryX: CGFloat, rightX: CGFloat?, bar: MarkerBar? = nil
    ) -> Zones {
        // An item the markers' own bar cannot account for — another display's bar, or a position
        // Accessibility never resolved — belongs to no zone. Sweeping it into the left zone would
        // hide an app the user never put there, and its x would be measured against the wrong bar.
        let placed = bar.map { bar in items.filter { bar.contains(x: $0.x, y: $0.y) } } ?? items
        guard let rightX, rightX > boundaryX else {
            return Zones(
                left: Set(placed.filter { $0.x < boundaryX }.map(\.bundleID)),
                right: Set(placed.filter { $0.x > boundaryX }.map(\.bundleID)))
        }
        // Hiding is per app, so an icon parked right of the `»` has to win over a sibling of the
        // same app inside a zone: the user put it there to keep it on screen.
        let parked = Set(placed.filter { $0.x >= rightX }.map(\.bundleID))
        return Zones(
            left: Set(placed.filter { $0.x < boundaryX }.map(\.bundleID)).subtracting(parked),
            right: Set(placed.filter { $0.x > boundaryX && $0.x < rightX }.map(\.bundleID))
                .subtracting(parked))
    }

    /// The bundle ids to hide right now: a zone contributes its members unless it is revealed.
    static func effective(_ zones: Zones, leftRevealed: Bool, rightRevealed: Bool) -> Set<String> {
        var hidden: Set<String> = []
        if !leftRevealed { hidden.formUnion(zones.left) }
        if !rightRevealed { hidden.formUnion(zones.right) }
        return hidden
    }

    static func allowList(running: [String], hidden: Set<String>, alwaysAllowed: Set<String>) -> [String] {
        Array(Set(running).subtracting(hidden).union(alwaysAllowed)).sorted()
    }
}
