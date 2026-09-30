import Foundation

final class Settings {
    static let shared = Settings()

    private let defaults: UserDefaults
    private enum Key {
        static let autoHideSeconds = "autoHideSeconds"
        /// The right zone. The key name predates the two-zone layout and is kept verbatim: the old
        /// value already meant "third-party icons between `|` and `»`", so an update reads a correct
        /// warm start and a downgrade still finds a meaningful value.
        static let hiddenBundleIDs = "hiddenBundleIDs"
        static let hiddenLeftBundleIDs = "hiddenLeftBundleIDs"
        static let removedMenuExtraIDs = "removedMenuExtraIDs"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.autoHideSeconds: 10])
    }

    /// 0 disables the auto-hide timer.
    var autoHideSeconds: Int {
        get { defaults.integer(forKey: Key.autoHideSeconds) }
        set { defaults.set(newValue, forKey: Key.autoHideSeconds) }
    }

    /// Last computed zones: let the app hide before the first Accessibility scan.
    var zones: HiddenSet.Zones {
        get { HiddenSet.Zones(left: hiddenLeftBundleIDs, right: hiddenRightBundleIDs) }
        set {
            hiddenLeftBundleIDs = newValue.left
            hiddenRightBundleIDs = newValue.right
        }
    }

    /// The right zone: third-party icons between `|` and `»`.
    var hiddenRightBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.hiddenBundleIDs) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.hiddenBundleIDs) }
    }

    /// The left zone: third-party icons left of `|`.
    var hiddenLeftBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.hiddenLeftBundleIDs) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.hiddenLeftBundleIDs) }
    }

    var removedMenuExtraIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.removedMenuExtraIDs) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.removedMenuExtraIDs) }
    }
}
