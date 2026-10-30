import AVFoundation
import SwiftUI

struct DownloadedVideo: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var channel: String
    var channelId: String?
    var fileName: String
    var label: String
    var size: Int64
    var date: Date
    var duration: Int

    var url: URL { YouTubeDownloads.videoFolder.appendingPathComponent(fileName) }
    var video: Video {
        var v = Video(id: id, title: title, channelName: channel, channelId: channelId)
        if duration > 0 { v.duration = String(format: "%d:%02d", duration / 60, duration % 60) }
        return v
    }
}

/// YouTube downloads: videos (Documents/Videos, playable offline in the player) and
/// audio (into the music downloads, with a square cover).
@MainActor
final class YouTubeDownloads: ObservableObject {
    static let shared = YouTubeDownloads()

    struct Job: Identifiable {
        let id: String
        let video: Video
        let option: YTDownloadOption
        var progress: Double = 0
        var status = "Wird vorbereitet …"
        var failed = false
    }

    @Published private(set) var videos: [DownloadedVideo] = []
    @Published private(set) var jobs: [String: Job] = [:]
    /// Video whose download sheet should be shown.
    @Published var request: Video?
    /// Where finished downloads go additionally ("app", "photos", "files").
    @AppStorage("ytSaveTarget") var saveTarget = "app"
    /// Shows a short message (set by the root view).
    var onToast: ((String) -> Void)?

    private var tasks: [String: Task<Void, Never>] = [:]

    nonisolated static var videoFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("videoDownloads.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let list = try? JSONDecoder().decode([DownloadedVideo].self, from: data) {
            videos = list.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
    }

    var totalSize: Int64 { videos.reduce(0) { $0 + $1.size } }
    var activeJobs: [Job] { jobs.values.sorted { $0.id < $1.id } }

    func file(for videoId: String) -> DownloadedVideo? { videos.first { $0.id == videoId } }
    func jobs(for videoId: String) -> [Job] { activeJobs.filter { $0.video.id == videoId } }

    /// Ready-to-play local copy for the player.
    func offlineStream(for videoId: String) -> PreparedStream? {
        guard let file = file(for: videoId) else { return nil }
        var info = StreamInfo(videoId: videoId, hlsURL: file.url, title: file.title, author: file.channel,
                              channelId: file.channelId, viewCount: nil, lengthSeconds: file.duration,
                              description: "", isLive: false, captions: [])
        info.isHLS = false
        info.source = "Offline"
        return PreparedStream(info: info, asset: AVURLAsset(url: file.url), label: "Offline (\(file.label))", proxy: nil)
    }

    // MARK: Jobs

    func start(_ video: Video, option: YTDownloadOption, sources: YouTubeDownloader.Sources? = nil) {
        let id = video.id + "-" + option.id
        guard jobs[id] == nil || jobs[id]?.failed == true else { return }
        jobs[id] = Job(id: id, video: video, option: option)
        Haptics.success()
        onToast?(option.kind == .audio ? "Audio-Download gestartet" : "Download gestartet (\(option.label))")
        tasks[id] = Task { await run(id, video: video, option: option, sources: sources) }
    }

    func cancel(_ jobId: String) {
        tasks[jobId]?.cancel()
        tasks[jobId] = nil
        jobs[jobId] = nil
        Haptics.tap()
    }

    func delete(_ videoId: String) {
        guard let item = file(for: videoId) else { return }
        try? FileManager.default.removeItem(at: item.url)
        videos.removeAll { $0.id == videoId }
        save()
        Haptics.tap()
    }

    func deleteAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        jobs = [:]
        for item in videos { try? FileManager.default.removeItem(at: item.url) }
        videos = []
        save()
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

    private func run(_ id: String, video: Video, option: YTDownloadOption, sources: YouTubeDownloader.Sources?) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yt-" + UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            tasks[id] = nil
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let src: YouTubeDownloader.Sources
            if let sources { src = sources } else { src = try await YouTubeDownloader.sources(video.id) }
            update(id, status: option.kind == .audio ? "Audio wird geladen …" : "Video wird geladen …")
            let report: @Sendable (Double) -> Void = { [weak self] p in
                Task { @MainActor in self?.update(id, progress: min(0.97, p)) }
            }

