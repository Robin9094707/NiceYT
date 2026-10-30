import AVFoundation
import UIKit

/// One downloadable variant of a video, as offered in the download sheet.
struct YTDownloadOption: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case audio, video }
    let kind: Kind
    /// Video height (0 for audio).
    let height: Int
    let fps: Int
    let codec: String
    let estimatedBytes: Int64?

    var id: String { kind == .audio ? "audio" : "\(height)-\(fps)-\(codec)" }

    var label: String {
        guard kind == .video else { return "Nur Audio" }
        let name = height >= 2160 ? "4K" : height >= 1440 ? "1440p" : "\(height)p"
        return fps > 30 ? "\(name) \(fps) fps" : name
    }

    var detail: String {
        var parts: [String] = []
        parts.append(kind == .audio ? "M4A (AAC) mit Cover" : "MP4 · \(codec)")
        if let b = estimatedBytes, b > 0 { parts.append("ca. " + ByteCountFormatter.string(fromByteCount: b, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
}

/// Finds and downloads YouTube streams with the same clients and deciphering the player
/// uses, so whatever plays can also be saved. Adaptive MP4 streams are fetched in chunks
/// (like yt-dlp) and joined with AVFoundation; HLS is the fallback.
enum YouTubeDownloader {
    struct Sources {
        let meta: StreamInfo
        let userAgent: String
        /// Deciphered adaptive formats (empty when only HLS is available).
        let videos: [(format: Parser.RawFormat, url: URL)]
        let audio: (format: Parser.RawFormat, url: URL)?
        let hlsURL: URL?

        var options: [YTDownloadOption] {
            var out: [YTDownloadOption] = []
            let audioBytes = audio?.format.contentLength
            if audio != nil || hlsURL != nil {
                out.append(YTDownloadOption(kind: .audio, height: 0, fps: 0, codec: "AAC", estimatedBytes: audioBytes))
            }
            if !videos.isEmpty {
                var seen = Set<String>()
                for v in videos.sorted(by: { ($0.format.height, $0.format.fps) > ($1.format.height, $1.format.fps) }) {
                    let codec = v.format.mime.contains("av01") ? "AV1" : "H.264"
                    let key = "\(v.format.height)-\(v.format.fps > 30 ? 60 : 30)"
                    guard seen.insert(key).inserted else { continue }
                    let bytes = v.format.contentLength.map { $0 + (audioBytes ?? 0) }
                    out.append(YTDownloadOption(kind: .video, height: v.format.height, fps: v.format.fps, codec: codec, estimatedBytes: bytes))
                }
            } else if hlsURL != nil {
                for h in [1080, 720, 480, 360] {
                    out.append(YTDownloadOption(kind: .video, height: h, fps: 30, codec: "H.264", estimatedBytes: nil))
                }
            }
            return out
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    // MARK: Sources

    /// Asks the player clients that give direct stream URLs; the first with usable
    /// adaptive MP4 formats wins, otherwise its HLS manifest is used.
    static func sources(_ videoId: String) async throws -> Sources {
        var hlsFallback: Sources?
        var lastError: Error = YTError.unplayable("Für dieses Video wurde kein Download gefunden.")
        for client in [ITClient.visionos, .tv, .webEmbedded, .ios] {
            do {
                var playback: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
                if client.needsJSPlayer, let sts = await NSolver.shared.signatureTimestamp() {
                    playback["signatureTimestamp"] = sts
                }
                let body: [String: Any] = [
                    "videoId": videoId, "contentCheckOk": true, "racyCheckOk": true,
                    "playbackContext": ["contentPlaybackContext": playback]
                ]
                let j = try await InnerTube.shared.post("player", body, client: client, authenticated: client.supportsCookies)
                guard j.at("playabilityStatus.status").string == "OK" else {
                    lastError = YTError.unplayable(j.at("playabilityStatus.reason").string ?? "Video nicht verfügbar")
                    continue
                }
                let meta = try Parser.stream(j, videoId: videoId, client: client)
                let hls = meta.isHLS ? meta.hlsURL : nil
                // iOS direct URLs need a PO token – only its HLS is useful.
                guard client != .ios else {
                    if hlsFallback == nil, let hls { hlsFallback = Sources(meta: meta, userAgent: client.userAgent, videos: [], audio: nil, hlsURL: hls) }
                    continue
                }
                let formats = Parser.rawFormats(j).filter { !$0.isMuxed }
                let videoFormats = formats.filter { $0.mime.hasPrefix("video/mp4") && ($0.mime.contains("avc1") || $0.mime.contains("av01")) }
                var audioByTrack: [String: Parser.RawFormat] = [:]
                for f in formats where f.mime.hasPrefix("audio/mp4") {
                    let key = f.audioTrackId ?? "default"
                    if let current = audioByTrack[key], current.bitrate >= f.bitrate { continue }
                    audioByTrack[key] = f
                }
                let audio = audioByTrack.values.max {
                    AudioMatch.score(name: $0.audioName ?? "", language: $0.audioLanguage, isDefault: $0.audioIsDefault,
                                     original: $0.audioIsOriginal, dubbed: $0.audioIsDubbed)
                        < AudioMatch.score(name: $1.audioName ?? "", language: $1.audioLanguage, isDefault: $1.audioIsDefault,
                                           original: $1.audioIsOriginal, dubbed: $1.audioIsDubbed)
                }
                // Per height keep H.264 if there is one (plays everywhere), else AV1.
                var bestPerHeight: [String: Parser.RawFormat] = [:]
                for f in videoFormats {
                    let key = "\(f.height)-\(f.fps > 30 ? 60 : 30)"
                    if let cur = bestPerHeight[key] {
                        let curAVC = cur.mime.contains("avc1"), newAVC = f.mime.contains("avc1")
                        if curAVC && !newAVC { continue }
                        if curAVC == newAVC && cur.bitrate >= f.bitrate { continue }
                    }
                    bestPerHeight[key] = f
                }
                let chosen = Array(bestPerHeight.values) + [audio].compactMap { $0 }
                let urls = await decipher(chosen)
                let videos = bestPerHeight.values.compactMap { f in urls[f.itag].map { (format: f, url: $0) } }
                let audioPair = audio.flatMap { a in urls[a.itag].map { (format: a, url: $0) } }
                if audioPair != nil, !videos.isEmpty {
                    DebugLog.log("⬇︎ Download-Quellen von \(client.name): \(videos.count) Videoformate")
                    return Sources(meta: meta, userAgent: client.userAgent, videos: videos, audio: audioPair, hlsURL: hls)
                }
                if hlsFallback == nil, let hls {
                    hlsFallback = Sources(meta: meta, userAgent: client.userAgent, videos: [], audio: nil, hlsURL: hls)
                }
            } catch {
                lastError = error
            }
        }
        if let hlsFallback {
            DebugLog.log("⬇︎ Download über HLS (\(hlsFallback.meta.source))")
            return hlsFallback
        }
        throw lastError
    }

    /// Solves signatures and n values of the given formats; returns final URLs by itag.
    private static func decipher(_ formats: [Parser.RawFormat]) async -> [Int: URL] {
        let sigs = formats.compactMap { $0.cipher?.s }
        let raw = formats.compactMap { $0.url ?? $0.cipher?.url }
        let solved = await NSolver.shared.solve(n: raw.flatMap { NSolver.challenges(in: $0) }, sig: sigs)
        var out: [Int: URL] = [:]
        for f in formats {
            var u: String
            if let url = f.url {
                u = url
            } else if let c = f.cipher, let sig = solved.sig[c.s] {
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&=+/")
                u = c.url + "&" + c.sp + "=" + (sig.addingPercentEncoding(withAllowedCharacters: allowed) ?? sig)
            } else {
                continue
            }
            u = NSolver.apply(solved.n, to: u)
            if let url = URL(string: u) { out[f.itag] = url }
        }
        return out
    }

    // MARK: Fetching

    /// Downloads a googlevideo URL in 10 MB pieces (single requests get throttled).
    static func fetch(_ url: URL, to file: URL, userAgent: String, expected: Int64?,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let chunk: Int64 = 10 * 1024 * 1024
        var offset: Int64 = 0
        while true {
            try Task.checkCancellation()
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps.queryItems = (comps.queryItems ?? []).filter { $0.name != "range" }
                + [URLQueryItem(name: "range", value: "\(offset)-\(offset + chunk - 1)")]
            var req = URLRequest(url: comps.url ?? url, timeoutInterval: 40)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
            req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
            let data = try await load(req)
            if data.isEmpty { break }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            progress(offset)
            if let expected, offset >= expected { break }
            if Int64(data.count) < chunk { break }
        }
        guard offset > 0 else { throw YTError.unplayable("Leere Antwort beim Download") }
    }

    /// GET with a few retries for flaky connections.
    private static func load(_ request: URLRequest) async throws -> Data {
        var lastError: Error = YTError.invalidResponse
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt))) }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                lastError = YTError.http(status)
                if status == 403 || status == 404 { break }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: HLS fallback

    /// Downloads one video variant (closest to `height`) and the preferred audio
    /// rendition of an HLS stream as fragmented MP4 files.
    static func fetchHLS(_ sources: Sources, height: Int?, dir: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> (video: URL?, audio: URL) {
        guard let master = sources.hlsURL else { throw YTError.invalidResponse }
        var info = sources.meta
        info.userAgent = sources.userAgent
        let headers = StreamResolver.headers(for: info)
        let (status, data) = await StreamResolver.get(master, headers: headers)
        let text = String(data: data, encoding: .utf8) ?? ""
        guard status == 200, text.hasPrefix("#EXTM3U") else { throw YTError.http(status) }
        let lines = text.components(separatedBy: "\n")

        // Variants
        struct Variant { let url: URL; let height: Int; let bandwidth: Int; let audioGroup: String?; let avc: Bool }
        var variants: [Variant] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") && i + 1 < lines.count {
            guard let url = absolute(lines[i + 1], base: master) else { continue }
            var h = 0
            if let r = line.range(of: #"RESOLUTION=\d+x(\d+)"#, options: .regularExpression) {
                h = Int(line[r].split(separator: "x").last ?? "") ?? 0
            }
            let bw = Int(StreamResolver.attribute("BANDWIDTH", in: line) ?? "") ?? 0
            variants.append(Variant(url: url, height: h, bandwidth: bw, audioGroup: StreamResolver.attribute("AUDIO", in: line),
                                    avc: line.contains("avc1")))
        }
        guard !variants.isEmpty else { throw YTError.invalidResponse }
        let pool = variants.contains(where: \.avc) ? variants.filter(\.avc) : variants
        let variant: Variant
        if let height {
            variant = pool.filter { $0.height <= height }.max { ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth) }
                ?? pool.min { $0.height < $1.height }!
        } else {
            variant = pool.min { $0.bandwidth < $1.bandwidth }!
        }

        // Audio rendition of that variant's group in the preferred language.
        let renditions = StreamResolver.audioRenditions(in: text)
        let wanted = StreamResolver.preferredRendition(renditions)?.language
        var audioURL: URL?
        var firstInGroup: URL?
        for line in lines where line.hasPrefix("#EXT-X-MEDIA") && line.contains("TYPE=AUDIO") {
            guard let uri = StreamResolver.attribute("URI", in: line), let url = absolute(uri, base: master) else { continue }
            if let g = variant.audioGroup, StreamResolver.attribute("GROUP-ID", in: line) != g { continue }
            if firstInGroup == nil { firstInGroup = url }
            if let wanted, StreamResolver.attribute("LANGUAGE", in: line) == wanted { audioURL = url; break }
        }
        audioURL = audioURL ?? firstInGroup

        let videoFile = dir.appendingPathComponent("video.mp4")
        let audioFile = dir.appendingPathComponent("audio.m4a")
        let needVideo = height != nil || audioURL == nil
        var parts: [(URL, URL, Double)] = []
        if needVideo { parts.append((variant.url, videoFile, audioURL == nil ? 1 : 0.85)) }
        if let audioURL { parts.append((audioURL, audioFile, needVideo ? 0.15 : 1)) }
        var done = 0.0
        for (playlist, file, share) in parts {
            let base = done
            try await fetchMediaPlaylist(playlist, to: file, info: info, headers: headers) { p in
                progress(base + p * share)
            }
            done += share
        }
        return (needVideo ? videoFile : nil, audioURL == nil ? videoFile : audioFile)
    }

    private static func fetchMediaPlaylist(_ url: URL, to file: URL, info: StreamInfo, headers: [String: String],
                                           progress: @escaping @Sendable (Double) -> Void) async throws {
        let (status, data) = await StreamResolver.get(url, headers: headers)
        var text = String(data: data, encoding: .utf8) ?? ""
        guard status == 200, text.hasPrefix("#EXTM3U") else { throw YTError.http(status) }
        let challenges = NSolver.challenges(in: text)
        if !challenges.isEmpty {
            let map = await NSolver.shared.solve(challenges)
            text = NSolver.apply(map, to: text)
        }
        var segments: [URL] = []
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#EXT-X-MAP:"), let uri = StreamResolver.attribute("URI", in: t), let u = absolute(uri, base: url) {
                segments.append(u)
            } else if !t.isEmpty, !t.hasPrefix("#"), let u = absolute(t, base: url) {
                segments.append(u)
            }
        }
        if let pot = info.poToken, !pot.isEmpty { segments = segments.map { HLSProxy.appending(pot: pot, to: $0) } }
        guard !segments.isEmpty else { throw YTError.invalidResponse }

        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let batch = 6
        for start in stride(from: 0, to: segments.count, by: batch) {
            try Task.checkCancellation()
            let slice = Array(segments[start..<min(segments.count, start + batch)])
            let results = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (i, u) in slice.enumerated() {
                    group.addTask {
                        var req = URLRequest(url: u, timeoutInterval: 30)
                        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                        return (i, try await load(req))
                    }
                }
                var out: [Int: Data] = [:]
                for try await (i, d) in group { out[i] = d }
                return out
            }
            for i in 0..<slice.count { if let d = results[i] { try handle.write(contentsOf: d) } }
            progress(Double(min(segments.count, start + batch)) / Double(segments.count))
        }
    }

    private static func absolute(_ s: String, base: URL) -> URL? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("http") { return URL(string: t) }
        return URL(string: t, relativeTo: base)?.absoluteURL
    }

    // MARK: Joining

    /// Puts video (optional) and audio into one MP4 / M4A without re-encoding.
    static func export(video: URL?, audio: URL, to output: URL, fileType: AVFileType,
                       metadata: [AVMetadataItem]) async throws {
        let composition = AVMutableComposition()
        var videoDuration: CMTime?
        if let video {
            let asset = AVURLAsset(url: video)
            guard let track = try await asset.loadTracks(withMediaType: .video).first,
                  let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw YTError.unplayable("Die Videospur ist beschädigt.")
            }
            let range = try await track.load(.timeRange)
            try target.insertTimeRange(range, of: track, at: .zero)
            target.preferredTransform = try await track.load(.preferredTransform)
            videoDuration = range.duration
        }
        let audioAsset = AVURLAsset(url: audio)
        if let track = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let range = try await track.load(.timeRange)
            let duration = videoDuration.map { CMTimeMinimum($0, range.duration) } ?? range.duration
            try target.insertTimeRange(CMTimeRange(start: range.start, duration: duration), of: track, at: .zero)
        } else if video == nil {
            throw YTError.unplayable("Die Tonspur ist beschädigt.")
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw YTError.unplayable("Export nicht möglich.")
        }
        session.metadata = metadata
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: fileType)
    }

    static func metadata(title: String, artist: String, album: String?, cover: Data?) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol, dataType: String? = nil) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            m.extendedLanguageTag = "und"
            if let dataType { m.dataType = dataType }
            return m
        }
        var items = [
            item(.commonIdentifierTitle, title as NSString),
            item(.commonIdentifierArtist, artist as NSString),
            item(.iTunesMetadataSongName, title as NSString),
            item(.iTunesMetadataArtist, artist as NSString)
        ]
        if let album {
            items.append(item(.commonIdentifierAlbumName, album as NSString))
            items.append(item(.iTunesMetadataAlbum, album as NSString))
        }
        if let cover {
            items.append(item(.commonIdentifierArtwork, cover as NSData, dataType: kCMMetadataBaseDataType_JPEG as String))
            items.append(item(.iTunesMetadataCoverArt, cover as NSData, dataType: kCMMetadataBaseDataType_JPEG as String))
        }
        return items
    }

    // MARK: Cover

    /// Best thumbnail, cut to a centred square (music players expect square covers).
    static func squareCover(_ videoId: String) async -> Data? {
        for name in ["maxresdefault", "sddefault", "hqdefault"] {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(videoId)/\(name).jpg"),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data), let cg = image.cgImage, cg.width > 200 else { continue }
            var rect = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
            // hq/sd thumbnails are 4:3 with black bars: use the 16:9 picture inside.
            if name != "maxresdefault" {
                let h = CGFloat(cg.width) * 9 / 16
                rect = CGRect(x: 0, y: (CGFloat(cg.height) - h) / 2, width: CGFloat(cg.width), height: h)
            }
            let side = min(rect.width, rect.height)
            let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side).integral
            guard let cropped = cg.cropping(to: square) else { continue }
            return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.9)
        }
        return nil
    }

    /// "Artist - Title (Official Video)" → ("Artist", "Title").
    static func songInfo(title: String, channel: String) -> (artist: String, title: String) {
        let artistFromChannel = channel.replacingOccurrences(of: " - Topic", with: "")
            .replacingOccurrences(of: "VEVO", with: "").trimmingCharacters(in: .whitespaces)
        for separator in [" - ", " – ", " — ", " | "] {
            let parts = title.components(separatedBy: separator)
            if parts.count >= 2 {
                let artist = parts[0].trimmingCharacters(in: .whitespaces)
                let song = MusicSearchRequest.clean(parts.dropFirst().joined(separator: separator))
                if !artist.isEmpty, !song.isEmpty { return (artist, song) }
            }
        }
        let song = MusicSearchRequest.clean(title)
        return (artistFromChannel.isEmpty ? channel : artistFromChannel, song.isEmpty ? title : song)
    }
}
