import Foundation

enum UpdateError: LocalizedError, Equatable {
    /// No usable network: nothing to report, the check just happens again tomorrow.
    case offline
    /// GitHub's unauthenticated quota is per address and shared with anything else on it: back off
    /// quietly rather than telling the user about someone else's traffic.
    case rateLimited
    case noRelease
    case http(Int)
    case badPayload
    case missingZip
    case downloadFailed
    case notThisApp(String)
    case badSignature
    case destinationNotWritable

    var errorDescription: String? {
        switch self {
        case .offline: return "No network connection."
        case .rateLimited: return "GitHub is rate limiting the update check. It will try again later."
        case .noRelease: return "The release could not be found."
        case .http(let code): return "GitHub answered with HTTP \(code)."
        case .badPayload: return "GitHub's answer could not be read."
        case .missingZip: return "That release has no download attached."
        case .downloadFailed: return "The download did not finish."
        case .notThisApp(let reason): return "The download is not a usable MenuHider: \(reason)"
        case .badSignature: return "The downloaded app's signature is not intact."
        case .destinationNotWritable: return "The Downloads folder cannot be written to."
        }
    }
}

/// Fetches the newest published release. Behind a protocol so tests never touch the network.
protocol ReleaseFetching {
    func latestRelease() async throws -> Release
}

struct GitHubReleases: ReleaseFetching {
    /// The check runs behind a menu, so it must not sit on a minute-long default timeout.
    private static let requestTimeout: TimeInterval = 15

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func latestRelease() async throws -> Release {
        var request = URLRequest(url: AppInfo.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub rejects requests without a User-Agent, and it must not identify the user.
        request.setValue("MenuHider/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.requestTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            Log.update.error("release request failed: \(error.code.rawValue, privacy: .public)")
            throw error.code == .notConnectedToInternet || error.code == .networkConnectionLost
                || error.code == .cannotFindHost || error.code == .timedOut
                ? UpdateError.offline : UpdateError.downloadFailed
        }

        guard let http = response as? HTTPURLResponse else { throw UpdateError.badPayload }
        switch http.statusCode {
        case 200: break
        case 403, 429: throw UpdateError.rateLimited
        case 404: throw UpdateError.noRelease
        default: throw UpdateError.http(http.statusCode)
        }
        guard let payload = try? JSONDecoder().decode(GitHubRelease.self, from: data),
            let release = payload.release()
        else { throw UpdateError.badPayload }
        return release
    }
}
