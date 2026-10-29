import AVFoundation
import Foundation

/// A stream that passed the pre-flight checks and is ready to hand to AVPlayer.
struct PreparedStream {
    let info: StreamInfo
    let asset: AVAsset
    let label: String
    /// Keeps the resource-loader delegate alive (AVAssetResourceLoader holds it weakly).
    let proxy: HLSProxy?
}

/// Turns raw player responses into playable assets: probes manifests and segments,
/// solves the "n" challenge and routes playlists through `HLSProxy` when needed.
enum StreamResolver {
    static let probeTimeout: TimeInterval = 12

    /// Tries the sources in order and returns the first one `accept` agrees to play.
    /// A fast pass uses the clients that answer first; only if none of them works are
    /// all clients (and finally the web player) asked.
    @MainActor
    static func firstPlayable(_ videoId: String, accept: (PreparedStream) async -> Bool) async -> PreparedStream? {
        DebugLog.log("▶︎ Video \(videoId)")
        var tried = Set<String>()
        for thorough in [false, true] {
            let result = await YouTube.streamCandidates(videoId, thorough: thorough)
            for info in result.candidates {
                if Task.isCancelled { return nil }
                guard tried.insert(info.source + (info.isHLS ? " HLS" : "")).inserted else { continue }
                if let prepared = await prepare(info), await accept(prepared) { return prepared }
            }
            if result.complete { break }
            if Task.isCancelled { return nil }
            DebugLog.log("↻ Alle Clients abfragen")
        }
        if Task.isCancelled { return nil }
        DebugLog.log("↻ Fallback: Web-Player-Extraktion")
        if let info = await WebViewExtractor.shared.extract(videoId),
           let prepared = await prepare(info), await accept(prepared) {
            return prepared
        }
        DebugLog.log("✖︎ Keine abspielbare Quelle für \(videoId)")
        return nil
    }

