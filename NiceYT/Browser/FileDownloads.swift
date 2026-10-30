import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct SavedFile: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var fileName: String
    var source: String
    var page: String?
    var size: Int64
    var date: Date
    /// Cover/preview from the site (used for audio without embedded artwork).
    var thumbnail: String?
    /// "TikTok", "Instagram" … when it came through the download assistant.
    var site: String?

    var url: URL { FileDownloads.folder.appendingPathComponent(fileName) }
    var kind: MediaKind { MediaKind(fileExtension: (fileName as NSString).pathExtension) }
    var fileExtension: String { (fileName as NSString).pathExtension.uppercased() }
    var host: String? { URL(string: page ?? source)?.host?.replacingOccurrences(of: "www.", with: "") }
}

enum MediaKind: String, Codable, Sendable {
    case video, audio, stream, image, file

    init(fileExtension ext: String) {
        switch ext.lowercased() {
        case "mp4", "mov", "m4v", "webm", "mkv", "ts", "3gp": self = .video
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus": self = .audio
        case "m3u8", "mpd": self = .stream
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "avif": self = .image
        default: self = .file
        }
    }

    var icon: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .stream: return "dot.radiowaves.left.and.right"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    var label: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .stream: return "Stream"
        case .image: return "Bild"
        case .file: return "Datei"
        }
    }

    var isPlayable: Bool { self == .video || self == .audio || self == .stream }
}

/// Where a finished download goes in addition to the media library.
enum DownloadTarget: String, CaseIterable, Identifiable, Sendable {
    case library, photos, files

    var id: String { rawValue }
    var label: String {
        switch self {
        case .library: return "Mediathek"
        case .photos: return "Fotos"
        case .files: return "Dateien"
        }
    }
    var icon: String {
        switch self {
        case .library: return "square.stack.fill"
        case .photos: return "photo.on.rectangle"
        case .files: return "folder.fill"
        }
    }

    static var current: DownloadTarget {
        DownloadTarget(rawValue: UserDefaults.standard.string(forKey: "downloadTarget") ?? "") ?? .library
    }
}

/// Downloads of the browser and the download assistant (Documents/Downloads) – the media library.
@MainActor
final class FileDownloads: ObservableObject {
    static let shared = FileDownloads()

    /// Everything needed to run (or retry) one download.
    struct Request: Sendable {
        var candidates: [URL]
        var name: String?
        var page: URL?
        var userAgent: String
        var headers: [String: String] = [:]
        /// Separate sound track (DASH) that gets merged into the video.
        var audio: [URL] = []
        var thumbnail: URL?
        var site: String?
        var target: DownloadTarget
        var isPrivate = false
    }

    struct Job: Identifiable {
        let id: String
        var name: String
        var progress: Double = 0
        var status = "Wird geladen …"
        var failed = false
        let source: URL
        var request: Request?
    }

    @Published private(set) var files: [SavedFile] = []
    @Published private(set) var jobs: [String: Job] = [:]
    /// Job id → id of the saved file, so the assistant can show the result.
    @Published private(set) var finished: [String: String] = [:]
    var onToast: ((String) -> Void)?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var filesExport: [URL] = []
    private var exportTask: Task<Void, Never>?

    nonisolated static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("fileDownloads.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let list = try? JSONDecoder().decode([SavedFile].self, from: data) {
            files = list.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
    }

    var activeJobs: [Job] { jobs.values.sorted { $0.id < $1.id } }
    var runningCount: Int { jobs.values.filter { !$0.failed }.count }
    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    func file(_ id: String) -> SavedFile? { files.first { $0.id == id } }

    /// Sortable (by start time) and unique.
    private static func newJobId() -> String {
        String(format: "%.6f-", Date().timeIntervalSince1970) + String(UUID().uuidString.prefix(6))
    }

    // MARK: Starting

