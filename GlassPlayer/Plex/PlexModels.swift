import Foundation

// Plex sends some ids as strings in one endpoint and numbers in another; accept both.
extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }
    func flexInt(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return nil
    }
    func flexBool(_ key: Key) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = flexInt(key) { return i != 0 }
        return nil
    }
}

struct PlexPart: Decodable, Hashable {
    let key: String?
    let file: String?
    let size: Int?

    enum CodingKeys: String, CodingKey { case key, file, size }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = c.flexString(.key)
        file = c.flexString(.file)
        size = c.flexInt(.size)
    }
}

struct PlexMedia: Decodable, Hashable {
    let videoResolution: String?
    let videoCodec: String?
    let audioCodec: String?
    let audioChannels: Int?
    let bitrate: Int?
    let videoDynamicRange: String?
    let parts: [PlexPart]

    enum CodingKeys: String, CodingKey {
        case videoResolution, videoCodec, audioCodec, audioChannels, bitrate, videoDynamicRange
        case parts = "Part"
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        videoResolution = c.flexString(.videoResolution)
        videoCodec = c.flexString(.videoCodec)
        audioCodec = c.flexString(.audioCodec)
        audioChannels = c.flexInt(.audioChannels)
        bitrate = c.flexInt(.bitrate)
        videoDynamicRange = c.flexString(.videoDynamicRange)
        parts = (try? c.decodeIfPresent([PlexPart].self, forKey: .parts)) ?? []
    }
}

struct PlexImage: Decodable, Hashable {
    let type: String
    let url: String
    enum CodingKeys: String, CodingKey { case type, url }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        type = c.flexString(.type) ?? ""
        url = c.flexString(.url) ?? ""
    }
}

struct PlexItem: Decodable, Identifiable, Hashable {
    let ratingKey: String
    let key: String?
    let type: String?                 // movie, show, season, episode
    let title: String
    let grandparentTitle: String?
    let grandparentRatingKey: String?
    let parentTitle: String?
    let parentRatingKey: String?
    let parentIndex: Int?
    let index: Int?
    let year: Int?
    let summary: String?
    let thumb: String?
    let art: String?
    let parentThumb: String?
    let grandparentThumb: String?
    let viewOffset: Int?              // ms
    let duration: Int?                // ms
    let viewCount: Int?
    let leafCount: Int?
    let viewedLeafCount: Int?
    let childCount: Int?
    let grandparentArt: String?
    let addedAt: Int?
    let lastViewedAt: Int?
    let originallyAvailableAt: String?
    let contentRating: String?
    let audienceRating: Double?
    let images: [PlexImage]
    let media: [PlexMedia]

    var id: String { ratingKey }

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title, grandparentTitle, grandparentRatingKey, parentTitle, parentRatingKey
        case parentIndex, index, year, summary, thumb, art, parentThumb, grandparentThumb
        case viewOffset, duration, viewCount, leafCount, viewedLeafCount, childCount
        case grandparentArt, addedAt, lastViewedAt, originallyAvailableAt, contentRating, audienceRating
        case images = "Image"
        case media = "Media"
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        ratingKey = c.flexString(.ratingKey) ?? UUID().uuidString
        key = c.flexString(.key)
        type = c.flexString(.type)
        title = c.flexString(.title) ?? ""
        grandparentTitle = c.flexString(.grandparentTitle)
        grandparentRatingKey = c.flexString(.grandparentRatingKey)
        parentTitle = c.flexString(.parentTitle)
        parentRatingKey = c.flexString(.parentRatingKey)
        parentIndex = c.flexInt(.parentIndex)
        index = c.flexInt(.index)
        year = c.flexInt(.year)
        summary = c.flexString(.summary)
        thumb = c.flexString(.thumb)
        art = c.flexString(.art)
        parentThumb = c.flexString(.parentThumb)
        grandparentThumb = c.flexString(.grandparentThumb)
        viewOffset = c.flexInt(.viewOffset)
        duration = c.flexInt(.duration)
        viewCount = c.flexInt(.viewCount)
        leafCount = c.flexInt(.leafCount)
        viewedLeafCount = c.flexInt(.viewedLeafCount)
        childCount = c.flexInt(.childCount)
        grandparentArt = c.flexString(.grandparentArt)
        addedAt = c.flexInt(.addedAt)
        lastViewedAt = c.flexInt(.lastViewedAt)
        originallyAvailableAt = c.flexString(.originallyAvailableAt)
        contentRating = c.flexString(.contentRating)
        audienceRating = (try? c.decodeIfPresent(Double.self, forKey: .audienceRating)) ?? c.flexString(.audienceRating).flatMap(Double.init)
        images = (try? c.decodeIfPresent([PlexImage].self, forKey: .images)) ?? []
        media = (try? c.decodeIfPresent([PlexMedia].self, forKey: .media)) ?? []
    }

    var isEpisode: Bool { type == "episode" }
    var isShowLike: Bool { type == "show" || type == "season" }

    var watched: Bool {
        if let leafCount, let viewedLeafCount, leafCount > 0 { return viewedLeafCount >= leafCount }
        return (viewCount ?? 0) > 0 && (viewOffset ?? 0) == 0
    }

    var progress: Double? {
        guard let viewOffset, let duration, duration > 0, viewOffset > 0 else { return nil }
        return min(1, Double(viewOffset) / Double(duration))
    }

    /// Poster for cards: episodes use the show poster.
    var posterPath: String? {
        if isEpisode { return grandparentThumb ?? parentThumb ?? thumb }
        return thumb ?? parentThumb
    }

    /// "S02 · E05" for episodes.
    var episodeCode: String? {
        guard isEpisode else { return nil }
        var s = ""
        if let parentIndex { s += String(format: "S%02d", parentIndex) }
        if let index { s += (s.isEmpty ? "" : " · ") + String(format: "E%02d", index) }
        return s.isEmpty ? nil : s
    }

    var displayTitle: String { isEpisode ? (grandparentTitle ?? title) : title }

    var displaySubtitle: String? {
        if isEpisode {
            return [episodeCode, title].compactMap { $0 }.joined(separator: " · ")
        }
        if type == "season" { return parentTitle }
        if let year { return String(year) }
        return nil
    }

    var partKey: String? { media.first?.parts.first?.key }

    /// Title logo ("clear logo") when Plex has one.
    var logoPath: String? { images.first(where: { $0.type == "clearLogo" })?.url }

    /// Wide background art: the show's for episodes.
    var backdropPath: String? { isEpisode ? (grandparentArt ?? art) : art }

    /// Landscape picture for cards: the episode still, or the movie's background.
    var stillPath: String? { isEpisode ? (thumb ?? grandparentArt) : (art ?? thumb) }

    /// The show this item belongs to (itself for shows and movies).
    var showKey: String { isEpisode ? (grandparentRatingKey ?? ratingKey) : type == "season" ? (parentRatingKey ?? ratingKey) : ratingKey }

    var runtimeText: String? {
        guard let duration, duration > 0 else { return nil }
        let m = duration / 60000
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    var remainingText: String? {
        guard let duration, let viewOffset, viewOffset > 0, duration > 0 else { return runtimeText }
        return "\(max(1, (duration - viewOffset) / 60000)) min left"
    }

    /// "2160p · HEVC · HDR · TrueHD 7.1" from Plex metadata.
    var mediaSummary: String {
        guard let m = media.first else { return "" }
        var p: [String] = []
        if let r = m.videoResolution {
            p.append(r.lowercased() == "4k" ? "2160p" : (Int(r) != nil ? "\(r)p" : r.uppercased()))
        }
        if let v = m.videoCodec { p.append(MPVTrack.prettyCodec(v)) }
        if let dr = m.videoDynamicRange, dr.uppercased() != "SDR" { p.append(dr) }
        if let b = m.bitrate, b > 0 { p.append(String(format: "%.1f Mbps", Double(b) / 1000)) }
        if let a = m.audioCodec {
            var s = MPVTrack.prettyCodec(a)
            if let ch = m.audioChannels { s += " " + MPVTrack.prettyChannels(ch) }
            p.append(s)
        }
        return p.joined(separator: " · ")
    }
}

