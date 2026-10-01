import AppKit
import ServiceManagement

/// What a click on one of the two markers asks for.
enum MarkerClick: Equatable {
    case toggleRight
    case toggleLeft
    case menu
    case none
}

/// The two separator icons in the menu bar and the context menu behind them.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let autoHideChoices: [(seconds: Int, title: String)] = [
        (0, "Never"), (5, "5 seconds"), (10, "10 seconds"), (30, "30 seconds"), (60, "1 minute"),
    ]

    /// The `»` switch: always on screen, and the only thing that toggles a zone.
    private let statusItem: NSStatusItem
    /// The `|` divider between the two zones: a drag handle, on screen only while a zone is
    /// revealed — the only time a scan can read the zones' positions anyway.
    private let leftSeparator: NSStatusItem
    private let menu = NSMenu()
    private var controller: HidingController?
    private var updates: UpdateChecker?
    private var downloader: UpdateDownloading?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        leftSeparator = NSStatusBar.system.statusItem(withLength: 12)
        super.init()
        menu.delegate = self
        configure(statusItem, autosaveName: "MenuHiderSeparator")
        configure(leftSeparator, autosaveName: "MenuHiderLeftSeparator")
        leftSeparator.button?.image = Self.boundaryImage()
        updateIcon(state: .fullyRevealed)
    }

    func attach(_ controller: HidingController) {
        self.controller = controller
    }

    /// The update check and the downloader behind its menu items. The alert is the controller's
    /// business: a menu bar app has to come forward before it can show one.
    func attachUpdates(_ updates: UpdateChecker, downloader: UpdateDownloading) {
        self.updates = updates
        self.downloader = downloader
        updates.onFirstSighting = { [weak self] release in self?.announce(release) }
    }

    func stateChanged() {
        if let controller { updateIcon(state: controller.state) }
    }

    var separators: SeparatorPositions {
        SeparatorPositions(
            boundaryX: leftSeparator.isVisible ? leftSeparator.button?.window?.frame.minX : nil,
            // Both markers are measured by their leading edge, and an item is parked at or past
            // it. The trailing edge would be the tighter reading, but a status item's window is
            // wider than the icon it draws: an icon packed against the `»` reports an x a point or
            // two inside that padding, and would be swept into the right zone — hidden — although
            // it is the first icon the user sees to the right of the switch.
            rightX: statusItem.button?.window?.frame.minX,
            bar: Self.markerBar(for: statusItem.button?.window?.frame))
    }

    /// The bar the markers sit on, translated into the coordinates Accessibility reports item
    /// positions in. Every status item is drawn on every display's menu bar while an item's
    /// position comes from only one of them, so the scan needs to know which bar it belongs to.
    static func markerBar(for frame: CGRect?) -> MarkerBar? {
        guard let frame else { return nil }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens.first
        else { return nil }
        // Accessibility counts y downward from the top of the primary display; NSScreen counts it
        // upward from the bottom of the primary screen, which is the one at the origin.
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? screen).frame.height
        return MarkerBar(
            minX: screen.frame.minX, maxX: screen.frame.maxX,
            minY: primaryHeight - screen.frame.maxY, maxY: primaryHeight - screen.frame.minY)
    }

    // MARK: - Status items

    private func configure(_ item: NSStatusItem, autosaveName: String) {
        item.autosaveName = autosaveName
        item.behavior = []
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateIcon(state: HidingController.State) {
        let name = Self.symbolName(for: state)
        // A nil symbol would leave the switch blank and looking dead, so fall back to one that has
        // been in SF Symbols since the first release.
        let image =
            Self.symbol(name, description: Self.description(for: state))
            ?? Self.symbol("chevron.left", description: Self.description(for: state))
        statusItem.button?.image = image
        leftSeparator.isVisible = state.anyRevealed
    }

    /// Double chevrons for the two extremes, a single chevron pointing at whichever zone is still
    /// hidden in between. The two extremes keep the icons they had before the zones were split.
    static func symbolName(for state: HidingController.State) -> String {
        switch state {
        case .collapsed: return "chevron.left.2"
        case .rightRevealed: return "chevron.left"
        case .leftRevealed: return "chevron.right"
        case .fullyRevealed: return "chevron.right.2"
        }
    }

    static func description(for state: HidingController.State) -> String {
        switch state {
        case .collapsed: return "MenuHider: both zones hidden"
        case .rightRevealed: return "MenuHider: right zone shown"
        case .leftRevealed: return "MenuHider: left zone shown"
        case .fullyRevealed: return "MenuHider: both zones shown"
        }
    }

    /// Control-click wins over the event type: AppKit reports control-click and a two-finger tap
    /// both as `.rightMouseUp`, so only the modifier tells them apart. Masking to the device
    /// independent flags keeps caps lock and the function keys from leaking in.
    ///
    /// A two-finger tap is the left zone's switch only while something is already on screen to
    /// reorganise; on a bare bar there is nothing to peek at, so it falls back to the menu that a
    /// right click used to open.
    static func route(
        eventType: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags, isLeftMarker: Bool, anyRevealed: Bool
    ) -> MarkerClick {
        if modifiers.intersection(.deviceIndependentFlagsMask).contains(.control) { return .menu }
        guard eventType == .rightMouseUp else { return isLeftMarker ? .none : .toggleRight }
        return anyRevealed ? .toggleLeft : .menu
    }

    private static func symbol(_ name: String, description: String? = nil) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    /// The left boundary is drawn instead of taken from SF Symbols: it has to read as a plain
    /// `|`, and no symbol is a bare bar. Template mode lets macOS tint it for light and dark bars.
    private static func boundaryImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 3, height: 14), flipped: false) { rect in
            // Draw relative to the rect AppKit passes in: it scales with the display, so
            // absolute coordinates would land in a corner of the Retina representation.
            let barWidth = rect.width * 0.5
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: rect.minX + (rect.width - barWidth) / 2, y: rect.minY,
                    width: barWidth, height: rect.height),
                xRadius: barWidth / 2, yRadius: barWidth / 2
            ).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MenuHider boundary"
        return image
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let click = Self.route(
            eventType: event?.type, modifiers: event?.modifierFlags ?? [],
            isLeftMarker: sender === leftSeparator.button,
            anyRevealed: controller?.state.anyRevealed ?? false
        )
        // Public on purpose: which gesture produced which action is the only way to tell a routing
        // bug from a state one, and os_log redacts interpolations by default.
        Log.ui.error(
            "separator clicked, route=\(String(describing: click), privacy: .public) anyRevealed=\(self.controller?.state.anyRevealed ?? false, privacy: .public)"
        )
        switch click {
        case .toggleRight, .toggleLeft:
            // The second half of an accidental double click must not toggle straight back.
            guard (event?.clickCount ?? 1) <= 1 else { return }
            if click == .toggleRight { controller?.toggleRight() } else { controller?.toggleLeft() }
        case .menu:
            let clicked = sender === leftSeparator.button ? leftSeparator : statusItem
            clicked.menu = menu
            clicked.button?.performClick(nil)
            clicked.menu = nil
        case .none:
            break
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller else { return }

        menu.addItem(header(controller))
        if !controller.isAccessibilityTrusted {
            menu.addItem(
                item("Open Accessibility Settings…", symbol: "hand.raised", action: #selector(openAccessibility)))
        }
        menu.addItem(.separator())

        let left = item("Show Left Zone", symbol: nil, action: #selector(toggleLeft))
        left.state = controller.state.leftRevealed ? .on : .off
        left.toolTip =
            "The icons left of the | divider. A two-finger tap on either marker does the same while something is on screen."
        menu.addItem(left)

        let right = item("Show Right Zone", symbol: nil, action: #selector(toggleRight))
        right.state = controller.state.rightRevealed ? .on : .off
        right.toolTip = "The icons between | and ». A click on the » switch does the same."
        menu.addItem(right)

        let both = item("Show Both Zones", symbol: "eye", action: #selector(revealAll))
        both.isEnabled = !controller.state.isFullyRevealed
        menu.addItem(both)

        let rescan = item("Rescan Layout", symbol: "arrow.clockwise", action: #selector(refresh))
        rescan.toolTip = "Re-read which icons sit in each zone."
        menu.addItem(rescan)
        menu.addItem(.separator())

        menu.addItem(autoHideMenu())
        let login = item("Launch at Login", symbol: nil, action: #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        addUpdateItems(to: menu)
        menu.addItem(.separator())

        menu.addItem(item("About MenuHider", symbol: nil, action: #selector(openRepository)))
        menu.addItem(item("Quit MenuHider", symbol: nil, action: #selector(quit), keyEquivalent: "q"))
    }

    /// Built fresh on every open, because the menu is rebuilt from scratch each time and the answer
    /// to "is there an update" changes under it.
    private func addUpdateItems(to menu: NSMenu) {
        guard let updates else { return }

        if let release = updates.available {
            let download = item(
                "Download MenuHider \(release.version)…", symbol: "arrow.down.circle", action: #selector(downloadUpdate)
            )
            download.toolTip =
                "Downloads the verified archive to your Downloads folder. macOS asks you to confirm it when you open it."
            menu.addItem(download)
        } else if let error = updates.lastError {
            let failed = item(
                "Update check failed: \(error.errorDescription ?? "unknown error")", symbol: nil, action: nil)
            failed.isEnabled = false
            menu.addItem(failed)
        }

        menu.addItem(item("Check for Updates", symbol: nil, action: #selector(checkForUpdates)))

        let automatic = item("Check for Updates Automatically", symbol: nil, action: #selector(toggleUpdateCheck))
        automatic.state = updates.isEnabled ? .on : .off
        automatic.toolTip = "One request a day to api.github.com. This is the only network access MenuHider makes."
        menu.addItem(automatic)
    }

    private func header(_ controller: HidingController) -> NSMenuItem {
        let status: String
        let symbol: String
        if !controller.isEngineAvailable {
            status = "Hiding unavailable on this macOS build"
            symbol = "exclamationmark.triangle"
        } else if !controller.isAccessibilityTrusted {
            status = "Accessibility permission required"
            symbol = "exclamationmark.triangle"
        } else if let error = controller.lastError {
            status = "Error: \(error.localizedDescription)"
            symbol = "exclamationmark.triangle"
        } else if controller.hiddenCount == 0 {
            status = "All items visible"
            symbol = "eye"
        } else {
            status = "Hiding \(controller.hiddenCount) apps\(collapsedZones(controller))"
            symbol = "eye.slash"
        }
        let line = item(status, symbol: symbol, action: nil)
        line.isEnabled = false
        return line
    }

    /// Names the zones the count comes from, so a half-collapsed bar is not a mystery.
    private func collapsedZones(_ controller: HidingController) -> String {
        let zones = controller.zones
        let names = [
            !controller.state.leftRevealed && !zones.left.isEmpty ? "left zone" : nil,
            !controller.state.rightRevealed && !zones.right.isEmpty ? "right zone" : nil,
        ].compactMap { $0 }
        return names.isEmpty ? "" : " (\(names.joined(separator: " + ")))"
    }

    private func autoHideMenu() -> NSMenuItem {
        let parent = item("Auto-hide After", symbol: "timer", action: nil)
        let submenu = NSMenu()
        for choice in Self.autoHideChoices {
            let entry = item(choice.title, symbol: nil, action: #selector(setAutoHide(_:)))
            entry.tag = choice.seconds
            entry.state = controller?.settings.autoHideSeconds == choice.seconds ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    private func item(_ title: String, symbol: String?, action: Selector?, keyEquivalent: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        entry.target = self
        if let symbol { entry.image = Self.symbol(symbol) }
        return entry
    }

    // MARK: - Actions

    @objc private func toggleRight() { controller?.toggleRight() }

    @objc private func toggleLeft() { controller?.toggleLeft() }

    @objc private func revealAll() { controller?.revealAll() }

    @objc private func refresh() { controller?.rescan() }

    @objc private func setAutoHide(_ sender: NSMenuItem) {
        controller?.setAutoHideSeconds(sender.tag)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            Log.ui.error("launch at login failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Updates

    @objc private func checkForUpdates() {
        Task { [weak self] in
            guard let self, let updates = self.updates else { return }
            self.report(await updates.checkForUser(), from: updates)
        }
    }

    @objc private func toggleUpdateCheck() {
        updates?.isEnabled.toggle()
    }

    @objc private func downloadUpdate() {
        guard let release = updates?.available, let downloader else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let app = try await downloader.deliver(release, into: Self.downloadsDirectory())
                self.reportDownloaded(app, version: release.version)
            } catch {
                self.reportDownloadFailure(error, release: release)
            }
        }
    }

    /// The one alert the daily check may raise, and only the first time a version is seen.
    private func announce(_ release: Release) {
        let response = alert(
            "MenuHider \(release.version) is available",
            """
            You have \(AppInfo.version). Downloading puts a verified copy in your Downloads folder, \
            and you drag it into Applications yourself.

            macOS asks you to confirm it the first time you open it: these builds are not notarized, \
            so that confirmation is the only check standing in for a signature, and opening the new \
            version asks for the Accessibility permission again.
            """,
            buttons: ["Download", "Later", "Skip This Version"])
        switch response {
        case .alertFirstButtonReturn: downloadUpdate()
        case .alertThirdButtonReturn: updates?.skip()
        default: break
        }
    }

    private func report(_ outcome: UpdateOutcome, from updates: UpdateChecker) {
        switch outcome {
        case .upToDate:
            inform("MenuHider \(AppInfo.version) is the newest version.")
        case .available(let release):
            announce(release)
        case .failed(let error):
            let response = alert(
                "The update check failed", error.errorDescription ?? "unknown error",
                buttons: ["OK", "Open Release Page"])
            if response == .alertSecondButtonReturn { NSWorkspace.shared.open(AppInfo.repositoryURL) }
        }
    }

    private func reportDownloaded(_ app: URL, version: ReleaseVersion) {
        // Show where it landed: for a menu bar app the alert may be the only thing the user notices.
        NSWorkspace.shared.activateFileViewerSelecting([app])
        inform(
            "MenuHider \(version) is in \(app.deletingLastPathComponent().lastPathComponent) — drag it into Applications, replacing the old one."
        )
    }

    private func reportDownloadFailure(_ error: Error, release: Release) {
        let detail = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
        Log.update.error("download failed: \(String(describing: error), privacy: .public)")
        let response = alert("The update could not be downloaded", detail, buttons: ["OK", "Open Release Page"])
        if response == .alertSecondButtonReturn { NSWorkspace.shared.open(release.pageURL) }
    }

    /// A menu bar app has no Dock icon and is never frontmost, so it has to come forward before an
    /// alert can be seen at all.
    private func alert(_ title: String, _ body: String, buttons: [String]) -> NSApplication.ModalResponse {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        for button in buttons { alert.addButton(withTitle: button) }
        return alert.runModal()
    }

    private func inform(_ body: String) {
        _ = alert("MenuHider", body, buttons: ["OK"])
    }

    private static func downloadsDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }

    @objc private func openAccessibility() {
        MenuBarScanner.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openRepository() {
        NSWorkspace.shared.open(AppInfo.repositoryURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
