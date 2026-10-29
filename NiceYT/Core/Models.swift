import Foundation

struct Video: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var channelName: String?
    var channelId: String?
    var channelAvatar: URL?
    var thumbnail: URL?
    var duration: String?
    var views: String?
    var published: String?
    var isLive = false
    var isShort = false

    var bestThumbnail: URL {
        thumbnail ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!
    }

    var maxThumbnail: URL { URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg")! }

    var shareURL: URL {
        URL(string: isShort ? "https://youtube.com/shorts/\(id)" : "https://youtu.be/\(id)")!
    }

    var subtitle: String {
        [channelName, views, published].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct Channel: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var avatar: URL?
    var subscribers: String?
    var handle: String?
}

struct Playlist: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var thumbnail: URL?
    var videoCount: String?
    var channelName: String?
    var firstVideoId: String?

    /// Mixes (RD…) cannot be browsed, only played.
    var isMix: Bool { id.hasPrefix("RD") }
}

enum FeedItem: Identifiable, Hashable, Sendable {
    case video(Video)
    case short(Video)
    case channel(Channel)
    case playlist(Playlist)

    var id: String {
        switch self {
        case .video(let v): return "v" + v.id
        case .short(let v): return "s" + v.id
        case .channel(let c): return "c" + c.id
        case .playlist(let p): return "p" + p.id
        }
    }

    var video: Video? {
        switch self {
        case .video(let v), .short(let v): return v
        default: return nil
        }
    }
}

struct FeedPage: Sendable {
    var items: [FeedItem] = []
    var continuation: String?
}

struct Comment: Identifiable, Hashable, Sendable {
    let id: String
    var author: String
    var authorAvatar: URL?
    var authorChannelId: String?
    var text: String
    var published: String?
    var likes: String?
    var replyCount: Int = 0
    var repliesToken: String?
    var isCreator = false
}

struct CommentPage: Sendable {
    var comments: [Comment] = []
    var continuation: String?
    var sortOptions: [(title: String, token: String)] = []
    var countText: String?
}

struct CaptionTrack: Identifiable, Hashable, Sendable {
    var id: String { languageCode + name }
    let name: String
    let languageCode: String
    let url: URL
    let isAuto: Bool
}

struct StreamInfo: Sendable {
    let videoId: String
    /// HLS manifest, a progressive MP4, or the video track when `audioURL` is set.
    var hlsURL: URL
    var isHLS = true
    /// Separate audio track (DASH-style adaptive pair, combined with AVMutableComposition).
    var audioURL: URL?
    var videoHeight = 0
    var userAgent = ITClient.iosUserAgent
    var source = "?"
    var poToken: String?
    let title: String
    let author: String
    let channelId: String?
    let viewCount: String?
    let lengthSeconds: Int
    let description: String
    let isLive: Bool
    let captions: [CaptionTrack]
}

struct WatchDetails: Sendable {
    var title = ""
    var views: String?
    var date: String?
    var description = ""
    var channel: Channel?
    var likeText: String?
    var likeStatus: String?   // LIKE / DISLIKE / INDIFFERENT
    var isSubscribed = false
    var related: [FeedItem] = []
    var relatedContinuation: String?
    var commentsToken: String?
    var commentCount: String?
    var commentPreview: Comment?
}

struct ChannelPage: Sendable {
    struct TabInfo: Identifiable, Hashable, Sendable {
        var id: String { title }
        let title: String
        let params: String?
        let selected: Bool
    }
    var channel: Channel
    var banner: URL?
    var description: String?
    var videoCount: String?
    var isSubscribed = false
    var tabs: [TabInfo] = []
    var feed = FeedPage()
}

struct PlaylistPage: Sendable {
    var title: String
    var subtitle: String?
    var thumbnail: URL?
    var feed = FeedPage()
}

struct AccountInfo: Codable, Hashable, Sendable {
    var name: String
    var handle: String?
    var avatar: URL?
}

struct SponsorSegment: Hashable, Sendable {
    let start: Double
    let end: Double
    let category: String
}

struct DislikeInfo: Sendable {
    let likes: Int
    let dislikes: Int
}

enum YTError: LocalizedError {
    case http(Int)
    case unplayable(String)
    case notSignedIn
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Serverfehler (\(code))"
        case .unplayable(let reason): return reason
        case .notSignedIn: return "Bitte melde dich zuerst an."
        case .invalidResponse: return "Unerwartete Antwort von YouTube."
        }
    }
}