    /// Waits until AVPlayer reports the item as playable (or failed / timed out).
    @MainActor
    static func waitUntilReady(_ item: AVPlayerItem, label: String, timeout: TimeInterval = 12) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if Task.isCancelled { return false }
            switch item.status {
            case .readyToPlay:
                DebugLog.log("✔︎ Wiedergabe über \(label) nach \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                return true
            case .failed:
                let e = item.error as NSError?
                DebugLog.log("✖︎ \(label): AVPlayer-Fehler \(e?.domain ?? "") \(e?.code ?? 0) – \(e?.localizedDescription ?? "")")
                logErrorEvents(item)
                return false
            default:
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        DebugLog.log("✖︎ \(label): Zeitüberschreitung beim Laden")
        logErrorEvents(item)
        return false
    }

    private static func logErrorEvents(_ item: AVPlayerItem) {
        for event in item.errorLog()?.events.suffix(4) ?? [] {
            DebugLog.log("   ErrorLog \(event.errorStatusCode) \(event.errorDomain): \(event.errorComment ?? "") \(DebugLog.short(event.uri.flatMap(URL.init(string:))))")
        }
    }

    static func headers(for info: StreamInfo) -> [String: String] {
        [
            "User-Agent": info.userAgent,
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com/"
        ]
    }

    static func get(_ url: URL, headers: [String: String], range: Bool = false) async -> (Int, Data) {
        var req = URLRequest(url: url, timeoutInterval: probeTimeout)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if range { req.setValue("bytes=0-4095", forHTTPHeaderField: "Range") }
        do {
            let (data, response) = try await InnerTube.shared.session.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            return (-1, Data(error.localizedDescription.utf8))
        }
    }

    static func prepare(_ info: StreamInfo) async -> PreparedStream? {
        let label = info.source
        let hdrs = headers(for: info)

        if !info.isHLS, let audioURL = info.audioURL {
            return await prepareAdaptive(info, audioURL: audioURL, headers: hdrs)
        }

        if !info.isHLS {
            var url = info.hlsURL
            let challenges = NSolver.challenges(in: url.absoluteString)
            if !challenges.isEmpty {
                let map = await NSolver.shared.solve(challenges)
                if let fixed = URL(string: NSolver.apply(map, to: url.absoluteString)) { url = fixed }
            }
            let (status, _) = await get(url, headers: hdrs, range: true)
            DebugLog.log("[\(label)] MP4-Probe HTTP \(status)")
            guard (200..<300).contains(status) else { return nil }
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": hdrs])
            return PreparedStream(info: info, asset: asset, label: label, proxy: nil)
        }

        // 1. Master manifest
        let (masterStatus, masterData) = await get(info.hlsURL, headers: hdrs)
        let master = String(data: masterData, encoding: .utf8) ?? ""
        let variants = master.components(separatedBy: "\n").filter { $0.hasPrefix("#EXT-X-STREAM-INF") }
        DebugLog.log("[\(label)] Master HTTP \(masterStatus), \(masterData.count) B, \(variants.count) Varianten")
        guard masterStatus == 200, master.hasPrefix("#EXTM3U") else {
            DebugLog.log("[\(label)] Master-Antwort: \(String(master.prefix(160)))")
            return nil
        }
        if let first = variants.first(where: { $0.contains("avc1") }) ?? variants.first {
            DebugLog.log("[\(label)] Variante: \(first.prefix(150))")
        }

        // 2. One variant playlist (prefer H.264 ~720p) to discover segment URLs.
        let variantURL = pickVariant(master, base: info.hlsURL)
        var variantText = ""
        if let variantURL {
            let (vStatus, vData) = await get(variantURL, headers: hdrs)
            variantText = String(data: vData, encoding: .utf8) ?? ""
            DebugLog.log("[\(label)] Varianten-Playlist HTTP \(vStatus), \(vData.count) B")
        }

        // 3. Solve "n" challenges if present.
        let challenges = NSolver.challenges(in: master + "\n" + variantText)
        var map: [String: String] = [:]
        if !challenges.isEmpty {
            map = await NSolver.shared.solve(challenges)
            DebugLog.log("[\(label)] n-Challenges: \(challenges.count), gelöst: \(map.count)")
        }

        // 4. Probe the first media segment.
        if let segment = firstSegment(variantText, base: variantURL ?? info.hlsURL) {
            var segURL = segment
            if !map.isEmpty, let fixed = URL(string: NSolver.apply(map, to: segment.absoluteString)) { segURL = fixed }
            if let pot = info.poToken, !pot.isEmpty { segURL = HLSProxy.appending(pot: pot, to: segURL) }
            let (segStatus, segData) = await get(segURL, headers: hdrs, range: true)
            DebugLog.log("[\(label)] Segment-Probe HTTP \(segStatus), \(segData.count) B")
            guard (200..<300).contains(segStatus) else { return nil }
        } else {
            DebugLog.log("[\(label)] Kein Segment in der Playlist gefunden")
        }

        // 5. Build the asset — through the proxy when playlists need rewriting.
        if !map.isEmpty || (info.poToken?.isEmpty == false) {
            let proxy = HLSProxy(nMap: map, poToken: info.poToken, headers: hdrs)
            let asset = AVURLAsset(url: HLSProxy.proxied(info.hlsURL), options: ["AVURLAssetHTTPHeaderFieldsKey": hdrs])
            asset.resourceLoader.setDelegate(proxy, queue: proxy.queue)
            return PreparedStream(info: info, asset: asset, label: label + " (Proxy)", proxy: proxy)
        }
        let asset = AVURLAsset(url: info.hlsURL, options: ["AVURLAssetHTTPHeaderFieldsKey": hdrs])
        return PreparedStream(info: info, asset: asset, label: label, proxy: nil)
    }

    /// Separate video + audio streams (like DASH) combined into one composition.
    private static func prepareAdaptive(_ info: StreamInfo, audioURL: URL, headers hdrs: [String: String]) async -> PreparedStream? {
        let label = info.source
        async let videoProbe = get(info.hlsURL, headers: hdrs, range: true)
        async let audioProbe = get(audioURL, headers: hdrs, range: true)
        let (vStatus, _) = await videoProbe
        let (aStatus, _) = await audioProbe
        DebugLog.log("[\(label)] Video-Probe HTTP \(vStatus), Audio-Probe HTTP \(aStatus)")
        guard (200..<300).contains(vStatus), (200..<300).contains(aStatus) else { return nil }

        let options = ["AVURLAssetHTTPHeaderFieldsKey": hdrs]
        let videoAsset = AVURLAsset(url: info.hlsURL, options: options)
        let audioAsset = AVURLAsset(url: audioURL, options: options)
        do {
            guard let vt = try await videoAsset.loadTracks(withMediaType: .video).first,
                  let at = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                DebugLog.log("[\(label)] Keine Spuren gefunden")
                return nil
            }
            let vRange = try await vt.load(.timeRange)
            let aRange = try await at.load(.timeRange)
            let composition = AVMutableComposition()
            guard let cv = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let ca = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return nil
            }
            try cv.insertTimeRange(vRange, of: vt, at: .zero)
            cv.preferredTransform = try await vt.load(.preferredTransform)
            let audioDuration = CMTimeMinimum(aRange.duration, vRange.duration)
            try ca.insertTimeRange(CMTimeRange(start: aRange.start, duration: audioDuration), of: at, at: .zero)
            DebugLog.log("[\(label)] Komposition bereit (\(Int(vRange.duration.seconds)) s)")
            return PreparedStream(info: info, asset: composition, label: label, proxy: nil)
        } catch {
            DebugLog.log("[\(label)] Komposition fehlgeschlagen: \(error.localizedDescription)")
            return nil
        }
    }

    private static func resolve(_ line: String, base: URL) -> URL? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("http") { return URL(string: t) }
        return URL(string: t, relativeTo: base)?.absoluteURL
    }

    static func pickVariant(_ master: String, base: URL) -> URL? {
        let lines = master.components(separatedBy: "\n")
        var best: (score: Int, url: URL)?
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") && i + 1 < lines.count {
            guard let url = resolve(lines[i + 1], base: base) else { continue }
            var height = 0
            if let r = line.range(of: #"RESOLUTION=\d+x(\d+)"#, options: .regularExpression) {
                height = Int(line[r].split(separator: "x").last ?? "") ?? 0
            }
            let score = (line.contains("avc1") ? 10_000 : 0) - abs(height - 720)
            if best == nil || score > best!.score { best = (score, url) }
        }
        return best?.url
    }

    static func firstSegment(_ playlist: String, base: URL) -> URL? {
        for line in playlist.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#EXT-X-MAP:"), let r = t.range(of: #"URI="([^"]+)""#, options: .regularExpression) {
                let uri = t[r].dropFirst(5).dropLast()
                return resolve(String(uri), base: base)
            }
            if !t.isEmpty, !t.hasPrefix("#") { return resolve(t, base: base) }
        }
        return nil
    }
}

