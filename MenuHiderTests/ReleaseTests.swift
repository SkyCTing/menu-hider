import XCTest

@testable import MenuHider

final class ReleaseVersionTests: XCTestCase {
    func testComparesNumericallyRatherThanAlphabetically() {
        let newer = ReleaseVersion("1.10.0")!
        let older = ReleaseVersion("1.9.0")!

        XCTAssertTrue(newer > older, "string order would put 1.9.0 first and offer a downgrade")
    }

    func testALeadingVIsTolerated() {
        XCTAssertEqual(ReleaseVersion("v1.2.3"), ReleaseVersion("1.2.3"))
        XCTAssertEqual(ReleaseVersion("V1.2.3"), ReleaseVersion("1.2.3"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertEqual(ReleaseVersion("1.0"), ReleaseVersion("1.0.0"))
        XCTAssertFalse(ReleaseVersion("1.0")! < ReleaseVersion("1.0.0")!)
        XCTAssertFalse(ReleaseVersion("1.0.0")! < ReleaseVersion("1.0")!)
    }

    func testAChannelSuffixIsIgnored() {
        XCTAssertEqual(ReleaseVersion("1.0.1-beta.2"), ReleaseVersion("1.0.1"))
    }

    func testATagThatIsNotAVersionIsRefused() {
        XCTAssertNil(ReleaseVersion("nightly"))
        XCTAssertNil(ReleaseVersion("release"))
        XCTAssertNil(ReleaseVersion("v"))
        XCTAssertNil(ReleaseVersion("1.x.0"))
        XCTAssertNil(ReleaseVersion(""))
    }

    func testDescribesItselfTheWayTheBundleDoes() {
        XCTAssertEqual(ReleaseVersion("v1.2.3")?.description, "1.2.3", "the tag carries a v, the version does not")
    }
}

final class ReleaseTests: XCTestCase {
    private func release(tag: String, assets: [(name: String, size: Int)]) -> Release? {
        let json = """
            {
              "tag_name": "\(tag)",
              "html_url": "https://github.com/SkyCTing/menu-hider/releases/tag/\(tag)",
              "body": "notes",
              "assets": [
                \(assets.map { #"{"name": "\#($0.name)", "browser_download_url": "https://example.com/\#($0.name)", "size": \#($0.size)}"# }
                    .joined(separator: ","))
              ]
            }
            """
        guard let payload = try? JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8)) else { return nil }
        return payload.release()
    }

    func testTheArchiveNamedAfterTheVersionIsPreferred() {
        let release = release(
            tag: "v1.1.0", assets: [("checksums.txt", 10), ("MenuHider-1.1.0.zip", 20), ("other.zip", 30)])!

        XCTAssertEqual(release.version.description, "1.1.0")
        XCTAssertEqual(release.zip?.name, "MenuHider-1.1.0.zip")
        XCTAssertEqual(release.notes, "notes")
    }

    func testAnyOtherZipIsAcceptedAsAFallback() {
        let release = release(tag: "v1.1.0", assets: [("MenuHider.zip", 20), ("checksums.txt", 10)])!

        XCTAssertEqual(release.zip?.name, "MenuHider.zip")
    }

    func testAReleaseWithoutAZipHasNoDownload() {
        let release = release(tag: "v1.1.0", assets: [("checksums.txt", 10)])!

        XCTAssertNil(release.zip, "the menu then offers the release page rather than a download")
    }

    func testAReleaseWhoseTagIsNotAVersionIsIgnored() {
        XCTAssertNil(release(tag: "nightly", assets: [("MenuHider-nightly.zip", 20)]))
    }

    func testMissingBodyReadsAsEmptyNotes() throws {
        let json = """
            {"tag_name": "v1.1.0", "html_url": "https://example.com", "body": null, "assets": []}
            """
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))

        XCTAssertEqual(payload.release()?.notes, "")
    }
}
