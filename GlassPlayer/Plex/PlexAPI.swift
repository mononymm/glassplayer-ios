import Foundation
import UIKit
import Security

enum PlexError: LocalizedError {
    case http(Int)
    case noServer
    case unreachable
    case badURL

    var errorDescription: String? {
        switch self {
        case .http(let c): return "Plex returned an error (\(c))."
        case .noServer: return "No Plex server found on this account."
        case .unreachable: return "Couldn't reach your Plex server."
        case .badURL: return "Bad address."
        }
    }
}

/// Tiny Keychain wrapper for the Plex token.
enum Keychain {
    static func set(_ value: String?, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// Everything that talks to plex.tv and the Plex Media Server.
final class PlexAPI {
    static let product = "Glass"
    static let version = "0.1"

    static var clientID: String = {
        if let id = UserDefaults.standard.string(forKey: "plexClientID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "plexClientID")
        return id
    }()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private let decoder = JSONDecoder()

    static func headers(token: String?) -> [String: String] {
        var h = [
            "Accept": "application/json",
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Client-Identifier": clientID,
            "X-Plex-Platform": "iOS",
            "X-Plex-Platform-Version": UIDevice.current.systemVersion,
            "X-Plex-Device": UIDevice.current.model,
            "X-Plex-Device-Name": UIDevice.current.name,
            "X-Plex-Provides": "player",
        ]
        if let token { h["X-Plex-Token"] = token }
        return h
    }

    private func request(_ url: URL, method: String = "GET", token: String?, timeout: TimeInterval? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        for (k, v) in Self.headers(token: token) { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlexError.http(http.statusCode)
        }
        return data
    }

    // MARK: sign-in (plex.tv/link PIN)

    func createPin() async throws -> PlexPin {
        let url = URL(string: "https://plex.tv/api/v2/pins?strong=false")!
        let data = try await request(url, method: "POST", token: nil)
        return try decoder.decode(PlexPin.self, from: data)
    }

    func checkPin(_ id: Int) async throws -> PlexPin {
        let url = URL(string: "https://plex.tv/api/v2/pins/\(id)")!
        let data = try await request(url, token: nil)
        return try decoder.decode(PlexPin.self, from: data)
    }

    // MARK: servers

    func servers(token: String) async throws -> [PlexResource] {
        let url = URL(string: "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1")!
        let data = try await request(url, token: token)
        return try decoder.decode([PlexResource].self, from: data).filter { $0.isServer }
    }

    /// Tries every connection at once; prefers local, then remote, then relay.
    func connect(_ res: PlexResource, accountToken: String) async throws -> PlexServer {
        let token = res.accessToken ?? accountToken
        let ranked = res.connections.sorted { a, b in
            func rank(_ c: PlexConnection) -> Int { c.relay ? 2 : (c.local ? 0 : 1) }
            return rank(a) < rank(b)
        }
        let working: [(Int, String)] = await withTaskGroup(of: (Int, String)?.self) { group in
            for (i, c) in ranked.enumerated() {
                group.addTask {
                    guard let url = URL(string: c.uri + "/identity") else { return nil }
                    do {
                        _ = try await self.request(url, token: token, timeout: 5)
                        return (i, c.uri)
                    } catch { return nil }
                }
            }
            var out: [(Int, String)] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
        guard let best = working.min(by: { $0.0 < $1.0 }) else { throw PlexError.unreachable }
        return PlexServer(name: res.name, id: res.clientIdentifier, token: token, uri: best.1)
    }

    // MARK: library

    func get(_ server: PlexServer, _ path: String, query: [String: String] = [:]) async throws -> PlexContainer {
        guard var comps = URLComponents(string: server.uri + path) else { throw PlexError.badURL }
        var items = comps.queryItems ?? []
        for (k, v) in query { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items.isEmpty ? nil : items
        guard let url = comps.url else { throw PlexError.badURL }
        let data = try await request(url, token: server.token)
        return try decoder.decode(PlexContainer.self, from: data)
    }

    func sections(_ s: PlexServer) async throws -> [PlexSection] {
        try await get(s, "/library/sections").sections.filter { $0.type == "movie" || $0.type == "show" }
    }

    func continueWatching(_ s: PlexServer) async throws -> [PlexItem] {
        if let c = try? await get(s, "/hubs/continueWatching/items"), !c.items.isEmpty { return c.items }
        if let c = try? await get(s, "/hubs/home/continueWatching"), let hub = c.hubs.first, !hub.items.isEmpty {
            return hub.items
        }
        return try await get(s, "/library/onDeck").items
    }

    /// Recently played episodes/movies in a library, newest first (includes ones rewound to 0:00,
    /// which Plex's own Continue Watching leaves out).
    func recentlyViewed(_ s: PlexServer, section: PlexSection, limit: Int = 30) async throws -> [PlexItem] {
        let type = section.type == "show" ? "4" : "1"
        return try await get(s, "/library/sections/\(section.key)/all", query: [
            "type": type, "sort": "lastViewedAt:desc",
            "X-Plex-Container-Start": "0", "X-Plex-Container-Size": String(limit),
        ]).items
    }

    func recentlyAdded(_ s: PlexServer, section: String) async throws -> [PlexItem] {
        try await get(s, "/library/sections/\(section)/recentlyAdded",
                      query: ["X-Plex-Container-Start": "0", "X-Plex-Container-Size": "24"]).items
    }

    /// Recently added, as whole shows / movies: new episodes and seasons are shown as their show.
    func recentlyAddedTitles(_ s: PlexServer, section: PlexSection, limit: Int = 24) async throws -> [PlexItem] {
        let recent = try await get(s, "/library/sections/\(section.key)/recentlyAdded",
                                   query: ["X-Plex-Container-Start": "0", "X-Plex-Container-Size": "400"]).items
        var keys: [String] = []
        for it in recent {
            let k: String
            switch it.type {
            case "episode": k = it.grandparentRatingKey ?? it.ratingKey
            case "season": k = it.parentRatingKey ?? it.ratingKey
            default: k = it.ratingKey
            }
            if !keys.contains(k) { keys.append(k) }
            if keys.count >= limit { break }
        }
        if section.type == "movie" {
            let byKey = Dictionary(recent.map { ($0.ratingKey, $0) }, uniquingKeysWith: { a, _ in a })
            return keys.compactMap { byKey[$0] }
        }
        // a few busy shows can fill the look-back; top up with the newest shows in the library
        if keys.count < limit {
            let newest = (try? await get(s, "/library/sections/\(section.key)/all", query: [
                "type": "2", "sort": "addedAt:desc", "X-Plex-Container-Start": "0", "X-Plex-Container-Size": String(limit),
            ]).items) ?? []
            for it in newest where !keys.contains(it.ratingKey) && keys.count < limit { keys.append(it.ratingKey) }
        }
        guard !keys.isEmpty else { return [] }
        // one request for all the shows, then back into "newest first" order
        let shows = try await get(s, "/library/metadata/" + keys.joined(separator: ",")).items
        let byKey = Dictionary(shows.map { ($0.ratingKey, $0) }, uniquingKeysWith: { a, _ in a })
        return keys.compactMap { byKey[$0] }
    }

    func all(_ s: PlexServer, section: String) async throws -> [PlexItem] {
        try await get(s, "/library/sections/\(section)/all", query: ["sort": "titleSort"]).items
    }

    func children(_ s: PlexServer, of ratingKey: String) async throws -> [PlexItem] {
        try await get(s, "/library/metadata/\(ratingKey)/children").items
    }

    func metadata(_ s: PlexServer, _ ratingKey: String) async throws -> PlexItem? {
        try await get(s, "/library/metadata/\(ratingKey)", query: ["includeMarkers": "1"]).items.first
    }

    func search(_ s: PlexServer, _ text: String) async throws -> [PlexItem] {
        let c = try await get(s, "/hubs/search", query: ["query": text, "limit": "20"])
        return c.hubs.filter { ["movie", "show", "episode"].contains($0.type ?? "") }.flatMap { $0.items }
    }

    // MARK: urls

    func streamURL(_ s: PlexServer, partKey: String) -> URL? {
        URL(string: s.uri + partKey + (partKey.contains("?") ? "&" : "?") + "X-Plex-Token=" + s.token)
    }

    func imageURL(_ s: PlexServer, _ path: String?, width: Int, height: Int) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        var c = URLComponents(string: s.uri + "/photo/:/transcode")
        c?.queryItems = [
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "X-Plex-Token", value: s.token),
        ]
        return c?.url
    }

    // MARK: progress

    /// Reports where we are. Plex keeps this as the resume point.
    func timeline(_ s: PlexServer, ratingKey: String, state: String, timeMs: Int, durationMs: Int) async {
        guard var c = URLComponents(string: s.uri + "/:/timeline") else { return }
        c.queryItems = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "time", value: String(timeMs)),
            URLQueryItem(name: "duration", value: String(durationMs)),
            URLQueryItem(name: "playbackTime", value: String(timeMs)),
            URLQueryItem(name: "hasMDE", value: "1"),
        ]
        guard let url = c.url else { return }
        _ = try? await request(url, token: s.token, timeout: 10)
    }

    func scrobble(_ s: PlexServer, ratingKey: String) async {
        guard let url = URL(string: s.uri + "/:/scrobble?key=\(ratingKey)&identifier=com.plexapp.plugins.library") else { return }
        _ = try? await request(url, token: s.token, timeout: 10)
    }

    func unscrobble(_ s: PlexServer, ratingKey: String) async {
        guard let url = URL(string: s.uri + "/:/unscrobble?key=\(ratingKey)&identifier=com.plexapp.plugins.library") else { return }
        _ = try? await request(url, token: s.token, timeout: 10)
    }
}
