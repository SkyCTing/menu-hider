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
    private static let autoHideChoices: [(seconds: Int, text: Text)] = [
        (0, .autoHideNever), (5, .autoHide5), (10, .autoHide10), (30, .autoHide30), (60, .autoHide60),
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
    /// The interface strings, rebuilt when the language changes: the menu is redrawn on every open,
    /// so the switch takes effect without a relaunch.
    private var strings: Strings

    override init() {
        strings = Strings(language: Settings.shared.language)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        leftSeparator = NSStatusBar.system.statusItem(withLength: 12)
        super.init()
        menu.delegate = self
        configure(statusItem, autosaveName: "MenuHiderSeparator")
        configure(leftSeparator, autosaveName: "MenuHiderLeftSeparator")
        leftSeparator.button?.image = Self.boundaryImage(description: strings(.axBoundary))
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
        let description = strings(Self.description(for: state))
        // A nil symbol would leave the switch blank and looking dead, so fall back to one that has
        // been in SF Symbols since the first release.
        let image = Self.symbol(name, description: description) ?? Self.symbol("chevron.left", description: description)
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

    /// Spoken by VoiceOver, so the wording describes the icon's state rather than naming it.
    static func description(for state: HidingController.State) -> Text {
        switch state {
        case .collapsed: return .axCollapsed
        case .rightRevealed: return .axRightShown
        case .leftRevealed: return .axLeftShown
        case .fullyRevealed: return .axFullyRevealed
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
    private static func boundaryImage(description: String) -> NSImage {
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
        image.accessibilityDescription = description
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
                item(strings(.openAccessibility), symbol: "hand.raised", action: #selector(openAccessibility)))
        }
        menu.addItem(.separator())

        let left = item(strings(.showLeftZone), symbol: nil, action: #selector(toggleLeft))
        left.state = controller.state.leftRevealed ? .on : .off
        left.toolTip = strings(.tooltipShowLeftZone)
        menu.addItem(left)

        let right = item(strings(.showRightZone), symbol: nil, action: #selector(toggleRight))
        right.state = controller.state.rightRevealed ? .on : .off
        right.toolTip = strings(.tooltipShowRightZone)
        menu.addItem(right)

        let both = item(strings(.showBothZones), symbol: "eye", action: #selector(revealAll))
        both.isEnabled = !controller.state.isFullyRevealed
        menu.addItem(both)

        let rescan = item(strings(.rescanLayout), symbol: "arrow.clockwise", action: #selector(refresh))
        rescan.toolTip = strings(.tooltipRescan)
        menu.addItem(rescan)
        menu.addItem(.separator())

        menu.addItem(autoHideMenu())
        let login = item(strings(.launchAtLogin), symbol: nil, action: #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        addUpdateItems(to: menu)
        menu.addItem(languageMenu())
        menu.addItem(.separator())

        menu.addItem(item(strings(.about), symbol: nil, action: #selector(openRepository)))
        menu.addItem(item(strings(.quit), symbol: nil, action: #selector(quit), keyEquivalent: "q"))
    }

    /// Built fresh on every open, because the menu is rebuilt from scratch each time and the answer
    /// to "is there an update" changes under it.
    private func addUpdateItems(to menu: NSMenu) {
        guard let updates else { return }

        if let release = updates.available {
            let download = item(
                strings(.download, release.version.description), symbol: "arrow.down.circle",
                action: #selector(downloadUpdate))
            download.toolTip = strings(.tooltipDownload)
            menu.addItem(download)
        } else if let error = updates.lastError {
            let failed = item(strings(.checkFailed, strings.message(for: error)), symbol: nil, action: nil)
            failed.isEnabled = false
            menu.addItem(failed)
        }

        menu.addItem(item(strings(.checkForUpdates), symbol: nil, action: #selector(checkForUpdates)))

        let automatic = item(strings(.checkAutomatically), symbol: nil, action: #selector(toggleUpdateCheck))
        automatic.state = updates.isEnabled ? .on : .off
        automatic.toolTip = strings(.tooltipCheckAutomatically)
        menu.addItem(automatic)
    }

    /// A language is always named in itself, whatever the interface is currently in, so nobody has
    /// to find their own language written in one they cannot read.
    private func languageMenu() -> NSMenuItem {
        let parent = item(strings(.language), symbol: "globe", action: nil)
        let submenu = NSMenu()
        for language in Language.allCases {
            let entry = item(language.name, symbol: nil, action: #selector(setLanguage(_:)))
            entry.representedObject = language.rawValue
            entry.state = controller?.settings.language == language ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    private func header(_ controller: HidingController) -> NSMenuItem {
        let status: String
        let symbol: String
        if !controller.isEngineAvailable {
            status = strings(.engineUnavailable)
            symbol = "exclamationmark.triangle"
        } else if !controller.isAccessibilityTrusted {
            status = strings(.needsAccessibility)
            symbol = "exclamationmark.triangle"
        } else if let error = controller.lastError {
            status = strings(.error, error.localizedDescription)
            symbol = "exclamationmark.triangle"
        } else if controller.hiddenCount == 0 {
            status = strings(.allVisible)
            symbol = "eye"
        } else {
            let count = controller.hiddenCount
            status = strings(count == 1 ? .hidingOne : .hidingOther, count, collapsedZones(controller))
            symbol = "eye.slash"
        }
        let line = item(status, symbol: symbol, action: nil)
        line.isEnabled = false
        return line
    }

    /// Names the zones the count comes from, so a half-collapsed bar is not a mystery. One whole
    /// phrase per case rather than pieces joined with a separator: the pieces would not survive
    /// translation.
    private func collapsedZones(_ controller: HidingController) -> String {
        let zones = controller.zones
        let left = !controller.state.leftRevealed && !zones.left.isEmpty
        let right = !controller.state.rightRevealed && !zones.right.isEmpty
        switch (left, right) {
        case (true, true): return strings(.zonesBoth)
        case (true, false): return strings(.zonesLeft)
        case (false, true): return strings(.zonesRight)
        case (false, false): return ""
        }
    }

    private func autoHideMenu() -> NSMenuItem {
        let parent = item(strings(.autoHide), symbol: "timer", action: nil)
        let submenu = NSMenu()
        for choice in Self.autoHideChoices {
            let entry = item(strings(choice.text), symbol: nil, action: #selector(setAutoHide(_:)))
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
            strings(.updateTitle, release.version.description),
            strings(.updateBody, AppInfo.version),
            buttons: [strings(.updateDownload), strings(.updateLater), strings(.updateSkip)])
        switch response {
        case .alertFirstButtonReturn: downloadUpdate()
        case .alertThirdButtonReturn: updates?.skip()
        default: break
        }
    }

    private func report(_ outcome: UpdateOutcome, from updates: UpdateChecker) {
        switch outcome {
        case .upToDate:
            inform(strings(.upToDate, AppInfo.version))
        case .available(let release):
            announce(release)
        case .failed(let error):
            let response = alert(
                strings(.checkFailedTitle), strings.message(for: error),
                buttons: [strings(.ok), strings(.openReleasePage)])
            if response == .alertSecondButtonReturn { NSWorkspace.shared.open(AppInfo.repositoryURL) }
        }
    }

    private func reportDownloaded(_ delivered: URL, version: ReleaseVersion) {
        // Show where it landed: for a menu bar app the alert may be the only thing the user notices.
        NSWorkspace.shared.activateFileViewerSelecting([delivered])
        // An image has to be opened before it can be dragged from; the zip fallback leaves the app
        // itself in place, ready to drag.
        let text: Text = delivered.pathExtension.lowercased() == "dmg" ? .downloadedImage : .downloaded
        inform(strings(text, version.description, delivered.deletingLastPathComponent().lastPathComponent))
    }

    private func reportDownloadFailure(_ error: Error, release: Release) {
        let detail = (error as? UpdateError).map { strings.message(for: $0) } ?? error.localizedDescription
        Log.update.error("download failed: \(String(describing: error), privacy: .public)")
        let response = alert(
            strings(.downloadFailed), detail, buttons: [strings(.ok), strings(.openReleasePage)])
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
        _ = alert("MenuHider", body, buttons: [strings(.ok)])
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = Language(rawValue: raw) else { return }
        controller?.settings.language = language
        strings = Strings(language: language)
        Log.ui.error("language → \(language.rawValue, privacy: .public)")
        // The menu is rebuilt on its next open, and the icon's spoken description follows now.
        stateChanged()
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
