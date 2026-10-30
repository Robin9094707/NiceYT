import Foundation

/// Browser identities used for pages and downloads (readable from any thread).
enum UserAgents {
    static let mobile = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
    static let desktop = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
}

/// One file of a download option, with mirrors to try in order.
struct MediaFile: Hashable, Sendable {
    var candidates: [URL]
    var ext: String
    /// Separate sound track that gets merged in (DASH video).
    var audio: [URL] = []
}

/// Something the assistant offers: a video quality, the sound, all pictures …
struct MediaOption: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var detail: String?
    var kind: MediaKind
    var files: [MediaFile]
    var headers: [String: String] = [:]
    var recommended = false
    /// Appended to the file name ("Ton", "HD" …) when several options of one post are saved.
    var nameSuffix: String?
}

enum MediaSite: String, Sendable {
    case tiktok, instagram, facebook, x, reddit, vimeo, dailymotion, web

    init(_ url: URL) {
        let host = url.host?.lowercased() ?? ""
        func on(_ domains: [String]) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }
        if on(["tiktok.com"]) { self = .tiktok }
        else if on(["instagram.com", "instagr.am"]) { self = .instagram }
        else if on(["facebook.com", "fb.watch", "fb.com"]) { self = .facebook }
        else if on(["twitter.com", "x.com"]) { self = .x }
        else if on(["reddit.com", "redd.it"]) && !host.hasPrefix("v.redd") && !host.hasPrefix("i.redd") { self = .reddit }
        else if on(["vimeo.com"]) { self = .vimeo }
        else if on(["dailymotion.com", "dai.ly"]) { self = .dailymotion }
        else { self = .web }
    }

    var name: String {
        switch self {
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram"
        case .facebook: return "Facebook"
        case .x: return "X"
        case .reddit: return "Reddit"
        case .vimeo: return "Vimeo"
        case .dailymotion: return "Dailymotion"
        case .web: return "Web"
        }
    }

    var symbol: String {
        switch self {
        case .tiktok: return "music.note"
        case .instagram: return "camera"
        case .facebook: return "person.2.fill"
        case .x: return "xmark"
        case .reddit: return "bubble.left.and.bubble.right.fill"
        case .vimeo: return "play.rectangle.fill"
        case .dailymotion: return "play.tv.fill"
        case .web: return "globe"
        }
    }
}

/// What the assistant found behind a link.
struct ExtractedMedia: Sendable {
    var site: MediaSite
    var page: URL
    var title: String
    var author: String?
    var thumbnail: URL?
    var duration: Int?
    var options: [MediaOption]
    var userAgent: String = UserAgents.mobile

    /// Base file name: "@author – title".
    var fileBaseName: String {
        let clean = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let short = clean.count > 70 ? String(clean.prefix(70)).trimmingCharacters(in: .whitespaces) + "…" : clean
        let parts = [author, short.isEmpty ? nil : short].compactMap { $0 }
        return parts.isEmpty ? "\(site.name) \(Self.stamp())" : parts.joined(separator: " – ")
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f.string(from: Date())
    }
}

enum ExtractError: LocalizedError {
    case nothingFound
    case privatePost
    case unreachable(String)

    var errorDescription: String? {
        switch self {
        case .nothingFound: return "Auf dieser Seite wurde nichts zum Herunterladen gefunden."
        case .privatePost: return "Der Beitrag ist privat oder nur angemeldet sichtbar – melde dich im Browser an und versuch es erneut."
        case .unreachable(let site): return "\(site) antwortet gerade nicht. Versuch es gleich noch einmal oder öffne den Link im Browser."
        }
    }
}

/// Finds the real media files behind links of TikTok, Instagram, Facebook, X, Reddit, Vimeo,
/// Dailymotion and ordinary web pages – without opening the browser. Logged-in browser
/// sessions are used, so private posts you can see work too.
enum MediaExtractor {
    static let desktopUA = UserAgents.desktop
    static let mobileUA = UserAgents.mobile

    static func extract(_ url: URL, isPrivate: Bool = false) async throws -> ExtractedMedia {
        let site = MediaSite(url)
        let cookieHost: String
        switch site {
        case .tiktok: cookieHost = "tiktok.com"
        case .instagram: cookieHost = "instagram.com"
        case .facebook: cookieHost = "facebook.com"
        case .reddit: cookieHost = "reddit.com"
        default: cookieHost = url.host ?? ""
        }
        let jar = CookieJar(await BrowserModel.cookies(for: cookieHost, isPrivate: isPrivate))
        let http = Fetcher(jar: jar)
        DebugLog.log("🔎 Assistent: \(site.name) \(url.absoluteString)")
        switch site {
        case .tiktok: return try await tiktok(url, http)
        case .instagram: return try await instagram(url, http)
        case .facebook: return try await facebook(url, http)
        case .x: return try await twitter(url, http)
        case .reddit: return try await reddit(url, http)
        case .vimeo: return try await vimeo(url, http)
        case .dailymotion: return try await dailymotion(url, http)
        case .web: return try await generic(url, http)
        }
    }

    // MARK: TikTok

    private static func tiktok(_ url: URL, _ http: Fetcher) async throws -> ExtractedMedia {
        var target = url
        if tiktokId(target) == nil {
            // vm.tiktok.com / vt.tiktok.com / tiktok.com/t/… redirect to the post.
            if let resolved = try? await http.get(url, ua: desktopUA).1.url { target = resolved }
        }
        if let id = tiktokId(target) {
            do {
                return try await tiktokWeb(id: id, target: target, http)
            } catch {
                DebugLog.log("🔎 TikTok-Seite: \(error.localizedDescription) – versuche Alternative")
            }
        }
        return try await tiktokFallback(url, http)
    }

