import Foundation

/// Runs a tool and reports whether it succeeded, off the main actor: unpacking and signature
/// verification take long enough that blocking the menu bar would be visible.
enum Command {
    static func run(_ executable: String, _ arguments: [String]) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            // The output is not read: a pipe nobody drains can fill up and hang the child.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Checks what can honestly be checked about a downloaded bundle: that it really is this app, that
/// it is complete, and that its signature is intact. The builds are ad-hoc signed, so nothing here
/// can prove who published it, and this does not pretend otherwise.
enum BundleVerifier {
    static func verify(_ bundle: URL, bundleID: String, version: ReleaseVersion) async throws {
        let info = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw UpdateError.notThisApp("it has no readable Info.plist") }

        guard plist["CFBundlePackageType"] as? String == "APPL" else {
            throw UpdateError.notThisApp("it is not an application bundle")
        }
        guard plist["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError.notThisApp("its bundle identifier is not \(bundleID)")
        }
        guard ReleaseVersion(plist["CFBundleShortVersionString"] as? String ?? "") == version else {
            throw UpdateError.notThisApp("it is not version \(version)")
        }
        // A bundle whose declared executable is missing is exactly the half-unpacked state worth
        // refusing: a running process keeps executing a binary that is already gone.
        guard let executable = plist["CFBundleExecutable"] as? String,
            FileManager.default.isExecutableFile(
                atPath: bundle.appending(path: "Contents/MacOS/\(executable)").path(percentEncoded: false))
        else { throw UpdateError.notThisApp("the executable its Info.plist names is missing") }

        try refuseSymlinksLeaving(bundle)

        // --strict, and deliberately not --deep, which Apple documents as unreliable for
        // verification. `spctl` is not used either: an ad-hoc build fails Gatekeeper assessment by
        // design, so asking it would reject legitimate updates.
        guard
            try await Command.run(
                "/usr/bin/codesign", ["--verify", "--strict", bundle.path(percentEncoded: false)])
        else { throw UpdateError.badSignature }
    }

    /// A symlink pointing outside the bundle is how a repackaged download smuggles in a target the
    /// reader never sees. This app installs nothing itself, but it does hand the user an app to drag
    /// into place, so the archive has to be what it looks like.
    private static func refuseSymlinksLeaving(_ bundle: URL) throws {
        guard
            let walker = FileManager.default.enumerator(
                at: bundle, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
        else { return }
        for case let entry as URL in walker {
            guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path(percentEncoded: false))
            guard !target.hasPrefix("/") else {
                throw UpdateError.notThisApp("it contains an absolute symlink")
            }
            let resolved = entry.deletingLastPathComponent().appending(path: target).standardizedFileURL
            guard
                resolved.path(percentEncoded: false)
                    .hasPrefix(bundle.standardizedFileURL.path(percentEncoded: false))
            else { throw UpdateError.notThisApp("it contains a symlink pointing outside itself") }
        }
    }
}
