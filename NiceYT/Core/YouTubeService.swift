import Foundation

enum SearchFilter: String, CaseIterable, Identifiable {
    case all, videos, shorts, channels, playlists

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "Alle"
        case .videos: return "Videos"
        case .shorts: return "Shorts"
        case .channels: return "Kanäle"
        case .playlists: return "Playlists"
        }
    }
    var params: String? {
        switch self {
        case .all: return nil
        case .videos: return "EgIQAQ=="
        case .shorts: return "EgIQCQ=="
        case .channels: return "EgIQAg=="
        case .playlists: return "EgIQAw=="
        }
    }
}

/// High-level YouTube operations used by the UI.
enum YouTube {
    private static var api: InnerTube { .shared }

    // MARK: Feeds

    static func home() async throws -> FeedPage {
        try await browse("FEwhat_to_watch")
    }

    static func subscriptionsFeed() async throws -> FeedPage {
        guard CookieJar.shared.isSignedIn else { throw YTError.notSignedIn }
        return try await browse("FEsubscriptions")
    }

    static func browse(_ browseId: String, params: String? = nil) async throws -> FeedPage {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        let j = try await api.post("browse", body)
        return Parser.feed(j["contents"])
    }

    static func browseMore(_ token: String) async throws -> FeedPage {
        let j = try await api.post("browse", ["continuation": token])
        return Parser.feed(j)
    }

    static func search(_ query: String, filter: SearchFilter = .all) async throws -> FeedPage {
        var body: [String: Any] = ["query": query]
        if let p = filter.params { body["params"] = p }
        let j = try await api.post("search", body)
        return Parser.feed(j["contents"])
    }

    static func searchMore(_ token: String) async throws -> FeedPage {
        let j = try await api.post("search", ["continuation": token])
        return Parser.feed(j)
    }

    static func suggestions(_ query: String) async -> [String] {
        var comps = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        comps.queryItems = [
            .init(name: "client", value: "firefox"),
            .init(name: "ds", value: "yt"),
            .init(name: "hl", value: AppSettings.hl),
            .init(name: "gl", value: AppSettings.gl),
            .init(name: "q", value: query)
        ]
        guard let url = comps.url, let j = try? await api.getJSON(url) else { return [] }
        return j[1].array.compactMap(\.string)
    }

    /// Popular videos for the signed-out start page.
    static func explore(_ topic: String) async throws -> FeedPage {
        // "This week" + sort by view count
        let j = try await api.post("search", ["query": topic, "params": "CAMSBAgDEAE="], authenticated: false)
        return Parser.feed(j["contents"])
    }

    // MARK: Watch

