import Foundation

/// Hands the user a verified copy of a release to install by hand.
///
/// This app never replaces its own bundle. The builds are ad-hoc signed, so a download can be
/// checked for being this app, this version, with an intact seal — but not for who published it.
/// Replacing an installed app on that basis would be taking the user's word for it, so the OS's own
/// confirmation stays in the loop instead: the download is marked as coming from the internet, and
/// the user does the dragging.
protocol UpdateDownloading {
    func deliver(_ release: Release, into directory: URL) async throws -> URL
}

struct UpdateDownloader: UpdateDownloading {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // Far looser than the check's: this one carries a file across whatever proxy the
            // network has, and a first byte that takes a moment is not a failure.
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: configuration)
        }
    }

    func deliver(_ release: Release, into directory: URL) async throws -> URL {
        guard FileManager.default.isWritableFile(atPath: directory.path(percentEncoded: false)) else {
            throw UpdateError.destinationNotWritable
        }
        // The image is what the Releases page hands out, so the updater delivers the same thing
        // rather than a zip the user then has to know what to do with. A release without an image
        // still updates through the zip.
        if let image = release.image {
            return try await deliver(image: image, version: release.version, into: directory)
        }
        guard let asset = release.zip else { throw UpdateError.missingZip }

        Log.update.error(
            "downloading \(asset.name, privacy: .public) from \(release.version.description, privacy: .public)")
        let archive = try await download(asset, into: directory)

        // One empty, private directory, so a repackaged archive cannot write outside it.
        let staging = FileManager.default.temporaryDirectory.appending(path: "MenuHiderUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }

        guard
            try await Command.run(
                "/usr/bin/ditto",
                ["-x", "-k", archive.path(percentEncoded: false), staging.path(percentEncoded: false)])
        else { throw UpdateError.downloadFailed }

        // `ditto` recreates whatever the archive held, so the shape is asserted rather than assumed.
        let contents = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard contents.count == 1, let bundle = contents.first, bundle.pathExtension == "app" else {
            throw UpdateError.notThisApp("its archive does not hold exactly one .app")
        }
        try await BundleVerifier.verify(bundle, bundleID: AppInfo.bundleID, version: release.version)

        // The staging directory and the Downloads folder are normally on the same volume, so this is
        // a rename; across volumes it is a copy into a place that holds nothing precious.
        let destination = directory.appending(path: bundle.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: bundle, to: destination)
        // The archive was only ever the wrapper: the app inside it is the deliverable.
        try? FileManager.default.removeItem(at: archive)
        try quarantine(destination)
        Log.update.error("delivered \(destination.path(percentEncoded: false), privacy: .public)")
        return destination
    }

    /// The image path: the user gets the same file the Releases page offers, opened by them.
    private func deliver(image asset: ReleaseAsset, version: ReleaseVersion, into directory: URL) async throws -> URL {
        Log.update.error("downloading \(asset.name, privacy: .public) from \(version.description, privacy: .public)")
        let image = try await download(asset, into: directory)
        try await verifyAppInsideImage(image, expecting: version)
        try quarantine(image)
        Log.update.error("delivered \(image.path(percentEncoded: false), privacy: .public)")
        return image
    }

    /// Checks the image, then the app inside it, then detaches.
    ///
    /// Mounting a downloaded image is the most trusting thing this app does, so the image is
    /// verified first, mounted read-only, and detached on both the success and the failure path —
    /// an image left mounted would sit in the user's Finder sidebar and keep the file busy.
    func verifyAppInsideImage(_ image: URL, expecting version: ReleaseVersion) async throws {
        guard try await Command.run("/usr/bin/hdiutil", ["verify", image.path(percentEncoded: false)]) else {
            throw UpdateError.notThisApp("its disk image is damaged")
        }

        let mountpoint = FileManager.default.temporaryDirectory.appending(path: "MenuHiderImage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountpoint, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: mountpoint) }

        guard
            try await Command.run(
                "/usr/bin/hdiutil",
                [
                    "attach", image.path(percentEncoded: false), "-nobrowse", "-readonly", "-mountpoint",
                    mountpoint.path(percentEncoded: false),
                ])
        else { throw UpdateError.notThisApp("its disk image could not be opened") }

        let outcome: Result<Void, Error>
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: mountpoint, includingPropertiesForKeys: nil)
            guard let bundle = contents.first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError.notThisApp("its disk image holds no app")
            }
            try await BundleVerifier.verify(bundle, bundleID: AppInfo.bundleID, version: version)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        _ = try? await Command.run("/usr/bin/hdiutil", ["detach", mountpoint.path(percentEncoded: false)])
        try outcome.get()
    }

    private func download(_ asset: ReleaseAsset, into directory: URL) async throws -> URL {
        var request = URLRequest(url: asset.url)
        // A cached archive would defeat the version check that follows it.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        let archive = directory.appending(path: asset.name)
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: temporary, to: archive)
        return archive
    }

    /// Mark the download as having come from the internet, exactly as a browser would. With no
    /// signature to check authorship against, this attribute is what keeps macOS's confirmation in
    /// the loop rather than this app vouching for code it cannot verify.
    private func quarantine(_ bundle: URL) throws {
        let value = "0081;\(Int(Date().timeIntervalSince1970));MenuHider;\(UUID().uuidString)"
        let result = value.withCString { pointer in
            setxattr(bundle.path(percentEncoded: false), "com.apple.quarantine", pointer, strlen(pointer), 0, 0)
        }
        // Not fatal: an app that cannot be marked is still an app the user can drag into place, and
        // refusing the whole update over an xattr would be worse than the missing warning.
        if result != 0 {
            Log.update.error("could not mark the download as quarantined: \(errno, privacy: .public)")
        }
    }
}
