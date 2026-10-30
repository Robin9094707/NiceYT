import CryptoKit
import Foundation
import WebKit

struct SPUser: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let imageURL: URL?
    let product: String?
}

struct SPPlaylist: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var imageURL: URL?
    var owner: String?
    var trackCount: Int?

    init?(_ j: JSON) {
        guard let id = j["id"].string else { return nil }
        self.id = id
        name = j["name"].string ?? ""
        imageURL = j.at("images.0.url").string.flatMap(URL.init(string:))
        owner = j.at("owner.display_name").string
        trackCount = j.at("tracks.total").int ?? j.at("items.total").int
    }

    var shareURL: URL { URL(string: "https://open.spotify.com/playlist/\(id)")! }
}

struct SPAlbum: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var artist: String
    var imageURL: URL?
    var year: String?

    init?(_ j: JSON) {
        guard let id = j["id"].string else { return nil }
        self.id = id
        name = j["name"].string ?? ""
        artist = j["artists"].array.compactMap { $0["name"].string }.joined(separator: ", ")
        imageURL = j.at("images.0.url").string.flatMap(URL.init(string:))
        year = j["release_date"].string.map { String($0.prefix(4)) }
    }

    var shareURL: URL { URL(string: "https://open.spotify.com/album/\(id)")! }
}

struct SPSearchResult: Sendable {
    var tracks: [DZTrack] = []
    var albums: [SPAlbum] = []
    var playlists: [SPPlaylist] = []
    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && playlists.isEmpty }
}

enum SpotifyError: LocalizedError {
    case notLoggedIn, http(Int), noToken

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Bitte zuerst bei Spotify anmelden."
        case .http(let c): return "Spotify antwortet mit HTTP \(c)."
        case .noToken: return "Spotify-Sitzung konnte nicht erneuert werden – bitte neu anmelden."
        }
    }
}