    /// Downloads `url` with the browser's cookies (needed by TikTok, Instagram …).
    /// `alternatives` are tried in order when a mirror fails.
    @discardableResult
    func download(_ url: URL, name: String? = nil, page: URL? = nil, userAgent: String = BrowserModel.mobileUA,
                  headers: [String: String] = [:], alternatives: [URL] = [], audio: [URL] = [], thumbnail: URL? = nil,
                  site: String? = nil, target: DownloadTarget? = nil, isPrivate: Bool = false, quiet: Bool = false) -> String {
        let request = Request(candidates: [url] + alternatives.filter { $0 != url }, name: name, page: page, userAgent: userAgent,
                              headers: headers, audio: audio, thumbnail: thumbnail, site: site, target: target ?? .current,
                              isPrivate: isPrivate)
        return start(request, quiet: quiet)
    }

    @discardableResult
    func start(_ request: Request, quiet: Bool = false) -> String {
        let id = Self.newJobId()
        let source = request.candidates.first ?? URL(string: "about:blank")!
        let display = request.name.map { ($0 as NSString).deletingPathExtension } ?? Self.displayName(for: source)
        jobs[id] = Job(id: id, name: display, source: source, request: request)
        if !quiet {
            Haptics.success()
            onToast?("Download gestartet")
        }
        tasks[id] = Task { await run(id, request) }
        return id
    }

    @discardableResult
    func retry(_ id: String) -> String? {
        guard let job = jobs[id], let request = job.request else { return nil }
        jobs[id] = nil
        return start(request)
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        jobs[id] = nil
    }

    /// A file that WebKit downloaded itself (links, form posts).
    func register(_ file: URL, name: String, source: URL?, page: URL?) {
        let target = Self.uniqueURL(for: name)
        try? FileManager.default.moveItem(at: file, to: target)
        let saved = add(target, name: name, source: source?.absoluteString ?? "", page: page, thumbnail: nil, site: nil)
        export(saved, to: .current)
    }

    @discardableResult
    private func add(_ file: URL, name: String, source: String, page: URL?, thumbnail: URL?, site: String?) -> SavedFile {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let saved = SavedFile(id: UUID().uuidString, name: (name as NSString).deletingPathExtension, fileName: file.lastPathComponent,
                              source: source, page: page?.absoluteString, size: size, date: Date(),
                              thumbnail: thumbnail?.absoluteString, site: site)
        files.insert(saved, at: 0)
        save()
        Haptics.success()
        onToast?("„\(saved.name)“ gespeichert")
        return saved
    }

    /// Copies a finished download to Photos or Files, depending on the target.
    func export(_ file: SavedFile, to target: DownloadTarget) {
        switch target {
        case .library:
            break
        case .photos:
            if file.kind == .video || file.kind == .image {
                FileSaver.saveToPhotos(file.url) { [weak self] in self?.onToast?($0) }
            } else {
                queueFilesExport(file.url)
            }
        case .files:
            queueFilesExport(file.url)
        }
    }

    /// Several files finishing together (carousels, slideshows) go into one Files dialog.
    private func queueFilesExport(_ url: URL) {
        filesExport.append(url)
        exportTask?.cancel()
        exportTask = Task {
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            let urls = filesExport
            filesExport = []
            FileSaver.saveToFiles(urls)
        }
    }

    // MARK: Downloads run by WebKit

    func startExternal(name: String, source: URL?) -> String {
        let id = Self.newJobId()
        jobs[id] = Job(id: id, name: name, source: source ?? URL(string: "about:blank")!)
        Haptics.success()
        onToast?("Download gestartet")
        return id
    }

    func updateExternal(_ id: String, progress: Double) {
        update(id, progress: min(0.99, progress))
    }

    func finishExternal(_ id: String, file: URL, name: String, source: URL?, page: URL?) {
        jobs[id] = nil
        register(file, name: name, source: source, page: page)
        if let saved = files.first { finished[id] = saved.id }
    }