    /// Queries several player clients in parallel (order follows yt-dlp's current
    /// JS-less defaults) and returns every usable stream, HLS first.
    static func streamCandidates(_ videoId: String) async -> [StreamInfo] {
        let body: [String: Any] = [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]]
        ]
        var clients: [ITClient] = [.visionos, .ios]
        if CookieJar.shared.isSignedIn { clients.append(.webSafari) }
        clients.append(.mweb)

        let results = await withTaskGroup(of: (Int, StreamInfo?).self) { group in
            for (index, client) in clients.enumerated() {
                group.addTask {
                    do {
                        let j = try await api.post("player", body, client: client, authenticated: client.supportsCookies)
                        let status = j.at("playabilityStatus.status").string ?? "?"
                        let sd = j["streamingData"]
                        let formats = sd["formats"].array.count + sd["adaptiveFormats"].array.count
                        DebugLog.log("[\(client.name)] Status \(status), HLS \(sd["hlsManifestUrl"].exists ? "ja" : "nein"), Formate \(formats), SABR \(sd["serverAbrStreamingUrl"].exists ? "ja" : "nein")\(status == "OK" ? "" : " – " + (j.at("playabilityStatus.reason").string ?? ""))")
                        return (index, try Parser.stream(j, videoId: videoId, client: client))
                    } catch {
                        DebugLog.log("[\(client.name)] Fehler: \(error.localizedDescription)")
                        return (index, nil)
                    }
                }
            }
            var collected: [(Int, StreamInfo?)] = []
            for await r in group { collected.append(r) }
            return collected
        }
        let ordered = results.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
        return ordered.filter(\.isHLS) + ordered.filter { !$0.isHLS }
    }

    /// Metadata-only player response (title, captions …) from the first answering client.
    static func stream(_ videoId: String) async throws -> StreamInfo {
        if let first = await streamCandidates(videoId).first { return first }
        throw YTError.unplayable("Kein Stream verfügbar.")
    }

    static func watch(_ videoId: String, playlistId: String? = nil) async throws -> WatchDetails {
        var body: [String: Any] = ["videoId": videoId]
        if let playlistId { body["playlistId"] = playlistId }
        let j = try await api.post("next", body)
        return Parser.watch(j)
    }

    static func relatedMore(_ token: String) async throws -> FeedPage {
        let j = try await api.post("next", ["continuation": token])
        return Parser.feed(j)
    }

    static func comments(_ token: String) async throws -> CommentPage {
        let j = try await api.post("next", ["continuation": token])
        return Parser.comments(j)
    }

    /// Adds the video to the signed-in user's watch history.
    static func markWatched(_ videoId: String) async {
        guard CookieJar.shared.isSignedIn,
              let j = try? await api.post("player", ["videoId": videoId, "contentCheckOk": true, "racyCheckOk": true]),
              let base = j.at("playbackTracking.videostatsPlaybackUrl.baseUrl").string,
              var comps = URLComponents(string: base) else { return }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let cpn = String((0..<16).map { _ in alphabet.randomElement()! })
        comps.queryItems = (comps.queryItems ?? []) + [
            .init(name: "ver", value: "2"),
            .init(name: "cpn", value: cpn),
            .init(name: "fs", value: "0"),
            .init(name: "volume", value: "100"),
            .init(name: "muted", value: "0")
        ]
        if let url = comps.url { await api.ping(url) }
    }

    // MARK: Channel & playlists

    static func channel(_ id: String, params: String? = "EgZ2aWRlb3PyBgQKAjoA") async throws -> ChannelPage {
        var body: [String: Any] = ["browseId": id]
        if let params { body["params"] = params }
        var j = try await api.post("browse", body)
        if j["contents"].exists == false, params != nil {
            j = try await api.post("browse", ["browseId": id])
        }
        return Parser.channel(j, id: id)
    }

    static func resolveHandle(_ url: String) async throws -> String? {
        let j = try await api.post("navigation/resolve_url", ["url": url])
        return j.findFirst("browseEndpoint")["browseId"].string
    }

    static func playlist(_ id: String) async throws -> PlaylistPage {
        let browseId = id.hasPrefix("VL") ? id : "VL" + id
        let j = try await api.post("browse", ["browseId": browseId])
        return Parser.playlist(j)
    }

    static func subscribedChannels() async throws -> [Channel] {
        guard CookieJar.shared.isSignedIn else { throw YTError.notSignedIn }
        if let j = try? await api.post("browse", ["browseId": "FEchannels"]) {
            let list = Parser.channels(j["contents"])
            if !list.isEmpty { return list }
        }
        let g = try await api.post("guide", [:])
        return Parser.guideSubscriptions(g)
    }

    static func account() async throws -> AccountInfo? {
        let j = try await api.post("account/account_menu", [:])
        return Parser.account(j)
    }

    // MARK: Actions

    static func setLike(_ videoId: String, status: String) async throws {
        let endpoint: String
        switch status {
        case "LIKE": endpoint = "like/like"
        case "DISLIKE": endpoint = "like/dislike"
        default: endpoint = "like/removelike"
        }
        guard CookieJar.shared.isSignedIn else { throw YTError.notSignedIn }
        _ = try await api.post(endpoint, ["target": ["videoId": videoId]])
    }

    static func setSubscribed(_ channelId: String, _ subscribed: Bool) async throws {
        guard CookieJar.shared.isSignedIn else { throw YTError.notSignedIn }
        _ = try await api.post(subscribed ? "subscription/subscribe" : "subscription/unsubscribe",
                               ["channelIds": [channelId]])
    }

    static func addToWatchLater(_ videoId: String) async throws {
        guard CookieJar.shared.isSignedIn else { throw YTError.notSignedIn }
        _ = try await api.post("browse/edit_playlist", [
            "playlistId": "WL",
            "actions": [["addedVideoId": videoId, "action": "ACTION_ADD_VIDEO"]]
        ])
    }

    // MARK: Shorts

    static func shortsStart() async throws -> (first: String?, sequence: String?) {
        let j = try await api.post("reel/reel_item_watch", [
            "params": "CA8%3D",
            "inputType": "REEL_WATCH_INPUT_TYPE_SEEDLESS",
            "disablePlayerResponse": true
        ])
        return (j.findFirst("replacementEndpoint")["reelWatchEndpoint"]["videoId"].string
                    ?? j.findFirst("reelWatchEndpoint")["videoId"].string,
                j["sequenceContinuation"].string)
    }

    static func shortsSequence(_ params: String) async throws -> (ids: [String], next: String?) {
        let j = try await api.post("reel/reel_watch_sequence", ["sequenceParams": params])
        let ids = j["entries"].array.compactMap { $0.findFirst("reelWatchEndpoint")["videoId"].string }
        let next = j.at("continuationEndpoint.continuationCommand.token").string
        return (ids, next)
    }
}

/// SponsorBlock (sponsor.ajay.app) and Return YouTube Dislike.
enum Community {
    static func sponsorSegments(_ videoId: String, categories: Set<String>) async -> [SponsorSegment] {
        guard !categories.isEmpty else { return [] }
        var comps = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")!
        let cats = "[" + categories.sorted().map { "\"\($0)\"" }.joined(separator: ",") + "]"
        comps.queryItems = [.init(name: "videoID", value: videoId), .init(name: "categories", value: cats)]
        guard let url = comps.url, let j = try? await InnerTube.shared.getJSON(url) else { return [] }
        return j.array.compactMap { s in
            guard let start = s["segment"][0].double, let end = s["segment"][1].double, end > start else { return nil }
            return SponsorSegment(start: start, end: end, category: s["category"].string ?? "sponsor")
        }
    }

    static func dislikes(_ videoId: String) async -> DislikeInfo? {
        guard let url = URL(string: "https://returnyoutubedislikeapi.com/votes?videoId=\(videoId)"),
              let j = try? await InnerTube.shared.getJSON(url),
              let likes = j["likes"].int, let dislikes = j["dislikes"].int else { return nil }
        return DislikeInfo(likes: likes, dislikes: dislikes)
    }
}

extension Int {
    /// Compact number like "1,2 Mio.".
    var compact: String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: AppSettings.hl)
        f.maximumFractionDigits = 1
        let d = Double(self)
        switch d {
        case 1_000_000_000...: return (f.string(from: NSNumber(value: d / 1_000_000_000)) ?? "") + " Mrd."
        case 1_000_000...: return (f.string(from: NSNumber(value: d / 1_000_000)) ?? "") + " Mio."
        case 10_000...: return (f.string(from: NSNumber(value: d / 1_000)) ?? "") + " Tsd."
        default: return f.string(from: NSNumber(value: self)) ?? "\(self)"
        }
    }
}
