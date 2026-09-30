import AppKit

protocol RunningAppsSource {
    var bundleIDs: [String] { get }
}

protocol TimerScheduler {
    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) -> Cancellable
}

protocol Cancellable {
    func cancel()
}

/// Screen x of the `|` boundary that opens the hidden area, and of the `»` toggle that closes it;
/// nil while the item is not on screen or has no frame yet. `bar` is the menu bar both markers are
/// on, so a scan can ignore the copies drawn on other displays.
struct SeparatorPositions {
    var boundaryX: CGFloat?
    var rightX: CGFloat?
    var bar: MarkerBar?
}

/// Owns the intent, the two zones and the timers, and derives the restriction MenuBarAgent holds.
@MainActor
final class HidingController {
    /// Which zones are on screen. They are independent: either, neither or both can be revealed.
    /// `.fullyRevealed` is also the only state item positions can be read in, so it doubles as the
    /// scan window.
    enum State: Equatable {
        case collapsed
        case leftRevealed
        case rightRevealed
        case fullyRevealed

        var leftRevealed: Bool { self == .leftRevealed || self == .fullyRevealed }
        var rightRevealed: Bool { self == .rightRevealed || self == .fullyRevealed }
        var isFullyRevealed: Bool { self == .fullyRevealed }
        /// Something is on screen that a click could take away again.
        var anyRevealed: Bool { self != .collapsed }

        static func make(left: Bool, right: Bool) -> State {
            switch (left, right) {
            case (true, true): return .fullyRevealed
            case (true, false): return .leftRevealed
            case (false, true): return .rightRevealed
            case (false, false): return .collapsed
            }
        }

        func setting(leftRevealed: Bool? = nil, rightRevealed: Bool? = nil) -> State {
            .make(left: leftRevealed ?? self.leftRevealed, right: rightRevealed ?? self.rightRevealed)
        }
    }

    /// Time for the freshly created separators to be laid out before the first scan.
    private static let launchSettleDelay: TimeInterval = 1.5
    private static let permissionPollInterval: TimeInterval = 2
    private static let hoverGraceDelay: TimeInterval = 0.5
    /// Time for the revealed items to be laid out before a scan reads their positions.
    private static let settleDelay: TimeInterval = 0.6
    /// App launches come in bursts of helper processes; one reconcile per burst is enough.
    private static let runningAppsDebounce: TimeInterval = 1

    private let engine: HidingEngine
    private let items: MenuBarItemSource
    private let runningApps: RunningAppsSource
    private let extras: MenuExtraHost
    private let separators: () -> SeparatorPositions
    private let scheduler: TimerScheduler
    let settings: Settings

    private(set) var state: State = .fullyRevealed
    private(set) var zones: HiddenSet.Zones
    private(set) var lastError: Error?
    /// Notification Center refuses to open while the restriction is active, and an already-open
    /// panel survives its return: the bar stays unrestricted while the pointer rests on the clock.
    var pointerOverClock = false {
        didSet { pointerOverClockChanged(from: oldValue) }
    }

    private var pendingHide: Cancellable?
    private var pendingRescan: Cancellable?
    private var hoverGrace: Cancellable?
    private var appsChange: Cancellable?
    private var startupPoll: Cancellable?
    private var revealSettle: Cancellable?
    /// The state a rescan has to put back once it has read the positions.
    private var rescanRestoreTarget: State?

    /// Bumped by every intent that changes the state. An in-flight rescan restore only runs while
    /// its captured value still matches, so a click during the settle always wins.
    private var gestureGeneration = 0
    /// False between entering `.fullyRevealed` and the icons being laid out; gates the scan. The
    /// initial state is settled by `start()`'s launch delay, which is why it starts true.
    private var revealSettled = true

    var onChange: (() -> Void)?

    init(
        engine: HidingEngine,
        items: MenuBarItemSource,
        runningApps: RunningAppsSource,
        extras: MenuExtraHost,
        separators: @escaping () -> SeparatorPositions,
        settings: Settings,
        scheduler: TimerScheduler
    ) {
        self.engine = engine
        self.items = items
        self.runningApps = runningApps
        self.extras = extras
        self.separators = separators
        self.settings = settings
        self.scheduler = scheduler
        self.zones = settings.zones
    }

    var isEngineAvailable: Bool { engine.isAvailable }
    var isAccessibilityTrusted: Bool { items.isTrusted }
    var canHide: Bool { engine.isAvailable && items.isTrusted }

    // MARK: - Intent

    func start() {
        reconcileMenuExtras()
        startupPoll = scheduler.schedule(after: Self.launchSettleDelay) { [weak self] in
            self?.collapseWhenPermitted()
        }
    }

    /// The `»` one-finger click: the main switch. It never leaves a peeked left zone on screen —
    /// a click is always a step back towards the bare bar, so the left zone cannot be left behind
    /// by the switch you use all day. Reach it again with a two-finger tap.
    func toggleRight() {
        apply { state in
            state.leftRevealed
                ? state.setting(leftRevealed: false, rightRevealed: false)
                : state.setting(rightRevealed: !state.rightRevealed)
        }
    }