    func failExternal(_ id: String, error: Error) {
        update(id, status: "Fehlgeschlagen: \(error.localizedDescription)")
        jobs[id]?.failed = true
        Haptics.error()
    }

    // MARK: Library

    func delete(_ id: String) {
        guard let f = files.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: f.url)
        ThumbnailCache.shared.forget(f)
        files.removeAll { $0.id == id }
        save()
    }

    func delete(_ ids: Set<String>) {
        for f in files where ids.contains(f.id) {
            try? FileManager.default.removeItem(at: f.url)
            ThumbnailCache.shared.forget(f)
        }
        files.removeAll { ids.contains($0.id) }
        save()
        Haptics.warning()
    }

    /// Renames the entry and the file on disk (keeps the extension).
    func rename(_ id: String, to newName: String) {
        let clean = Self.safe(newName.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let i = files.firstIndex(where: { $0.id == id }), !clean.isEmpty else { return }
        let old = files[i]
        let ext = (old.fileName as NSString).pathExtension
        let target = Self.uniqueURL(for: clean + (ext.isEmpty ? "" : ".\(ext)"))
        if (try? FileManager.default.moveItem(at: old.url, to: target)) != nil {
            ThumbnailCache.shared.forget(old)
            files[i].fileName = target.lastPathComponent
        }
        files[i].name = clean
        save()
        Haptics.success()
    }

    func deleteAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        jobs = [:]
        for f in files {
            try? FileManager.default.removeItem(at: f.url)
            ThumbnailCache.shared.forget(f)
        }
        files = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(files) { try? data.write(to: Self.indexURL, options: .atomic) }
    }

    private func update(_ id: String, progress: Double? = nil, status: String? = nil) {
        guard var job = jobs[id] else { return }
        if let progress {
            guard progress - job.progress > 0.005 || progress >= 1 else { return }
            job.progress = progress
        }
        if let status { job.status = status }
        jobs[id] = job
    }

    // MARK: Running

    private func run(_ id: String, _ request: Request) async {
        defer { tasks[id] = nil }
        let report: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in self?.update(id, progress: min(0.98, p)) }
        }
        var lastError: Error = YTError.invalidResponse
        for (index, url) in request.candidates.enumerated() {
            if index > 0 { update(id, status: "Anderer Server wird versucht …") }
            var headers = await BrowserModel.requestHeaders(for: url, page: request.page, userAgent: request.userAgent,
                                                            isPrivate: request.isPrivate)
            for (k, v) in request.headers { headers[k] = v }
            do {
                let isHLS = url.pathExtension.lowercased() == "m3u8" || url.absoluteString.contains(".m3u8")
                var result: (file: URL, name: String)
                if isHLS {
                    update(id, status: "Stream wird geladen …")
                    let base = request.name.map { ($0 as NSString).deletingPathExtension } ?? Self.displayName(for: request.page ?? url)
                    result = try await HLSDownloader.download(url, headers: headers, name: base, progress: report)
                } else {
                    result = try await Self.fetch(url, headers: headers, name: request.name, progress: report)
                }
                try Task.checkCancellation()
                if !request.audio.isEmpty {
                    update(id, status: "Ton wird geladen …")
                    result.file = await Self.merge(video: result.file, audio: request.audio, headers: headers)
                    result.name = (result.name as NSString).deletingPathExtension + ".mp4"
                }
                try Task.checkCancellation()
                let target = Self.uniqueURL(for: result.name)
                try FileManager.default.moveItem(at: result.file, to: target)
                jobs[id] = nil
                let saved = add(target, name: result.name, source: url.absoluteString, page: request.page,
                                thumbnail: request.thumbnail, site: request.site)
                finished[id] = saved.id
                export(saved, to: request.target)
                return
            } catch is CancellationError {
                jobs[id] = nil
                return
            } catch {
                if Task.isCancelled { jobs[id] = nil; return }
                lastError = error
                DebugLog.log("⬇︎ Datei-Download fehlgeschlagen (\(url.host ?? "")): \(error.localizedDescription)")
            }
        }
        update(id, status: "Fehlgeschlagen: \(lastError.localizedDescription)")
        jobs[id]?.failed = true
        Haptics.error()
    }

    /// Adds the first loadable sound track to the video; keeps the silent video if none works.
    nonisolated private static func merge(video: URL, audio candidates: [URL], headers: [String: String]) async -> URL {
        for url in candidates {
            guard let sound = try? await fetch(url, headers: headers, name: "audio.mp4", progress: { _ in }) else { continue }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            do {
                try await YouTubeDownloader.export(video: video, audio: sound.file, to: out, fileType: .mp4, metadata: [])
                try? FileManager.default.removeItem(at: video)
                try? FileManager.default.removeItem(at: sound.file)
                return out
            } catch {
                DebugLog.log("⬇︎ Ton zusammenführen fehlgeschlagen: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: sound.file)
            }
        }
        return video
    }

    /// Plain HTTP download with progress; picks the file name from the response.
    nonisolated static func fetch(_ url: URL, headers: [String: String], name: String?,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> (file: URL, name: String) {
        var req = URLRequest(url: url, timeoutInterval: 60)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let delegate = DownloadProgress(progress)
        let (temp, response) = try await URLSession.shared.download(for: req, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: temp)
            throw YTError.http(status)
        }
        let requested = name.map { MediaKind(fileExtension: ($0 as NSString).pathExtension) } ?? .file
        // An expired media link answers with an HTML error page instead of the file.
        if requested != .file, response.mimeType?.hasPrefix("text/html") == true {
            try? FileManager.default.removeItem(at: temp)
            throw YTError.unplayable("Der Server hat keine Datei geliefert (Link abgelaufen?)")
        }
        var fileName = name ?? response.suggestedFilename ?? url.lastPathComponent
        if (fileName as NSString).pathExtension.isEmpty {
            let ext = response.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
                ?? (url.pathExtension.isEmpty ? "bin" : url.pathExtension)
            fileName += "." + ext
        }
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + safe(fileName))
        try FileManager.default.moveItem(at: temp, to: moved)
        return (moved, safe(fileName))
    }

    nonisolated static func displayName(for url: URL) -> String {
        let last = url.deletingPathExtension().lastPathComponent
        return last.isEmpty || last == "/" ? (url.host ?? "Datei") : last
    }

    nonisolated static func safe(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:#").union(.newlines).union(.controlCharacters)
        let clean = name.components(separatedBy: illegal).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let ext = (clean as NSString).pathExtension
        let base = (clean as NSString).deletingPathExtension
        let short = String(base.prefix(110)).trimmingCharacters(in: .whitespaces)
        let result = ext.isEmpty || ext.count > 5 ? String(clean.prefix(120)) : short + "." + ext
        return result.isEmpty ? "Datei" : result
    }

    nonisolated static func uniqueURL(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return candidate
    }
}

