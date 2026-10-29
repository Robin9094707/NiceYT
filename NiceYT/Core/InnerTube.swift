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
        cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
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

enum ITClient {
    case web, ios

    static let webVersion = "2.20251020.01.00"
    static let iosVersion = "21.16.2"
    static let iosDevice = "iPhone17,2"
    static let iosOS = "26.0.0.23A341"

    static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let iosUserAgent = "com.google.ios.youtube/\(iosVersion) (\(iosDevice); U; CPU iOS 26_0 like Mac OS X;)"
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

    func context(_ client: ITClient) -> [String: Any] {
        var c: [String: Any] = [
            "hl": AppSettings.hl,
            "gl": AppSettings.gl,
            "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60
        ]
        switch client {
        case .web:
            c["clientName"] = "WEB"
            c["clientVersion"] = ITClient.webVersion
            c["platform"] = "DESKTOP"
            c["userAgent"] = ITClient.webUserAgent
        case .ios:
            c["clientName"] = "IOS"
            c["clientVersion"] = ITClient.iosVersion
            c["deviceMake"] = "Apple"
            c["deviceModel"] = ITClient.iosDevice
            c["osName"] = "iPhone"
            c["osVersion"] = ITClient.iosOS
            c["userAgent"] = ITClient.iosUserAgent
        }
        if let v = visitorData { c["visitorData"] = v }
        return ["client": c, "user": ["lockedSafetyMode": false], "request": ["useSsl": true]]
    }

    /// POST to `youtubei/v1/<endpoint>`.
    func post(_ endpoint: String, _ body: [String: Any], client: ITClient = .web, authenticated: Bool = true) async throws -> JSON {
        var payload = body
        payload["context"] = context(client)

        var request = URLRequest(url: URL(string: "\(Self.origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppSettings.hl, forHTTPHeaderField: "Accept-Language")
        if let v = visitorData { request.setValue(v, forHTTPHeaderField: "X-Goog-Visitor-Id") }

        switch client {
        case .web:
            request.setValue(ITClient.webUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
            request.setValue(ITClient.webVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
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
        case .ios:
            request.setValue(ITClient.iosUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("5", forHTTPHeaderField: "X-Youtube-Client-Name")
            request.setValue(ITClient.iosVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw YTError.http(status) }
        let json = JSON(data: data)
        if visitorData == nil, let v = json.at("responseContext.visitorData").string {
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
