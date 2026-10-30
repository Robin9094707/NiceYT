import Foundation

/// YouTube Music (music.youtube.com) – songs search and radio, no account needed.
/// Results become tracks with id "yt-<videoId>" and play through the YouTube sources.
enum YouTubeMusic {
    static let clientVersion = "1.20260701.01.00"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
    private static let songWords: Set<String> = ["titel", "songs", "song", "lieder"]
    /// Filter params for "songs" (changes now and then – also read from the result chips).
    private static let songsParams = ["EgWKAQIIAWoMEAUQBBAVEAoQEBAR", "EgWKAQIIAWoKEAkQBRAKEAMQBA=="]

    static func post(_ endpoint: String, _ body: [String: Any]) async throws -> JSON {
        var payload = body
        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": clientVersion, "hl": AppSettings.hl, "gl": AppSettings.gl]
        if let v = InnerTube.shared.visitorData { client["visitorData"] = v }
        payload["context"] = ["client": client]
        var req = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        req.setValue("67", forHTTPHeaderField: "X-Youtube-Client-Name")
        req.setValue(clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        if let v = InnerTube.shared.visitorData { req.setValue(v, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        let jar = CookieJar.shared
        if jar.isSignedIn {
            req.setValue(jar.header, forHTTPHeaderField: "Cookie")
            if let auth = jar.authorization(origin: "https://music.youtube.com") {
                req.setValue(auth, forHTTPHeaderField: "Authorization")
            }
            req.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        }
        let (data, response) = try await InnerTube.shared.session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw YTError.http(status) }
        return JSON(data: data)
    }

    /// Songs for `query`: the "Songs" filter if YouTube Music offers it, else all playable items
    /// (songs first, then videos).
    static func searchSongs(_ query: String) async throws -> [DZTrack] {
        let first = try await post("search", ["query": query])
        var songs = items(in: first).filter(\.isSong).map(\.track)
        if songs.count < 5 {
            var params = first.findAll("chipCloudChipRenderer").compactMap { chip -> String? in
                let text = (chip["text"].text ?? "").lowercased()
                guard songWords.contains(text) else { return nil }
                return chip.at("navigationEndpoint.searchEndpoint.params").string?.removingPercentEncoding
            }
            params += songsParams
            for p in params {
                if let j = try? await post("search", ["query": query, "params": p]) {
                    let found = items(in: j).map(\.track)
                    if !found.isEmpty { songs = found; break }
                }
            }
        }
        if songs.isEmpty { songs = items(in: first).map(\.track) }
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
    }

    /// Endless radio starting with `videoId` (like "Radio starten" in YouTube Music).
    static func radio(_ videoId: String) async throws -> [DZTrack] {
        let j = try await post("next", ["videoId": videoId, "playlistId": "RDAMVM" + videoId, "isAudioOnly": true])
        return j.findAll("playlistPanelVideoRenderer").compactMap { r -> DZTrack? in
            guard let id = r["videoId"].string else { return nil }
            let title = r["title"].text ?? ""
            let byline = r["longBylineText"]["runs"].array.compactMap { $0["text"].string }
            let artist = byline.first ?? r["shortBylineText"].text ?? ""
            var t = track(id: id, title: title, artist: artist, thumb: r["thumbnail"].thumbURL)
            t.duration = seconds(r["lengthText"].text)
            if byline.count >= 3 { t.album = byline[2] }
            return t
        }
    }

    // MARK: Parsing

    private struct Item {
        let track: DZTrack
        let isSong: Bool
    }

    private static func items(in j: JSON) -> [Item] {
        j.findAll("musicResponsiveListItemRenderer").compactMap { r -> Item? in
            let columns = r["flexColumns"].array.map { $0.at("musicResponsiveListItemFlexColumnRenderer.text.runs").array }
            guard let titleRuns = columns.first, let titleRun = titleRuns.first else { return nil }
            guard let videoId = titleRun.at("navigationEndpoint.watchEndpoint.videoId").string
                    ?? r.at("playlistItemData.videoId").string else { return nil }
            let info = columns.count > 1 ? columns[1] : []
            let texts = info.compactMap { $0["text"].string }
            let kind = texts.first?.lowercased() ?? ""
            let typeLabels: Set<String> = ["titel", "song", "video", "episode", "folge"]
            var artists: [String] = []
            var album: String?
            var duration = 0
            for run in info {
                guard let text = run["text"].string else { continue }
                let page = run.at("navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType").string ?? ""
                if page.contains("ARTIST") || page.contains("USER_CHANNEL") {
                    artists.append(text)
                } else if page.contains("ALBUM") {
                    album = text
                } else if text.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil {
                    duration = seconds(text)
                }
            }
            if artists.isEmpty {
                // Plain-text byline: "Titel • Artist • Album • 3:12" (first entry may be the type).
                let parts = texts.filter { $0 != " • " && $0 != " & " && $0 != ", " }
                let start = typeLabels.contains(parts.first?.lowercased() ?? "") ? 1 : 0
                if parts.count > start { artists = [parts[start]] }
            }
            let thumb = r.at("thumbnail.musicThumbnailRenderer.thumbnail").thumbURL
            var t = track(id: videoId, title: titleRun["text"].string ?? "", artist: artists.joined(separator: ", "), thumb: thumb)
            t.artists = artists.isEmpty ? [t.artist] : artists
            t.duration = duration
            if let album { t.album = album }
            let isVideo = kind == "video" || r.at("musicItemRendererDisplayPolicy").string != nil
            return Item(track: t, isSong: !isVideo && (kind == "titel" || kind == "song" || album != nil))
        }
    }

    static func track(id: String, title: String, artist: String, thumb: URL?) -> DZTrack {
        var t = DZTrack(youtube: Video(id: id, title: title), title: title, artist: artist)
        t.album = "YouTube Music"
        t.artworkURL = squareArt(thumb) ?? t.artworkURL
        t.sourceURL = URL(string: "https://music.youtube.com/watch?v=\(id)")
        return t
    }

    /// YouTube Music thumbnails are square; ask for a large size.
    private static func squareArt(_ url: URL?) -> URL? {
        guard let s = url?.absoluteString else { return nil }
        if let r = s.range(of: #"=w\d+-h\d+.*$"#, options: .regularExpression) {
            return URL(string: s.replacingCharacters(in: r, with: "=w600-h600-l90-rj"))
        }
        return url
    }

    private static func seconds(_ text: String?) -> Int {
        (text ?? "").split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }
}
