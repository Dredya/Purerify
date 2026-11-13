import Foundation

enum ServerConverterError: LocalizedError {
    case invalidURL
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid server URL."
        case .invalidResponse:
            return "The server returned an unexpected response."
        case let .server(message):
            return message
        }
    }
}

struct ServerConvertResponse: Decodable {
    let id: String
    let title: String
    let author: String?
    let audioUrl: String
    let contentLength: Int?
    let userAgent: String?
    let clientName: String?
}

enum ServerConverter {
    private static let baseKey = "PurerifyServerBaseURL"

    static var baseURLString: String {
        UserDefaults.standard.string(forKey: baseKey) ?? "https://192.168.1.6:8443"
    }

    static func setBaseURL(_ value: String) {
        UserDefaults.standard.set(value, forKey: baseKey)
    }

    static var baseURL: URL {
        URL(string: baseURLString) ?? URL(string: "https://192.168.1.6:8443")!
    }

    static func convert(_ input: String) async throws -> ResolvedVideo {
        let endpoint = baseURL.appendingPathComponent("convert")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["url": input])

        let (data, response) = try await ServerNetwork.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServerConverterError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = object["detail"] as? String {
                throw ServerConverterError.server(detail)
            }
            throw ServerConverterError.server("Server returned HTTP \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(ServerConvertResponse.self, from: data)
        guard let audioURL = URL(string: decoded.audioUrl) else {
            throw ServerConverterError.invalidResponse
        }

        return ResolvedVideo(
            id: decoded.id,
            title: decoded.title,
            author: decoded.author ?? "",
            audioURL: audioURL,
            audioBitrate: nil,
            contentLength: decoded.contentLength,
            userAgent: decoded.userAgent ?? "",
            clientName: decoded.clientName ?? "server"
        )
    }
}

/// Development-only session that accepts self-signed certificates (e.g. the local HTTPS server).
final class ServerNetworkDelegate: NSObject, URLSessionTaskDelegate, Sendable {
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
}

enum ServerNetwork {
    static let session: URLSession = {
        URLSession(configuration: .default, delegate: ServerNetworkDelegate(), delegateQueue: nil)
    }()
}

struct SpotifyTrackInfo: Decodable {
    let title: String
    let artist: String
    let album: String?
    let durationMs: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case artist
        case album
        case durationMs = "durationMs"
    }
}

struct SpotifyPlaylistInfo: Decodable {
    let name: String
    let tracks: [SpotifyTrackInfo]
}

struct YouTubeSearchResult: Decodable {
    let id: String
    let title: String
    let author: String
    let url: String
}

extension ServerConverter {
    static func fetchSpotifyPlaylist(_ url: String) async throws -> SpotifyPlaylistInfo {
        let endpoint = baseURL.appendingPathComponent("spotify/playlist")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["url": url])
        let (data, response) = try await ServerNetwork.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServerConverterError.invalidResponse
        }
        return try JSONDecoder().decode(SpotifyPlaylistInfo.self, from: data)
    }

    static func searchYouTube(query: String) async throws -> YouTubeSearchResult {
        let endpoint = baseURL.appendingPathComponent("search/youtube")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, response) = try await ServerNetwork.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServerConverterError.invalidResponse
        }
        return try JSONDecoder().decode(YouTubeSearchResult.self, from: data)
    }
}