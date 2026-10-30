import AVFoundation
import ImageIO
import QuickLook
import SwiftUI

/// Thumbnails and durations of library files, generated once and kept in Caches.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let memory = NSCache<NSString, UIImage>()
    private var running: [String: Task<UIImage?, Never>] = [:]
    private var durations: [String: Double] = [:]

    nonisolated static var folder: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cached(_ f: SavedFile) -> UIImage? { memory.object(forKey: f.id as NSString) }

    func image(for f: SavedFile) async -> UIImage? {
        if let image = cached(f) { return image }
        if let task = running[f.id] { return await task.value }
        let url = f.url
        let kind = f.kind
        let disk = Self.folder.appendingPathComponent(f.id + ".jpg")
        let remote = f.thumbnail.flatMap(URL.init(string:))
        let task = Task.detached(priority: .utility) { () -> UIImage? in
            if let data = try? Data(contentsOf: disk), let image = UIImage(data: data) { return image }
            var image: UIImage?
            switch kind {
            case .video: image = await Self.videoFrame(url)
            case .image: image = Self.downsample(url, maxPixels: 500)
            default: break
            }
            if image == nil, let remote, let (data, _) = try? await URLSession.shared.data(from: remote) {
                image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 500, height: 500))
            }
            if let image, let jpg = image.jpegData(compressionQuality: 0.82) { try? jpg.write(to: disk, options: .atomic) }
            return image
        }
        running[f.id] = task
        let image = await task.value
        running[f.id] = nil
        if let image { memory.setObject(image, forKey: f.id as NSString) }
        return image
    }

    func duration(for f: SavedFile) async -> Double? {
        if let d = durations[f.id] { return d }
        guard f.kind == .video || f.kind == .audio else { return nil }
        let url = f.url
        let seconds = await Task.detached(priority: .utility) { () -> Double? in
            guard let d = try? await AVURLAsset(url: url).load(.duration), d.isNumeric else { return nil }
            return d.seconds
        }.value
        if let seconds { durations[f.id] = seconds }
        return seconds
    }

    func forget(_ f: SavedFile) {
        memory.removeObject(forKey: f.id as NSString)
        durations[f.id] = nil
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(f.id + ".jpg"))
    }

    nonisolated private static func videoFrame(_ url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        for second in [1.0, 0.0] {
            if let frame = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)) {
                return UIImage(cgImage: frame.image)
            }
        }
        return nil
    }

    nonisolated private static func downsample(_ url: URL, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

// MARK: - Media library

/// Everything downloaded through the browser and the assistant: videos, songs, pictures, files.
struct MediaLibraryView: View {
    @ObservedObject private var files = FileDownloads.shared
    @AppStorage("libraryGrid") private var grid = true
    @AppStorage("librarySort") private var sort: Sort = .newest
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var playing: NativeMediaItem?
    @State private var previewURL: URL?
    @State private var renaming: SavedFile?
    @State private var newName = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all, videos, audio, images, files
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Alle"
            case .videos: return "Videos"
            case .audio: return "Audio"
            case .images: return "Bilder"
            case .files: return "Dateien"
            }
        }
        var icon: String {
            switch self {
            case .all: return "square.stack"
            case .videos: return "film"
            case .audio: return "waveform"
            case .images: return "photo"
            case .files: return "doc"
            }
        }
        func matches(_ f: SavedFile) -> Bool {
            switch self {
            case .all: return true
            case .videos: return f.kind == .video || f.kind == .stream
            case .audio: return f.kind == .audio
            case .images: return f.kind == .image
            case .files: return f.kind == .file
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case newest, oldest, name, size
        var id: String { rawValue }
        var title: String {
            switch self {
            case .newest: return "Neueste zuerst"
            case .oldest: return "Älteste zuerst"
            case .name: return "Name"
            case .size: return "Größe"
            }
        }
    }

    private var shown: [SavedFile] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = files.files.filter { filter.matches($0) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)
            || ($0.host?.localizedCaseInsensitiveContains(q) ?? false) || ($0.site?.localizedCaseInsensitiveContains(q) ?? false)) }
        switch sort {
        case .newest: return list.sorted { $0.date > $1.date }
        case .oldest: return list.sorted { $0.date < $1.date }
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: return list.sorted { $0.size > $1.size }
        }
    }

    private var quickLookURLs: [URL] {
        shown.filter { $0.kind == .image || $0.kind == .file }.map(\.url)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summary
                filterChips
                if !files.activeJobs.isEmpty { runningJobs }
                if shown.isEmpty {
                    empty
                } else if grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 106), spacing: 4)], spacing: 4) {
                        ForEach(shown) { f in
                            MediaTile(file: f, selecting: selecting, selected: selection.contains(f.id))
                                .onTapGesture { tap(f) }
                                .contextMenu { menu(f) } preview: { MediaTilePreview(file: f) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(shown) { f in
                            MediaRowView(file: f, selecting: selecting, selected: selection.contains(f.id))
                                .onTapGesture { tap(f) }
                                .contextMenu { menu(f) }
                        }
                    }
                }
                if !files.files.isEmpty {
                    Text("Alle Dateien liegen auch in der Dateien-App unter „Auf meinem iPhone › Nova › Downloads“.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, selecting ? 90 : 24)
            .animation(.snappy, value: filter)
            .animation(.snappy, value: grid)
        }
        .searchable(text: $search, prompt: "Mediathek durchsuchen")
        .navigationTitle("Mediathek")
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
        .quickLookPreview($previewURL, in: quickLookURLs)
        .sheet(item: $playing) { NativeMediaSheet(item: $0) }
        .alert("Umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Sichern") {
                if let f = renaming { files.rename(f.id, to: newName) }
                renaming = nil
            }
            Button("Abbrechen", role: .cancel) { renaming = nil }
        }
    }

    // MARK: Parts

    private var summary: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(LinearGradient(colors: [.accentColor, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(files.files.isEmpty ? "Noch leer" : "\(files.files.count) Dateien").font(.headline)
                Text(counts).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                if let url = UIPasteboard.general.url ?? UIPasteboard.general.string.flatMap({ LinkRouter.firstURL(in: $0) }) {
                    LinkRouter.shared.download(url)
                } else {
                    files.onToast?("Kein Link in der Zwischenablage")
                    Haptics.warning()
                }
            } label: {
                Label("Link laden", systemImage: "link.badge.plus").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glassProminent)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var counts: String {
        let v = files.files.filter { $0.kind == .video }.count
        let a = files.files.filter { $0.kind == .audio }.count
        let i = files.files.filter { $0.kind == .image }.count
        let parts = [v > 0 ? "\(v) Videos" : nil, a > 0 ? "\(a) Audio" : nil, i > 0 ? "\(i) Bilder" : nil].compactMap { $0 }
        let size = ByteCountFormatter.string(fromByteCount: files.totalSize, countStyle: .file)
        return files.files.isEmpty ? "Teile einen Link mit Nova oder füge ihn ein." : (parts + [size]).joined(separator: " · ")
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases) { f in
                        Chip(title: f.title, systemImage: f.icon, selected: filter == f) { filter = f }
                    }
                }
            }
        }
        .scrollClipDisabled()
    }

    private var runningJobs: some View {
        VStack(spacing: 8) {
            ForEach(files.activeJobs) { job in
                HStack(spacing: 12) {
                    if job.failed {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 28)
                    } else {
                        ProgressRing(value: job.progress).frame(width: 28, height: 28)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(job.failed ? job.status : "\(job.status) \(Int(job.progress * 100)) %")
                            .font(.caption)
                            .foregroundStyle(job.failed ? Color.orange : Color.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if job.failed, job.request != nil {
                        Button { files.retry(job.id) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                    }
                    Button { files.cancel(job.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(search.isEmpty ? "Keine \(filter == .all ? "Downloads" : filter.title)" : "Nichts gefunden",
                  systemImage: search.isEmpty ? filter.icon : "magnifyingglass")
        } description: {
            Text(search.isEmpty ? "Teile in TikTok, Instagram & Co. einen Link mit Nova – oder tippe im Browser auf ⬇︎ an einem Video." : "")
        }
        .padding(.top, 30)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") {
                    selecting = false
                    selection = []
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == shown.count ? "Keine" : "Alle") {
                    selection = selection.count == shown.count ? [] : Set(shown.map(\.id))
                }
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Auswählen", systemImage: "checkmark.circle") {
                        selecting = true
                        Haptics.selection()
                    }
                    Picker(selection: $grid) {
                        Label("Raster", systemImage: "square.grid.3x3").tag(true)
                        Label("Liste", systemImage: "list.bullet").tag(false)
                    } label: { Label("Ansicht", systemImage: "eye") }
                    Picker(selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.title).tag($0) }
                    } label: { Label("Sortieren", systemImage: "arrow.up.arrow.down") }
                    if !files.files.isEmpty {
                        Divider()
                        Button("Alle in Dateien sichern", systemImage: "folder") { FileSaver.saveToFiles(shown.map(\.url)) }
                        Button("Alle löschen", systemImage: "trash", role: .destructive) {
                            ConfirmCenter.shared.ask("Alle \(files.files.count) Dateien löschen?") { files.deleteAll() }
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
            }
        }
    }

    private var selectionBar: some View {
        let chosen = files.files.filter { selection.contains($0.id) }
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ShareLink(items: chosen.map(\.url)) { barLabel("Teilen", "square.and.arrow.up") }
                    .disabled(chosen.isEmpty)
                Button {
                    for f in chosen where f.kind == .video || f.kind == .image { FileSaver.saveToPhotos(f.url) { files.onToast?($0) } }
                } label: { barLabel("Fotos", "photo.on.rectangle") }
                .disabled(!chosen.contains { $0.kind == .video || $0.kind == .image })
                Button { FileSaver.saveToFiles(chosen.map(\.url)) } label: { barLabel("Dateien", "folder") }
                    .disabled(chosen.isEmpty)
                Button(role: .destructive) {
                    ConfirmCenter.shared.ask("\(chosen.count) Dateien löschen?") {
                        files.delete(Set(chosen.map(\.id)))
                        selection = []
                    }
                } label: { barLabel("Löschen", "trash").foregroundStyle(.red) }
                .disabled(chosen.isEmpty)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func barLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.headline)
            Text(title).font(.caption2.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    @ViewBuilder private func menu(_ f: SavedFile) -> some View {
        if f.kind.isPlayable {
            Button("Abspielen", systemImage: "play.fill") { tap(f) }
        }
        ShareLink(item: f.url) { Label("Teilen", systemImage: "square.and.arrow.up") }
        if f.kind == .video || f.kind == .image {
            Button("In Fotos sichern", systemImage: "photo.on.rectangle") { FileSaver.saveToPhotos(f.url) { files.onToast?($0) } }
        }
        Button("In Dateien sichern", systemImage: "folder") { FileSaver.saveToFiles([f.url]) }
        Button("Umbenennen", systemImage: "pencil") {
            newName = f.name
            renaming = f
        }
        if let page = f.page.flatMap(URL.init(string:)) {
            Button("Quelle öffnen", systemImage: "safari") { BrowserModel.shared.open(page) }
        }
        Button("Quelllink kopieren", systemImage: "link") {
            UIPasteboard.general.string = f.page ?? f.source
            Haptics.success()
        }
        Divider()
        Button("Löschen", systemImage: "trash", role: .destructive) {
            ConfirmCenter.shared.ask("„\(f.name)“ löschen?", message: "Die Datei wird vom Gerät entfernt.") { files.delete(f.id) }
        }
    }

    private func tap(_ f: SavedFile) {
        if selecting {
            Haptics.selection()
            if selection.contains(f.id) { selection.remove(f.id) } else { selection.insert(f.id) }
            return
        }
        if f.kind.isPlayable {
            playing = NativeMediaItem(url: f.url, kind: f.kind, title: f.name, poster: f.thumbnail.flatMap(URL.init(string:)), file: f)
        } else {
            previewURL = f.url
        }
    }
}

// MARK: - Tiles

struct MediaThumb: View {
    let file: SavedFile
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image = image ?? ThumbnailCache.shared.cached(file) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 4) {
                    Image(systemName: file.kind.icon).font(.title2.weight(.semibold))
                    if file.kind == .file { Text(file.fileExtension).font(.caption2.weight(.heavy)) }
                }
                .foregroundStyle(.white.opacity(0.92))
            }
        }
        .task(id: file.id + file.fileName) { image = await ThumbnailCache.shared.image(for: file) }
    }

    private var gradient: [Color] {
        switch file.kind {
        case .video, .stream: return [.indigo, .purple]
        case .audio: return [.pink, .orange]
        case .image: return [.teal, .blue]
        case .file: return [.gray, .secondary]
        }
    }
}

