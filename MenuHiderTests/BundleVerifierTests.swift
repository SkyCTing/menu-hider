import XCTest

@testable import MenuHider

/// Integration tests on purpose: they run `ditto` and `codesign` for real, against the built app,
/// because the whole point of the verifier is how those tools behave on an ad-hoc signed bundle.
/// None of them touch /Applications or the permission database.
final class BundleVerifierTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "MenuHiderVerifier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The test host is MenuHider.app, so the bundle under test is the app the tests are running in.
    private var runningBundle: URL { Bundle.main.bundleURL }

    private var runningVersion: ReleaseVersion {
        get throws {
            let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            return try XCTUnwrap(ReleaseVersion(raw))
        }
    }

    func testTheRunningBundleVerifies() async throws {
        try await BundleVerifier.verify(runningBundle, bundleID: AppInfo.bundleID, version: try runningVersion)
    }

    func testAWaitingVersionIsRefused() async throws {
        let expected = try XCTUnwrap(ReleaseVersion("9.9.9"))

        do {
            try await BundleVerifier.verify(runningBundle, bundleID: AppInfo.bundleID, version: expected)
            XCTFail("a bundle of the wrong version must not be offered to the user")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .notThisApp("it is not version 9.9.9"))
        }
    }

    func testAnotherAppsBundleIsRefused() async throws {
        do {
            try await BundleVerifier.verify(
                runningBundle, bundleID: "com.example.somethingelse", version: try runningVersion)
            XCTFail("a bundle with the wrong identifier must not be offered to the user")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .notThisApp("its bundle identifier is not com.example.somethingelse"))
        }
    }

    /// The seal check has to have teeth: an archive that was repackaged after signing must fail even
    /// though its identifier and version still look right.
    func testATamperedCopyFailsTheSealCheck() async throws {
        let copy = scratch.appending(path: "MenuHider.app")
        try await Command.run(
            "/usr/bin/ditto", [runningBundle.path(percentEncoded: false), copy.path(percentEncoded: false)])
        let info = copy.appending(path: "Contents/Info.plist")
        try await Command.run(
            "/usr/libexec/PlistBuddy",
            ["-c", "Set :CFBundleShortVersionString 9.9.9", info.path(percentEncoded: false)])

        do {
            try await BundleVerifier.verify(
                copy, bundleID: AppInfo.bundleID, version: try XCTUnwrap(ReleaseVersion("9.9.9")))
            XCTFail("editing the bundle after signing must break the seal")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .badSignature)
        }
    }

    /// The archive round trip is what keeps the signature readable. Losing it here is how an update
    /// ships an app that Gatekeeper will refuse, so it is checked rather than assumed.
    func testADittoRoundTripKeepsTheBundleVerifiable() async throws {
        let archive = scratch.appending(path: "MenuHider.zip")
        let staging = scratch.appending(path: "staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)

        try await Command.run(
            "/usr/bin/ditto",
            [
                "-c", "-k", "--keepParent", runningBundle.path(percentEncoded: false),
                archive.path(percentEncoded: false),
            ])
        try await Command.run(
            "/usr/bin/ditto", ["-x", "-k", archive.path(percentEncoded: false), staging.path(percentEncoded: false)])

        let unpacked = staging.appending(path: "MenuHider.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpacked.path(percentEncoded: false)))
        try await BundleVerifier.verify(unpacked, bundleID: AppInfo.bundleID, version: try runningVersion)
    }

    func testASymlinkLeavingTheBundleIsRefused() async throws {
        let copy = scratch.appending(path: "MenuHider.app")
        try await Command.run(
            "/usr/bin/ditto", [runningBundle.path(percentEncoded: false), copy.path(percentEncoded: false)])
        let escape = copy.appending(path: "Contents/escape")
        try FileManager.default.createSymbolicLink(
            atPath: escape.path(percentEncoded: false), withDestinationPath: "/etc/hosts")

        do {
            try await BundleVerifier.verify(copy, bundleID: AppInfo.bundleID, version: try runningVersion)
            XCTFail("an archive that reaches outside itself must not be handed over")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .notThisApp("it contains an absolute symlink"))
        }
    }
}