            var videoFile: URL?
            var audioFile: URL
            if let audio = src.audio, !src.videos.isEmpty {
                let v = option.kind == .video ? Self.pick(src.videos, for: option) : nil
                let total = Double((v?.format.contentLength ?? 0) + (audio.format.contentLength ?? 0))
                audioFile = dir.appendingPathComponent("audio.m4a")
                let audioShare = total > 0 ? Double(audio.format.contentLength ?? 0) / total : (v == nil ? 1 : 0.15)
                let audioExpected = Double(audio.format.contentLength ?? 0)
                try await YouTubeDownloader.fetch(audio.url, to: audioFile, userAgent: src.userAgent,
                                                  expected: audio.format.contentLength) { bytes in
                    report(audioExpected > 0 ? Double(bytes) / audioExpected * audioShare : 0)
                }
                if let v {
                    let file = dir.appendingPathComponent("video.mp4")
                    let videoExpected = Double(v.format.contentLength ?? 0)
                    try await YouTubeDownloader.fetch(v.url, to: file, userAgent: src.userAgent,
                                                      expected: v.format.contentLength) { bytes in
                        report(audioShare + (videoExpected > 0 ? Double(bytes) / videoExpected * (1 - audioShare) : 0))
                    }
                    videoFile = file
                }
            } else {
                (videoFile, audioFile) = try await YouTubeDownloader.fetchHLS(
                    src, height: option.kind == .video ? option.height : nil, dir: dir, progress: report)
            }
            try Task.checkCancellation()
            update(id, status: "Wird gespeichert …")

            let meta = src.meta
            let title = meta.title.isEmpty ? video.title : meta.title
            let channel = meta.author.isEmpty ? (video.channelName ?? "YouTube") : meta.author
            if option.kind == .audio {
                let song = YouTubeDownloader.songInfo(title: title, channel: channel)
                let cover = await YouTubeDownloader.squareCover(video.id)
                let fileName = Self.safeName("\(song.artist) - \(song.title)") + " [yt-\(video.id)].m4a"
                let out = DownloadStore.folder.appendingPathComponent(fileName)
                try await YouTubeDownloader.export(video: nil, audio: audioFile, to: out, fileType: .m4a,
                                                   metadata: YouTubeDownloader.metadata(title: song.title, artist: song.artist,
                                                                                        album: "YouTube", cover: cover))
                var track = DZTrack(youtube: video, title: song.title, artist: song.artist)
                track.duration = meta.lengthSeconds
                DownloadStore.shared.addExternal(track, fileName: fileName, size: Self.size(of: out))
                onToast?("„\(song.title)“ ist jetzt in Musik → Downloads")
                if saveTarget != "app" { FileSaver.saveToFiles([out]) }
            } else {
                let thumb = try? await URLSession.shared.data(from: video.maxThumbnail).0
                let label = option.label
                let fileName = Self.safeName(title) + " [\(label)] [\(video.id)].mp4"
                let out = Self.videoFolder.appendingPathComponent(fileName)
                try await YouTubeDownloader.export(video: videoFile, audio: audioFile, to: out, fileType: .mp4,
                                                   metadata: YouTubeDownloader.metadata(title: title, artist: channel, album: nil,
                                                                                        cover: thumb.flatMap { UIImage(data: $0) != nil ? $0 : nil }))
                if let old = file(for: video.id), old.fileName != fileName { try? FileManager.default.removeItem(at: old.url) }
                videos.removeAll { $0.id == video.id }
                videos.insert(DownloadedVideo(id: video.id, title: title, channel: channel, channelId: meta.channelId ?? video.channelId,
                                              fileName: fileName, label: label, size: Self.size(of: out), date: Date(),
                                              duration: meta.lengthSeconds), at: 0)
                save()
                onToast?("„\(title)“ gespeichert")
                switch saveTarget {
                case "photos": FileSaver.saveToPhotos(out) { [weak self] text in self?.onToast?(text) }
                case "files": FileSaver.saveToFiles([out])
                default: break
                }
            }
            jobs[id] = nil
            Haptics.success()
        } catch is CancellationError {
            jobs[id] = nil
        } catch {
            if Task.isCancelled { jobs[id] = nil; return }
            DebugLog.log("⬇︎ Download fehlgeschlagen: \(error.localizedDescription)")
            update(id, status: "Fehlgeschlagen: \(error.localizedDescription)")
            jobs[id]?.failed = true
            Haptics.error()
            onToast?("Download fehlgeschlagen")
        }
    }

    private static func pick(_ videos: [(format: Parser.RawFormat, url: URL)], for option: YTDownloadOption) -> (format: Parser.RawFormat, url: URL)? {
        let wants60 = option.fps > 30
        return videos.filter { $0.format.height == option.height && ($0.format.fps > 30) == wants60 }.first
            ?? videos.filter { $0.format.height == option.height }.first
            ?? videos.filter { $0.format.height <= option.height }.max { $0.format.height < $1.format.height }
            ?? videos.min { $0.format.height < $1.format.height }
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func safeName(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines).union(.controlCharacters)
        let clean = raw.components(separatedBy: illegal).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(clean.prefix(110))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(videos) { try? data.write(to: Self.indexURL, options: .atomic) }
    }
}