    /// The `»` two-finger tap.
    func toggleLeft() {
        apply { $0.setting(leftRevealed: !$0.leftRevealed) }
    }

    func collapseAll() {
        apply { $0.setting(leftRevealed: false, rightRevealed: false) }
    }

    func revealAll() {
        apply { $0.setting(leftRevealed: true, rightRevealed: true) }
    }

    /// Reveals everything long enough to read positions, then puts the bar back as it was.
    func rescan() {
        // A second Rescan must not capture the first one's temporary full reveal as the state to go
        // back to.
        let previous = rescanRestoreTarget ?? state
        rescanRestoreTarget = previous
        gestureGeneration += 1
        let generation = gestureGeneration
        pendingRescan?.cancel()
        cancelPendingHide()
        startupPoll?.cancel()
        startupPoll = nil
        setState(.fullyRevealed, armAutoHide: false)
        pendingRescan = scheduler.schedule(after: Self.settleDelay) { [weak self] in
            guard let self, self.gestureGeneration == generation else { return }
            self.pendingRescan = nil
            self.rescanRestoreTarget = nil
            // Scan first, restore second: restoring first would reconcile against stale zones.
            self.refreshZones(force: true)
            // The read just happened, so the restore has nothing left to learn from a second one.
            self.setState(previous, refreshOnExit: false)
        }
    }

    func setAutoHideSeconds(_ seconds: Int) {
        settings.autoHideSeconds = seconds
        guard state.anyRevealed else { return }
        cancelPendingHide()
        armAutoHide()
    }

    /// Call on every app launch or quit: the allow list must follow the running set.
    func runningAppsChanged() {
        appsChange?.cancel()
        appsChange = scheduler.schedule(after: Self.runningAppsDebounce) { [weak self] in
            self?.reconcile()
        }
    }

    func shutdown() {
        gestureGeneration += 1
        cancelPendingHide()
        pendingRescan?.cancel()
        rescanRestoreTarget = nil
        hoverGrace?.cancel()
        appsChange?.cancel()
        startupPoll?.cancel()
        revealSettle?.cancel()
        state = .fullyRevealed
        engine.release()
        reconcileMenuExtras()
    }

    // MARK: - Derivation

    /// The apps that must be hidden right now; empty while both zones are on screen.
    private var pendingHiddenBundleIDs: Set<String> {
        HiddenSet.effective(zones, leftRevealed: state.leftRevealed, rightRevealed: state.rightRevealed)
    }

    var hiddenCount: Int { pendingHiddenBundleIDs.count }

    /// True while the restriction is or would be in force, i.e. whatever the clock hover lifts.
    var isHidingAnything: Bool { canHide && !pendingHiddenBundleIDs.isEmpty }

    private var desiredAllowList: [String]? {
        let hiddenApps = pendingHiddenBundleIDs.filter { !MenuExtras.isExtra($0) }
        guard canHide, !pointerOverClock, !hiddenApps.isEmpty else { return nil }
        return HiddenSet.allowList(
            running: runningApps.bundleIDs, hidden: hiddenApps, alwaysAllowed: SystemItems.alwaysAllowedBundleIDs)
    }

    /// No pointerOverClock check: unloaded extras do not block Notification Center.
    private var desiredRemovedExtras: Set<String> {
        guard canHide else { return [] }
        return pendingHiddenBundleIDs.filter(MenuExtras.isExtra)
    }

    /// Idempotent: an unchanged allow list is not re-sent.
    private func reconcile() {
        reconcileMenuExtras()
        guard let desired = desiredAllowList else {
            engine.release()
            return
        }
        guard desired != engine.appliedAllowList else { return }
        engine.restrict(allowedBundleIDs: desired) { [weak self] error in
            guard let self else { return }
            self.lastError = error
            if let error { Log.controller.error("restrict failed: \(error.localizedDescription)") }
            self.onChange?()
        }
    }

    private func reconcileMenuExtras() {
        let desired = desiredRemovedExtras
        var removed = settings.removedMenuExtraIDs
        for id in removed.subtracting(desired).sorted() where extras.restore(id) {
            removed.remove(id)
        }
        for id in desired.subtracting(removed).sorted() where extras.remove(id) {
            removed.insert(id)
        }
        settings.removedMenuExtraIDs = removed
    }

    // MARK: - State

