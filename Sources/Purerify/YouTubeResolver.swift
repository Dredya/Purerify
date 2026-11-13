import Foundation

struct ResolvedVideo: Sendable {
    let id: String
    let title: String
    let author: String
    let audioURL: URL
    let audioBitrate: Int?
    let contentLength: Int?
    /// The User-Agent of the client that resolved this URL. googlevideo rejects (403)
    /// downloads whose User-Agent does not match the client that requested the stream.
    let userAgent: String
    let clientName: String
    /// True for URLs captured from the hidden web player (PO token included). These use
    /// the `range` query parameter and m.youtube.com Origin/Referer.
    var isWebStream = false
}

/// An InnerTube client identity. Streams resolved by one client must be downloaded
/// with that same client's User-Agent.
struct InnerTubeClient: Sendable {
    let name: String
    let id: String
    let version: String
    let userAgent: String
    let extra: [String: any Sendable]

    /// Tried in order. Tested Nov 2026: IOS and ANDROID serve the whole file (past 1 MB
    /// googlevideo answers 302 redirects, which must be followed). ANDROID_VR was removed:
    /// it 403s after the first 1 MB without a PO token and is often bot-checked.
    static let all: [InnerTubeClient] = [
        InnerTubeClient(
            name: "IOS",
            id: "5",
            version: "20.10.4",
            userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            extra: [
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "18.3.2.22D82",
            ]
        ),
        InnerTubeClient(
            name: "ANDROID",
            id: "3",
            version: "20.10.38",
            userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip",
            extra: [
                "androidSdkVersion": 34,
                "osName": "Android",
                "osVersion": "14",
            ]
        ),
    ]
}

enum YouTubeResolverError: LocalizedError {
    case invalidURL
    case unavailable(String)
    case noCompatibleAudio
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid YouTube video link."
        case let .unavailable(reason):
            return reason.isEmpty ? "This video is unavailable." : reason
        case .noCompatibleAudio:
            return "No downloadable AAC audio was found. YouTube may have changed its response or may require sign-in."
        case .invalidResponse:
            return "YouTube returned an unexpected response. Try again later."
        }
    }
}

/// A cookieless, cacheless session, matching the PC test that downloads successfully.
/// The shared session stored YouTube cookies (and we sent a saved visitorData) which
/// tied every request to an identity YouTube had flagged, so streams came back 403.
enum YouTubeNetwork {
    static let session: URLSession = {
        // Drop the visitorData older builds saved.
        UserDefaults.standard.removeObject(forKey: "PurerifyVisitorData")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
}

enum YouTubeResolver {
    private static let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!

    private static func isBotCheck(_ error: Error) -> Bool {
        guard case let YouTubeResolverError.unavailable(reason) = error else { return false }
        let lower = reason.lowercased()
        return lower.contains("bot") || lower.contains("sign in")
    }