private struct DurationBadge: View {
    let file: SavedFile
    @State private var seconds: Double?

    var body: some View {
        Group {
            if let seconds, seconds > 0 {
                Text(Self.format(seconds))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: .capsule)
            }
        }
        .task(id: file.id) { seconds = await ThumbnailCache.shared.duration(for: file) }
    }

    static func format(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

private struct MediaTile: View {
    let file: SavedFile
    let selecting: Bool
    let selected: Bool

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { MediaThumb(file: file) }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if file.kind != .image { Image(systemName: file.kind == .audio ? "music.note" : file.kind == .file ? "doc.fill" : "play.fill") }
                    Spacer(minLength: 0)
                    DurationBadge(file: file)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? Color.accentColor : Color.black.opacity(0.25))
                        .padding(6)
                }
            }
            .overlay { if selected { Color.white.opacity(0.18) } }
            .contentShape(.rect)
    }
}

private struct MediaTilePreview: View {
    let file: SavedFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MediaThumb(file: file).frame(width: 300, height: 300).clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([file.site ?? file.host, file.kind.label, ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(width: 300)
    }
}

private struct MediaRowView: View {
    let file: SavedFile
    let selecting: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            MediaThumb(file: file)
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(file.kind == .file ? file.fileExtension : file.kind.label)
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    if let source = file.site ?? file.host { Text(source) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(file.date, format: .relative(presentation: .numeric)).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .glassEffect(selected ? .regular.tint(.accentColor.opacity(0.2)) : .regular, in: .rect(cornerRadius: 18))
        .contentShape(.rect)
    }
}
