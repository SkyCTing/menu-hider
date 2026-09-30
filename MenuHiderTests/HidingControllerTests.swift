import XCTest

@testable import MenuHider

@MainActor
final class HidingControllerTests: XCTestCase {
    private let leftApp = "left.app"
    private let rightApp = "right.app"

    private var engine: FakeEngine!
    private var items: FakeItems!
    private var running: FakeRunning!
    private var extras: FakeExtras!
    private var scheduler: ManualScheduler!
    private var settings: Settings!
    private var suiteName: String!
    /// The `|` sits at 500 and the `»` at 900, so x < 500 is the left zone and 500 < x < 900 the
    /// right one. Anything at 900 or more is parked and never hidden.
    private var boundaryX: CGFloat? = 500
    private var rightX: CGFloat? = 900
    private var controller: HidingController!

    override func setUp() {
        super.setUp()
        engine = FakeEngine()
        items = FakeItems()
        running = FakeRunning()
        running.bundleIDs = [leftApp, rightApp, "other"]
        extras = FakeExtras()
        scheduler = ManualScheduler()
        suiteName = "HidingControllerTests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suiteName)!)
        controller = makeController()
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController() -> HidingController {
        HidingController(
            engine: engine, items: items, runningApps: running, extras: extras,
            separators: { [unowned self] in
                SeparatorPositions(boundaryX: self.boundaryX, rightX: self.rightX)
            },
            settings: settings, scheduler: scheduler)
    }

    /// One app in each zone, both collapsed. The scan that fills the zones happens on the way.
    private func hideBothZones() {
        items.positions = [.init(bundleID: leftApp, x: 100), .init(bundleID: rightApp, x: 700)]
        controller.collapseAll()
    }

    // MARK: - The scan window

    func testCollapseScansAndRestricts() {
        hideBothZones()

        XCTAssertEqual(controller.state, .collapsed)
        XCTAssertEqual(controller.zones, HiddenSet.Zones(left: [leftApp], right: [rightApp]))
        XCTAssertEqual(settings.zones, controller.zones)
        let allowed = Set(engine.restrictions[0])
        XCTAssertTrue(allowed.isSuperset(of: ["other", "com.apple.controlcenter"]))
        XCTAssertFalse(allowed.contains(leftApp))
        XCTAssertFalse(allowed.contains(rightApp))
    }

    func testPositionsAreReadOnlyWhileEverythingIsOnScreen() {
        settings.autoHideSeconds = 0
        hideBothZones()
        XCTAssertEqual(items.scanCount, 1)

        controller.toggleRight()
        controller.toggleLeft()
        XCTAssertEqual(items.scanCount, 1, "a partially revealed bar has no positions to read")
        XCTAssertEqual(controller.state, .fullyRevealed)
        XCTAssertEqual(controller.zones, HiddenSet.Zones(left: [leftApp], right: [rightApp]))

        items.positions.append(.init(bundleID: "moved", x: 600))
        scheduler.fireAll()
        XCTAssertEqual(items.scanCount, 2, "a full reveal reached by hand refreshes the zones for free")
        XCTAssertEqual(controller.zones.right, ["moved", rightApp])

        controller.collapseAll()
        XCTAssertEqual(items.scanCount, 3)
    }

    func testEmptyZonesHoldNoRestriction() {
        items.positions = []
        controller.collapseAll()

        XCTAssertEqual(controller.state, .collapsed)
        XCTAssertTrue(engine.restrictions.isEmpty, "nothing to hide, so assessment mode must stay off")
    }

    func testCollapseDoesNothingWithoutAccessibility() {
        items.isTrusted = false
        hideBothZones()

        XCTAssertEqual(controller.state, .fullyRevealed)
        XCTAssertTrue(engine.restrictions.isEmpty)
    }

    func testZonesPersistAcrossInstances() {
        hideBothZones()

        XCTAssertEqual(makeController().zones, HiddenSet.Zones(left: [leftApp], right: [rightApp]))
    }

    func testActivationErrorIsExposedAndClearedByRevealing() {
        engine.nextError = Boom()
        hideBothZones()
        XCTAssertNotNil(controller.lastError)
        XCTAssertEqual(controller.state, .collapsed, "the intent stands; the menu shows the error")

        engine.nextError = nil
        controller.revealAll()
        XCTAssertNil(controller.lastError)
    }

    // MARK: - The two zones

    func testEachZoneHidesOnItsOwn() {
        hideBothZones()

        controller.toggleRight()
        XCTAssertEqual(controller.state, .rightRevealed)
        XCTAssertEqual(engine.appliedAllowList?.contains(rightApp), true)
        XCTAssertEqual(engine.appliedAllowList?.contains(leftApp), false, "the left zone is still hidden")

        controller.toggleRight()
        XCTAssertEqual(controller.state, .collapsed)
        XCTAssertEqual(engine.appliedAllowList?.contains(rightApp), false)
    }

    func testTogglingTheLeftZoneLeavesTheRightZoneAlone() {
        hideBothZones()

        controller.toggleLeft()

        XCTAssertEqual(controller.state, .leftRevealed)
        XCTAssertEqual(engine.appliedAllowList?.contains(leftApp), true)
        XCTAssertEqual(engine.appliedAllowList?.contains(rightApp), false)
    }

    /// The one-finger switch is the everyday control: it must never leave a peeked left zone
    /// stranded on screen, which is what makes the left icons look permanent.
    func testTheMainSwitchNeverLeavesTheLeftZoneOnScreen() {
        hideBothZones()

        controller.toggleLeft()
        XCTAssertEqual(controller.state, .leftRevealed)
        controller.toggleRight()
        XCTAssertEqual(controller.state, .collapsed, "a click is always a step back towards the bare bar")
        XCTAssertEqual(engine.appliedAllowList?.contains(leftApp), false)

        controller.toggleRight()
        XCTAssertEqual(controller.state, .rightRevealed)
        controller.toggleLeft()
        XCTAssertEqual(controller.state, .fullyRevealed, "the tap is what adds the left zone back")

        controller.toggleRight()
        XCTAssertEqual(controller.state, .collapsed, "and the switch takes it away from any state")
        XCTAssertEqual(engine.appliedAllowList?.contains(leftApp), false)
    }

    func testAnAppWithIconsInBothZonesHidesUntilBothZonesAreRevealed() {
        running.bundleIDs = ["both", "other"]
        items.positions = [.init(bundleID: "both", x: 100), .init(bundleID: "both", x: 700)]
        controller.collapseAll()

        XCTAssertEqual(controller.zones.left, ["both"])
        XCTAssertEqual(controller.zones.right, ["both"])
        XCTAssertEqual(engine.appliedAllowList?.contains("both"), false)

        controller.toggleRight()
        XCTAssertEqual(engine.appliedAllowList?.contains("both"), false, "the left zone still hides it")

        controller.toggleLeft()
        XCTAssertEqual(controller.state, .fullyRevealed)
        XCTAssertNil(engine.appliedAllowList, "with both zones revealed nothing is restricted at all")
    }

    func testRevealingEverythingReleasesTheRestriction() {
        hideBothZones()
        XCTAssertEqual(engine.restrictions.count, 1)

        controller.revealAll()

        XCTAssertEqual(controller.state, .fullyRevealed)
        XCTAssertNil(engine.appliedAllowList, "nothing hidden, so assessment mode must go off")
        XCTAssertEqual(engine.releases, 1)
    }

    func testIconsParkedRightOfTheToggleAreNeverHidden() {
        running.bundleIDs = ["hidden", "parked", "alsoParked"]
        hideBothZones()
        items.positions = [
            .init(bundleID: "hidden", x: 600), .init(bundleID: "parked", x: 901),
            .init(bundleID: "alsoParked", x: 1200),
        ]
        controller.rescan()
        scheduler.fireAll()

        XCTAssertEqual(controller.zones.right, ["hidden"])
        XCTAssertEqual(controller.zones.left, [])
        XCTAssertEqual(engine.appliedAllowList?.contains("parked"), true)
        XCTAssertEqual(engine.appliedAllowList?.contains("alsoParked"), true)
        XCTAssertEqual(engine.appliedAllowList?.contains("hidden"), false)
    }

    // MARK: - Auto-hide

    func testAutoHideCollapsesBothZones() {
        settings.autoHideSeconds = 5
        hideBothZones()

        controller.toggleRight()
        controller.toggleLeft()
        XCTAssertEqual(controller.state, .fullyRevealed)

        scheduler.fireAll()

        XCTAssertEqual(controller.state, .collapsed)
        XCTAssertEqual(engine.appliedAllowList?.contains(leftApp), false)
        XCTAssertEqual(engine.appliedAllowList?.contains(rightApp), false)
    }

    func testAutoHideDisabledLeavesTheZonesAlone() {
        settings.autoHideSeconds = 0
        hideBothZones()

        controller.revealAll()
        scheduler.fireAll()

        XCTAssertEqual(controller.state, .fullyRevealed, "with the timer off nothing may take the zones away")
    }

    func testAutoHideSurvivesATwoFingerToggle() {
        settings.autoHideSeconds = 5
        hideBothZones()

        controller.revealAll()
        controller.toggleLeft()
        XCTAssertEqual(controller.state, .rightRevealed)

        scheduler.fireAll()

        XCTAssertEqual(controller.state, .collapsed, "the timer must be re-armed, not dropped")
    }

    func testChangingAutoHideWhileRevealedReArmsTheTimer() {
        settings.autoHideSeconds = 10
        hideBothZones()
        controller.revealAll()

        controller.setAutoHideSeconds(0)
        scheduler.fireAll()
        XCTAssertEqual(controller.state, .fullyRevealed, "Never must cancel the armed timer")

        controller.setAutoHideSeconds(5)
        scheduler.fireAll()
        XCTAssertEqual(controller.state, .collapsed)
    }

    // MARK: - Rescan

    /// Collapses, moves to `state`, then rescans from there.
    private func rescan(from state: HidingController.State) {
        settings.autoHideSeconds = 0
        hideBothZones()
        switch state {
        case .collapsed: break
        case .rightRevealed: controller.toggleRight()
        case .leftRevealed: controller.toggleLeft()
        case .fullyRevealed:
            controller.toggleRight()
            controller.toggleLeft()
        }
        XCTAssertEqual(controller.state, state)

        controller.rescan()
        XCTAssertEqual(controller.state, .fullyRevealed, "the rescan reveals everything to read positions")
        scheduler.fireAll()
    }

    func testRescanRestoresTheCollapsedState() {
        rescan(from: .collapsed)
        XCTAssertEqual(controller.state, .collapsed)
    }

    func testRescanRestoresTheRightOnlyState() {
        rescan(from: .rightRevealed)
        XCTAssertEqual(controller.state, .rightRevealed)
        XCTAssertEqual(engine.appliedAllowList?.contains(leftApp), false)
    }

    func testRescanRestoresTheLeftOnlyState() {
        rescan(from: .leftRevealed)
        XCTAssertEqual(controller.state, .leftRevealed)
    }

    func testRescanRestoresTheFullyRevealedState() {
        rescan(from: .fullyRevealed)
        XCTAssertEqual(controller.state, .fullyRevealed)
    }

    func testRescanLeavesNoAutoHideBehind() {
        settings.autoHideSeconds = 5
        hideBothZones()

        controller.rescan()
        scheduler.fireAll()

        XCTAssertEqual(controller.state, .collapsed)
        XCTAssertTrue(scheduler.live.isEmpty, "no timer may outlive the rescan")
    }

    func testRescanPicksUpAnIconMovedBetweenZones() {
        settings.autoHideSeconds = 0
        items.positions = [.init(bundleID: "app", x: 100)]
        controller.collapseAll()
        XCTAssertEqual(controller.zones.left, ["app"])

        controller.rescan()
        items.positions = [.init(bundleID: "app", x: 700)]
        scheduler.fireAll()

        XCTAssertEqual(controller.zones.left, [])
        XCTAssertEqual(controller.zones.right, ["app"])
    }

    func testAGestureDuringTheRescanSettleWins() {
        settings.autoHideSeconds = 0
        hideBothZones()
        // The rescan has everything on screen; the tap closes the left zone again, while the
        // restore would put the whole bar back to `.collapsed`.
        controller.rescan()
        controller.toggleLeft()
        scheduler.fireAll()

        XCTAssertEqual(controller.state, .rightRevealed, "the restore must not undo the tap")
        XCTAssertEqual(engine.appliedAllowList?.contains(rightApp), true)
        XCTAssertEqual(engine.appliedAllowList?.contains(leftApp), false)
    }

    func testASecondRescanSupersedesTheFirst() {
        settings.autoHideSeconds = 0
        items.positions = [.init(bundleID: "first", x: 700)]
        controller.collapseAll()

        controller.rescan()
        items.positions = [.init(bundleID: "second", x: 700)]
        controller.rescan()
        XCTAssertEqual(controller.state, .fullyRevealed)
        scheduler.fireAll()

        XCTAssertEqual(controller.state, .collapsed)
        XCTAssertEqual(controller.zones.right, ["second"])
        XCTAssertEqual(engine.appliedAllowList?.contains("second"), false)
    }

    func testShutdownCancelsAPendingRescan() {
        items.positions = [.init(bundleID: "hidden", x: 700)]
        controller.rescan()
        controller.shutdown()
        scheduler.fireAll()

        XCTAssertTrue(engine.restrictions.isEmpty, "a dying app must not re-restrict the bar")
    }

    // MARK: - Launch

    func testStartWaitsForAccessibilityThenCollapses() {
        items.isTrusted = false
        items.positions = [.init(bundleID: "hidden", x: 700)]
        controller.start()

        scheduler.fireAll()
        XCTAssertEqual(controller.state, .fullyRevealed, "nothing may be hidden before the grant")
        XCTAssertEqual(scheduler.live.count, 1, "keeps polling")

        items.isTrusted = true
        scheduler.fireAll()

        XCTAssertEqual(controller.state, .collapsed)
        XCTAssertEqual(engine.restrictions.count, 1)
    }

    func testStartRetriesUntilTheBoundaryHasAFrame() {
        boundaryX = nil
        controller.start()
        scheduler.fireAll()

        XCTAssertEqual(
            controller.state, .fullyRevealed,
            "collapsing without a boundary reading would freeze a zone set that can never be recomputed")
        XCTAssertEqual(scheduler.live.count, 1, "keeps polling")

        boundaryX = 500
        scheduler.fireAll()
        XCTAssertEqual(controller.state, .collapsed)
    }

    func testWarmStartUsesThePersistedZones() {
        settings.zones = HiddenSet.Zones(left: ["l"], right: ["r"])

        XCTAssertEqual(makeController().zones, HiddenSet.Zones(left: ["l"], right: ["r"]))
    }

    // MARK: - Running apps

    func testRunningAppsChangedReappliesAfterDebounce() {
        running.bundleIDs = [rightApp]
        hideBothZones()
        running.bundleIDs = [rightApp, "new"]

        controller.runningAppsChanged()
        controller.runningAppsChanged()
        XCTAssertEqual(engine.restrictions.count, 1, "nothing until the burst settles")
        scheduler.fireAll()

        XCTAssertEqual(engine.restrictions.count, 2, "one reconcile per burst")
        XCTAssertTrue(engine.restrictions[1].contains("new"))
        XCTAssertFalse(engine.restrictions[1].contains(rightApp))
    }

    func testRunningAppsChangedSkipsIdenticalAllowList() {
        hideBothZones()
        controller.runningAppsChanged()
        scheduler.fireAll()
        XCTAssertEqual(engine.restrictions.count, 1, "an unchanged allow list must not be re-sent")
    }

    func testRunningAppsChangedIgnoredWhileFullyRevealed() {
        controller.runningAppsChanged()
        scheduler.fireAll()
        XCTAssertTrue(engine.restrictions.isEmpty)
    }

    // MARK: - Clock hover

    func testPointerOverClockReleasesAndRestoresAfterGrace() {
        hideBothZones()
        XCTAssertEqual(engine.restrictions.count, 1)

        controller.pointerOverClock = true
        XCTAssertEqual(engine.releases, 1, "restriction drops as soon as the pointer reaches the clock")
        XCTAssertEqual(controller.state, .collapsed)

        controller.pointerOverClock = false
        XCTAssertEqual(engine.restrictions.count, 1, "restore waits for the grace period")
        scheduler.fireAll()
        XCTAssertEqual(engine.restrictions.count, 2)
    }

    func testReenteringClockCancelsPendingRestore() {
        hideBothZones()
        controller.pointerOverClock = true
        controller.pointerOverClock = false
        controller.pointerOverClock = true
        scheduler.fireAll()
        XCTAssertEqual(engine.restrictions.count, 1, "cancelled restore must not fire")
        XCTAssertEqual(engine.releases, 1)
    }

    func testRunningAppsChangedKeepsBarUnrestrictedWhilePointerOnClock() {
        hideBothZones()
        controller.pointerOverClock = true
        running.bundleIDs = ["new"]
        controller.runningAppsChanged()
        scheduler.fireAll()
        XCTAssertEqual(engine.restrictions.count, 1, "the clock hover must keep the bar unrestricted")
    }

    func testHoverIgnoredWhileFullyRevealed() {
        controller.pointerOverClock = true
        controller.pointerOverClock = false
        scheduler.fireAll()
        XCTAssertEqual(engine.releases, 0)
        XCTAssertTrue(engine.restrictions.isEmpty)
    }

    func testRevealWhilePointerOnClockDoesNotRestoreLater() {
        settings.autoHideSeconds = 0
        hideBothZones()
        controller.pointerOverClock = true
        controller.pointerOverClock = false
        controller.revealAll()
        scheduler.fireAll()
        XCTAssertEqual(engine.restrictions.count, 1, "a pending hover restore must not re-hide after a reveal")
    }

    func testAutoHideWhilePointerAlreadyOnClockStaysUnrestricted() {
        settings.autoHideSeconds = 5
        hideBothZones()
        controller.revealAll()
        controller.pointerOverClock = true
        scheduler.fireAll()
        XCTAssertEqual(controller.state, .collapsed)
        XCTAssertNil(engine.appliedAllowList, "the clock must stay clickable")
    }

    // MARK: - Menu extras

    private let timeMachine = "com.apple.menuextra.TimeMachine"
    private let vpn = "com.apple.menuextra.vpn"

    /// Boundary at 500 and the toggle far right, so Time Machine sits in the left zone and the VPN
    /// in the right one; both extras hide on a full collapse.
    private func hideTimeMachineAndOneApp() {
        rightX = 1000
        extras.loaded = [vpn, timeMachine]
        items.positions = [
            .init(bundleID: timeMachine, x: 100),
            .init(bundleID: "hidden", x: 700),
            .init(bundleID: vpn, x: 950),
        ]
        controller.collapseAll()
    }

    func testCollapseUnloadsTheExtrasInBothZones() {
        hideTimeMachineAndOneApp()

        XCTAssertEqual(Set(extras.removals), [vpn, timeMachine])
        XCTAssertEqual(settings.removedMenuExtraIDs, [vpn, timeMachine])
        XCTAssertTrue(engine.restrictions[0].contains("com.apple.systemuiserver"))
    }

    func testEachExtraFollowsItsOwnZone() {
        hideTimeMachineAndOneApp()
        extras.removals = []

        controller.toggleLeft()

        XCTAssertEqual(extras.restorations, [timeMachine], "the revealed zone's extra comes back")
        XCTAssertEqual(extras.removals, [], "the collapsed zone keeps its extra unloaded")
        XCTAssertEqual(settings.removedMenuExtraIDs, [vpn])
    }

    func testCollapsingOnlyExtrasHoldsNoRestriction() {
        extras.loaded = [timeMachine]
        items.positions = [.init(bundleID: timeMachine, x: 100)]
        controller.collapseAll()

        XCTAssertEqual(extras.removals, [timeMachine])
        XCTAssertTrue(engine.restrictions.isEmpty, "assessment mode would block Notification Center for nothing")
    }

    func testRevealingReloadsUnloadedExtras() {
        hideTimeMachineAndOneApp()
        controller.revealAll()

        XCTAssertEqual(Set(extras.restorations), [vpn, timeMachine])
        XCTAssertEqual(settings.removedMenuExtraIDs, [])
    }

    func testPointerOverClockKeepsExtrasUnloaded() {
        hideTimeMachineAndOneApp()
        controller.pointerOverClock = true

        XCTAssertEqual(engine.releases, 1)
        XCTAssertTrue(extras.restorations.isEmpty)
    }

    func testStartReloadsExtrasLeftUnloadedByPreviousRun() {
        settings.removedMenuExtraIDs = [timeMachine]
        controller.start()

        XCTAssertEqual(extras.restorations, [timeMachine])
        XCTAssertEqual(settings.removedMenuExtraIDs, [])
    }

    func testShutdownReloadsExtras() {
        hideTimeMachineAndOneApp()
        controller.shutdown()

        XCTAssertEqual(Set(extras.restorations), [vpn, timeMachine])
        XCTAssertEqual(settings.removedMenuExtraIDs, [])
    }

    func testFailedReloadIsRetriedLater() {
        hideTimeMachineAndOneApp()
        extras.failRestore = true
        controller.revealAll()
        XCTAssertEqual(
            settings.removedMenuExtraIDs, [vpn, timeMachine], "an extra that failed to load must be retried")

        extras.failRestore = false
        controller.shutdown()
        XCTAssertEqual(Set(extras.restorations), [vpn, timeMachine])
        XCTAssertEqual(settings.removedMenuExtraIDs, [])
        XCTAssertEqual(extras.restorations.count, 4, "the earlier attempts failed and were repeated")
    }
}
