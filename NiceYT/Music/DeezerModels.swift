import Foundation

/// Audio formats Deezer serves (names as used by `media.deezer.com/v1/get_url`).
enum DZQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case mp3_128 = "MP3_128", mp3_320 = "MP3_320", flac = "FLAC"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp3_128: return "MP3 · 128 kbit/s"
        case .mp3_320: return "MP3 · 320 kbit/s"
        case .flac: return "FLAC · verlustfrei"
        }
    }

    var badge: String {
        switch self {
        case .mp3_128: return "128"
        case .mp3_320: return "320"
        case .flac: return "FLAC"
        }
    }

    var fileExtension: String { self == .flac ? "flac" : "mp3" }

    /// Uniform type identifier for AVFoundation's resource loader.
    var contentType: String { self == .flac ? "org.xiph.flac" : "public.mp3" }

    /// This format and every lower one, best first.
    var fallbackChain: [DZQuality] {
        switch self {
        case .flac: return [.flac, .mp3_320, .mp3_128]
        case .mp3_320: return [.mp3_320, .mp3_128]
        case .mp3_128: return [.mp3_128]
        }
    }
}

/// Image on Deezer's CDN (covers, artist pictures, playlist pictures).
enum DZImage {
    static func url(_ md5: String?, kind: String = "cover", size: Int = 500) -> URL? {
        guard let md5, !md5.isEmpty else { return nil }
        return URL(string: "https://cdn-images.dzcdn.net/images/\(kind)/\(md5)/\(size)x\(size)-000000-80-0-0.jpg")
    }
}

struct DZTrack: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    var version: String?
    var artist: String
    var artists: [String]
    var artistId: String?
    var album: String
    var albumId: String?
    var cover: String?
    var duration: Int
    var trackNumber: Int?
    var discNumber: Int?
    var isrc: String?
    var releaseDate: String?
    var explicit = false
    var token: String?
    var tokenExpires: Double?
    var fallbackId: String?
    /// Cover of tracks that don't come from Deezer (YouTube audio downloads).
    var artworkURL: URL?
    var sourceURL: URL?

    /// Audio downloaded from a YouTube video (lives in the music downloads).
    init(youtube video: Video, title: String, artist: String) {
        id = "yt-" + video.id
        self.title = title
        self.artist = artist
        artists = [artist]
        album = "YouTube"
        duration = 0
        artworkURL = video.maxThumbnail
        sourceURL = video.shareURL
    }

    var isYouTube: Bool { id.hasPrefix("yt-") }
    var isSpotify: Bool { id.hasPrefix("sp-") }
    /// A real Deezer song (favourites, lyrics, albums … work).
    var isDeezer: Bool { !isYouTube && !isSpotify }
    var youtubeId: String? { isYouTube ? String(id.dropFirst(3)) : nil }

    /// Song from a Spotify library; played and downloaded through Deezer (ISRC) or YouTube.
    init?(spotify j: JSON) {
        guard let sid = j["id"].string, j["type"].string ?? "track" == "track" else { return nil }
        id = "sp-" + sid
        title = j["name"].string ?? ""
        artists = j["artists"].array.compactMap { $0["name"].string }
        artist = artists.first ?? ""
        artistId = nil
        album = j.at("album.name").string ?? ""
        duration = (j["duration_ms"].int ?? 0) / 1000
        trackNumber = j["track_number"].int
        discNumber = j["disc_number"].int
        isrc = j.at("external_ids.isrc").string
        releaseDate = j.at("album.release_date").string
        explicit = j["explicit"].bool ?? false
        artworkURL = j.at("album.images.0.url").string.flatMap(URL.init(string:))
        sourceURL = URL(string: "https://open.spotify.com/track/\(sid)")
    }

    init?(gw j: JSON) {
        guard let id = j["SNG_ID"].string, id != "0", Int(id) ?? 0 > 0 else { return nil }
        self.id = id
        title = j["SNG_TITLE"].string ?? ""
        let v = (j["VERSION"].string ?? "").trimmingCharacters(in: .whitespaces)
        version = v.isEmpty ? nil : v
        artist = j["ART_NAME"].string ?? ""
        let names = j["ARTISTS"].array.compactMap { $0["ART_NAME"].string }
        artists = names.isEmpty ? [artist] : names
        artistId = j["ART_ID"].string
        album = j["ALB_TITLE"].string ?? ""
        albumId = j["ALB_ID"].string
        cover = j["ALB_PICTURE"].string
        duration = j["DURATION"].int ?? 0
        trackNumber = j["TRACK_NUMBER"].int
        discNumber = j["DISK_NUMBER"].int
        isrc = j["ISRC"].string
        releaseDate = j["PHYSICAL_RELEASE_DATE"].string ?? j["DIGITAL_RELEASE_DATE"].string
        explicit = (j["EXPLICIT_LYRICS"].int ?? 0) == 1 || (j.at("EXPLICIT_TRACK_CONTENT.EXPLICIT_LYRICS_STATUS").int ?? 0) == 1
        token = j["TRACK_TOKEN"].string
        tokenExpires = j["TRACK_TOKEN_EXPIRE"].double
        let fb = j.at("FALLBACK.SNG_ID").string
        fallbackId = (fb == nil || fb == "0") ? nil : fb
    }

    var fullTitle: String { version.map { "\(title) \($0)" } ?? title }
    var artistLine: String { artists.joined(separator: ", ") }
    func coverURL(_ size: Int = 500) -> URL? { artworkURL ?? DZImage.url(cover, size: size) }
    var shareURL: URL { sourceURL ?? URL(string: "https://www.deezer.com/track/\(id)")! }
    var durationText: String { duration > 0 ? String(format: "%d:%02d", duration / 60, duration % 60) : "" }
    var year: String? { releaseDate.map { String($0.prefix(4)) } }

    var tokenIsFresh: Bool {
        guard token != nil else { return false }
        guard let exp = tokenExpires else { return true }
        return exp > Date().timeIntervalSince1970 + 60
    }

    /// Track identity without the short-lived token (for downloads and comparisons).
    static func == (a: DZTrack, b: DZTrack) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Song text; `lines` carry timestamps when Deezer has synced lyrics.