// MARK: - Views

/// Choose audio-only or a video quality for a YouTube video.
struct YouTubeDownloadSheet: View {
    @EnvironmentObject private var downloads: YouTubeDownloads
    @Environment(\.dismiss) private var dismiss
    let video: Video
    @State private var sources: YouTubeDownloader.Sources?
    @State private var options: [YTDownloadOption] = []
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Thumbnail(video: video, cornerRadius: 10).frame(width: 120)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sources?.meta.title ?? video.title).font(.subheadline.weight(.semibold)).lineLimit(3)
                            if let c = sources?.meta.author ?? video.channelName {
                                Text(c).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                let running = downloads.jobs(for: video.id)
                if !running.isEmpty {
                    Section("Läuft") {
                        ForEach(running) { job in JobRow(job: job) }
                    }
                }
                if isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Formate werden gesucht …").foregroundStyle(.secondary)
                        }
                    }
                } else if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Button("Erneut versuchen", systemImage: "arrow.clockwise") { Task { await load() } }
                    }
                } else {
                    if let audio = options.first(where: { $0.kind == .audio }) {
                        Section {
                            optionRow(audio, icon: "music.note")
                        } header: {
                            Text("Audio")
                        } footer: {
                            Text("Als M4A mit quadratischem Cover, Titel und Interpret. Landet in Musik → Downloads und kann in jede App geteilt werden.")
                        }
                    }
                    Section {
                        Picker("Zusätzlich sichern", selection: $downloads.saveTarget) {
                            Text("Nur in der App").tag("app")
                            Text("In Fotos (Videos)").tag("photos")
                            Text("In Dateien").tag("files")
                        }
                    } footer: {
                        Text("Nach dem Download wird die Datei zusätzlich in Fotos oder einen Ordner deiner Wahl in der Dateien-App gesichert. Audio geht bei „Fotos“ in die Dateien-App.")
                    }
                    let videoOptions = options.filter { $0.kind == .video }
                    if !videoOptions.isEmpty {
                        Section {
                            ForEach(videoOptions) { optionRow($0, icon: "film") }
                        } header: {
                            Text("Video")
                        } footer: {
                            Text("Als MP4 mit Originalton. Gespeicherte Videos spielen ohne Internet und liegen in der Dateien-App unter NicePlay › Videos.")
                        }
                    }
                }
            }
            .navigationTitle("Herunterladen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark") { dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func optionRow(_ option: YTDownloadOption, icon: String) -> some View {
        Button {
            downloads.start(video, option: option, sources: sources)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.body.weight(.semibold))
                    Text(option.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            let s = try await YouTubeDownloader.sources(video.id)
            sources = s
            options = s.options
            if options.isEmpty { error = "Für dieses Video gibt es keine herunterladbaren Formate." }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

struct JobRow: View {
    @EnvironmentObject private var downloads: YouTubeDownloads
    let job: YouTubeDownloads.Job

    var body: some View {
        HStack(spacing: 12) {
            ProgressRing(value: job.failed ? 0 : job.progress).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.video.title.isEmpty ? job.option.label : job.video.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(job.option.label) · \(job.failed ? job.status : job.status + " \(Int(job.progress * 100)) %")")
                    .font(.caption)
                    .foregroundStyle(job.failed ? Color.orange : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if job.failed {
                Button("Erneut") { downloads.start(job.video, option: job.option) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            Button { downloads.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Abbrechen")
        }
    }
}

/// "Downloads" in the library: saved videos plus running YouTube downloads.
struct DownloadedVideosView: View {
    @EnvironmentObject private var downloads: YouTubeDownloads
    @EnvironmentObject private var player: PlayerModel
    @State private var confirmDelete: DownloadedVideo?

    var body: some View {
        List {
            if !downloads.activeJobs.isEmpty {
                Section("Läuft") {
                    ForEach(downloads.activeJobs) { JobRow(job: $0) }
                }
            }
            if downloads.videos.isEmpty && downloads.activeJobs.isEmpty {
                ContentUnavailableView("Keine Downloads",
                                       systemImage: "arrow.down.circle",
                                       description: Text("Halte ein Video gedrückt oder tippe im Player auf „Download“, um es als Video oder nur als Audio zu speichern."))
                    .listRowBackground(Color.clear)
            }
            if !downloads.videos.isEmpty {
                Section {
                    ForEach(downloads.videos) { item in
                        Button { player.play(item.video, queue: downloads.videos.map(\.video)) } label: {
                            HStack(spacing: 12) {
                                Thumbnail(video: item.video, cornerRadius: 10).frame(width: 128)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text(item.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text("\(item.label) · \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Löschen", systemImage: "trash", role: .destructive) { confirmDelete(item) }
                        }
                        .swipeActions(edge: .leading) {
                            ShareLink(item: item.url) { Label("Teilen", systemImage: "square.and.arrow.up") }.tint(.blue)
                        }
                        .contextMenu {
                            Button("Abspielen", systemImage: "play.fill") { player.play(item.video) }
                            ShareLink(item: item.url) { Label("Datei teilen", systemImage: "square.and.arrow.up") }
                            Button("In Fotos sichern", systemImage: "photo.on.rectangle") {
                                FileSaver.saveToPhotos(item.url) { player.showToast($0) }
                            }
                            Button("In Dateien sichern", systemImage: "folder") { FileSaver.saveToFiles([item.url]) }
                            Button("Löschen", systemImage: "trash", role: .destructive) { confirmDelete(item) }
                        }
                    }
                } header: {
                    Text("\(downloads.videos.count) Videos · \(ByteCountFormatter.string(fromByteCount: downloads.totalSize, countStyle: .file))")
                } footer: {
                    Text("Gespeicherte Videos spielen ohne Internet. Audio-Downloads findest du unter Musik → Downloads.")
                }
            }
        }
        .navigationTitle("Downloads")
    }

    private func confirmDelete(_ item: DownloadedVideo) {
        ConfirmCenter.shared.ask("„\(item.title)“ löschen?", message: "Das Video wird vom Gerät entfernt.") {
            downloads.delete(item.id)
        }
    }
}

extension View {
    /// Presents the YouTube download sheet while `active` (root vs. player cover).
    func youTubeDownloadSheet(active: Bool) -> some View {
        modifier(YouTubeDownloadSheetModifier(active: active))
    }
}

private struct YouTubeDownloadSheetModifier: ViewModifier {
    @ObservedObject private var downloads = YouTubeDownloads.shared
    let active: Bool

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { active ? downloads.request : nil },
                                    set: { downloads.request = $0 })) { video in
            YouTubeDownloadSheet(video: video).environmentObject(downloads)
        }
    }
}
