import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController!
    private var controller: HidingController!
    private var hoverMonitor: ClockHoverMonitor!
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarScanner.requestTrust()

        statusItem = StatusItemController()
        let extras = SystemUIServerExtras()
        controller = HidingController(
            engine: MenuBarAgentBridge(),
            items: MenuBarScanner(extras: extras),
            runningApps: WorkspaceRunningApps(),
            extras: extras,
            separators: { [weak statusItem] in statusItem?.separators ?? SeparatorPositions() },
            settings: Settings.shared,
            scheduler: DispatchTimerScheduler()
        )
        statusItem.attach(controller)

        let updates = UpdateChecker(
            feed: GitHubReleases(), settings: Settings.shared, scheduler: DispatchTimerScheduler())
        statusItem.attachUpdates(updates, downloader: UpdateDownloader())

        // Relevant while already over the clock too: an auto-hide can fire under a resting pointer.
        hoverMonitor = ClockHoverMonitor { [weak controller] in
            guard let controller else { return false }
            return controller.isHidingAnything || controller.pointerOverClock
        }
        hoverMonitor.onChange = { [weak controller] over in controller?.pointerOverClock = over }
        controller.onChange = { [weak self] in
            self?.statusItem.stateChanged()
            self?.hoverMonitor.update()
        }
        hoverMonitor.start()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.controller.runningAppsChanged() }
                })
        }

        controller.start()
        // The check is a no-op unless the last one is a day old, and stays quiet about failures.
        updates.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}