struct DZLyrics: Sendable {
    struct Line: Identifiable, Sendable {
        let id: Int
        let time: Double?
        let text: String
    }
    var lines: [Line]
    var isSynced: Bool { lines.contains { $0.time != nil } }
    var copyright: String?
}

struct DZAlbum: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artist: String
    var artistId: String?
    var cover: String?
    var releaseDate: String?
    var trackCount: Int?
    var type: String?
    var label: String?

    init?(gw j: JSON) {
        guard let id = j["ALB_ID"].string, id != "0" else { return nil }
        self.id = id
        title = j["ALB_TITLE"].string ?? ""
        artist = j["ART_NAME"].string ?? ""
        artistId = j["ART_ID"].string
        cover = j["ALB_PICTURE"].string
        releaseDate = j["ORIGINAL_RELEASE_DATE"].string ?? j["PHYSICAL_RELEASE_DATE"].string ?? j["DIGITAL_RELEASE_DATE"].string
        trackCount = j["NUMBER_TRACK"].int
        label = j["LABEL_NAME"].string
        switch j["TYPE"].string {
        case "0": type = "Single"
        case "3": type = "EP"
        case "2": type = "Compilation"
        default: type = "Album"
        }
    }

    func coverURL(_ size: Int = 500) -> URL? { DZImage.url(cover, size: size) }
    var year: String? { releaseDate.map { String($0.prefix(4)) } }
    var shareURL: URL { URL(string: "https://www.deezer.com/album/\(id)")! }
}

struct DZArtist: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var picture: String?
    var fans: Int?

    init?(gw j: JSON) {
        guard let id = j["ART_ID"].string, id != "0" else { return nil }
        self.id = id
        name = j["ART_NAME"].string ?? ""
        picture = j["ART_PICTURE"].string
        fans = j["NB_FAN"].int
    }

    func pictureURL(_ size: Int = 500) -> URL? { DZImage.url(picture, kind: "artist", size: size) }
    var shareURL: URL { URL(string: "https://www.deezer.com/artist/\(id)")! }
}

struct DZPlaylist: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var picture: String?
    var pictureType: String
    var owner: String?
    var trackCount: Int?
    var description: String?

    init?(gw j: JSON) {
        guard let id = j["PLAYLIST_ID"].string, id != "0" else { return nil }
        self.id = id
        title = j["TITLE"].string ?? ""
        picture = j["PLAYLIST_PICTURE"].string
        pictureType = j["PICTURE_TYPE"].string ?? "playlist"
        owner = j["PARENT_USERNAME"].string
        trackCount = j["NB_SONG"].int
        description = j["DESCRIPTION"].string
    }

    func pictureURL(_ size: Int = 500) -> URL? { DZImage.url(picture, kind: pictureType, size: size) }
    var shareURL: URL { URL(string: "https://www.deezer.com/playlist/\(id)")! }
}

struct DZUser: Sendable, Equatable, Codable {
    let id: String
    let name: String
    let picture: String?
    let licenseToken: String
    let canStreamHQ: Bool
    let canStreamLossless: Bool
    let country: String
    let lovedTracksId: String?
    let offerName: String?

    var pictureURL: URL? { DZImage.url(picture, kind: "user", size: 200) }

    /// Best format the subscription allows.
    var maxQuality: DZQuality { canStreamLossless ? .flac : canStreamHQ ? .mp3_320 : .mp3_128 }
}

struct DZSearchResult: Sendable {
    var tracks: [DZTrack] = []
    var albums: [DZAlbum] = []
    var artists: [DZArtist] = []
    var playlists: [DZPlaylist] = []
    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

enum DeezerError: LocalizedError {
    case invalidARL
    case notLoggedIn
    case api(String)
    case noStream
    case geoBlocked
    case license
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidARL: return "Der ARL-Cookie ist ungültig oder abgelaufen."
        case .notLoggedIn: return "Bitte zuerst bei Deezer anmelden."
        case .api(let m): return "Deezer: \(m)"
        case .noStream: return "Für diesen Song gibt es keinen abspielbaren Stream."
        case .geoBlocked: return "Dieser Song ist in deinem Land nicht verfügbar."
        case .license: return "Dein Deezer-Abo erlaubt diesen Song gerade nicht."
        case .http(let c): return "Deezer antwortet mit HTTP \(c)."
        }
    }
}