struct PlexSection: Decodable, Identifiable, Hashable {
    let key: String
    let title: String
    let type: String

    var id: String { key }

    enum CodingKeys: String, CodingKey { case key, title, type }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = c.flexString(.key) ?? ""
        title = c.flexString(.title) ?? ""
        type = c.flexString(.type) ?? ""
    }
}

struct PlexHub: Decodable {
    let title: String?
    let type: String?
    let hubIdentifier: String?
    let items: [PlexItem]

    enum CodingKeys: String, CodingKey {
        case title, type, hubIdentifier
        case items = "Metadata"
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = c.flexString(.title)
        type = c.flexString(.type)
        hubIdentifier = c.flexString(.hubIdentifier)
        items = (try? c.decodeIfPresent([PlexItem].self, forKey: .items)) ?? []
    }
}

struct PlexContainer: Decodable {
    let items: [PlexItem]
    let sections: [PlexSection]
    let hubs: [PlexHub]
    let size: Int?
    let totalSize: Int?

    enum Outer: String, CodingKey { case MediaContainer }
    enum CodingKeys: String, CodingKey {
        case items = "Metadata"
        case sections = "Directory"
        case hubs = "Hub"
        case size, totalSize
    }
    init(from d: Decoder) throws {
        let outer = try d.container(keyedBy: Outer.self)
        let c = try outer.nestedContainer(keyedBy: CodingKeys.self, forKey: .MediaContainer)
        items = (try? c.decodeIfPresent([PlexItem].self, forKey: .items)) ?? []
        sections = (try? c.decodeIfPresent([PlexSection].self, forKey: .sections)) ?? []
        hubs = (try? c.decodeIfPresent([PlexHub].self, forKey: .hubs)) ?? []
        size = c.flexInt(.size)
        totalSize = c.flexInt(.totalSize)
    }
}

// plex.tv

struct PlexPin: Decodable {
    let id: Int
    let code: String
    let authToken: String?
}

struct PlexConnection: Decodable, Hashable {
    let uri: String
    let local: Bool
    let relay: Bool

    enum CodingKeys: String, CodingKey { case uri, local, relay }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        uri = c.flexString(.uri) ?? ""
        local = c.flexBool(.local) ?? false
        relay = c.flexBool(.relay) ?? false
    }
}

struct PlexResource: Decodable, Hashable {
    let name: String
    let clientIdentifier: String
    let accessToken: String?
    let provides: String
    let owned: Bool
    let connections: [PlexConnection]

    enum CodingKeys: String, CodingKey { case name, clientIdentifier, accessToken, provides, owned, connections }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = c.flexString(.name) ?? "Plex"
        clientIdentifier = c.flexString(.clientIdentifier) ?? ""
        accessToken = c.flexString(.accessToken)
        provides = c.flexString(.provides) ?? ""
        owned = c.flexBool(.owned) ?? false
        connections = (try? c.decodeIfPresent([PlexConnection].self, forKey: .connections)) ?? []
    }

    var isServer: Bool { provides.split(separator: ",").contains("server") }
}

/// The server we picked, with the connection that answered.
struct PlexServer: Codable, Hashable {
    let name: String
    let id: String
    let token: String
    let uri: String
}
