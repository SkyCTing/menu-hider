import Foundation

/// Where this app comes from, in one place: the menu, the update check and the release script all
/// have to agree on these, or the check quietly starts looking at the wrong repository.
enum AppInfo {
    static let bundleID = "com.skycting.MenuHider"
    static let repository = "SkyCTing/menu-hider"
    static let repositoryURL = URL(string: "https://github.com/\(repository)")!
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