/// Spotify Web API with either the web player's session (signed in on open.spotify.com)
/// or an own Client ID (official OAuth with PKCE).
actor Spotify {
    static let shared = Spotify()

    enum Mode: String { case web, client }

    static let redirectURI = "niceyt://spotify-callback"
    private static let refreshKey = "spotifyRefreshToken"

    private var token: String?
    private var expires = Date.distantPast
    private(set) var user: SPUser?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        return URLSession(configuration: config)
    }()

    static var mode: Mode? {
        get { UserDefaults.standard.string(forKey: "spotifyMode").flatMap(Mode.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "spotifyMode") }
    }

    static var clientId: String? {
        get { UserDefaults.standard.string(forKey: "spotifyClientId").flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: "spotifyClientId") }
    }

    static var cachedUser: SPUser? {
        guard mode != nil, let data = UserDefaults.standard.data(forKey: "spotifyUser") else { return nil }
        return try? JSONDecoder().decode(SPUser.self, from: data)
    }

    // MARK: Auth

    /// Token captured from the signed-in web player.
    func useWebToken(_ value: String, expiresAt: Date?) async throws -> SPUser {
        token = value
        expires = expiresAt ?? Date().addingTimeInterval(50 * 60)
        Self.mode = .web
        return try await loadUser()
    }

    /// Official OAuth: exchanges the authorization code (PKCE).
    func completeClientLogin(code: String, verifier: String, clientId: String) async throws -> SPUser {
        let j = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
            "client_id": clientId, "code_verifier": verifier
        ])
        try storeToken(j)
        Self.clientId = clientId
        Self.mode = .client
        return try await loadUser()
    }

    func restore() async -> SPUser? {
        if let user { return user }
        guard Self.mode != nil else { return nil }
        return try? await loadUser()
    }

    func logout() {
        token = nil
        expires = .distantPast
        user = nil
        Self.mode = nil
        Keychain.remove(Self.refreshKey)
        UserDefaults.standard.removeObject(forKey: "spotifyUser")
    }

    private func loadUser() async throws -> SPUser {
        let j = try await get("me")
        guard let id = j["id"].string else { throw SpotifyError.notLoggedIn }
        let u = SPUser(id: id, name: j["display_name"].string ?? id,
                       imageURL: j.at("images.0.url").string.flatMap(URL.init(string:)), product: j["product"].string)
        user = u
        if let data = try? JSONEncoder().encode(u) { UserDefaults.standard.set(data, forKey: "spotifyUser") }
        return u
    }

    private func tokenRequest(_ form: [String: String]) async throws -> JSON {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SpotifyError.http(status) }
        return JSON(data: data)
    }

    private func storeToken(_ j: JSON) throws {
        guard let access = j["access_token"].string else { throw SpotifyError.noToken }
        token = access
        expires = Date().addingTimeInterval(Double(j["expires_in"].int ?? 3600) - 60)
        if let refresh = j["refresh_token"].string { Keychain.set(Data(refresh.utf8), for: Self.refreshKey) }
    }

    private func validToken() async throws -> String {
        if let token, expires > Date() { return token }
        switch Self.mode {
        case .web:
            guard let fresh = await SpotifyWebSession.shared.fetchToken() else { throw SpotifyError.noToken }
            token = fresh.token
            expires = fresh.expires ?? Date().addingTimeInterval(50 * 60)
            return fresh.token
        case .client:
            guard let clientId = Self.clientId,
                  let refresh = Keychain.get(Self.refreshKey).flatMap({ String(data: $0, encoding: .utf8) }) else {
                throw SpotifyError.noToken
            }
            try storeToken(try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientId]))
            guard let token else { throw SpotifyError.noToken }
            return token
        case nil:
            throw SpotifyError.notLoggedIn
        }
    }

    // MARK: Requests

    func get(_ path: String, retry: Int = 0) async throws -> JSON {
        let url = path.hasPrefix("http") ? URL(string: path)! : URL(string: "https://api.spotify.com/v1/" + path)!
        var req = URLRequest(url: url)
        req.setValue("Bearer " + (try await validToken()), forHTTPHeaderField: "Authorization")
        req.setValue("de", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401, retry < 1 {
            token = nil
            expires = .distantPast
            return try await get(path, retry: retry + 1)
        }
        if status == 429, retry < 3 {
            let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
            try await Task.sleep(for: .seconds(min(wait, 10)))
            return try await get(path, retry: retry + 1)
        }
        guard (200..<300).contains(status) else { throw SpotifyError.http(status) }
        return JSON(data: data)
    }

    /// Follows `next` links of a paging object (up to `limit` items).
    private func paged(_ first: String, limit: Int = 5000, items: (JSON) -> [JSON] = { $0["items"].array }) async throws -> [JSON] {
        var out: [JSON] = []
        var next: String? = first
        while let path = next, out.count < limit {
            let j = try await get(path)
            out += items(j)
            next = j["next"].string
        }
        return out
    }

    // MARK: Library

    func playlists() async throws -> [SPPlaylist] {
        try await paged("me/playlists?limit=50", limit: 500).compactMap(SPPlaylist.init)
    }

    func likedTracks() async throws -> [DZTrack] {
        try await paged("me/tracks?limit=50").compactMap { DZTrack(spotify: $0["track"]) }
    }

    func playlist(_ id: String) async throws -> (SPPlaylist?, [DZTrack]) {
        let info = SPPlaylist(try await get("playlists/\(id)?fields=id,name,images,owner(display_name),tracks(total)"))
        var raw: [JSON]
        do {
            raw = try await paged("playlists/\(id)/items?limit=100")
        } catch {
            raw = try await paged("playlists/\(id)/tracks?limit=100")
        }
        let tracks = raw.compactMap { DZTrack(spotify: $0["item"].exists ? $0["item"] : $0["track"]) }
        return (info, tracks)
    }

    func album(_ id: String) async throws -> (SPAlbum?, [DZTrack]) {
        let j = try await get("albums/\(id)")
        let album = SPAlbum(j)
        var tracks: [DZTrack] = []
        for t in j.at("tracks.items").array {
            // Album track objects lack the album – add it for covers and tags.
            var dict = (t.raw as? [String: Any]) ?? [:]
            dict["album"] = j.raw
            if let track = DZTrack(spotify: JSON(dict)) { tracks.append(track) }
        }
        return (album, tracks)
    }

    func search(_ query: String) async throws -> SPSearchResult {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~ ")
        let q = (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query).replacingOccurrences(of: " ", with: "%20")
        let j = try await get("search?q=\(q)&type=track,album,playlist&limit=20&market=from_token")
        var out = SPSearchResult()
        out.tracks = j.at("tracks.items").array.compactMap(DZTrack.init(spotify:))
        out.albums = j.at("albums.items").array.compactMap(SPAlbum.init)
        out.playlists = j.at("playlists.items").array.compactMap(SPPlaylist.init)
        return out
    }

    // MARK: PKCE helpers

    nonisolated static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    nonisolated static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    nonisolated private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func authorizeURL(clientId: String, challenge: String) -> URL {
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: "user-read-private user-library-read playlist-read-private playlist-read-collaborative")
        ]
        return c.url!
    }
}