    static func tiktokId(_ url: URL) -> String? {
        if let id = first(#"/(?:video|photo|v)/(\d{15,22})"#, in: url.absoluteString) { return id }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "item_id" || $0.name == "share_item_id" }?.value
    }

    private static func tiktokWeb(id: String, target: URL, _ http: Fetcher) async throws -> ExtractedMedia {
        let isPost = target.host?.contains("www.tiktok.com") == true && target.path.contains("/@")
        let page = isPost ? target : URL(string: "https://www.tiktok.com/@i/video/\(id)")!
        let (html, final) = try await http.text(page, ua: desktopUA, headers: ["Accept-Language": "de-DE,de;q=0.9,en;q=0.8"])
        var item = JSON(nil)
        if let raw = first(#"<script[^>]+id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>(.*?)</script>"#, in: html) {
            let j = JSON(data: Data(raw.utf8))
            let detail = j["__DEFAULT_SCOPE__"]["webapp.video-detail"]
            if let status = detail["statusCode"].int, status != 0, status != 10000 { throw ExtractError.privatePost }
            item = detail["itemInfo"]["itemStruct"]
        }
        if !item.exists, let raw = first(#"<script[^>]+id="SIGI_STATE"[^>]*>(.*?)</script>"#, in: html) {
            item = JSON(data: Data(raw.utf8))["ItemModule"][id]
        }
        guard item.exists else { throw ExtractError.nothingFound }

        let rawHeaders: [String: String?] = ["Referer": "https://www.tiktok.com/", "Cookie": http.jar.header(domain: "tiktok.com"),
                                             "User-Agent": desktopUA]
        let headers = rawHeaders.compactMapValues { $0 }
        let video = item["video"]
        var options: [MediaOption] = []

        struct Variant { let urls: [URL]; let width: Int; let height: Int; let bitrate: Int; let codec: String }
        let variants: [Variant] = video["bitrateInfo"].array.compactMap { b in
            let urls = b["PlayAddr"]["UrlList"].array.compactMap { $0.string.flatMap(URL.init(string:)) }
            guard !urls.isEmpty else { return nil }
            return Variant(urls: urls, width: b["PlayAddr"]["Width"].int ?? 0, height: b["PlayAddr"]["Height"].int ?? 0,
                           bitrate: b["Bitrate"].int ?? 0, codec: (b["CodecType"].string ?? "").lowercased())
        }
        func quality(_ v: Variant) -> String {
            let p = min(v.width, v.height)
            return p > 0 ? "\(p)p" : "Original"
        }
        let isHEVC: (Variant) -> Bool = { $0.codec.contains("265") || $0.codec.contains("hvc") || $0.codec.contains("bytevc1") }
        let best = variants.max { ($0.height * $0.width, $0.bitrate) < ($1.height * $1.width, $1.bitrate) }
        let bestH264 = variants.filter { !isHEVC($0) }.max { ($0.height * $0.width, $0.bitrate) < ($1.height * $1.width, $1.bitrate) }
        if let best {
            options.append(MediaOption(id: "tt-best", title: "Video · ohne Wasserzeichen",
                                       detail: "Beste Qualität · \(quality(best))\(isHEVC(best) ? " · HEVC" : "")", kind: .video,
                                       files: [MediaFile(candidates: best.urls, ext: "mp4")], headers: headers, recommended: true))
        }
        if let bestH264, bestH264.urls != best?.urls {
            options.append(MediaOption(id: "tt-h264", title: "Video · kompatibel", detail: "\(quality(bestH264)) · H.264 – läuft überall",
                                       kind: .video, files: [MediaFile(candidates: bestH264.urls, ext: "mp4")], headers: headers,
                                       nameSuffix: "H.264"))
        }
        if options.isEmpty, let play = video["playAddr"].string.flatMap(URL.init(string:)) {
            options.append(MediaOption(id: "tt-play", title: "Video · ohne Wasserzeichen", detail: nil, kind: .video,
                                       files: [MediaFile(candidates: [play], ext: "mp4")], headers: headers, recommended: true))
        }
        if let wm = video["downloadAddr"].string.flatMap(URL.init(string:)), !wm.absoluteString.isEmpty {
            options.append(MediaOption(id: "tt-wm", title: "Video · mit Wasserzeichen", detail: "Wie die „Speichern“-Funktion von TikTok",
                                       kind: .video, files: [MediaFile(candidates: [wm], ext: "mp4")], headers: headers,
                                       nameSuffix: "Wasserzeichen"))
        }
        let images = item["imagePost"]["images"].array.compactMap { img -> MediaFile? in
            let urls = img["imageURL"]["urlList"].array.compactMap { $0.string.flatMap(URL.init(string:)) }
            return urls.isEmpty ? nil : MediaFile(candidates: urls, ext: "jpg")
        }
        if !images.isEmpty {
            options.insert(MediaOption(id: "tt-images", title: images.count == 1 ? "Bild" : "Alle \(images.count) Bilder",
                                       detail: "Diashow in Originalgröße", kind: .image, files: images, headers: headers,
                                       recommended: options.isEmpty), at: 0)
        }
        if let music = item["music"]["playUrl"].string.flatMap(URL.init(string:)) {
            let name = [item["music"]["title"].string, item["music"]["authorName"].string].compactMap { $0 }.joined(separator: " – ")
            options.append(MediaOption(id: "tt-music", title: "Nur Ton", detail: name.isEmpty ? "MP3" : name, kind: .audio,
                                       files: [MediaFile(candidates: [music], ext: "mp3")], headers: headers, nameSuffix: "Ton"))
        }
        guard !options.isEmpty else { throw ExtractError.nothingFound }
        let author = item["author"]["uniqueId"].string ?? item["author"].string
        let cover = [video["originCover"].string, video["cover"].string, video["dynamicCover"].string]
            .compactMap { $0 }.first { !$0.isEmpty }.flatMap(URL.init(string:)) ?? images.first?.candidates.first
        return ExtractedMedia(site: .tiktok, page: final, title: item["desc"].string ?? "", author: author.map { "@" + $0 },
                              thumbnail: cover, duration: video["duration"].int, options: options, userAgent: desktopUA)
    }

    /// TikWM: public no-watermark service, used when TikTok's page can't be read.
    private static func tiktokFallback(_ url: URL, _ http: Fetcher) async throws -> ExtractedMedia {
        var c = URLComponents(string: "https://www.tikwm.com/api/")!
        c.queryItems = [.init(name: "url", value: url.absoluteString), .init(name: "hd", value: "1")]
        guard let api = c.url, let j = try? await http.json(api, ua: mobileUA) else { throw ExtractError.unreachable("TikTok") }
        guard j["code"].int == 0 else { throw ExtractError.nothingFound }
        let d = j["data"]
        func link(_ s: String?) -> URL? {
            guard let s, !s.isEmpty else { return nil }
            return URL(string: s.hasPrefix("http") ? s : "https://www.tikwm.com" + s)
        }
        var options: [MediaOption] = []
        let images = d["images"].array.compactMap { link($0.string) }.map { MediaFile(candidates: [$0], ext: "jpg") }
        if !images.isEmpty {
            options.append(MediaOption(id: "tw-images", title: images.count == 1 ? "Bild" : "Alle \(images.count) Bilder",
                                       detail: "Diashow", kind: .image, files: images, recommended: true))
        } else {
            let sizeText: (Int?) -> String? = { $0.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) : nil } }
            if let hd = link(d["hdplay"].string) {
                options.append(MediaOption(id: "tw-hd", title: "Video · HD ohne Wasserzeichen", detail: sizeText(d["hd_size"].int),
                                           kind: .video, files: [MediaFile(candidates: [hd] + [link(d["play"].string)].compactMap { $0 }, ext: "mp4")],
                                           recommended: true))
            }
            if let sd = link(d["play"].string) {
                options.append(MediaOption(id: "tw-sd", title: "Video · ohne Wasserzeichen", detail: sizeText(d["size"].int), kind: .video,
                                           files: [MediaFile(candidates: [sd], ext: "mp4")], recommended: options.isEmpty, nameSuffix: "SD"))
            }
            if let wm = link(d["wmplay"].string) {
                options.append(MediaOption(id: "tw-wm", title: "Video · mit Wasserzeichen", detail: sizeText(d["wm_size"].int), kind: .video,
                                           files: [MediaFile(candidates: [wm], ext: "mp4")], nameSuffix: "Wasserzeichen"))
            }
        }
        if let music = link(d["music"].string) {
            options.append(MediaOption(id: "tw-music", title: "Nur Ton", detail: d["music_info"]["title"].string, kind: .audio,
                                       files: [MediaFile(candidates: [music], ext: "mp3")], nameSuffix: "Ton"))
        }
        guard !options.isEmpty else { throw ExtractError.nothingFound }
        let author = d["author"]["unique_id"].string
        return ExtractedMedia(site: .tiktok, page: url, title: d["title"].string ?? "", author: author.map { "@" + $0 },
                              thumbnail: link(d["origin_cover"].string) ?? link(d["cover"].string), duration: d["duration"].int,
                              options: options, userAgent: mobileUA)
    }

    // MARK: Instagram

    private static let igAppId = "936619743392459"

    private static func instagram(_ url: URL, _ http: Fetcher) async throws -> ExtractedMedia {
        var target = url
        if instagramCode(target) == nil, let resolved = try? await http.get(url, ua: mobileUA).1.url { target = resolved }
        guard let code = instagramCode(target) else { throw ExtractError.nothingFound }
        let page = URL(string: "https://www.instagram.com/p/\(code)/")!
        if http.jar.has("sessionid"), let media = try? await instagramAPI(code, page: page, http) { return media }
        if let media = try? await instagramGraphQL(code, page: page, http) { return media }
        if let media = try? await instagramEmbed(code, page: page, http) { return media }
        throw http.jar.has("sessionid") ? ExtractError.nothingFound : ExtractError.privatePost
    }

    static func instagramCode(_ url: URL) -> String? {
        first(#"/(?:p|reel|reels|tv)/([A-Za-z0-9_-]{5,})"#, in: url.path)
    }

    private static func instagramMediaId(_ code: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var id: UInt64 = 0
        for ch in code.prefix(11) {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            id = id &* 64 &+ UInt64(i)
        }
        return String(id)
    }

    /// Logged in (browser session): the app API returns every version of the post.
    private static func instagramAPI(_ code: String, page: URL, _ http: Fetcher) async throws -> ExtractedMedia {
        guard let id = instagramMediaId(code), let api = URL(string: "https://www.instagram.com/api/v1/media/\(id)/info/") else {
            throw ExtractError.nothingFound
        }
        let j = try await http.json(api, ua: desktopUA, headers: [
            "X-IG-App-ID": igAppId, "X-Requested-With": "XMLHttpRequest", "X-CSRFToken": http.jar.value("csrftoken") ?? "",
            "Referer": page.absoluteString
        ])
        let item = j["items"][0]
        guard item.exists else { throw ExtractError.nothingFound }
        let nodes = item["carousel_media"].array.isEmpty ? [item] : item["carousel_media"].array
        var files: [(kind: MediaKind, file: MediaFile)] = []
        for n in nodes {
            if let v = n["video_versions"].array.max(by: { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) })?["url"].string,
               let u = URL(string: v) {
                files.append((.video, MediaFile(candidates: [u], ext: "mp4")))
            } else if let i = n["image_versions2"]["candidates"].array.max(by: { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) })?["url"].string,
                      let u = URL(string: i) {
                files.append((.image, MediaFile(candidates: [u], ext: "jpg")))
            }
        }
        let thumb = item["image_versions2"]["candidates"][0]["url"].string.flatMap(URL.init(string:))
            ?? nodes.first?["image_versions2"]["candidates"][0]["url"].string.flatMap(URL.init(string:))
        return try instagramResult(files, page: page, title: item["caption"]["text"].string, author: item["user"]["username"].string,
                                   thumbnail: thumb, duration: item["video_duration"].double.map { Int($0) })
    }

    /// Public posts without login: the same GraphQL query the website uses.
    private static func instagramGraphQL(_ code: String, page: URL, _ http: Fetcher) async throws -> ExtractedMedia {
        let (html, _) = try await http.text(page, ua: desktopUA)
        let lsd = first(#""LSD",\[\],\{"token":"([^"]+)""#, in: html) ?? first(#""lsd":"([^"]+)""#, in: html) ?? "AVq" + String(UUID().uuidString.prefix(8))
        let csrf = http.jar.value("csrftoken") ?? first(#""csrf_token":"([^"]+)""#, in: html) ?? ""
        let variables = #"{"shortcode":"\#(code)","fetch_tagged_user_count":null,"hoisted_comment_id":null,"hoisted_reply_id":null}"#
        let form: [(String, String)] = [
            ("av", "0"), ("__d", "www"), ("__user", "0"), ("__a", "1"), ("__req", "3"), ("dpr", "3"), ("lsd", lsd),
            ("fb_api_caller_class", "RelayModern"), ("fb_api_req_friendly_name", "PolarisPostActionLoadPostQueryQuery"),
            ("variables", variables), ("server_timestamps", "true"), ("doc_id", "8845758582119845")
        ]
        let j = try await http.postForm(URL(string: "https://www.instagram.com/graphql/query")!, form: form, ua: desktopUA, headers: [
            "X-IG-App-ID": igAppId, "X-FB-LSD": lsd, "X-ASBD-ID": "129477", "X-CSRFToken": csrf,
            "X-FB-Friendly-Name": "PolarisPostActionLoadPostQueryQuery", "Origin": "https://www.instagram.com",
            "Referer": page.absoluteString
        ])
        let m = j["data"]["xdt_shortcode_media"].exists ? j["data"]["xdt_shortcode_media"] : j["data"]["shortcode_media"]
        guard m.exists else { throw ExtractError.nothingFound }
        let children = m["edge_sidecar_to_children"]["edges"].array.map { $0["node"] }
        let nodes = children.isEmpty ? [m] : children
        let files: [(kind: MediaKind, file: MediaFile)] = nodes.compactMap { n in
            if n["is_video"].bool == true, let u = n["video_url"].string.flatMap(URL.init(string:)) {
                return (.video, MediaFile(candidates: [u], ext: "mp4"))
            }
            if let u = n["display_url"].string.flatMap(URL.init(string:)) { return (.image, MediaFile(candidates: [u], ext: "jpg")) }
            return nil
        }
        return try instagramResult(files, page: page, title: m["edge_media_to_caption"]["edges"][0]["node"]["text"].string,
                                   author: m["owner"]["username"].string,
                                   thumbnail: (m["thumbnail_src"].string ?? m["display_url"].string).flatMap(URL.init(string:)),
                                   duration: m["video_duration"].double.map { Int($0) })
    }

    /// Last resort: the embed page carries the video link of public posts.
    private static func instagramEmbed(_ code: String, page: URL, _ http: Fetcher) async throws -> ExtractedMedia {
        let (raw, _) = try await http.text(URL(string: "https://www.instagram.com/p/\(code)/embed/captioned/")!, ua: desktopUA)
        let html = raw.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\/", with: "/")
        var files: [(kind: MediaKind, file: MediaFile)] = []
        for v in all(#""video_url":"([^"]+)""#, in: html) {
            if let u = URL(string: unescape(v)), !files.contains(where: { $0.file.candidates.first == u }) {
                files.append((.video, MediaFile(candidates: [u], ext: "mp4")))
            }
        }
        if files.isEmpty, let img = first(#"class="EmbeddedMediaImage"[^>]*src="([^"]+)""#, in: raw).map(htmlDecode),
           let u = URL(string: img) {
            files.append((.image, MediaFile(candidates: [u], ext: "jpg")))
        }
        let author = first(#"class="UsernameText"[^>]*>([^<]+)<"#, in: raw)
        let thumb = first(#"class="EmbeddedMediaImage"[^>]*src="([^"]+)""#, in: raw).map(htmlDecode).flatMap(URL.init(string:))
        return try instagramResult(files, page: page, title: nil, author: author, thumbnail: thumb, duration: nil)
    }

    private static func instagramResult(_ files: [(kind: MediaKind, file: MediaFile)], page: URL, title: String?, author: String?,
                                        thumbnail: URL?, duration: Int?) throws -> ExtractedMedia {
        guard !files.isEmpty else { throw ExtractError.nothingFound }
        var options: [MediaOption] = []
        let videos = files.filter { $0.kind == .video }.map(\.file)
        let images = files.filter { $0.kind == .image }.map(\.file)
        if files.count > 1 {
            options.append(MediaOption(id: "ig-all", title: "Ganzer Beitrag (\(files.count))",
                                       detail: [videos.isEmpty ? nil : "\(videos.count) Videos", images.isEmpty ? nil : "\(images.count) Bilder"]
                                           .compactMap { $0 }.joined(separator: " · "),
                                       kind: videos.isEmpty ? .image : .video, files: files.map(\.file), recommended: true))
        }
        if videos.count == 1 {
            options.append(MediaOption(id: "ig-video", title: "Video", detail: "Originalqualität", kind: .video, files: videos,
                                       recommended: files.count == 1))
        } else if videos.count > 1 {
            options.append(MediaOption(id: "ig-videos", title: "Nur Videos (\(videos.count))", detail: nil, kind: .video, files: videos))
        }
        if images.count == 1, videos.isEmpty {
            options.append(MediaOption(id: "ig-image", title: "Bild", detail: "Originalgröße", kind: .image, files: images,
                                       recommended: files.count == 1))
        } else if images.count > 1 {
            options.append(MediaOption(id: "ig-images", title: "Nur Bilder (\(images.count))", detail: nil, kind: .image, files: images))
        }
        return ExtractedMedia(site: .instagram, page: page, title: title ?? "", author: author.map { "@" + $0 }, thumbnail: thumbnail,
                              duration: duration, options: options, userAgent: desktopUA)
    }

    // MARK: Facebook

    private static func facebook(_ url: URL, _ http: Fetcher) async throws -> ExtractedMedia {
        var lastError: Error = ExtractError.nothingFound
        for ua in [desktopUA, mobileUA] {
            do {
                let (html, final) = try await http.text(url, ua: ua, headers: [
                    "Accept-Language": "de-DE,de;q=0.9,en;q=0.8", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document"
                ])
                if let media = parseFacebook(html, page: final, ua: ua) { return media }
                if final.path.contains("/login") { lastError = ExtractError.privatePost }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func parseFacebook(_ html: String, page: URL, ua: String) -> ExtractedMedia? {
        func links(_ pattern: String) -> [URL] {
            all(pattern, in: html).compactMap { URL(string: unescape($0)) }.filter { $0.scheme == "https" }
        }
        var hd = links(#""(?:browser_native_hd_url|playable_url_quality_hd|hd_src_no_ratelimit|hd_src)":"([^"]+)""#)
        var sd = links(#""(?:browser_native_sd_url|playable_url|sd_src_no_ratelimit|sd_src)":"([^"]+)""#)
        let progressive = links(#""progressive_url":"([^"]+)""#)
        if hd.isEmpty, let p = progressive.first { hd = [p] }
        if sd.isEmpty, progressive.count > 1 { sd = [progressive[1]] }
        // m.facebook.com keeps the video in data-store attributes.
        for store in all(#"data-store="([^"]+)""#, in: html) {
            let decoded = htmlDecode(store)
            if let src = JSON(data: Data(decoded.utf8))["src"].string, let u = URL(string: src), u.path.contains(".mp4") { sd.append(u) }
        }
        for og in metaContents(html, ["og:video:secure_url", "og:video:url", "og:video"]) {
            if let u = URL(string: og), u.path.contains(".mp4") { sd.append(u) }
        }
        hd = unique(hd)
        sd = unique(sd).filter { !hd.contains($0) }
        guard !hd.isEmpty || !sd.isEmpty else { return nil }
        var options: [MediaOption] = []
        if !hd.isEmpty {
            options.append(MediaOption(id: "fb-hd", title: "Video · HD", detail: "Beste Qualität mit Ton", kind: .video,
                                       files: [MediaFile(candidates: hd + sd, ext: "mp4")], recommended: true))
        }
        if !sd.isEmpty {
            options.append(MediaOption(id: "fb-sd", title: "Video · SD", detail: "Kleinere Datei", kind: .video,
                                       files: [MediaFile(candidates: sd, ext: "mp4")], recommended: hd.isEmpty, nameSuffix: hd.isEmpty ? nil : "SD"))
        }
        let title = metaContents(html, ["og:title", "twitter:title"]).first.map(htmlDecode)
            ?? first(#"<title[^>]*>([^<]+)</title>"#, in: html).map(htmlDecode) ?? ""
        let thumb = first(#""preferred_thumbnail":\{"image":\{"uri":"([^"]+)""#, in: html).map(unescape).flatMap(URL.init(string:))
            ?? metaContents(html, ["og:image"]).first.map(htmlDecode).flatMap(URL.init(string:))
        let author = first(#""owner":\{"__typename":"(?:User|Page)","name":"([^"]+)""#, in: html).map(unescape)
        return ExtractedMedia(site: .facebook, page: page, title: title == "Facebook" ? "" : title, author: author, thumbnail: thumb,
                              duration: nil, options: options, userAgent: ua)
    }

    // MARK: X / Twitter

    private static func twitter(_ url: URL, _ http: Fetcher) async throws -> ExtractedMedia {
        guard let id = first(#"/status(?:es)?/(\d+)"#, in: url.path) else { throw ExtractError.nothingFound }
        var videos: [(URL, URL?)] = []
        var photos: [URL] = []
        var text = ""
        var author: String?
        if let j = try? await http.json(URL(string: "https://api.fxtwitter.com/status/\(id)")!, ua: mobileUA), j["tweet"].exists {
            let t = j["tweet"]
            text = t["text"].string ?? ""
            author = t["author"]["screen_name"].string
            for v in t["media"]["videos"].array {
                if let u = v["url"].string.flatMap(URL.init(string:)) { videos.append((u, v["thumbnail_url"].string.flatMap(URL.init(string:)))) }
            }
            photos = t["media"]["photos"].array.compactMap { $0["url"].string.flatMap(URL.init(string:)) }
        }
        if videos.isEmpty, photos.isEmpty,
           let j = try? await http.json(URL(string: "https://api.vxtwitter.com/Twitter/status/\(id)")!, ua: mobileUA) {
            text = j["text"].string ?? text
            author = j["user_screen_name"].string ?? author
            for m in j["media_extended"].array {
                guard let u = m["url"].string.flatMap(URL.init(string:)) else { continue }
                if m["type"].string == "image" { photos.append(u) } else { videos.append((u, m["thumbnail_url"].string.flatMap(URL.init(string:)))) }
            }
        }
        guard !videos.isEmpty || !photos.isEmpty else { throw ExtractError.nothingFound }
        var options: [MediaOption] = []
        if videos.count == 1 {
            options.append(MediaOption(id: "x-video", title: "Video", detail: "Beste Qualität", kind: .video,
                                       files: [MediaFile(candidates: [videos[0].0], ext: "mp4")], recommended: true))
        } else if videos.count > 1 {
            options.append(MediaOption(id: "x-videos", title: "Alle \(videos.count) Videos", detail: nil, kind: .video,
                                       files: videos.map { MediaFile(candidates: [$0.0], ext: "mp4") }, recommended: true))
        }
        if !photos.isEmpty {
            let originals = photos.map { u -> URL in
                guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false), u.host?.contains("pbs.twimg.com") == true else { return u }
                c.queryItems = [.init(name: "name", value: "orig")]
                return c.url ?? u
            }
            options.append(MediaOption(id: "x-photos", title: photos.count == 1 ? "Bild" : "Alle \(photos.count) Bilder",
                                       detail: "Originalgröße", kind: .image,
                                       files: zip(originals, photos).map { MediaFile(candidates: [$0, $1], ext: "jpg") },
                                       recommended: videos.isEmpty))
        }
        return ExtractedMedia(site: .x, page: url, title: text, author: author.map { "@" + $0 },
                              thumbnail: videos.first?.1 ?? photos.first, duration: nil, options: options)
    }

    // MARK: Reddit

    private static func reddit(_ url: URL, _ http: Fetcher) async throws -> ExtractedMedia {
        var target = url
        if redditId(target) == nil, let resolved = try? await http.get(url, ua: desktopUA).1.url { target = resolved }
        guard let id = redditId(target) else { throw ExtractError.nothingFound }
        let j = try await http.json(URL(string: "https://www.reddit.com/comments/\(id).json?raw_json=1")!, ua: desktopUA)
        var post = j[0]["data"]["children"][0]["data"]
        guard post.exists else { throw ExtractError.nothingFound }
        if post["crosspost_parent_list"][0].exists, post["secure_media"]["reddit_video"].exists == false {
            post = post["crosspost_parent_list"][0]
        }
        var options: [MediaOption] = []
        let rv = [post["secure_media"]["reddit_video"], post["media"]["reddit_video"], post["preview"]["reddit_video_preview"]]
            .first { $0.exists } ?? JSON(nil)
        if let fallback = rv["fallback_url"].string.flatMap(URL.init(string:)) {
            var clean = URLComponents(url: fallback, resolvingAgainstBaseURL: false)
            clean?.query = nil
            let video = clean?.url ?? fallback
            let base = video.deletingLastPathComponent()
            let audio = rv["has_audio"].bool == false ? [] :
                ["DASH_AUDIO_128.mp4", "DASH_AUDIO_64.mp4", "DASH_audio.mp4", "audio"].map { base.appendingPathComponent($0) }
            let height = rv["height"].int.map { "\($0)p" }
            options.append(MediaOption(id: "rd-video", title: "Video", detail: [height, audio.isEmpty ? "ohne Ton" : "mit Ton"]
                                           .compactMap { $0 }.joined(separator: " · "),
                                       kind: .video, files: [MediaFile(candidates: [video], ext: "mp4", audio: audio)], recommended: true))
        }
        var images: [MediaFile] = []
        if post["is_gallery"].bool == true {
            for item in post["gallery_data"]["items"].array {
                guard let mid = item["media_id"].string, let u = post["media_metadata"][mid]["s"]["u"].string.flatMap(URL.init(string:)) else { continue }
                images.append(MediaFile(candidates: [u], ext: "jpg"))
            }
        } else if let u = post["url_overridden_by_dest"].string.flatMap(URL.init(string:)),
                  ["jpg", "jpeg", "png", "gif", "webp"].contains(u.pathExtension.lowercased()) {
            images.append(MediaFile(candidates: [u], ext: u.pathExtension.lowercased()))
        }
        if !images.isEmpty {
            options.append(MediaOption(id: "rd-images", title: images.count == 1 ? "Bild" : "Alle \(images.count) Bilder",
                                       detail: "Originalgröße", kind: .image, files: images, recommended: options.isEmpty))
        }
        guard !options.isEmpty else { throw ExtractError.nothingFound }
        let thumb = post["preview"]["images"][0]["source"]["url"].string.flatMap(URL.init(string:))
        return ExtractedMedia(site: .reddit, page: target, title: post["title"].string ?? "",
                              author: post["subreddit_name_prefixed"].string ?? post["author"].string.map { "u/" + $0 },
                              thumbnail: thumb, duration: rv["duration"].int, options: options, userAgent: desktopUA)
    }

    private static func redditId(_ url: URL) -> String? {
        if url.host?.contains("redd.it") == true, let id = url.path.split(separator: "/").first { return String(id) }
        return first(#"/comments/([a-z0-9]+)"#, in: url.path)
    }

    // MARK: Vimeo & Dailymotion

    private static func vimeo(_ url: URL, _ http: Fetcher) async throws -> ExtractedMedia {
        guard let id = url.path.split(separator: "/").first(where: { $0.count >= 6 && $0.allSatisfy(\.isNumber) }) else {
            return try await generic(url, http)
        }
        let j = try await http.json(URL(string: "https://player.vimeo.com/video/\(id)/config")!, ua: desktopUA,
                                    headers: ["Referer": "https://vimeo.com/"])
        var options: [MediaOption] = []
        let progressive = j["request"]["files"]["progressive"].array.sorted { ($0["height"].int ?? 0) > ($1["height"].int ?? 0) }
        for (i, p) in progressive.enumerated() {
            guard let u = p["url"].string.flatMap(URL.init(string:)) else { continue }
            let q = p["quality"].string ?? p["height"].int.map { "\($0)p" } ?? "MP4"
            options.append(MediaOption(id: "vm-\(i)", title: "Video · \(q)", detail: "MP4", kind: .video,
                                       files: [MediaFile(candidates: [u], ext: "mp4")], recommended: i == 0, nameSuffix: i == 0 ? nil : q))
        }
        let hls = j["request"]["files"]["hls"]
        let cdn = hls["default_cdn"].string ?? hls["cdns"].keys.first ?? ""
        if let u = hls["cdns"][cdn]["url"].string.flatMap(URL.init(string:)) {
            options.append(MediaOption(id: "vm-hls", title: "Video · Stream", detail: "Beste verfügbare Qualität", kind: .stream,
                                       files: [MediaFile(candidates: [u], ext: "mp4")], recommended: options.isEmpty))
        }
        guard !options.isEmpty else { throw ExtractError.nothingFound }
        let thumbs = j["video"]["thumbs"]
        return ExtractedMedia(site: .vimeo, page: url, title: j["video"]["title"].string ?? "", author: j["video"]["owner"]["name"].string,
                              thumbnail: (thumbs["1280"].string ?? thumbs["640"].string ?? thumbs["base"].string).flatMap(URL.init(string:)),
                              duration: j["video"]["duration"].int, options: options, userAgent: desktopUA)
    }

    private static func dailymotion(_ url: URL, _ http: Fetcher) async throws -> ExtractedMedia {
        let id = url.host?.contains("dai.ly") == true ? url.path.split(separator: "/").first.map(String.init)
            : first(#"/video/([a-zA-Z0-9]+)"#, in: url.path)
        guard let id else { return try await generic(url, http) }
        let j = try await http.json(URL(string: "https://www.dailymotion.com/player/metadata/video/\(id)")!, ua: desktopUA)
        guard let stream = j["qualities"]["auto"][0]["url"].string.flatMap(URL.init(string:)) else { throw ExtractError.nothingFound }
        let thumb = (j["posters"]["1080"].string ?? j["posters"]["720"].string ?? j["thumbnails"]["720"].string).flatMap(URL.init(string:))
        return ExtractedMedia(site: .dailymotion, page: url, title: j["title"].string ?? "", author: j["owner"]["screenname"].string,
                              thumbnail: thumb, duration: j["duration"].int,
                              options: [MediaOption(id: "dm-hls", title: "Video", detail: "Beste verfügbare Qualität", kind: .stream,
                                                    files: [MediaFile(candidates: [stream], ext: "mp4")], recommended: true)],
                              userAgent: desktopUA)
    }

    // MARK: Any page

    private static let fileExtensions: Set<String> = ["zip", "rar", "7z", "pdf", "apk", "ipa", "dmg", "exe", "pkg", "epub", "doc",
                                                      "docx", "xls", "xlsx", "ppt", "pptx", "csv", "torrent", "txt", "json"]

    private static func generic(_ url: URL, _ http: Fetcher) async throws -> ExtractedMedia {
        let ext = url.pathExtension.lowercased()
        let kind = MediaKind(fileExtension: ext)
        if kind != .file || fileExtensions.contains(ext) {
            return direct(url, kind: kind, name: url.deletingPathExtension().lastPathComponent, ext: ext)
        }
        let (data, response) = try await http.get(url, ua: mobileUA)
        let mime = response.mimeType?.lowercased() ?? ""
        let final = response.url ?? url
        if !mime.contains("html"), !mime.contains("xml"), !mime.hasPrefix("text/") {
            let name = response.suggestedFilename ?? final.lastPathComponent
            let e = (name as NSString).pathExtension.lowercased()
            let k = mime.hasPrefix("video/") ? MediaKind.video : mime.hasPrefix("audio/") ? .audio : mime.hasPrefix("image/") ? .image
                : MediaKind(fileExtension: e)
            return direct(final, kind: k, name: (name as NSString).deletingPathExtension, ext: e.isEmpty ? "bin" : e)
        }
        let html = String(decoding: data, as: UTF8.self)
        var found: [(URL, MediaKind, String)] = []
        func take(_ raw: String, _ label: String) {
            let s = htmlDecode(unescape(raw))
            guard let u = URL(string: s, relativeTo: final)?.absoluteURL, u.scheme?.hasPrefix("http") == true,
                  !found.contains(where: { $0.0 == u }) else { return }
            var k = MediaKind(fileExtension: u.pathExtension)
            if k == .file || k == .image {
                guard label == "Video" else { return }
                k = .video
            }
            found.append((u, k, label))
        }
        metaContents(html, ["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream"]).forEach { take($0, "Video") }
        metaContents(html, ["og:audio", "og:audio:secure_url"]).forEach { take($0, "Audio") }
        all(#"<(?:video|audio|source)[^>]+src=["']([^"']+)["']"#, in: html).forEach { take($0, "Player") }
        all(#""contentUrl"\s*:\s*"([^"]+)""#, in: html).forEach { take($0, "Video") }
        all(#""(?:video_url|videoUrl|mp4_url|file_url|hls_url|hlsUrl|stream_url|playable_url|download_url)"\s*:\s*"(https?:[^"]+)""#, in: html)
            .forEach { take($0, "Versteckt") }
        all(#"https?:(?:\\?/){2}[^\s"'<>()\\]+?\.(?:mp4|m4v|mov|webm|m3u8|mp3|m4a|aac|flac|ogg|wav)(?:\?[^\s"'<>\\]*)?"#, in: html)
            .prefix(20).forEach { take($0, "Versteckt") }
        guard !found.isEmpty else { throw ExtractError.nothingFound }
        let options: [MediaOption] = found.prefix(12).enumerated().map { i, f in
            let e = f.0.pathExtension.lowercased()
            return MediaOption(id: "web-\(i)", title: "\(f.1 == .stream ? "Stream" : f.1.label) · \(f.2)",
                               detail: f.0.host.map { $0 + (e.isEmpty ? "" : " · " + e.uppercased()) }, kind: f.1,
                               files: [MediaFile(candidates: [f.0], ext: f.1 == .stream ? "mp4" : (e.isEmpty ? "mp4" : e))],
                               recommended: i == 0, nameSuffix: i == 0 ? nil : "\(i + 1)")
        }
        let title = metaContents(html, ["og:title", "twitter:title"]).first.map(htmlDecode)
            ?? first(#"<title[^>]*>([^<]+)</title>"#, in: html).map(htmlDecode) ?? (final.host ?? "")
        let thumb = metaContents(html, ["og:image", "twitter:image"]).first.map(htmlDecode).flatMap { URL(string: $0, relativeTo: final)?.absoluteURL }
        return ExtractedMedia(site: .web, page: final, title: title, author: final.host?.replacingOccurrences(of: "www.", with: ""),
                              thumbnail: thumb, duration: nil, options: options)
    }

    private static func direct(_ url: URL, kind: MediaKind, name: String, ext: String) -> ExtractedMedia {
        let option = MediaOption(id: "direct", title: kind == .stream ? "Stream als Video" : "\(kind.label) · \(ext.uppercased())",
                                 detail: url.host, kind: kind,
                                 files: [MediaFile(candidates: [url], ext: kind == .stream ? "mp4" : ext)], recommended: true)
        return ExtractedMedia(site: .web, page: url, title: name.removingPercentEncoding ?? name, author: url.host, thumbnail: nil,
                              duration: nil, options: [option])
    }

    // MARK: Text helpers

    static func first(_ pattern: String, in text: String) -> String? {
        all(pattern, in: text, limit: 1).first
    }

    static func all(_ pattern: String, in text: String, limit: Int = 50) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        var out: [String] = []
        let ns = text as NSString
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
            guard r.location != NSNotFound else { continue }
            out.append(ns.substring(with: r))
            if out.count >= limit { break }
        }
        return out
    }

    /// `content` of <meta property|name="…"> tags, in the order of `names`.
    static func metaContents(_ html: String, _ names: [String]) -> [String] {
        names.flatMap { name -> [String] in
            let n = NSRegularExpression.escapedPattern(for: name)
            return all(#"<meta[^>]+(?:property|name)=["']\#(n)["'][^>]*content=["']([^"']+)["']"#, in: html, limit: 5)
                + all(#"<meta[^>]+content=["']([^"']+)["'][^>]*(?:property|name)=["']\#(n)["']"#, in: html, limit: 5)
        }
    }

    /// Decodes JSON string escapes (\/, & …).
    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        if let decoded = try? JSONSerialization.jsonObject(with: Data("\"\(s)\"".utf8), options: [.fragmentsAllowed]) as? String {
            return decoded
        }
        return s.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\u0026", with: "&")
    }

    static func htmlDecode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }
}

// MARK: - Networking

/// Cookies of one extraction (browser session + whatever the site sets on the way).
final class CookieJar: @unchecked Sendable {
    private var cookies: [String: HTTPCookie] = [:]
    private let lock = NSLock()

    init(_ initial: [HTTPCookie]) { add(initial) }

    func add(_ list: [HTTPCookie]) {
        lock.lock()
        defer { lock.unlock() }
        for c in list { cookies[c.name + "@" + c.domain.lowercased()] = c }
    }

    func has(_ name: String) -> Bool { value(name) != nil }

    func value(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cookies.values.first { $0.name == name }?.value
    }

    /// Cookie header for requests to `domain` and its subdomains (CDNs included).
    func header(domain: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let d = domain.lowercased()
        let list = cookies.values.filter { c in
            let cd = c.domain.lowercased().hasPrefix(".") ? String(c.domain.lowercased().dropFirst()) : c.domain.lowercased()
            return cd == d || cd.hasSuffix("." + d) || d.hasSuffix("." + cd)
        }
        guard !list.isEmpty else { return nil }
        return list.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func header(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let list = cookies.values.filter { c in
            let cd = c.domain.lowercased().hasPrefix(".") ? String(c.domain.lowercased().dropFirst()) : c.domain.lowercased()
            return host == cd || host.hasSuffix("." + cd)
        }
        guard !list.isEmpty else { return nil }
        return list.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// Plain requests with a manual cookie jar (no shared cookie storage involved).
final class Fetcher: @unchecked Sendable {
    let jar: CookieJar
    private let session: URLSession

    init(jar: CookieJar) {
        self.jar = jar
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func get(_ url: URL, ua: String, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return try await send(req, headers: headers)
    }

    func text(_ url: URL, ua: String, headers: [String: String] = [:]) async throws -> (String, URL) {
        let (data, response) = try await get(url, ua: ua, headers: headers)
        return (String(decoding: data, as: UTF8.self), response.url ?? url)
    }

    func json(_ url: URL, ua: String, headers: [String: String] = [:]) async throws -> JSON {
        var h = headers
        if h["Accept"] == nil { h["Accept"] = "application/json, text/plain, */*" }
        let (data, _) = try await get(url, ua: ua, headers: h)
        let j = JSON(data: data)
        guard j.exists else { throw ExtractError.nothingFound }
        return j
    }

    func postForm(_ url: URL, form: [(String, String)], ua: String, headers: [String: String] = [:]) async throws -> JSON {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await send(req, headers: headers)
        let j = JSON(data: data)
        guard j.exists else { throw ExtractError.nothingFound }
        return j
    }

    private func send(_ request: URLRequest, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var req = request
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "Cookie") == nil, let url = req.url, let cookie = jar.header(for: url) {
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw YTError.invalidResponse }
        if let url = http.url {
            let fields = http.allHeaderFields.reduce(into: [String: String]()) { out, pair in
                if let k = pair.key as? String, let v = pair.value as? String { out[k] = v }
            }
            jar.add(HTTPCookie.cookies(withResponseHeaderFields: fields, for: url))
        }
        guard (200..<400).contains(http.statusCode) else { throw YTError.http(http.statusCode) }
        return (data, http)
    }
}
