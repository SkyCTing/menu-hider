import XCTest

@testable import MenuHider

/// The image path runs `hdiutil` for real against an image built in the test, because mounting is
/// the most trusting thing this app does and the sequence — verify, mount read-only, check the app
/// inside, detach — is worth exercising rather than assuming.
final class UpdateDownloaderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "MenuHiderImage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var runningVersion: ReleaseVersion {
        get throws {
            let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            return try XCTUnwrap(ReleaseVersion(raw))
        }
    }

    /// An image shaped like the released one: a volume holding exactly the app.
    private func makeImage(at image: URL) async throws {
        let contents = scratch.appending(path: "src")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
        try await Command.run(
            "/usr/bin/ditto",
            [
                Bundle.main.bundleURL.path(percentEncoded: false),
                contents.appending(path: "MenuHider.app").path(percentEncoded: false),
            ])
        try await Command.run(
            "/usr/bin/hdiutil",
            [
                "create", "-volname", "MenuHider", "-srcfolder", contents.path(percentEncoded: false), "-ov", "-format",
                "UDZO", image.path(percentEncoded: false),
            ])
    }

    func testAnImageHoldingTheAppVerifiesAndDetaches() async throws {
        let image = scratch.appending(path: "MenuHider.dmg")
        try await makeImage(at: image)

        try await UpdateDownloader().verifyAppInsideImage(image, expecting: try runningVersion)

        let mounted = try await mountedVolumes()
        XCTAssertFalse(mounted.contains("MenuHider"), "the image must not be left mounted")
    }

    func testAnImageHoldingAnotherVersionIsRefused() async throws {
        let image = scratch.appending(path: "MenuHider.dmg")
        try await makeImage(at: image)

        do {
            try await UpdateDownloader().verifyAppInsideImage(image, expecting: try XCTUnwrap(ReleaseVersion("9.9.9")))
            XCTFail("an image of the wrong version must not be offered to the user")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .notThisApp("it is not version 9.9.9"))
        }
        let mounted = try await mountedVolumes()
        XCTAssertFalse(mounted.contains("MenuHider"), "a refused image must be detached too")
    }

    func testSomethingThatIsNotAnImageIsRefused() async throws {
        let notAnImage = scratch.appending(path: "MenuHider.dmg")
        try Data("this is not a disk image".utf8).write(to: notAnImage)

        do {
            try await UpdateDownloader().verifyAppInsideImage(notAnImage, expecting: try runningVersion)
            XCTFail("an unreadable image must not be offered to the user")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .notThisApp("its disk image is damaged"))
        }
    }

    private func mountedVolumes() async throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        return output.split(separator: "\n")
            .filter { $0.contains("/Volumes/") || $0.contains("MenuHiderImage-") }
            .map(String.init)
    }
}
