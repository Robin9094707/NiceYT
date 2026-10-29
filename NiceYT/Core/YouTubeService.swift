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

    /// Queries several player clients in parallel (order follows yt-dlp 2026.10: visionOS,
    /// TV, embedded web) and returns the usable streams: HLS first, then adaptive
    /// video+audio pairs, then progressive MP4.
    ///
    /// Unless `thorough` is set it doesn't wait for every client: as soon as the best
    /// answering client is known (or shortly after the first usable answer) it returns,
    /// so playback can start quickly. `complete` tells whether all clients answered.
    static func streamCandidates(_ videoId: String, thorough: Bool = false) async -> (candidates: [StreamInfo], complete: Bool) {
        var clients: [ITClient] = [.visionos, .tv, .webEmbedded, .ios]
        if CookieJar.shared.isSignedIn { clients.append(.webSafari) }
        clients.append(.mweb)

        let (stream, continuation) = AsyncStream.makeStream(of: (index: Int, infos: [StreamInfo]).self)
        let tasks = clients.enumerated().map { index, client in
            Task {
                let infos = await playerCandidates(videoId, client: client)
                continuation.yield((index, infos))
            }
        }
        var grace: Task<Void, Never>?
        defer {
            tasks.forEach { $0.cancel() }
            grace?.cancel()
            continuation.finish()
        }

        var collected: [Int: [StreamInfo]] = [:]
        for await result in stream {
            if result.index < 0 {
                if collected.values.contains(where: { !$0.isEmpty }) { break }
                continue
            }
            collected[result.index] = result.infos
            if collected.count == clients.count { break }
            if thorough { continue }
            guard let best = collected.filter({ !$0.value.isEmpty }).keys.min() else { continue }
            // Every client that would be preferred over `best` has answered → done.
            if (0..<best).allSatisfy({ collected[$0] != nil }) { break }
            if grace == nil {
                grace = Task {
                    try? await Task.sleep(for: .milliseconds(1200))
                    if !Task.isCancelled { continuation.yield((-1, [])) }
                }
            }
        }
        let ordered = collected.sorted { $0.key < $1.key }.flatMap { $0.value }
        let candidates = ordered.filter(\.isHLS)
            + ordered.filter { !$0.isHLS && $0.audioURL != nil }
            + ordered.filter { !$0.isHLS && $0.audioURL == nil }
        return (candidates, collected.count == clients.count)
    }

    /// One player request with `client`, turned into playable candidates.
    private static func playerCandidates(_ videoId: String, client: ITClient) async -> [StreamInfo] {
        var playback: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
        if client.needsJSPlayer, let sts = await NSolver.shared.signatureTimestamp() {
            playback["signatureTimestamp"] = sts
        }
        if Task.isCancelled { return [] }
        let body: [String: Any] = [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": ["contentPlaybackContext": playback]
        ]
        do {
            let j = try await api.post("player", body, client: client, authenticated: client.supportsCookies)
            let status = j.at("playabilityStatus.status").string ?? "?"
            let sd = j["streamingData"]
            let formats = sd["formats"].array.count + sd["adaptiveFormats"].array.count
            let reason = status == "OK" ? "" : " – " + (j.at("playabilityStatus.reason").string ?? "")
            DebugLog.log("[\(client.name)] Status \(status), HLS \(sd["hlsManifestUrl"].exists ? "ja" : "nein"), Formate \(formats)\(reason)")
            let meta = try Parser.stream(j, videoId: videoId, client: client)
            return await candidates(from: j, meta: meta, client: client)
        } catch {
            if !Task.isCancelled { DebugLog.log("[\(client.name)] Fehler: \(error.localizedDescription)") }
            return []
        }
    }

    /// Builds playable variants from one player response, deciphering signatures and n values.
    private static func candidates(from j: JSON, meta: StreamInfo, client: ITClient) async -> [StreamInfo] {
        var out: [StreamInfo] = []
        if meta.isHLS { out.append(meta) }
        // iOS / mobile-web direct URLs require a PO token nowadays (HTTP 403 without).
        guard client == .tv || client == .webEmbedded || client == .visionos else { return out }

        let formats = Parser.rawFormats(j)
        let maxHeight = AppSettings.shared.quality == .auto ? 1080 : min(Int(AppSettings.shared.quality.rawValue) ?? 1080, 1080)
        let video = formats
            .filter { !$0.isMuxed && $0.mime.hasPrefix("video/mp4") && $0.mime.contains("avc1") && $0.height <= maxHeight }
            .max { ($0.height, $0.bitrate) < ($1.height, $1.bitrate) }
        // Videos with AI-dubbed translations have one audio set per language:
        // keep the best format of each and pick the one matching the preference.
        var audioByTrack: [String: Parser.RawFormat] = [:]
        for f in formats where !f.isMuxed && f.mime.hasPrefix("audio/mp4") {
            let key = f.audioTrackId ?? "default"
            if let current = audioByTrack[key], current.bitrate >= f.bitrate { continue }
            audioByTrack[key] = f
        }
        let audioFormats = Array(audioByTrack.values)
        let audio = audioFormats.max {
            AudioMatch.score(name: $0.audioName ?? "", language: $0.audioLanguage, isDefault: $0.audioIsDefault,
                             original: $0.audioIsOriginal, dubbed: $0.audioIsDubbed)
                < AudioMatch.score(name: $1.audioName ?? "", language: $1.audioLanguage, isDefault: $1.audioIsDefault,
                                   original: $1.audioIsOriginal, dubbed: $1.audioIsDubbed)
        }
        let muxed = formats.filter { $0.isMuxed && $0.mime.hasPrefix("video/mp4") }.max { $0.height < $1.height }

        let chosen = [video, muxed].compactMap { $0 } + (audioFormats.count > 1 ? audioFormats : [audio].compactMap { $0 })
        guard !chosen.isEmpty else { return out }
        let sigs = chosen.compactMap { $0.cipher?.s }
        var raw = chosen.compactMap { $0.url ?? $0.cipher?.url }
        let nChallenges = raw.flatMap { NSolver.challenges(in: $0) }
        raw.removeAll()
        let solved = await NSolver.shared.solve(n: nChallenges, sig: sigs)

        func finalURL(_ f: Parser.RawFormat) -> URL? {
            var u: String
            if let url = f.url {
                u = url
            } else if let c = f.cipher, let sig = solved.sig[c.s] {
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&=+/")
                u = c.url + "&" + c.sp + "=" + (sig.addingPercentEncoding(withAllowedCharacters: allowed) ?? sig)
            } else {
                return nil
            }
            u = NSolver.apply(solved.n, to: u)
            return URL(string: u)
        }

        if let video, let audio, let v = finalURL(video), let a = finalURL(audio) {
            var s = meta
            s.isHLS = false
            s.hlsURL = v
            s.audioURL = a
            if audioFormats.count > 1 {
                s.audioTracks = audioFormats.compactMap { f -> AudioTrack? in
                    guard let url = finalURL(f) else { return nil }
                    let name = f.audioName ?? (f.audioLanguage.isEmpty ? "Standard" : f.audioLanguage)
                    return AudioTrack(id: f.audioTrackId ?? "default", name: name, url: url, language: f.audioLanguage,
                                      isOriginal: f.audioIsOriginal, isDubbed: f.audioIsDubbed)
                }
                .sorted { ($0.isOriginal ? 0 : 1, $0.name) < ($1.isOriginal ? 0 : 1, $1.name) }
            }
            s.videoHeight = video.height
            s.source = "\(client.name) \(video.height)p"
            out.append(s)
        }
        if let muxed, let m = finalURL(muxed) {
            var s = meta
            s.isHLS = false
            s.hlsURL = m
            s.audioURL = nil
            s.videoHeight = muxed.height
            s.source = "\(client.name) \(muxed.height)p MP4"
            out.append(s)
        }
        return out
    }

    /// Metadata-only player response (title, captions …) from the first answering client.
    static func stream(_ videoId: String) async throws -> StreamInfo {
        if let first = await streamCandidates(videoId).candidates.first { return first }
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

    /// Loads a comment page. Watch-page tokens belong to `next`, tokens from the Shorts
    /// panel to `browse`; when `endpoint` is unknown both are tried.
    static func comments(_ token: String, endpoint: String? = nil) async throws -> CommentPage {
        let endpoints = endpoint.map { [$0] } ?? ["next", "browse"]
        var lastError: Error?
        for ep in endpoints {
            do {
                let j = try await api.post(ep, ["continuation": token])
                var page = Parser.comments(j)
                page.endpoint = ep
                let empty = page.comments.isEmpty && page.continuation == nil && page.countText == nil
                if !empty || ep == endpoints.last { return page }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? YTError.invalidResponse
    }

    /// Comment token from the Shorts player (used when the watch page has none).
    static func shortCommentsToken(_ videoId: String) async -> String? {
        guard let j = try? await api.post("reel/reel_item_watch", [
            "playerRequest": ["videoId": videoId],
            "params": "CAUwAg%3D%3D",
            "disablePlayerResponse": true
        ]) else { return nil }
        for panel in j["engagementPanels"].array {
            let p = panel["engagementPanelSectionListRenderer"]
            let tag = (p["targetId"].string ?? "") + (p["panelIdentifier"].string ?? "")
            guard tag.contains("comment") else { continue }
            if let token = p["content"].findFirst("continuationCommand")["token"].string { return token }
        }
        return nil
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

    // MARK: Writing comments

    /// Posts a new top-level comment. `params` comes from the comment section of a
    /// signed-in response; without it the parameters are built like the web client does.
    static func postComment(_ text: String, videoId: String, params: String?) async throws {
        guard CookieJar.shared.isSignedIn else { throw YTError.notSignedIn }
        let p = params ?? CommentParams.create(videoId: videoId)
        let j = try await api.post("comment/create_comment", ["createCommentParams": p, "commentText": text])
        try checkAction(j)
    }

    /// Answers the comment `commentId`.
    static func postReply(_ text: String, videoId: String, commentId: String, params: String?) async throws {
        guard CookieJar.shared.isSignedIn else { throw YTError.notSignedIn }
        let p = params ?? CommentParams.reply(videoId: videoId, commentId: commentId)
        let j = try await api.post("comment/create_comment_reply", ["createReplyParams": p, "commentText": text])
        try checkAction(j)
    }

    private static func checkAction(_ j: JSON) throws {
        let status = j.at("actionResult.status").string
        if status == "STATUS_SUCCEEDED" || (status == nil && j["actions"].exists) { return }
        let message = j.at("actionResult.feedback").text
            ?? j.findFirst("errorMessage").findFirst("text").text
        throw YTError.unplayable(message ?? "Der Kommentar konnte nicht gesendet werden.")
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

/// Protobuf-encoded parameters for writing comments (same layout as the web client).
enum CommentParams {
    static func create(videoId: String) -> String {
        encode(string(2, videoId) + message(5, varint(1, 0)) + varint(10, 7))
    }

    static func reply(videoId: String, commentId: String) -> String {
        encode(string(2, videoId) + string(4, commentId) + message(5, varint(1, 0)) + varint(10, 7))
    }

    private static func rawVarint(_ value: Int) -> [UInt8] {
        var v = UInt64(value)
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private static func varint(_ field: Int, _ value: Int) -> [UInt8] {
        rawVarint(field << 3) + rawVarint(value)
    }

    private static func message(_ field: Int, _ bytes: [UInt8]) -> [UInt8] {
        rawVarint(field << 3 | 2) + rawVarint(bytes.count) + bytes
    }

    private static func string(_ field: Int, _ value: String) -> [UInt8] {
        message(field, Array(value.utf8))
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        let base64 = Data(bytes).base64EncodedString()
        return base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base64
    }
}
