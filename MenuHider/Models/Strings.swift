import Foundation

/// Every string the interface shows, as a case rather than a raw key: a typo becomes a compile
/// error, and the tests can walk `allCases` to prove both tables carry all of them.
enum Text: String, CaseIterable {
    // The menu and its submenus.
    case showLeftZone = "menu.showLeftZone"
    case showRightZone = "menu.showRightZone"
    case showBothZones = "menu.showBothZones"
    case rescanLayout = "menu.rescanLayout"
    case autoHide = "menu.autoHide"
    case autoHideNever = "menu.autoHide.never"
    case autoHide5 = "menu.autoHide.5"
    case autoHide10 = "menu.autoHide.10"
    case autoHide30 = "menu.autoHide.30"
    case autoHide60 = "menu.autoHide.60"
    case launchAtLogin = "menu.launchAtLogin"
    case checkForUpdates = "menu.checkForUpdates"
    case checkAutomatically = "menu.checkAutomatically"
    case download = "menu.download"
    case openAccessibility = "menu.openAccessibility"
    case language = "menu.language"
    case languageSystem = "menu.language.system"
    case languageEnglish = "menu.language.english"
    case languageChinese = "menu.language.chinese"
    case about = "menu.about"
    case quit = "menu.quit"

    // The status line. The count and the zone names are one sentence per language: assembling them
    // from fragments is how translations end up with English word order.
    case allVisible = "status.allVisible"
    case hidingOne = "status.hiding.one"
    case hidingOther = "status.hiding.other"
    case zonesLeft = "status.zones.left"
    case zonesRight = "status.zones.right"
    case zonesBoth = "status.zones.both"
    case needsAccessibility = "status.needsAccessibility"
    case engineUnavailable = "status.engineUnavailable"
    case error = "status.error"
    case checkFailed = "status.checkFailed"

    // Alerts.
    case updateTitle = "alert.update.title"
    case updateBody = "alert.update.body"
    case updateDownload = "alert.update.download"
    case updateLater = "alert.update.later"
    case updateSkip = "alert.update.skip"
    case upToDate = "alert.upToDate"
    case downloaded = "alert.downloaded"
    case downloadFailed = "alert.downloadFailed"
    case checkFailedTitle = "alert.checkFailed"
    case openReleasePage = "alert.openReleasePage"
    case ok = "alert.ok"

    // Tooltips.
    case tooltipShowLeftZone = "tooltip.showLeftZone"
    case tooltipShowRightZone = "tooltip.showRightZone"
    case tooltipRescan = "tooltip.rescan"
    case tooltipCheckAutomatically = "tooltip.checkAutomatically"
    case tooltipDownload = "tooltip.download"

    // Spoken by VoiceOver.
    case axCollapsed = "ax.state.collapsed"
    case axRightShown = "ax.state.rightShown"
    case axLeftShown = "ax.state.leftShown"
    case axFullyRevealed = "ax.state.fullyRevealed"
    case axBoundary = "ax.boundary"

    // Why an update check or download did not work.
    case errorOffline = "error.offline"
    case errorRateLimited = "error.rateLimited"
    case errorNoRelease = "error.noRelease"
    case errorHTTP = "error.http"
    case errorBadPayload = "error.badPayload"
    case errorMissingZip = "error.missingZip"
    case errorDownloadFailed = "error.downloadFailed"
    case errorNotThisApp = "error.notThisApp"
    case errorBadSignature = "error.badSignature"
    case errorDestinationNotWritable = "error.destinationNotWritable"
}

/// The interface strings for one language, read from that language's table.
struct Strings: Equatable {
    let language: Language
    private let bundle: Bundle

    init(language: Language) {
        self.language = language
        self.bundle = language.bundle
    }

    /// `strings(.showLeftZone)`, or `strings(.hidingOther, count, zones)` for the formatted ones.
    func callAsFunction(_ text: Text, _ arguments: CVarArg...) -> String {
        let format = bundle.localizedString(forKey: text.rawValue, value: nil, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, arguments: arguments)
    }

    /// What the user reads when a check or a download fails. `UpdateError.errorDescription` stays
    /// English: it goes to the log, which is read with `log show` rather than looked at by anyone
    /// using the app.
    func message(for error: UpdateError) -> String {
        switch error {
        case .offline: return self(.errorOffline)
        case .rateLimited: return self(.errorRateLimited)
        case .noRelease: return self(.errorNoRelease)
        case .http(let code): return self(.errorHTTP, code)
        case .badPayload: return self(.errorBadPayload)
        case .missingZip: return self(.errorMissingZip)
        case .downloadFailed: return self(.errorDownloadFailed)
        case .notThisApp(let reason): return self(.errorNotThisApp, reason)
        case .badSignature: return self(.errorBadSignature)
        case .destinationNotWritable: return self(.errorDestinationNotWritable)
        }
    }
}