    /// The one way a user intent or a timer changes the state. Everything is validated before
    /// anything is committed, so a rejected intent leaves the timers alone.
    private func apply(_ transform: (State) -> State) {
        let next = transform(state)
        guard next != state else { return }
        // Collapsing needs the engine and the permission; revealing never does.
        let collapses = (state.leftRevealed && !next.leftRevealed) || (state.rightRevealed && !next.rightRevealed)
        guard !collapses || canHide else {
            Log.controller.error(
                "collapse skipped: engine=\(self.engine.isAvailable) accessibility=\(self.items.isTrusted)")
            return
        }
        gestureGeneration += 1
        pendingRescan?.cancel()
        pendingRescan = nil
        rescanRestoreTarget = nil
        cancelPendingHide()
        startupPoll?.cancel()
        startupPoll = nil
        setState(next)
    }

    private func setState(_ next: State, armAutoHide shouldArm: Bool = true, refreshOnExit: Bool = true) {
        guard next != state else { return }
        // Leaving the fully revealed state is the scan window: the icons are about to go away, and
        // their positions are the only input the zones have.
        if refreshOnExit && state.isFullyRevealed && !next.isFullyRevealed {
            refreshZones()
        }
        if next.isFullyRevealed && !state.isFullyRevealed {
            revealSettled = false
            revealSettle = scheduler.schedule(after: Self.settleDelay) { [weak self] in
                guard let self else { return }
                self.revealSettled = true
                // A rescan has its own timed read; it must not fire this one as well.
                guard self.pendingRescan == nil else { return }
                // Reached by hand, so no collapse is coming to trigger a scan: take it for free.
                self.refreshZones()
            }
        } else if !next.isFullyRevealed {
            revealSettle?.cancel()
            revealSettle = nil
            revealSettled = true
        }
        state = next
        if next.isFullyRevealed { lastError = nil }
        reconcile()
        onChange?()
        if shouldArm { armAutoHide() }
    }

    /// The only place item positions are read. Positions are only meaningful while everything is on
    /// screen, so this is guarded on the state, not merely on being called at a convenient moment.
    private func refreshZones(force: Bool = false) {
        guard state.isFullyRevealed, items.isTrusted, force || revealSettled else { return }
        // A scan reads the extras' positions positionally, so none of them may be unloaded: while
        // fully revealed the desired set is empty, and this makes that true before we read.
        reconcileMenuExtras()
        let positions = separators()
        guard let boundaryX = positions.boundaryX else { return }
        let scanned = items.scan()
        zones = HiddenSet.partition(
            items: scanned, boundaryX: boundaryX, rightX: positions.rightX, bar: positions.bar)
        settings.zones = zones
        // Public on purpose: bundle identifiers and x positions are the only way to tell a bad
        // boundary reading from a bad scan, and os_log redacts interpolations by default.
        let dump = scanned.map { "\($0.bundleID)@\(Int($0.x))/\(Int($0.y))" }.joined(separator: " ")
        let left = zones.left.sorted().joined(separator: " ")
        let right = zones.right.sorted().joined(separator: " ")
        let parked = Set(scanned.filter { $0.x >= (positions.rightX ?? .greatestFiniteMagnitude) }.map(\.bundleID))
        Log.controller.error(
            "scan: boundary=\(boundaryX, privacy: .public) parked-from=\(positions.rightX.map { String(Int($0)) } ?? "none", privacy: .public) items=\(dump, privacy: .public) left=\(left, privacy: .public) right=\(right, privacy: .public) parked=\(parked.sorted().joined(separator: " "), privacy: .public)"
        )
    }

    private func pointerOverClockChanged(from previous: Bool) {
        guard previous != pointerOverClock else { return }
        hoverGrace?.cancel()
        if pointerOverClock {
            reconcile()
        } else {
            hoverGrace = scheduler.schedule(after: Self.hoverGraceDelay) { [weak self] in
                self?.reconcile()
            }
        }
    }

    private func collapseWhenPermitted() {
        guard isEngineAvailable else { return }
        // Collapsing with no boundary reading would commit to a zone set that can never be
        // recomputed, because nothing would be left on screen to read.
        guard isAccessibilityTrusted, separators().boundaryX != nil else {
            Log.controller.error(
                "waiting to collapse: accessibility=\(self.items.isTrusted) boundary=\(self.separators().boundaryX != nil)"
            )
            startupPoll = scheduler.schedule(after: Self.permissionPollInterval) { [weak self] in
                self?.collapseWhenPermitted()
            }
            return
        }
        collapseAll()
    }

    private func armAutoHide() {
        guard state.anyRevealed else { return }
        let seconds = settings.autoHideSeconds
        guard seconds > 0 else { return }
        pendingHide = scheduler.schedule(after: TimeInterval(seconds)) { [weak self] in
            // Both zones, so "revealed" never outlives the timer half-way.
            self?.collapseAll()
        }
    }

    private func cancelPendingHide() {
        pendingHide?.cancel()
        pendingHide = nil
    }
}

// MARK: - Default implementations

struct DispatchTimerScheduler: TimerScheduler {
    func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        let item = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }
}

extension DispatchWorkItem: Cancellable {}

struct WorkspaceRunningApps: RunningAppsSource {
    var bundleIDs: [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    }
}