/// Serves HLS playlists through a custom URL scheme so they can be rewritten
/// (solved "n" values, PO token on segment URLs) before AVPlayer reads them.
final class HLSProxy: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "nicehls"
    let queue = DispatchQueue(label: "niceyt.hlsproxy")
    private let nMap: [String: String]
    private let poToken: String?
    private let headers: [String: String]
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(nMap: [String: String], poToken: String?, headers: [String: String]) {
        self.nMap = nMap
        self.poToken = (poToken?.isEmpty == false) ? poToken : nil
        self.headers = headers
    }

    static func proxied(_ url: URL) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.scheme = scheme
        return c.url!
    }

    static func appending(pot: String, to url: URL) -> URL {
        let s = url.absoluteString
        return URL(string: s + (s.contains("?") ? "&" : "?") + "pot=" + pot) ?? url
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme,
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        c.scheme = "https"
        guard let real = c.url else { return false }
        var req = URLRequest(url: real, timeoutInterval: 30)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let key = ObjectIdentifier(loadingRequest)
        let task = InnerTube.shared.session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async { self.tasks[key] = nil }
            if let error {
                DebugLog.log("[Proxy] Fehler: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200..<300).contains(status) else {
                DebugLog.log("[Proxy] HTTP \(status) für Playlist")
                loadingRequest.finishLoading(with: NSError(domain: "NiceYT.HLSProxy", code: status))
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            let out = self.rewrite(text, base: real).data(using: .utf8) ?? data
            if let info = loadingRequest.contentInformationRequest {
                info.contentType = "public.m3u-playlist"
                info.contentLength = Int64(out.count)
                info.isByteRangeAccessSupported = false
            }
            loadingRequest.dataRequest?.respond(with: out)
            loadingRequest.finishLoading()
        }
        queue.async { self.tasks[key] = task }
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        tasks[key]?.cancel()
        tasks[key] = nil
    }

    private func rewrite(_ text: String, base: URL) -> String {
        let solved = NSolver.apply(nMap, to: text)
        let isMaster = solved.contains("#EXT-X-STREAM-INF")
        var out: [String] = []
        for line in solved.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { out.append(line); continue }
            if t.hasPrefix("#") {
                if isMaster, t.hasPrefix("#EXT-X-MEDIA"), let r = t.range(of: #"URI="([^"]+)""#, options: .regularExpression) {
                    let uri = String(t[r].dropFirst(5).dropLast())
                    if let abs = absolute(uri, base: base) {
                        out.append(t.replacingCharacters(in: r, with: "URI=\"\(Self.proxied(abs).absoluteString)\""))
                        continue
                    }
                }
                if !isMaster, let pot = poToken, t.hasPrefix("#EXT-X-MAP:"),
                   let r = t.range(of: #"URI="([^"]+)""#, options: .regularExpression) {
                    let uri = String(t[r].dropFirst(5).dropLast())
                    if let abs = absolute(uri, base: base) {
                        out.append(t.replacingCharacters(in: r, with: "URI=\"\(Self.appending(pot: pot, to: abs).absoluteString)\""))
                        continue
                    }
                }
                out.append(line)
                continue
            }
            guard let abs = absolute(t, base: base) else { out.append(line); continue }
            if isMaster {
                out.append(Self.proxied(abs).absoluteString)
            } else if let pot = poToken {
                out.append(Self.appending(pot: pot, to: abs).absoluteString)
            } else {
                out.append(abs.absoluteString)
            }
        }
        return out.joined(separator: "\n")
    }

    private func absolute(_ uri: String, base: URL) -> URL? {
        if uri.hasPrefix("http") { return URL(string: uri) }
        var https = URLComponents(url: base, resolvingAgainstBaseURL: false)
        https?.scheme = "https"
        guard let b = https?.url else { return nil }
        return URL(string: uri, relativeTo: b)?.absoluteURL
    }
}