private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] p, _ in report(p.fractionCompleted) }
    }
}

/// Downloads unencrypted HLS streams (fMP4 → MP4, MPEG-TS → .ts).
enum HLSDownloader {
    static func download(_ master: URL, headers: [String: String], name: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> (file: URL, name: String) {
        let text = try await load(master, headers: headers)
        let lines = text.components(separatedBy: "\n")
        var videoPlaylist = master
        var audioPlaylist: URL?
        if text.contains("#EXT-X-STREAM-INF") {
            var best: (bw: Int, url: URL, audio: String?)?
            for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") && i + 1 < lines.count {
                guard let u = resolve(lines[i + 1], base: master) else { continue }
                let bw = Int(StreamResolver.attribute("BANDWIDTH", in: line) ?? "") ?? 0
                if best == nil || bw > best!.bw { best = (bw, u, StreamResolver.attribute("AUDIO", in: line)) }
            }
            guard let best else { throw YTError.invalidResponse }
            videoPlaylist = best.url
            if let group = best.audio {
                var fallback: URL?
                for line in lines where line.hasPrefix("#EXT-X-MEDIA") && line.contains("TYPE=AUDIO")
                    && StreamResolver.attribute("GROUP-ID", in: line) == group {
                    guard let uri = StreamResolver.attribute("URI", in: line), let u = resolve(uri, base: master) else { continue }
                    if fallback == nil { fallback = u }
                    if StreamResolver.attribute("DEFAULT", in: line) == "YES" { audioPlaylist = u; break }
                }
                audioPlaylist = audioPlaylist ?? fallback
            }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hls-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let videoShare = audioPlaylist == nil ? 1.0 : 0.85
        let video = try await fetchPlaylist(videoPlaylist, headers: headers, into: dir.appendingPathComponent("video")) {
            progress($0 * videoShare)
        }
        var audio: (URL, Bool)?
        if let audioPlaylist {
            audio = try await fetchPlaylist(audioPlaylist, headers: headers, into: dir.appendingPathComponent("audio")) {
                progress(videoShare + $0 * (1 - videoShare))
            }
        }
        let base = FileDownloads.safe(name)
        if video.fmp4 {
            let out = dir.appendingPathComponent("out.mp4")
            try await YouTubeDownloader.export(video: video.file, audio: audio?.0 ?? video.file, to: out, fileType: .mp4, metadata: [])
            return (out, base + ".mp4")
        }
        // MPEG-TS can't be remuxed on iOS without re-encoding – keep it as .ts (VLC, Infuse …).
        return (video.file, base + ".ts")
    }

    private static func fetchPlaylist(_ url: URL, headers: [String: String], into file: URL,
                                      progress: @escaping @Sendable (Double) -> Void) async throws -> (file: URL, fmp4: Bool) {
        let text = try await load(url, headers: headers)
        if let key = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("#EXT-X-KEY") }),
           StreamResolver.attribute("METHOD", in: key) != "NONE" {
            throw YTError.unplayable("Dieser Stream ist verschlüsselt (DRM) und kann nicht gespeichert werden.")
        }
        var segments: [URL] = []
        var fmp4 = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#EXT-X-MAP:"), let uri = StreamResolver.attribute("URI", in: t), let u = resolve(uri, base: url) {
                segments.append(u)
                fmp4 = true
            } else if !t.isEmpty, !t.hasPrefix("#"), let u = resolve(t, base: url) {
                segments.append(u)
                if ["m4s", "mp4", "m4a", "m4v"].contains(u.pathExtension.lowercased()) { fmp4 = true }
            }
        }
        guard !segments.isEmpty else { throw YTError.invalidResponse }
        let out = file.appendingPathExtension(fmp4 ? "mp4" : "ts")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        let batch = 6
        for start in stride(from: 0, to: segments.count, by: batch) {
            try Task.checkCancellation()
            let slice = Array(segments[start..<min(segments.count, start + batch)])
            let parts = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (i, u) in slice.enumerated() {
                    group.addTask {
                        var req = URLRequest(url: u, timeoutInterval: 30)
                        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                        let (data, response) = try await URLSession.shared.data(for: req)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                        guard (200..<300).contains(status) else { throw YTError.http(status) }
                        return (i, data)
                    }
                }
                var out: [Int: Data] = [:]
                for try await (i, d) in group { out[i] = d }
                return out
            }
            for i in 0..<slice.count { if let d = parts[i] { try handle.write(contentsOf: d) } }
            progress(Double(min(segments.count, start + batch)) / Double(segments.count))
        }
        return (out, fmp4)
    }

    private static func load(_ url: URL, headers: [String: String]) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: 30)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw YTError.http(status) }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard text.hasPrefix("#EXTM3U") else { throw YTError.unplayable("Keine gültige Stream-Playlist") }
        return text
    }

    private static func resolve(_ s: String, base: URL) -> URL? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("http") { return URL(string: t) }
        return URL(string: t, relativeTo: base)?.absoluteURL
    }
}
