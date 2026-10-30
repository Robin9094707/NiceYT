import Foundation
import SwiftUI

struct DownloadedTrack: Identifiable, Codable, Hashable, Sendable {
    var id: String { track.id }
    var track: DZTrack
    var fileName: String
    var quality: DZQuality
    var size: Int64
    var date: Date

    var url: URL { DownloadStore.folder.appendingPathComponent(fileName) }
}

/// Downloads songs from Deezer, decrypts and tags them and keeps them in
/// Documents/Musik – visible in the Files app and shareable to any other app.
@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    @Published private(set) var items: [DownloadedTrack] = []
    /// Progress (0…1) of running downloads by track id.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var failed: Set<String> = []
    /// Songs waiting for or in download (for the list in the downloads view).
    @Published private(set) var active: [String: DZTrack] = [:]

    private var pending: [DZTrack] = []
    private var running = 0
    private let maxParallel = 3
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.httpAdditionalHeaders = ["User-Agent": Deezer.userAgent]
        return URLSession(configuration: config)
    }()

    nonisolated static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Musik", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("downloads.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let list = try? JSONDecoder().decode([DownloadedTrack].self, from: data) {
            items = list.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    func file(for trackId: String) -> DownloadedTrack? { items.first { $0.id == trackId } }
    func isDownloaded(_ trackId: String) -> Bool { items.contains { $0.id == trackId } }
    func isQueued(_ trackId: String) -> Bool { progress[trackId] != nil }

    // MARK: Downloading

    func download(_ track: DZTrack) {
        guard !isDownloaded(track.id), progress[track.id] == nil else { return }
        failed.remove(track.id)
        progress[track.id] = 0
        active[track.id] = track
        pending.append(track)
        Haptics.tap()
        pump()
    }

    /// Downloads every track of a list that isn't on the device yet.
    func download(all tracks: [DZTrack]) {
        let missing = tracks.filter { !isDownloaded($0.id) && progress[$0.id] == nil }
        guard !missing.isEmpty else { return }
        for t in missing {
            failed.remove(t.id)
            progress[t.id] = 0
            active[t.id] = t
            pending.append(t)
        }
        Haptics.success()
        MusicPlayer.shared.toast("\(missing.count) Songs werden heruntergeladen")
        pump()
    }

    func cancel(_ trackId: String) {
        pending.removeAll { $0.id == trackId }
        progress[trackId] = nil
        active[trackId] = nil
    }

    private func pump() {
        while running < maxParallel, !pending.isEmpty {
            let track = pending.removeFirst()
            running += 1
            Task {
                await run(track)
                running -= 1
                pump()
            }
        }
    }

    private func run(_ track: DZTrack) async {
        defer { if progress[track.id] == nil { active[track.id] = nil } }
        do {
            let quality = AppSettings.shared.musicDownloadQuality
            let media = try await Deezer.shared.mediaURL(for: track, quality: quality)
            guard progress[track.id] != nil else { return } // cancelled meanwhile
            let delegate = ProgressDelegate { [weak self] value in
                Task { @MainActor in
                    guard let self, let old = self.progress[track.id], value * 0.95 - old > 0.01 else { return }
                    self.progress[track.id] = value * 0.95
                }
            }
            var request = URLRequest(url: media.url)
            request.setValue(Deezer.userAgent, forHTTPHeaderField: "User-Agent")
            let (temp, response) = try await session.download(for: request, delegate: delegate)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw DeezerError.http(status) }
            let cover = await coverData(for: track)
            let fileName = Self.fileName(for: track, quality: media.quality)
            let target = Self.folder.appendingPathComponent(fileName)
            let size = try await Task.detached(priority: .utility) {
                try Self.decryptAndTag(temp, to: target, trackId: media.track.id, quality: media.quality,
                                       tags: AudioTagger.Tags(track, cover: cover))
            }.value
            guard progress[track.id] != nil else {
                try? FileManager.default.removeItem(at: target)
                return
            }
            progress[track.id] = nil
            items.removeAll { $0.id == track.id }
            items.insert(DownloadedTrack(track: track, fileName: fileName, quality: media.quality, size: size, date: Date()), at: 0)
            save()
            if pending.isEmpty, running <= 1 { Haptics.success() }
        } catch {
            progress[track.id] = nil
            failed.insert(track.id)
            Haptics.error()
            MusicPlayer.shared.toast("„\(track.title)“: \(error.localizedDescription)")
        }
    }

    private func coverData(for track: DZTrack) async -> Data? {
        guard let url = track.coverURL(1000) else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }

    /// Streams the encrypted file through the decryptor and writes the tagged result.
    nonisolated private static func decryptAndTag(_ source: URL, to target: URL, trackId: String,
                                                  quality: DZQuality, tags: AudioTagger.Tags) throws -> Int64 {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let decryptor = DeezerDecryptor(trackId: trackId)
        var plain = Data()
        var buffer = Data()
        var offset: Int64 = 0
        while true {
            let block = try input.read(upToCount: DeezerDecryptor.chunkSize * 3 * 64) ?? Data()
            buffer.append(block)
            let done = block.isEmpty
            plain.append(decryptor.process(&buffer, at: &offset, final: done))
            if done { break }
        }
        // MP4-based formats can carry leading zero padding (deemix strips it too).
        if quality != .flac, plain.first == 0 {
            if let first = plain.firstIndex(where: { $0 != 0 }) { plain = Data(plain[first...]) }
        }
        let tagged = AudioTagger.tag(plain, quality: quality, tags: tags)
        try? FileManager.default.removeItem(at: target)
        try tagged.write(to: target, options: .atomic)
        try? FileManager.default.removeItem(at: source)
        return Int64(tagged.count)
    }

    nonisolated static func fileName(for track: DZTrack, quality: DZQuality) -> String {
        let raw = "\(track.artist) - \(track.fullTitle)"
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines).union(.controlCharacters)
        let clean = raw.components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let base = String(clean.prefix(120))
        return "\(base.isEmpty ? track.id : base) [\(track.id)].\(quality.fileExtension)"
    }

    // MARK: Managing

    func delete(_ trackId: String) {
        guard let item = file(for: trackId) else { return }
        try? FileManager.default.removeItem(at: item.url)
        items.removeAll { $0.id == trackId }
        save()
        Haptics.tap()
    }

    func deleteAll() {
        for item in items { try? FileManager.default.removeItem(at: item.url) }
        items = []
        save()
        Haptics.warning()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.indexURL, options: .atomic) }
    }
}

/// Reports the progress of one URLSession download.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [onProgress] p, _ in
            onProgress(p.fractionCompleted)
        }
    }
}
