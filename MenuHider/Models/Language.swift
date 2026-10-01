import Foundation

/// The language the interface is drawn in. `.system` leaves the choice to macOS, which reads the
/// system preference — and a per-app override set in System Settings — through `Bundle.main`, so
/// there is nothing to resolve by hand.
enum Language: String, CaseIterable {
    case system
    case english
    case chinese

    /// Each case is its own label: a language is always named in itself, whatever the current
    /// interface language is, so nobody has to find their language written in one they cannot read.
    var name: String {
        switch self {
        case .system: return "Follow System"
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }

    /// Where the strings come from. A language whose `.lproj` is missing from the bundle falls back
    /// to the main bundle rather than showing blank labels.
    var bundle: Bundle {
        switch self {
        case .system:
            return .main
        case .english:
            return Self.localizedBundle("en") ?? .main
        case .chinese:
            return Self.localizedBundle("zh-Hans") ?? .main
        }
    }

    private static func localizedBundle(_ identifier: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}