/// The signed-in open.spotify.com session: keeps its cookies in an own website data store
/// and reads the access token the web player requests for itself.
@MainActor
final class SpotifyWebSession: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = SpotifyWebSession()
    static let storeId = UUID(uuidString: "6E1C3A52-5D1B-4C1E-9C55-3F1D1F2B7A01")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    private var webView: WKWebView?
    private var waiters: [CheckedContinuation<(token: String, expires: Date?)?, Never>] = []
    private var timeout: Task<Void, Never>?
    /// Called for every token seen (the login sheet listens to it).
    var onToken: ((String, Date?) -> Void)?

    static var dataStore: WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: storeId) }

    func configuration() -> WKWebViewConfiguration {
        let controller = WKUserContentController()
        controller.add(self, name: "niceSpotify")
        controller.addUserScript(WKUserScript(source: Self.sniffer, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = Self.dataStore
        config.mediaTypesRequiringUserActionForPlayback = .all
        return config
    }

    /// Loads the web player invisibly and waits for its access token.
    func fetchToken() async -> (token: String, expires: Date?)? {
        await withCheckedContinuation { cont in
            waiters.append(cont)
            guard waiters.count == 1 else { return }
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 4, height: 4), configuration: configuration())
            web.customUserAgent = Self.userAgent
            web.navigationDelegate = self
            webView = web
            web.load(URLRequest(url: URL(string: "https://open.spotify.com/")!))
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
        }
    }

    private func finish(_ result: (token: String, expires: Date?)?) {
        timeout?.cancel()
        timeout = nil
        let list = waiters
        waiters = []
        webView?.stopLoading()
        webView = nil
        list.forEach { $0.resume(returning: result) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        let j = JSON(data: Data(text.utf8))
        guard let token = j["token"].string, token.count > 40, j["anonymous"].bool != true else { return }
        let ms = j["exp"].double ?? 0
        let expires = ms > 0 ? Date(timeIntervalSince1970: ms / 1000).addingTimeInterval(-60) : nil
        onToken?(token, expires)
        if !waiters.isEmpty { finish((token, expires)) }
    }

    /// Forgets the Spotify web login (cookies of the own data store).
    static func clear() async {
        try? await WKWebsiteDataStore.remove(forIdentifier: storeId)
    }

    private static let sniffer = #"""
    (function () {
      'use strict';
      function post(t, e, anon) {
        try { window.webkit.messageHandlers.niceSpotify.postMessage(JSON.stringify({ token: t, exp: e || 0, anonymous: !!anon })); } catch (x) {}
      }
      function header(h) {
        try {
          if (!h) return null;
          if (typeof h.get === 'function') return h.get('authorization');
          if (Array.isArray(h)) { for (var i = 0; i < h.length; i++) if (String(h[i][0]).toLowerCase() === 'authorization') return h[i][1]; return null; }
          return h.authorization || h.Authorization || null;
        } catch (x) { return null; }
      }
      function check(a) { if (a && /^Bearer\s+/i.test(a)) post(a.replace(/^Bearer\s+/i, ''), 0, false); }
      var of = window.fetch;
      window.fetch = function (input, init) {
        try {
          check(header(init && init.headers) || (input && input.headers ? header(input.headers) : null));
          var u = typeof input === 'string' ? input : (input && input.url) || '';
          if (/\/api\/token|get_access_token/.test(u)) {
            var p = of.apply(this, arguments);
            p.then(function (r) { return r.clone().json(); }).then(function (j) {
              if (j && j.accessToken) post(j.accessToken, j.accessTokenExpirationTimestampMs, j.isAnonymous);
            }).catch(function () {});
            return p;
          }
        } catch (x) {}
        return of.apply(this, arguments);
      };
      var sh = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function (k, v) {
        try { if (String(k).toLowerCase() === 'authorization') check(v); } catch (x) {}
        return sh.apply(this, arguments);
      };
    })();
    """#
}