    /// Resolves with the first client that returns playable AAC audio.
    /// `skipping` lets the downloader retry with the next client after a 403.
    static func resolve(_ input: String, skipping skipped: Set<String> = []) async throws -> ResolvedVideo {
        guard let videoID = extractVideoID(from: input) else {
            throw YouTubeResolverError.invalidURL
        }

        var failures: [String] = []
        for client in InnerTubeClient.all where !skipped.contains(client.name) {
            do {
                return try await resolve(videoID: videoID, client: client)
            } catch let error where isBotCheck(error) {
                // Bot checks are often transient; one retry usually passes.
                do {
                    return try await resolve(videoID: videoID, client: client)
                } catch {
                    failures.append("\(client.name): \(error.localizedDescription)")
                }
            } catch {
                failures.append("\(client.name): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty { throw YouTubeResolverError.noCompatibleAudio }
        throw YouTubeResolverError.unavailable(failures.joined(separator: "\n"))
    }

    private static func resolve(videoID: String, client: InnerTubeClient) async throws -> ResolvedVideo {
        var clientContext: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "hl": "en",
        ]
        for (key, value) in client.extra { clientContext[key] = value }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(client.id, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": clientContext],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ])

        let (data, response) = try await YouTubeNetwork.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw YouTubeResolverError.invalidResponse
        }

        let player = try JSONDecoder().decode(PlayerResponse.self, from: data)
        guard player.playabilityStatus?.status == "OK" else {
            throw YouTubeResolverError.unavailable(
                player.playabilityStatus?.reason ?? "YouTube could not play this video."
            )
        }

        let audioFormats = (player.streamingData?.adaptiveFormats ?? [])
            .filter { format in
                format.mimeType?.hasPrefix("audio/mp4") == true && format.url != nil
            }
            .sorted { lhs, rhs in
                if lhs.itag == 140 { return true }
                if rhs.itag == 140 { return false }
                return (lhs.bitrate ?? 0) > (rhs.bitrate ?? 0)
            }

        guard let audio = audioFormats.first,
              let rawURL = audio.url,
              let audioURL = URL(string: rawURL) else {
            throw YouTubeResolverError.noCompatibleAudio
        }

        return ResolvedVideo(
            id: videoID,
            title: player.videoDetails?.title ?? "YouTube audio",
            author: player.videoDetails?.author ?? "",
            audioURL: audioURL,
            audioBitrate: audio.bitrate,
            contentLength: audio.contentLength.flatMap { Int($0) },
            userAgent: client.userAgent,
            clientName: client.name
        )
    }

    private static func extractVideoID(from input: String) -> String? {
        guard let url = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else {
            return nil
        }

        let allowedHosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtube-nocookie.com"]
        guard allowedHosts.contains(host) else { return nil }

        let candidate: String?
        if host == "youtu.be" {
            candidate = url.path.split(separator: "/").first.map(String.init)
        } else if url.path == "/watch" {
            candidate = url.queryItems?.first(where: { $0.name == "v" })?.value
        } else {
            let components = url.path.split(separator: "/")
            if let markerIndex = components.firstIndex(where: { ["shorts", "live", "embed", "v"].contains($0) }),
               components.indices.contains(markerIndex + 1) {
                candidate = String(components[markerIndex + 1])
            } else {
                candidate = nil
            }
        }

        guard let candidate,
              candidate.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return candidate
    }
}

private struct PlayerResponse: Decodable {
    let responseContext: ResponseContext?
    let playabilityStatus: PlayabilityStatus?
    let videoDetails: VideoDetails?
    let streamingData: StreamingData?
}

private struct ResponseContext: Decodable {
    let visitorData: String?
}

private struct PlayabilityStatus: Decodable {
    let status: String?
    let reason: String?
}

private struct VideoDetails: Decodable {
    let title: String?
    let author: String?
}

private struct StreamingData: Decodable {
    let adaptiveFormats: [StreamingFormat]?
}

private struct StreamingFormat: Decodable {
    let itag: Int
    let mimeType: String?
    let bitrate: Int?
    let url: String?
    let contentLength: String?
}

// MARK: - Download

enum AudioDownloaderError: LocalizedError {
    case http(Int, client: String)
    case empty

    var errorDescription: String? {
        switch self {
        case let .http(code, client):
            return "YouTube's media server returned HTTP \(code) (client \(client))."
        case .empty:
            return "The server returned no audio data."
        }
    }
}

/// Keeps our User-Agent and Range headers when googlevideo redirects (302) to another host.
private final class HeaderPreservingRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        var redirected = request
        for header in ["User-Agent", "Range", "Accept", "Origin", "Referer"] {
            if let value = task.originalRequest?.value(forHTTPHeaderField: header) {
                redirected.setValue(value, forHTTPHeaderField: header)
            }
        }
        return redirected
    }
}

enum AudioDownloader {
    /// googlevideo rejects requests for more than ~1 MB at a time, so fetch in
    /// small chunks using the HTTP Range header (not the query parameter).
    private static let chunkSize = 512 * 1024
    private static let redirects = HeaderPreservingRedirects()
    private static let maxRefreshes = 3

    /// Downloads in chunks. If a chunk gets 403 midway (expired/limited URL), asks
    /// `refresh` for a fresh URL and resumes from the same byte offset.
    static func download(
        _ video: ResolvedVideo,
        to destination: URL,
        input: String
    ) async throws {
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".part")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: tempURL.path
        )
        let handle = try FileHandle(forWritingTo: tempURL)
        var finished = false
        defer {
            try? handle.close()
            if !finished { try? FileManager.default.removeItem(at: tempURL) }
        }

        var video = video
        var refreshes = 0
        var start = 0
        while true {
            let end = start + chunkSize - 1
            let chunk: Data
            do {
                chunk = try await fetch(video, start: start, end: end)
            } catch AudioDownloaderError.http(403, _) where start > 0 && refreshes < maxRefreshes && !video.isWebStream {
                refreshes += 1
                let skipOthers = Set(InnerTubeClient.all.map(\.name)).subtracting([video.clientName])
                video = try await YouTubeResolver.resolve(input, skipping: skipOthers)
                continue
            }
            if chunk.isEmpty { break }
            try handle.write(contentsOf: chunk)
            start += chunk.count

            if let total = video.contentLength {
                if start >= total { break }
            } else if chunk.count < chunkSize {
                break
            }
        }

        guard start > 0 else { throw AudioDownloaderError.empty }
        try handle.close()

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
        finished = true
    }

    private static func fetch(_ video: ResolvedVideo, start: Int, end: Int) async throws -> Data {
        var url = video.audioURL
        if video.isWebStream,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = components.percentEncodedQueryItems ?? []
            items.removeAll { $0.name == "range" }
            items.append(URLQueryItem(name: "range", value: "\(start)-\(end)"))
            components.percentEncodedQueryItems = items
            url = components.url ?? url
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(video.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if video.isWebStream {
            request.setValue("https://m.youtube.com", forHTTPHeaderField: "Origin")
            request.setValue("https://m.youtube.com/", forHTTPHeaderField: "Referer")
        } else {
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        }

        let (data, response) = try await YouTubeNetwork.session.data(for: request, delegate: redirects)
        if let http = response as? HTTPURLResponse {
            if http.statusCode != 206 && http.statusCode != 200 {
                throw AudioDownloaderError.http(http.statusCode, client: "\(video.clientName) at \(start / 1024) KB")
            }
        }
        return data
    }
}
