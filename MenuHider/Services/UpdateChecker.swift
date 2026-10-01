import Foundation

/// What a check the user asked for came back with, so the menu can answer either way.
enum UpdateOutcome: Equatable {
    case upToDate
    case available(Release)
    case failed(UpdateError)
}

/// Checks GitHub for a newer release: at launch, once a day while running, and on demand.
@MainActor
final class UpdateChecker {
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private let feed: ReleaseFetching
    private let settings: Settings
    private let scheduler: TimerScheduler
    private let now: () -> Date
    private let currentVersion: ReleaseVersion?

    private var pending: Cancellable?
    private var inFlight = false

    /// The release to offer; nil while the app is up to date, still checking, or told to skip it.
    private(set) var available: Release?
    /// Kept for the menu's status line. Offline and a shared rate limit are not the user's problem,
    /// so they never end up here.
    private(set) var lastError: UpdateError?

    var onChange: (() -> Void)?
    /// Fires the first time a version is seen, so it can be announced exactly once.
    var onFirstSighting: ((Release) -> Void)?

    init(
        feed: ReleaseFetching,
        settings: Settings,
        scheduler: TimerScheduler,
        currentVersion: String = AppInfo.version,
        now: @escaping () -> Date = Date.init
    ) {
        self.feed = feed
        self.settings = settings
        self.scheduler = scheduler
        self.currentVersion = ReleaseVersion(currentVersion)
        self.now = now
    }

    var isEnabled: Bool {
        get { settings.updateCheckEnabled }
        set {
            settings.updateCheckEnabled = newValue
            if newValue { check() } else { stop() }
            onChange?()
        }
    }

    func start() {
        check()
    }

    func stop() {
        pending?.cancel()
        pending = nil
    }

    /// The daily check. `force` skips both the switch and the interval, which is what the menu's
    /// own item does.
    func check(force: Bool = false) {
        guard !inFlight else { return }
        guard force || isEnabled else { return }
        guard force || isDue else { return scheduleNextCheck() }
        begin()
        Task { [weak self] in
            _ = await self?.runCheck()
        }
    }

    /// The menu's "Check for Updates": same check, but the answer is the point.
    func checkForUser() async -> UpdateOutcome {
        guard !inFlight else { return available.map(UpdateOutcome.available) ?? .upToDate }
        begin()
        return await runCheck()
    }

    /// Stop offering this version. A newer one is still offered later.
    func skip() {
        guard let release = available else { return }
        settings.skippedUpdateVersion = release.version.description
        Log.update.error("skipping \(release.version.description, privacy: .public)")
        available = nil
        onChange?()
    }

    // MARK: - Checking

    private func begin() {
        inFlight = true
        lastError = nil
        settings.updateCheckLastAt = now()
    }

    private func runCheck() async -> UpdateOutcome {
        defer {
            inFlight = false
            scheduleNextCheck()
            onChange?()
        }
        do {
            adopt(try await feed.latestRelease())
            return available.map(UpdateOutcome.available) ?? .upToDate
        } catch {
            let failure = (error as? UpdateError) ?? .badPayload
            note(failure)
            return .failed(failure)
        }
    }

    private func adopt(_ release: Release) {
        guard let currentVersion, release.version > currentVersion else {
            Log.update.error("up to date: newest is \(release.version.description, privacy: .public)")
            available = nil
            return
        }
        // Compared as versions, not as strings: a skipped "1.0" and a tagged "v1.0.0" are the same.
        guard ReleaseVersion(settings.skippedUpdateVersion ?? "") != release.version else {
            Log.update.error("\(release.version.description, privacy: .public) was skipped")
            available = nil
            return
        }
        // Announced once per version: the check runs every day, the alert does not.
        let isNewSighting = available?.version != release.version
        available = release
        Log.update.error("update available: \(release.version.description, privacy: .public)")
        if isNewSighting { onFirstSighting?(release) }
    }

    private func note(_ failure: UpdateError) {
        switch failure {
        case .offline, .rateLimited:
            lastError = nil
        default:
            lastError = failure
        }
        Log.update.error("check failed: \(String(describing: failure), privacy: .public)")
    }

    private var isDue: Bool {
        guard let last = settings.updateCheckLastAt else { return true }
        let elapsed = now().timeIntervalSince(last)
        // A clock that moved backwards must not wedge the check until the calendar catches up.
        return elapsed >= Self.checkInterval || elapsed < 0
    }

    private func scheduleNextCheck() {
        pending?.cancel()
        guard isEnabled else { return }
        pending = scheduler.schedule(after: Self.checkInterval) { [weak self] in
            self?.check()
        }
    }
}
