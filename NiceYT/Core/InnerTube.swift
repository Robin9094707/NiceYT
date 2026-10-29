import Foundation
import CryptoKit

/// Thread-safe store of the signed-in YouTube cookies.
final class CookieJar: @unchecked Sendable {
    static let shared = CookieJar()
    private let lock = NSLock()
    private var storage: [String: String]

    private init() {
        if let data = Keychain.get("cookies"),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            storage = dict
        } else {
            storage = [:]
        }
    }

    var cookies: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var isSignedIn: Bool {
        let c = cookies
        return c["SAPISID"] != nil || c["__Secure-3PAPISID"] != nil
    }

    func replace(with cookies: [String: String]) {
        lock.lock()
        storage = cookies
        lock.unlock()
        Keychain.set(try? JSONEncoder().encode(cookies), for: "cookies")
    }

    func clear() {
        lock.lock()
        storage = [:]
        lock.unlock()
        Keychain.remove("cookies")
    }

    var header: String {
        var c = cookies
        // The PREF cookie carries the account's interface language (often "en" after
        // signing in) and would override the language chosen in the app.
        c["PREF"] = Self.pref(c["PREF"])
        return c.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private static func pref(_ value: String?) -> String {
        var parts = (value ?? "").split(separator: "&").map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("hl=") && !$0.hasPrefix("gl=") }
        parts += ["hl=\(AppSettings.hl)", "gl=\(AppSettings.gl)"]
        return parts.joined(separator: "&")
    }

    /// `SAPISIDHASH` style authorization used by the YouTube web client.
    func authorization(origin: String) -> String? {
        let c = cookies
        let ts = Int(Date().timeIntervalSince1970)
        func hash(_ value: String) -> String {
            let digest = Insecure.SHA1.hash(data: Data("\(ts) \(value) \(origin)".utf8))
            return "\(ts)_" + digest.map { String(format: "%02x", $0) }.joined()
        }
        var parts: [String] = []
        if let s = c["SAPISID"] ?? c["__Secure-3PAPISID"] { parts.append("SAPISIDHASH " + hash(s)) }
        if let s = c["__Secure-1PAPISID"] { parts.append("SAPISID1PHASH " + hash(s)) }
        if let s = c["__Secure-3PAPISID"] { parts.append("SAPISID3PHASH " + hash(s)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// InnerTube client identities. Player clients mirror yt-dlp (2026.10).
enum ITClient {
    case web, ios, visionos, webSafari, mweb, tv, webEmbedded

    static let webVersion = "2.20260708.00.00"
    static let iosVersion = "21.26.4"
    static let iosDevice = "iPhone16,2"

    static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let iosUserAgent = "com.google.ios.youtube/\(iosVersion) (\(iosDevice); U; CPU iOS 18_3_2 like Mac OS X;)"

    var name: String {
        switch self {
        case .web, .webSafari: return "WEB"
        case .ios: return "IOS"
        case .visionos: return "VISIONOS"
        case .mweb: return "MWEB"
        case .tv: return "TVHTML5"
        case .webEmbedded: return "WEB_EMBEDDED_PLAYER"
        }
    }

    var id: String {
        switch self {
        case .web, .webSafari: return "1"
        case .ios: return "5"
        case .visionos: return "101"
        case .mweb: return "2"
        case .tv: return "7"
        case .webEmbedded: return "56"
        }
    }

    var version: String {
        switch self {
        case .web, .webSafari, .webEmbedded: return Self.webVersion
        case .ios: return Self.iosVersion
        case .visionos: return "1.02"
        case .mweb: return "2.20260708.05.00"
        case .tv: return "5.20260707"
        }
    }

    var userAgent: String {
        switch self {
        case .web: return Self.webUserAgent
        case .ios: return Self.iosUserAgent
        case .visionos: return "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        case .webSafari, .webEmbedded: return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)"
        case .tv: return "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1"
        case .mweb: return "Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)"
        }
    }

    /// Web-based clients accept the signed-in cookie session.
    var supportsCookies: Bool { self == .web || self == .webSafari || self == .mweb || self == .tv || self == .webEmbedded }

    /// Clients whose stream URLs carry an encrypted signature / n value (need the JS player).
    var needsJSPlayer: Bool { self == .tv || self == .webEmbedded || self == .web || self == .webSafari || self == .mweb }

    var extraContext: [String: Any] {
        switch self {
        case .web: return ["platform": "DESKTOP"]
        case .ios: return ["deviceMake": "Apple", "deviceModel": Self.iosDevice, "osName": "iPhone", "osVersion": "18.3.2.22D82"]
        case .visionos: return ["deviceMake": "Apple", "deviceModel": "RealityDevice17,1", "osName": "visionOS", "osVersion": "26.5.23O471"]
        case .tv: return ["deviceMake": "Samsung", "deviceModel": "UKS9800", "osName": "Tizen", "osVersion": "2.4.0"]
        case .webSafari, .mweb, .webEmbedded: return [:]
        }
    }
}

/// Minimal client for YouTube's private InnerTube API.
final class InnerTube: @unchecked Sendable {
    static let shared = InnerTube()
    static let origin = "https://www.youtube.com"

    let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    var visitorData: String? {
        get { UserDefaults.standard.string(forKey: "visitorData") }
        set { UserDefaults.standard.set(newValue, forKey: "visitorData") }
    }

    func context(_ client: ITClient, includeVisitor: Bool = true) -> [String: Any] {
        var c: [String: Any] = [
            "hl": AppSettings.hl,
            "gl": AppSettings.gl,
            "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
            "clientName": client.name,
            "clientVersion": client.version,
            "userAgent": client.userAgent
        ]
        for (k, v) in client.extraContext { c[k] = v }
        if includeVisitor, let v = visitorData { c["visitorData"] = v }
        var ctx: [String: Any] = ["client": c, "user": ["lockedSafetyMode": false], "request": ["useSsl": true]]
        if client == .webEmbedded { ctx["thirdParty"] = ["embedUrl": "https://www.reddit.com/"] }
        return ctx
    }

    /// POST to `youtubei/v1/<endpoint>`.
    func post(_ endpoint: String, _ body: [String: Any], client: ITClient = .web, authenticated: Bool = true) async throws -> JSON {
        var payload = body
        // visionOS/TV need the visitor id (otherwise "confirm you're not a bot").
        let sendVisitor = client != .ios
        payload["context"] = context(client, includeVisitor: sendVisitor)

        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppSettings.hl, forHTTPHeaderField: "Accept-Language")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(client.id, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-Youtube-Client-Version")
        if sendVisitor, let v = visitorData { request.setValue(v, forHTTPHeaderField: "X-Goog-Visitor-Id") }

        if client.supportsCookies {
            request.setValue(Self.origin, forHTTPHeaderField: "Origin")
            request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
            request.setValue(Self.origin + "/", forHTTPHeaderField: "Referer")
            let jar = CookieJar.shared
            if authenticated, jar.isSignedIn {
                request.setValue(jar.header, forHTTPHeaderField: "Cookie")
                if let auth = jar.authorization(origin: Self.origin) {
                    request.setValue(auth, forHTTPHeaderField: "Authorization")
                }
                request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            }
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw YTError.http(status) }
        let json = JSON(data: data)
        if client.supportsCookies, visitorData == nil, let v = json.at("responseContext.visitorData").string {
            visitorData = v
        }
        return json
    }

    /// Plain GET returning JSON (used for third-party APIs).
    func getJSON(_ url: URL) async throws -> JSON {
        var request = URLRequest(url: url)
        request.setValue("NiceYT/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw YTError.http(status) }
        return JSON(data: data)
    }

    /// Authenticated GET against youtube.com (used for watch-history pings).
    func ping(_ url: URL) async {
        var request = URLRequest(url: url)
        request.setValue(ITClient.webUserAgent, forHTTPHeaderField: "User-Agent")
        let jar = CookieJar.shared
        if jar.isSignedIn {
            request.setValue(jar.header, forHTTPHeaderField: "Cookie")
            if let auth = jar.authorization(origin: Self.origin) {
                request.setValue(auth, forHTTPHeaderField: "Authorization")
            }
        }
        _ = try? await session.data(for: request)
    }
}
