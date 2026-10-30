import Foundation

/// Client for Deezer's private web gateway (`gw-light.php`) and media API, signed in with
/// the account's `arl` cookie – the same protocol deezer-py / deemix use.
actor Deezer {
    static let shared = Deezer()

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let arlKey = "deezerARL"

    private let session: URLSession
    /// Cookies kept by hand: the `arl` from the keychain must never be dropped or
    /// replaced by whatever a response sets (bot-protection, logout pages …).
    private var cookieJar: [String: String] = [:]
    private var arl: String?
    private var apiToken: String?
    private(set) var user: DZUser?
    private var userLoadedAt = Date.distantPast
    private var restoreTask: Task<DZUser?, Never>?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 25
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept-Language": "de-DE,de;q=0.9"]
        session = URLSession(configuration: config)
    }

    // MARK: Session

    static var storedARL: String? {
        Keychain.get(arlKey).flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Last known account (shown right away on start, verified in the background).
    static var cachedUser: DZUser? {
        guard let data = UserDefaults.standard.data(forKey: "deezerUser") else { return nil }
        return try? JSONDecoder().decode(DZUser.self, from: data)
    }

    static func clean(arl raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"';")))
        if let r = s.range(of: "arl=") { s = String(s[r.upperBound...]) }
        if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Signs in with an `arl` cookie (from the browser or the in-app login). Network
    /// problems are retried; only an answer that clearly says "not signed in" counts as
    /// an invalid ARL.
    @discardableResult
    func login(arl raw: String) async throws -> DZUser {
        let value = Self.clean(arl: raw)
        guard value.count > 40 else { throw DeezerError.invalidARL }
        var lastError: Error = DeezerError.invalidARL
        var anonymousAnswers = 0
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(Double(attempt) * 1.5)) }
            cookieJar = ["arl": value]
            arl = value
            apiToken = nil
            do {
                let data = try await gw("deezer.getUserData")
                guard let id = data.at("USER.USER_ID").string else {
                    lastError = DeezerError.api("Unerwartete Antwort – bitte gleich nochmal versuchen.")
                    continue
                }
                guard id != "0" else {
                    // Deezer sometimes answers anonymously once (bot protection warming up).
                    anonymousAnswers += 1
                    lastError = DeezerError.invalidARL
                    if anonymousAnswers >= 2 { break }
                    continue
                }
                let u = makeUser(id: id, data: data)
                user = u
                userLoadedAt = Date()
                apiToken = data["checkForm"].string
                Keychain.set(Data(value.utf8), for: Self.arlKey)
                if let encoded = try? JSONEncoder().encode(u) { UserDefaults.standard.set(encoded, forKey: "deezerUser") }
                return u
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func makeUser(id: String, data: JSON) -> DZUser {
        let o = data.at("USER.OPTIONS")
        return DZUser(
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
    }

    func logout() {
        cookieJar = [:]
        arl = nil
        apiToken = nil
        user = nil
        Keychain.remove(Self.arlKey)
        UserDefaults.standard.removeObject(forKey: "deezerUser")
    }

    /// Restores the stored session (on app start). Concurrent callers share one attempt.
    func restore() async -> DZUser? {
        if let user { return user }
        if let restoreTask { return await restoreTask.value }
        guard let stored = Self.storedARL else { return nil }
        let task = Task { try? await self.login(arl: stored) }
        restoreTask = task
        let result = await task.value
        restoreTask = nil
        return result
    }

    /// The license token expires after a while: reload the account data when it's old.
    private func freshUser() async throws -> DZUser {
        if let user, Date().timeIntervalSince(userLoadedAt) < 30 * 60 { return user }
        guard let arl = arl ?? Self.storedARL else { throw DeezerError.notLoggedIn }
        return try await login(arl: arl)
    }

    // MARK: Gateway

    private var cookieHeader: String {
        var jar = cookieJar
        if jar["arl"] == nil, let arl { jar["arl"] = arl }
        return jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// Takes over session cookies from a response (never touching the `arl`).
    private func absorbCookies(_ response: URLResponse?) {
        guard let http = response as? HTTPURLResponse, let url = http.url,
              let fields = http.allHeaderFields as? [String: String] else { return }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) where cookie.name != "arl" {
            if let expires = cookie.expiresDate, expires < Date() {
                cookieJar[cookie.name] = nil
            } else {
                cookieJar[cookie.name] = cookie.value
            }
        }
    }

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
            .init(name: "api_token", value: method == "deezer.getUserData" ? "null" : (apiToken ?? "null"))
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("https://www.deezer.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.deezer.com/", forHTTPHeaderField: "Referer")
        req.httpBody = try JSONSerialization.data(withJSONObject: args)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            if retry < 2, (error as? URLError)?.code != .cancelled {
                try? await Task.sleep(for: .seconds(1))
                return try await gw(method, args, retry: retry + 1)
            }
            throw error
        }
        absorbCookies(response)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if retry < 2, status == 403 || status >= 500 {
                try? await Task.sleep(for: .seconds(1.5))
                return try await gw(method, args, retry: retry + 1)
            }
            throw DeezerError.http(status)
        }
        let j = JSON(data: data)
        guard j.exists else {
            if retry < 2 { return try await gw(method, args, retry: retry + 1) }
            throw DeezerError.api("Unerwartete Antwort")
        }
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

    func lyrics(_ trackId: String) async throws -> DZLyrics? {
        let r = try await gw("song.getLyrics", ["SNG_ID": trackId])
        let synced = r["LYRICS_SYNC_JSON"].array.compactMap { l -> (Double, String)? in
            guard let ms = l["milliseconds"].double, let text = l["line"].string else { return nil }
            return (ms / 1000, text)
        }
        let copyright = r["LYRICS_COPYRIGHTS"].string
        if !synced.isEmpty {
            return DZLyrics(lines: synced.enumerated().map { DZLyrics.Line(id: $0.offset, time: $0.element.0, text: $0.element.1) },
                            copyright: copyright)
        }
        guard let text = r["LYRICS_TEXT"].string, !text.isEmpty else { return nil }
        let lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        return DZLyrics(lines: lines.enumerated().map { DZLyrics.Line(id: $0.offset, time: nil, text: $0.element) },
                        copyright: copyright)
    }

    /// Endless mix ("radio") starting from a song.
    func trackMix(_ track: DZTrack) async throws -> [DZTrack] {
        if let r = try? await gw("song.getSearchTrackMix", ["SNG_ID": track.id, "START_WITH_INPUT_TRACK": true]) {
            let list = r["data"].array.compactMap(DZTrack.init(gw:))
            if list.count > 1 { return list }
        }
        guard let artistId = track.artistId else { return [track] }
        let top = try await artist(artistId).1.filter { $0.id != track.id }
        return [track] + top.shuffled()
    }

    func addToPlaylist(_ playlistId: String, trackId: String) async throws {
        _ = try await gw("playlist.addSongs", ["PLAYLIST_ID": playlistId, "songs": [[trackId, 0]], "offset": -1])
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
        var user = try await freshUser()
        guard !user.licenseToken.isEmpty else { throw DeezerError.notLoggedIn }
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
                let (url, format): (URL, DZQuality)
                do {
                    (url, format) = try await requestURL(token: token, license: user.licenseToken, formats: allowed)
                } catch DeezerError.license {
                    // Expired license token: reload the account once and try again.
                    userLoadedAt = .distantPast
                    user = try await freshUser()
                    (url, format) = try await requestURL(token: token, license: user.licenseToken, formats: allowed)
                }
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
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DeezerError.http(status) }
        let item = JSON(data: data)["data"][0]
        if let code = item["errors"][0]["code"].int {
            if code == 2002 { throw DeezerError.geoBlocked }
            if code == 2001 || code == 1000 { throw DeezerError.license }
            throw DeezerError.api(item["errors"][0]["message"].string ?? "Fehler \(code)")
        }
        let media = item["media"][0]
        guard let s = media["sources"][0]["url"].string, let url = URL(string: s) else { throw DeezerError.noStream }
        let format = DZQuality(rawValue: media["format"].string ?? "") ?? formats.first ?? .mp3_128
        return (url, format)
    }
}
