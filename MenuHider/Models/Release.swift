import Foundation

/// A dotted version, compared numerically: `1.10.0` is newer than `1.9.0`, which a string compare
/// gets wrong. A leading `v` is tolerated because release tags carry one and the bundle version
/// does not, and a tag that is not a version at all reads as nil rather than as an error.
struct ReleaseVersion: Comparable, Equatable, CustomStringConvertible {
    let components: [Int]

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // A channel suffix is dropped: this app ships one stable channel, so `1.0.1-beta` counts as
        // `1.0.1`, and `nightly` — which has no leading digits — is not a version at all.
        let digits = text.prefix { $0.isNumber || $0 == "." }
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        let numbers = parts.map { Int($0) }
        guard numbers.allSatisfy({ $0 != nil }) else { return nil }
        components = numbers.map { $0! }
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    /// Missing components count as zero, so `1.0` and `1.0.0` are the same version — and equality
    /// has to agree with the ordering, or a tag of `v1.0` would look like a different version from
    /// the bundle's `1.0.0`.
    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// One downloadable file attached to a release.
struct ReleaseAsset: Equatable {
    let name: String
    let url: URL
    let byteCount: Int
}

/// A published release, reduced to what the update check needs.
struct Release: Equatable {
    let version: ReleaseVersion
    let pageURL: URL
    let notes: String
    let assets: [ReleaseAsset]

    /// `scripts/release.sh` names the archive `MenuHider-<version>.zip`, with no leading `v` on the
    /// version. Any other zip is accepted as a fallback, and a release without one has no download.
    var zip: ReleaseAsset? {
        assets.first { $0.name == "MenuHider-\(version).zip" }
            ?? assets.first { $0.name.lowercased().hasSuffix(".zip") }
    }

    /// What people expect to install from. The updater prefers this and falls back to the zip, so a
    /// release cut before the image existed still updates.
    var image: ReleaseAsset? {
        assets.first { $0.name == "MenuHider-\(version).dmg" }
            ?? assets.first { $0.name.lowercased().hasSuffix(".dmg") }
    }
}

/// The parts of GitHub's release payload this app reads. `body` really is optional in the API.
struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    let tagName: String
    let htmlURL: URL
    let body: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }

    /// A release whose tag is not a version is not something to update to, and says nothing.
    func release() -> Release? {
        guard let version = ReleaseVersion(tagName) else { return nil }
        return Release(
            version: version, pageURL: htmlURL, notes: body ?? "",
            assets: assets.map { ReleaseAsset(name: $0.name, url: $0.browserDownloadURL, byteCount: $0.size) })
    }
}
