import AVFoundation
import Foundation

/// Downloads MPEG-DASH presentations (.mpd) like dash-mpd-cli does – best video and
/// audio, every segment, all periods – but muxes them natively with AVFoundation into
/// one MP4, without ffmpeg. Supported: SegmentTemplate ($Number$/$Time$, SegmentTimeline),
/// SegmentList, SegmentBase/BaseURL single files, multi-period. Not: live, DRM, WebM.
enum DASHDownloader {
    enum DASHError: LocalizedError {
        case invalidManifest
        case live
        case drm
        case webm
        case noStreams
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidManifest: return "Die DASH-Beschreibung (MPD) ist ungültig."
            case .live: return "Live-Streams (DASH) können nicht gespeichert werden."
            case .drm: return "Dieser DASH-Stream ist verschlüsselt (DRM) und kann nicht gespeichert werden."
            case .webm: return "WebM-DASH wird nicht unterstützt (nur MP4-Segmente)."
            case .noStreams: return "Im DASH-Stream wurde kein Video oder Ton gefunden."
            case .http(let code): return "Serverfehler (\(code))"
            }
        }
    }

    /// Downloads `mpd` and returns an MP4 file in the temporary directory.
    static func download(_ mpd: URL, headers: [String: String] = [:],
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let (data, final) = try await fetch(mpd, headers: headers)
        let manifest = try Manifest(data: data, url: final)
        let periods = try manifest.plan()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dash-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let total = Double(max(1, periods.reduce(0) { $0 + $1.video.count + $1.audio.count }))
        let counter = Counter()
        var parts: [(video: URL?, audio: URL?)] = []
        for (i, period) in periods.enumerated() {
            let report: @Sendable () -> Void = { progress(min(0.97, Double(counter.increment()) / total)) }
            let video = period.video.isEmpty ? nil
                : try await fetchTrack(period.video, headers: headers, to: dir.appendingPathComponent("v\(i).mp4"), report: report)
            let audio = period.audio.isEmpty ? nil
                : try await fetchTrack(period.audio, headers: headers, to: dir.appendingPathComponent("a\(i).mp4"), report: report)
            parts.append((video, audio))
        }
        let out = dir.appendingPathComponent("out.mp4")
        try await mux(parts, to: out)
        progress(1)
        return out
    }

    // MARK: Networking

    private final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private static func fetch(_ url: URL, headers: [String: String], range: String? = nil) async throws -> (Data, URL) {
        var req = URLRequest(url: url, timeoutInterval: 40)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let range { req.setValue("bytes=" + range, forHTTPHeaderField: "Range") }
        var lastError: Error = DASHError.http(0)
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(status) else { throw DASHError.http(status) }
                return (data, response.url ?? url)
            } catch {
                lastError = error
                if let e = error as? DASHError, case .http(let code) = e, code == 404 || code == 403 { break }
                try await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        throw lastError
    }

    /// Appends init and media segments into one fragmented MP4 file.
    private static func fetchTrack(_ segments: [Segment], headers: [String: String], to file: URL,
                                   report: @escaping @Sendable () -> Void) async throws -> URL {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let batch = 6
        for start in stride(from: 0, to: segments.count, by: batch) {
            try Task.checkCancellation()
            let slice = Array(segments[start..<min(segments.count, start + batch)])
            let parts = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (i, s) in slice.enumerated() {
                    group.addTask {
                        let data = try await fetch(s.url, headers: headers, range: s.range).0
                        report()
                        return (i, data)
                    }
                }
                var out: [Int: Data] = [:]
                for try await (i, d) in group { out[i] = d }
                return out
            }
            for i in 0..<slice.count { if let d = parts[i] { try handle.write(contentsOf: d) } }
        }
        return file
    }

    // MARK: Muxing

    /// Puts the periods one after another into one MP4 (pass-through, no re-encoding).
    static func mux(_ parts: [(video: URL?, audio: URL?)], to output: URL) async throws {
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        var hasVideo = false
        var hasAudio = false
        for part in parts {
            var length = CMTime.zero
            let videoAsset = part.video.map { AVURLAsset(url: $0) }
            let audioAsset = part.audio.map { AVURLAsset(url: $0) } ?? videoAsset
            if let videoAsset, let track = try await videoAsset.loadTracks(withMediaType: .video).first {
                let range = try await track.load(.timeRange)
                try videoTrack?.insertTimeRange(range, of: track, at: cursor)
                if let transform = try? await track.load(.preferredTransform) { videoTrack?.preferredTransform = transform }
                length = range.duration
                hasVideo = true
            }
            if let audioAsset, let track = try await audioAsset.loadTracks(withMediaType: .audio).first {
                var range = try await track.load(.timeRange)
                if hasVideo, length > .zero, range.duration > length { range.duration = length }
                try audioTrack?.insertTimeRange(range, of: track, at: cursor)
                if length == .zero { length = range.duration }
                hasAudio = true
            }
            cursor = cursor + length
        }
        guard hasVideo || hasAudio else { throw DASHError.noStreams }
        if !hasVideo, let videoTrack { composition.removeTrack(videoTrack) }
        if !hasAudio, let audioTrack { composition.removeTrack(audioTrack) }
        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw DASHError.noStreams
        }
        export.shouldOptimizeForNetworkUse = true
        try await export.export(to: output, as: hasVideo ? .mp4 : .m4a)
    }

    // MARK: - Manifest

    struct Segment: Sendable {
        let url: URL
        let range: String?
    }

    struct PeriodPlan {
        var video: [Segment]
        var audio: [Segment]
    }

    /// Minimal XML tree of the MPD.
    final class Node {
        let name: String
        let attrs: [String: String]
        var children: [Node] = []
        var text = ""

        init(name: String, attrs: [String: String]) {
            self.name = name
            self.attrs = attrs
        }

        func all(_ name: String) -> [Node] { children.filter { $0.name == name } }
        func first(_ name: String) -> Node? { children.first { $0.name == name } }
        subscript(_ key: String) -> String? { attrs[key] }
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            var attrs: [String: String] = [:]
            for (k, v) in attributeDict { attrs[k.split(separator: ":").last.map(String.init) ?? k] = v }
            let node = Node(name: local, attrs: attrs)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }
    }

    struct Manifest {
        let root: Node
        let url: URL

        init(data: Data, url: URL) throws {
            let parser = XMLParser(data: data)
            let builder = TreeBuilder()
            parser.delegate = builder
            guard parser.parse(), let root = builder.root, root.name == "MPD" else { throw DASHError.invalidManifest }
            self.root = root
            self.url = url
        }

        /// Segments of the best video and audio of every period.
        func plan() throws -> [PeriodPlan] {
            if root["type"] == "dynamic" { throw DASHError.live }
            let total = root["mediaPresentationDuration"].flatMap(DASHDownloader.seconds)
            let base = DASHDownloader.base(root, url)
            let periods = root.all("Period")
            guard !periods.isEmpty else { throw DASHError.invalidManifest }
            var plans: [PeriodPlan] = []
            var offset: Double = 0
            for (i, period) in periods.enumerated() {
                let start = period["start"].flatMap(DASHDownloader.seconds) ?? offset
                var length = period["duration"].flatMap(DASHDownloader.seconds)
                if length == nil {
                    if i + 1 < periods.count, let next = periods[i + 1]["start"].flatMap(DASHDownloader.seconds) {
                        length = next - start
                    } else if let total {
                        length = total - start
                    }
                }
                offset = start + (length ?? 0)
                let periodBase = DASHDownloader.base(period, base)
                let sets = period.all("AdaptationSet")
                let video = try best(sets, kind: "video", period: period, base: periodBase, length: length ?? 0)
                let audio = try best(sets, kind: "audio", period: period, base: periodBase, length: length ?? 0)
                guard !video.isEmpty || !audio.isEmpty else { continue }
                plans.append(PeriodPlan(video: video, audio: audio))
            }
            guard !plans.isEmpty else { throw DASHError.noStreams }
            return plans
        }

        private func kind(of set: Node) -> String? {
            let rep = set.first("Representation")
            let mime = (set["mimeType"] ?? rep?["mimeType"] ?? "").lowercased()
            let type = (set["contentType"] ?? "").lowercased()
            let codecs = (set["codecs"] ?? rep?["codecs"] ?? "").lowercased()
            if type == "video" || mime.hasPrefix("video") { return "video" }
            if type == "audio" || mime.hasPrefix("audio") { return "audio" }
            if ["avc", "hvc", "hev", "av01", "vp09"].contains(where: { codecs.hasPrefix($0) }) { return "video" }
            if ["mp4a", "ac-3", "ec-3", "opus"].contains(where: { codecs.hasPrefix($0) }) { return "audio" }
            return nil
        }

        private func best(_ sets: [Node], kind wanted: String, period: Node, base: URL, length: Double) throws -> [Segment] {
            let matching = sets.filter { kind(of: $0) == wanted }
            guard !matching.isEmpty else { return [] }
            func isWebM(_ set: Node) -> Bool {
                ((set["mimeType"] ?? set.first("Representation")?["mimeType"] ?? "").lowercased()).contains("webm")
            }
            let mp4 = matching.filter { !isWebM($0) }
            guard !mp4.isEmpty else { throw DASHError.webm }
            var candidates: [(set: Node, rep: Node)] = []
            for set in mp4 {
                for rep in set.all("Representation") { candidates.append((set, rep)) }
            }
            func score(_ c: (set: Node, rep: Node)) -> (Int, Int) {
                let height = Int(c.rep["height"] ?? c.set["height"] ?? "") ?? 0
                let bandwidth = Int(c.rep["bandwidth"] ?? "") ?? 0
                return wanted == "video" ? (height, bandwidth) : (bandwidth, 0)
            }
            // Clear streams first; encrypted ones only if nothing else is there.
            let clear = candidates.filter { $0.set.first("ContentProtection") == nil && $0.rep.first("ContentProtection") == nil }
            guard let chosen = clear.max(by: { score($0) < score($1) }) else {
                if !candidates.isEmpty { throw DASHError.drm }
                return []
            }
            return try segments(rep: chosen.rep, set: chosen.set, period: period, base: base, length: length)
        }

        private func segments(rep: Node, set: Node, period: Node, base: URL, length: Double) throws -> [Segment] {
            let repBase = DASHDownloader.base(rep, DASHDownloader.base(set, base))
            let id = rep["id"] ?? ""
            let bandwidth = rep["bandwidth"] ?? ""
            if let template = mergedTemplate([period.first("SegmentTemplate"), set.first("SegmentTemplate"), rep.first("SegmentTemplate")]) {
                return try templateSegments(template, base: repBase, id: id, bandwidth: bandwidth, length: length)
            }
            if let list = rep.first("SegmentList") ?? set.first("SegmentList") {
                var out: [Segment] = []
                if let initNode = list.first("Initialization") {
                    let u = initNode["sourceURL"].flatMap { URL(string: $0, relativeTo: repBase)?.absoluteURL } ?? repBase
                    out.append(Segment(url: u, range: initNode["range"]))
                }
                for s in list.all("SegmentURL") {
                    let u = s["media"].flatMap { URL(string: $0, relativeTo: repBase)?.absoluteURL } ?? repBase
                    out.append(Segment(url: u, range: s["mediaRange"]))
                }
                return out
            }
            // SegmentBase / plain BaseURL: one file holds everything.
            return [Segment(url: repBase, range: nil)]
        }

        /// Attributes are inherited from period → adaptation set → representation.
        private func mergedTemplate(_ levels: [Node?]) -> Node? {
            let present = levels.compactMap { $0 }
            guard !present.isEmpty else { return nil }
            var attrs: [String: String] = [:]
            for n in present { attrs.merge(n.attrs) { _, new in new } }
            let merged = Node(name: "SegmentTemplate", attrs: attrs)
            if let timeline = present.reversed().compactMap({ $0.first("SegmentTimeline") }).first { merged.children = [timeline] }
            return merged
        }

        private func templateSegments(_ t: Node, base: URL, id: String, bandwidth: String, length: Double) throws -> [Segment] {
            let timescale = Double(t["timescale"] ?? "") ?? 1
            let startNumber = Int(t["startNumber"] ?? "") ?? 1
            let offset = Int64(t["presentationTimeOffset"] ?? "") ?? 0
            func url(_ pattern: String, number: Int, time: Int64) -> URL? {
                let path = DASHDownloader.fill(pattern, id: id, bandwidth: bandwidth, number: number, time: time)
                return URL(string: path, relativeTo: base)?.absoluteURL
            }
            var out: [Segment] = []
            if let initPattern = t["initialization"], let u = url(initPattern, number: startNumber, time: 0) {
                out.append(Segment(url: u, range: nil))
            }
            guard let media = t["media"] else { return out }
            var number = startNumber
            if let timeline = t.first("SegmentTimeline") {
                var time: Int64 = offset
                let end = offset + Int64(length * timescale)
                for s in timeline.all("S") {
                    if let start = Int64(s["t"] ?? "") { time = start }
                    let d = Int64(s["d"] ?? "") ?? 0
                    guard d > 0 else { continue }
                    var repeats = Int(s["r"] ?? "") ?? 0
                    if repeats < 0 { repeats = length > 0 ? max(0, Int((Double(end - time) / Double(d)).rounded(.up)) - 1) : 0 }
                    for _ in 0...repeats {
                        if let u = url(media, number: number, time: time) { out.append(Segment(url: u, range: nil)) }
                        time += d
                        number += 1
                    }
                }
            } else if let d = Double(t["duration"] ?? ""), d > 0 {
                guard length > 0 else { throw DASHError.invalidManifest }
                let count = Int((length * timescale / d).rounded(.up))
                for i in 0..<count {
                    let time = offset + Int64(Double(i) * d)
                    if let u = url(media, number: number, time: time) { out.append(Segment(url: u, range: nil)) }
                    number += 1
                }
            }
            return out
        }
    }

    // MARK: Helpers

    static func base(_ node: Node, _ parent: URL) -> URL {
        guard let text = node.first("BaseURL")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let u = URL(string: text, relativeTo: parent)?.absoluteURL else { return parent }
        return u
    }

    /// Replaces $RepresentationID$, $Bandwidth$, $Number%05d$, $Time$ and $$.
    static func fill(_ pattern: String, id: String, bandwidth: String, number: Int, time: Int64) -> String {
        guard let rx = try? NSRegularExpression(pattern: #"\$(RepresentationID|Number|Bandwidth|Time)(?:%0?(\d+)d)?\$"#) else { return pattern }
        let ns = pattern as NSString
        var result = ""
        var last = 0
        for m in rx.matches(in: pattern, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let key = ns.substring(with: m.range(at: 1))
            let width = m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) ?? 0 : 0
            let value: String
            switch key {
            case "RepresentationID": value = id
            case "Bandwidth": value = bandwidth
            case "Number": value = String(number)
            default: value = String(time)
            }
            result += value.count < width ? String(repeating: "0", count: width - value.count) + value : value
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result.replacingOccurrences(of: "$$", with: "$")
    }

    /// ISO 8601 durations like "PT1H2M3.5S" or "P1DT2H".
    static func seconds(_ iso: String) -> Double? {
        guard let rx = try? NSRegularExpression(pattern: #"^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#),
              let m = rx.firstMatch(in: iso, range: NSRange(iso.startIndex..., in: iso)) else { return nil }
        let factors = [86400.0, 3600, 60, 1]
        var total = 0.0
        for i in 1...4 {
            if let r = Range(m.range(at: i), in: iso), let v = Double(iso[r]) { total += v * factors[i - 1] }
        }
        return total
    }
}
