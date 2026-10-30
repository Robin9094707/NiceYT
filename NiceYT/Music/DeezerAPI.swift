import Foundation

/// Client for Deezer's private web gateway (`gw-light.php`) and media API, signed in with
/// the account's `arl` cookie – the same protocol deezer-py / deemix use.
actor Deezer {
    static let shared = Deezer()

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let arlKey = "deezerARL"

    private let session: URLSession
    private let cookies: HTTPCookieStorage
    private var apiToken: String?
    private(set) var user: DZUser?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 25
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept-Language": "de-DE,de;q=0.9"]
        cookies = config.httpCookieStorage ?? HTTPCookieStorage.shared
        session = URLSession(configuration: config)
    }

    // MARK: Session

    static var storedARL: String? {
        Keychain.get(arlKey).flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Signs in with an `arl` cookie (from the browser or the in-app login).
    @discardableResult
    func login(arl raw: String) async throws -> DZUser {
        let arl = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"';")))
            .replacingOccurrences(of: "arl=", with: "")
        guard arl.count > 40 else { throw DeezerError.invalidARL }
        for c in cookies.cookies ?? [] { cookies.deleteCookie(c) }
        if let cookie = HTTPCookie(properties: [
            .domain: ".deezer.com", .path: "/", .name: "arl", .value: arl, .secure: "TRUE",
            .expires: Date(timeIntervalSinceNow: 365 * 24 * 3600)
        ]) {
            cookies.setCookie(cookie)
        }
        apiToken = nil
        let data = try await gw("deezer.getUserData")
        guard let id = data.at("USER.USER_ID").string, id != "0" else {
            user = nil
            throw DeezerError.invalidARL
        }
        apiToken = data["checkForm"].string
        let o = data.at("USER.OPTIONS")
        let u = DZUser(
            id: id,
            name: data.at("USER.BLOG_NAME").string ?? "Deezer",
            picture: data.at("USER.USER_PICTURE").string,
            licenseToken: o["license_token"].string ?? "",
            canStreamHQ: (o["web_hq"].bool ?? false) || (o["mobile_hq"].bool ?? false),
            canStreamLossless: (o["web_lossless"].bool ?? false) || (o["mobile_lossless"].bool ?? false),
            country: o["license_country"].string ?? "",
            lovedTracksId: data.at("USER.LOVEDTRACKS_ID").string,
            offerName: data["OFFER_NAME"].string ?? data.at("USER.OFFER_NAME").string
        )
        user = u
        Keychain.set(Data(arl.utf8), for: Self.arlKey)
        return u
    }

    func logout() {
        for c in cookies.cookies ?? [] { cookies.deleteCookie(c) }
        apiToken = nil
        user = nil
        Keychain.remove(Self.arlKey)
    }

    /// Restores the stored session (on app start).
    func restore() async -> DZUser? {
        if let user { return user }
        guard let arl = Self.storedARL else { return nil }
        return try? await login(arl: arl)
    }

    // MARK: Gateway

    /// Calls a `gw-light.php` method and returns its `results`.
    func gw(_ method: String, _ args: [String: Any] = [:], retry: Int = 0) async throws -> JSON {
        if method != "deezer.getUserData", apiToken == nil {
            let data = try await gw("deezer.getUserData")
            apiToken = data["checkForm"].string
        }
        var comps = URLComponents(string: "https://www.deezer.com/ajax/gw-light.php")!
        comps.queryItems = [
            .init(name: "method", value: method),
            .init(name: "input", value: "3"),
            .init(name: "api_version", value: "1.0"),
            .init(name: "api_token", value: method == "deezer.getUserData" ? "" : (apiToken ?? ""))
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: args)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DeezerError.http(status) }
        let j = JSON(data: data)
        let error = j["error"]
        if !error.keys.isEmpty {
            let keys = Set(error.keys)
            if retry < 2, keys.contains("GATEWAY_ERROR") || keys.contains("VALID_TOKEN_REQUIRED") {
                apiToken = nil
                return try await gw(method, args, retry: retry + 1)
            }
            let fallback = j.at("payload.FALLBACK")
            if retry < 2, !fallback.keys.isEmpty, let dict = fallback.raw as? [String: Any] {
                var merged = args
                for (k, v) in dict { merged[k] = v }
                return try await gw(method, merged, retry: retry + 1)
            }
            let message = error.keys.compactMap { error[$0].string }.joined(separator: ", ")
            throw DeezerError.api(message.isEmpty ? keys.joined(separator: ", ") : message)
        }
        return j["results"]
    }

    // MARK: Catalogue

    func search(_ query: String) async throws -> DZSearchResult {
        let r = try await gw("deezer.pageSearch", [
            "query": query, "start": 0, "nb": 40, "suggest": true, "artist_suggest": true, "top_tracks": true
        ])
        var out = DZSearchResult()
        out.tracks = r.at("TRACK.data").array.compactMap(DZTrack.init(gw:))
        out.albums = r.at("ALBUM.data").array.compactMap(DZAlbum.init(gw:))
        out.artists = r.at("ARTIST.data").array.compactMap(DZArtist.init(gw:))
        out.playlists = r.at("PLAYLIST.data").array.compactMap(DZPlaylist.init(gw:))
        return out
    }

    func album(_ id: String) async throws -> (DZAlbum?, [DZTrack]) {
        let r = try await gw("deezer.pageAlbum", ["ALB_ID": id, "lang": "de", "header": true, "tab": 0])
        let album = DZAlbum(gw: r["DATA"])
        var tracks = r.at("SONGS.data").array.compactMap(DZTrack.init(gw:))
        if let album {
            for i in tracks.indices where tracks[i].releaseDate == nil { tracks[i].releaseDate = album.releaseDate }
        }
        return (album, tracks)
    }

    func playlist(_ id: String) async throws -> (DZPlaylist?, [DZTrack]) {
        let r = try await gw("deezer.pagePlaylist", [
            "PLAYLIST_ID": id, "lang": "de", "header": true, "tab": 0, "nb": 2000, "start": 0
        ])
        var tracks = r.at("SONGS.data").array.compactMap(DZTrack.init(gw:))
        let total = r.at("SONGS.total").int ?? tracks.count
        // Very large playlists come in pages.
        while tracks.count < total, tracks.count < 10_000 {
            let more = try await gw("playlist.getSongs", ["PLAYLIST_ID": id, "start": tracks.count, "nb": 2000])
            let page = more["data"].array.compactMap(DZTrack.init(gw:))
            if page.isEmpty { break }
            tracks += page
        }
        return (DZPlaylist(gw: r["DATA"]), tracks)
    }

    func artist(_ id: String) async throws -> (DZArtist?, [DZTrack], [DZAlbum]) {
        let r = try await gw("deezer.pageArtist", ["ART_ID": id, "lang": "de", "header": true, "tab": 0])
        let top = r.at("TOP.data").array.compactMap(DZTrack.init(gw:))
        let albums = r.at("ALBUMS.data").array.compactMap(DZAlbum.init(gw:))
        return (DZArtist(gw: r["DATA"]), top, albums)
    }

    /// Full track objects (with fresh tokens) for the given ids, in order.
    func tracks(_ ids: [String]) async throws -> [DZTrack] {
        var out: [DZTrack] = []
        for start in stride(from: 0, to: ids.count, by: 200) {
            let chunk = Array(ids[start..<min(ids.count, start + 200)])
            let r = try await gw("song.getListData", ["SNG_IDS": chunk])
            out += r["data"].array.compactMap(DZTrack.init(gw:))
        }
        return out
    }

    func favoriteTracks() async throws -> [DZTrack] {
        guard let user else { throw DeezerError.notLoggedIn }
        if let loved = user.lovedTracksId, loved != "0" {
            return try await playlist(loved).1
        }
        let r = try await gw("song.getFavoriteIds", ["nb": 10000, "start": 0, "checksum": NSNull()])
        return try await tracks(r["data"].array.compactMap { $0["SNG_ID"].string })
    }

    func favoriteIds() async -> Set<String> {
        guard let r = try? await gw("song.getFavoriteIds", ["nb": 10000, "start": 0, "checksum": NSNull()]) else { return [] }
        return Set(r["data"].array.compactMap { $0["SNG_ID"].string })
    }

    func setFavorite(_ trackId: String, _ on: Bool) async throws {
        _ = try await gw(on ? "favorite_song.add" : "favorite_song.remove", ["SNG_ID": trackId])
    }

    func userPlaylists() async throws -> [DZPlaylist] {
        guard let user else { throw DeezerError.notLoggedIn }
        let r = try await gw("deezer.pageProfile", ["USER_ID": user.id, "tab": "playlists", "nb": 200])
        return r.at("TAB.playlists.data").array.compactMap(DZPlaylist.init(gw:))
            .filter { $0.id != user.lovedTracksId }
    }

    /// Current charts (public API) resolved to playable tracks.
    func chartTracks(limit: Int = 50) async throws -> [DZTrack] {
        let ids = try await publicIds("https://api.deezer.com/chart/0/tracks?limit=\(limit)")
        return try await tracks(ids)
    }

    func chartPlaylists(limit: Int = 20) async -> [DZPlaylist] {
        guard let url = URL(string: "https://api.deezer.com/chart/0/playlists?limit=\(limit)"),
              let (data, _) = try? await session.data(from: url) else { return [] }
        return JSON(data: data)["data"].array.compactMap { p -> DZPlaylist? in
            guard let id = p["id"].string else { return nil }
            return DZPlaylist(gw: JSON([
                "PLAYLIST_ID": id, "TITLE": p["title"].string ?? "", "PLAYLIST_PICTURE": p["md5_image"].string ?? "",
                "PICTURE_TYPE": p["picture_type"].string ?? "playlist", "NB_SONG": p["nb_tracks"].int ?? 0,
                "PARENT_USERNAME": p.at("user.name").string ?? "Deezer"
            ] as [String: Any]))
        }
    }

    /// Flow-like mix: the user's personal radio, else the charts.
    func flow() async throws -> [DZTrack] {
        guard let user else { throw DeezerError.notLoggedIn }
        if let r = try? await gw("radio.getUserRadio", ["USER_ID": user.id]) {
            let tracks = r["data"].array.compactMap(DZTrack.init(gw:))
            if !tracks.isEmpty { return tracks }
        }
        return try await chartTracks(limit: 30)
    }

    private func publicIds(_ urlString: String) async throws -> [String] {
        guard let url = URL(string: urlString) else { return [] }
        let (data, _) = try await session.data(from: url)
        return JSON(data: data)["data"].array.compactMap { $0["id"].string }
    }

    // MARK: Media

    /// Encrypted CDN URL of the track in the best available format up to `quality`.
    func mediaURL(for track: DZTrack, quality: DZQuality) async throws -> (url: URL, quality: DZQuality, track: DZTrack) {
        guard let user, !user.licenseToken.isEmpty else { throw DeezerError.notLoggedIn }
        var track = track
        if !track.tokenIsFresh, let fresh = try await tracks([track.id]).first {
            track.token = fresh.token
            track.tokenExpires = fresh.tokenExpires
            track.fallbackId = fresh.fallbackId
        }
        let allowed = quality.fallbackChain.filter {
            switch $0 {
            case .flac: return user.canStreamLossless
            case .mp3_320: return user.canStreamHQ
            case .mp3_128: return true
            }
        }
        var candidates = [track]
        if let fb = track.fallbackId, let alt = try? await tracks([fb]).first { candidates.append(alt) }
        var lastError: Error = DeezerError.noStream
        for candidate in candidates {
            guard let token = candidate.token else { continue }
            do {
                let (url, format) = try await requestURL(token: token, license: user.licenseToken, formats: allowed)
                // Decryption uses the id of the track that was actually served.
                var served = track
                if candidate.id != track.id { served = candidate }
                return (url, format, served)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func requestURL(token: String, license: String, formats: [DZQuality]) async throws -> (URL, DZQuality) {
        var req = URLRequest(url: URL(string: "https://media.deezer.com/v1/get_url")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "license_token": license,
            "media": [["type": "FULL", "formats": formats.map { ["cipher": "BF_CBC_STRIPE", "format": $0.rawValue] }]],
            "track_tokens": [token]
        ] as [String: Any])
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DeezerError.http(status) }
        let item = JSON(data: data)["data"][0]
        if let code = item["errors"][0]["code"].int {
            if code == 2002 { throw DeezerError.geoBlocked }
            throw DeezerError.api(item["errors"][0]["message"].string ?? "Fehler \(code)")
        }
        let media = item["media"][0]
        guard let s = media["sources"][0]["url"].string, let url = URL(string: s) else { throw DeezerError.noStream }
        let format = DZQuality(rawValue: media["format"].string ?? "") ?? formats.first ?? .mp3_128
        return (url, format)
    }
}
