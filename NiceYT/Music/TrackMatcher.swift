import Foundation

/// Finds a playable source for songs that don't come from Deezer (Spotify library,
/// YouTube audio): the same recording on Deezer by ISRC, else the best YouTube upload –
/// the approach spotDL uses, without touching Spotify's DRM.
actor TrackMatcher {
    static let shared = TrackMatcher()

    private var deezerCache: [String: DZTrack?] = [:]
    private var youtubeCache: [String: String?] = [:]

    // MARK: Deezer

    func deezer(for track: DZTrack) async -> DZTrack? {
        if track.isDeezer { return track }
        if let cached = deezerCache[track.id] { return cached }
        var id: String?
        if let isrc = track.isrc, !isrc.isEmpty {
            id = await publicId("https://api.deezer.com/track/isrc:\(isrc)")
        }
        if id == nil {
            let q = "artist:\"\(track.artist)\" track:\"\(track.title)\""
            id = await bestSearchHit(q, duration: track.duration)
        }
        if id == nil {
            id = await bestSearchHit("\(track.artist) \(track.title)", duration: track.duration)
        }
        var match: DZTrack?
        if let id { match = try? await Deezer.shared.tracks([id]).first }
        deezerCache[track.id] = match
        return match
    }

    private func publicId(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let j = JSON(data: data)
        guard j["error"].exists == false, let id = j["id"].string, id != "0" else { return nil }
        return id
    }

    private func bestSearchHit(_ query: String, duration: Int) async -> String? {
        var c = URLComponents(string: "https://api.deezer.com/search")!
        c.queryItems = [.init(name: "q", value: query), .init(name: "limit", value: "10")]
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let hits = JSON(data: data)["data"].array
        let fitting = hits.first { duration == 0 || abs(($0["duration"].int ?? 0) - duration) <= 4 }
        return fitting?["id"].string
    }

    // MARK: YouTube

    /// Video id of the best YouTube upload of `track`.
    func youtube(for track: DZTrack) async -> String? {
        if let yt = track.youtubeId { return yt }
        if let cached = youtubeCache[track.id] { return cached }
        let query = "\(track.artist) - \(track.title)"
        var best: (score: Int, id: String)?
        for q in [query + " audio", query] {
            guard let page = try? await YouTube.search(q, filter: .videos) else { continue }
            for item in page.items.prefix(12) {
                guard case .video(let v) = item, !v.isLive else { continue }
                let s = score(v, for: track)
                if best == nil || s > best!.score { best = (s, v.id) }
            }
            if let best, best.score >= 60 { break }
        }
        let id = (best?.score ?? 0) > 0 ? best?.id : nil
        youtubeCache[track.id] = id
        return id
    }

    private func score(_ v: Video, for track: DZTrack) -> Int {
        let title = v.title.lowercased()
        let channel = (v.channelName ?? "").lowercased()
        let song = track.title.lowercased()
        let artist = track.artist.lowercased()
        var s = 0
        if title.contains(song) { s += 40 }
        if title.contains(artist) || channel.contains(artist) { s += 25 }
        if channel.hasSuffix("- topic") { s += 25 }
        if title.contains("official audio") || title.contains("audio") { s += 10 }
        if let d = Self.seconds(v.duration), track.duration > 0 {
            let diff = abs(d - track.duration)
            s += diff <= 3 ? 30 : diff <= 10 ? 10 : diff > 60 ? -60 : -15
        }
        for bad in ["live", "cover", "karaoke", "instrumental", "remix", "sped up", "slowed", "8d", "nightcore", "reaction"]
        where title.contains(bad) && !song.contains(bad) {
            s -= 40
        }
        return s
    }

    private static func seconds(_ text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
