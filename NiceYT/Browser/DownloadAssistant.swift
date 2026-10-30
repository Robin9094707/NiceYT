import SwiftUI

/// Paste or share a link → the assistant finds the files behind it and downloads them,
/// without opening the browser.
@MainActor
final class DownloadAssistant: ObservableObject {
    static let shared = DownloadAssistant()

    struct Request: Identifiable {
        let id = UUID()
        let url: URL
        var pageMedia: [MediaItem] = []
        var page: URL?
        var userAgent: String
        var isPrivate: Bool
        /// Starts the recommended option right away (shared and pasted links).
        var autoStart: Bool
    }

    @Published var request: Request?

    func start(_ url: URL, pageMedia: [MediaItem] = [], page: URL? = nil, userAgent: String = UserAgents.mobile,
               isPrivate: Bool = false, autoStart: Bool? = nil) {
        if let id = YouTubeLink.videoId(from: url.absoluteString) {
            YouTubeDownloads.shared.request = Video(id: id, title: "")
            return
        }
        request = Request(url: url, pageMedia: pageMedia, page: page, userAgent: userAgent, isPrivate: isPrivate,
                          autoStart: autoStart ?? BrowserLibrary.shared.quickDownload)
    }
}

extension View {
    /// Shows the download assistant while `active` (the topmost screen).
    func downloadAssistantSheet(active: Bool) -> some View {
        modifier(DownloadAssistantPresenter(active: active))
    }
}

private struct DownloadAssistantPresenter: ViewModifier {
    @ObservedObject private var assistant = DownloadAssistant.shared
    let active: Bool

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { active ? assistant.request : nil }, set: { assistant.request = $0 })) { request in
            DownloadAssistantSheet(request: request)
        }
    }
}

// MARK: - Sheet

struct DownloadAssistantSheet: View {
    let request: DownloadAssistant.Request
    @ObservedObject private var files = FileDownloads.shared
    @ObservedObject private var library = BrowserLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var media: ExtractedMedia?
    @State private var error: String?
    @State private var selected: Set<String> = []
    @State private var jobs: [String] = []
    @State private var preview: NativeMediaItem?
    @State private var openFile: SavedFile?

    private var isLoading: Bool { media == nil && error == nil }
    private var site: MediaSite { media?.site ?? MediaSite(request.url) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if !jobs.isEmpty {
                        progressCard
                    } else if let media {
                        optionsList(media)
                        targetPicker
                    } else if let error {
                        failure(error)
                    } else {
                        loadingRows
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) { bottomButton }
            .navigationTitle("Download-Assistent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Im Browser öffnen", systemImage: "safari") { openInBrowser() }
                        Button("Link kopieren", systemImage: "link") {
                            UIPasteboard.general.url = request.url
                            Haptics.success()
                        }
                        ShareLink(item: request.url) { Label("Link teilen", systemImage: "square.and.arrow.up") }
                        Button("Erneut analysieren", systemImage: "arrow.clockwise") { Task { await load() } }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            .sheet(item: $preview) { NativeMediaSheet(item: $0) }
            .sheet(item: $openFile) { f in
                NativeMediaSheet(item: NativeMediaItem(url: f.url, kind: f.kind, title: f.name,
                                                       poster: f.thumbnail.flatMap(URL.init(string:)), file: f))
            }
        }
        .presentationDetents([.fraction(0.72), .large])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                if let thumb = media?.thumbnail {
                    RemoteImage(url: thumb)
                } else {
                    LinearGradient(colors: [.accentColor.opacity(0.85), .purple.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay {
                            Image(systemName: site.symbol)
                                .font(.title.weight(.semibold))
                                .foregroundStyle(.white)
                                .symbolEffect(.pulse, isActive: isLoading)
                        }
                }
            }
            .frame(width: 86, height: 114)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 6) {
                Label(site.name, systemImage: site.symbol)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.25)), in: .capsule)
                if let media {
                    Text(media.title.isEmpty ? (media.author ?? media.page.host ?? "") : media.title)
                        .font(.headline)
                        .lineLimit(3)
                    HStack(spacing: 6) {
                        if let author = media.author, !media.title.isEmpty { Text(author) }
                        if let d = media.duration, d > 0 { Text(String(format: "%d:%02d", d / 60, d % 60)).monospacedDigit() }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else {
                    Text(isLoading ? "Wird analysiert …" : "Nichts gefunden").font(.headline)
                    Text(request.url.host?.replacingOccurrences(of: "www.", with: "") ?? request.url.absoluteString)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private var loadingRows: some View {
        VStack(spacing: 10) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 12) {
                    Circle().fill(.quaternary).frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(.quaternary).frame(width: 170, height: 12)
                        Capsule().fill(.quaternary).frame(width: 110, height: 10)
                    }
                    Spacer()
                }
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            HStack(spacing: 8) {
                ProgressView()
                Text("Suche Videos, Bilder und Ton …").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .redacted(reason: .placeholder)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.magnifyingglass").font(.system(size: 38)).foregroundStyle(.orange)
            Text(message).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { Task { await load() } } label: {
                    Label("Erneut", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button { openInBrowser() } label: {
                    Label("Im Browser suchen", systemImage: "safari").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
            Text("Im Browser erkennt Nova Videos beim Abspielen – tippe dann auf ⬇︎ am Video.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    // MARK: Options

    private func optionsList(_ media: ExtractedMedia) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Was möchtest du speichern?").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    ForEach(media.options) { option in optionRow(option, media: media) }
                }
            }
        }
    }

    private func optionRow(_ option: MediaOption, media: ExtractedMedia) -> some View {
        let isOn = selected.contains(option.id)
        return HStack(spacing: 12) {
            Image(systemName: icon(option.kind))
                .font(.headline)
                .foregroundStyle(isOn ? Color.white : Color.accentColor)
                .frame(width: 38, height: 38)
                .background(isOn ? Color.accentColor : Color.accentColor.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if option.recommended {
                        Text("Empfohlen")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.gradient, in: .capsule)
                    }
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if option.kind.isPlayable, let first = option.files.first?.candidates.first, first.pathExtension.lowercased() != "mpd" {
                Button {
                    preview = NativeMediaItem(url: first, kind: option.kind, title: media.title, poster: media.thumbnail,
                                              page: media.page, userAgent: media.userAgent, isPrivate: request.isPrivate,
                                              headers: option.headers)
                } label: {
                    Image(systemName: "play.fill").font(.footnote).frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Vorschau")
            }
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(12)
        .contentShape(.rect)
        .glassEffect(isOn ? .regular.tint(.accentColor.opacity(0.18)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 20))
        .onTapGesture {
            Haptics.selection()
            if isOn { selected.remove(option.id) } else { selected.insert(option.id) }
        }
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private func icon(_ kind: MediaKind) -> String {
        switch kind {
        case .video, .stream: return "film"
        case .audio: return "music.note"
        case .image: return "photo.on.rectangle"
        case .file: return "doc"
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speichern in").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(DownloadTarget.allCases) { t in
                        Button {
                            Haptics.selection()
                            library.downloadTarget = t
                        } label: {
                            Label(t.label, systemImage: t.icon)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(library.downloadTarget == t ? Color.white : Color.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .glassEffect(library.downloadTarget == t ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                                             in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(targetHint).font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
        }
    }

    private var targetHint: String {
        switch library.downloadTarget {
        case .library: return "Bleibt in deiner Mediathek in Nova (auch in der Dateien-App sichtbar)."
        case .photos: return "Videos und Bilder landen zusätzlich in der Fotos-App, Ton in einem Ordner deiner Wahl."
        case .files: return "Zusätzlich in einen Ordner deiner Wahl sichern (iCloud Drive, Auf meinem iPhone …)."
        }
    }

    // MARK: Progress

    private enum JobState { case running(Double, String), failed(String), done(SavedFile), gone }

    private func state(_ id: String) -> JobState {
        if let job = files.jobs[id] { return job.failed ? .failed(job.status) : .running(job.progress, job.status) }
        if let fileId = files.finished[id], let f = files.file(fileId) { return .done(f) }
        return .gone
    }

    private var doneFiles: [SavedFile] {
        jobs.compactMap { if case .done(let f) = state($0) { return f } else { return nil } }
    }

    private var allFinished: Bool {
        jobs.allSatisfy { id in
            switch state(id) {
            case .running: return false
            default: return true
            }
        }
    }

    private var progressCard: some View {
        VStack(spacing: 12) {
            ForEach(jobs, id: \.self) { id in
                HStack(spacing: 12) {
                    switch state(id) {
                    case .running(let p, let status):
                        ProgressRing(value: p).frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(files.jobs[id]?.name ?? "Download").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("\(status) \(Int(p * 100)) %").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        Button { files.cancel(id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    case .failed(let status):
                        Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange).frame(width: 30)
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Spacer()
                        Button("Erneut") {
                            if let new = files.retry(id), let i = jobs.firstIndex(of: id) { jobs[i] = new }
                        }
                            .buttonStyle(.glass)
                            .font(.caption.weight(.semibold))
                    case .done(let f):
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green).frame(width: 30)
                            .transition(.scale.combined(with: .opacity))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("\(f.kind.label) · \(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { openFile = f } label: { Image(systemName: "play.fill").frame(width: 32, height: 32) }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                    case .gone:
                        Image(systemName: "xmark.circle").font(.title2).foregroundStyle(.secondary).frame(width: 30)
                        Text("Abgebrochen").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            if allFinished, !doneFiles.isEmpty {
                HStack(spacing: 10) {
                    ShareLink(items: doneFiles.map(\.url)) {
                        Label("Teilen", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    if library.downloadTarget != .photos, doneFiles.contains(where: { $0.kind == .video || $0.kind == .image }) {
                        Button {
                            for f in doneFiles where f.kind == .video || f.kind == .image {
                                FileSaver.saveToPhotos(f.url) { FileDownloads.shared.onToast?($0) }
                            }
                        } label: {
                            Label("In Fotos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .controlSize(.large)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: allFinished)
    }

    // MARK: Bottom

    @ViewBuilder private var bottomButton: some View {
        Group {
            if !jobs.isEmpty {
                Button { dismiss() } label: {
                    Label(allFinished ? "Fertig" : "Im Hintergrund weiterladen", systemImage: allFinished ? "checkmark" : "arrow.down.circle.dotted")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
            } else if let media {
                let chosen = media.options.filter { selected.contains($0.id) }
                let count = chosen.reduce(0) { $0 + $1.files.count }
                Button { download(chosen, from: media) } label: {
                    Label(count > 1 ? "\(count) Dateien laden" : "Herunterladen", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(chosen.isEmpty)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            if media != nil || !jobs.isEmpty {
                Rectangle().fill(.bar).ignoresSafeArea(edges: .bottom)
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .init(x: 0.5, y: 0.3)))
            }
        }
    }

    // MARK: Actions

    private func load() async {
        media = nil
        error = nil
        jobs = []
        do {
            var result = try await MediaExtractor.extract(request.url, isPrivate: request.isPrivate)
            let known = Set(result.options.flatMap { $0.files.flatMap(\.candidates) })
            result.options += pageOptions(excluding: known)
            withAnimation(.snappy) { media = result }
            selected = Set(result.options.filter(\.recommended).prefix(1).map(\.id))
            if selected.isEmpty, let first = result.options.first { selected = [first.id] }
            Haptics.success()
            if request.autoStart {
                download(result.options.filter { selected.contains($0.id) }, from: result)
            }
        } catch {
            let found = pageOptions(excluding: [])
            let page = request.page ?? request.url
            if !found.isEmpty {
                withAnimation(.snappy) {
                    media = ExtractedMedia(site: MediaSite(page), page: page, title: "", author: page.host, thumbnail: nil,
                                           duration: nil, options: found, userAgent: request.userAgent)
                }
                if let first = found.first { selected = [first.id] }
            } else {
                Haptics.error()
                withAnimation(.snappy) { self.error = error.localizedDescription }
            }
        }
    }

    /// What the browser's detector found on the page (network requests, players, hidden links).
    private func pageOptions(excluding known: Set<URL>) -> [MediaOption] {
        request.pageMedia.filter { $0.kind != .image && !known.contains($0.url) }.prefix(15).map { item in
            let ext = item.url.pathExtension.lowercased()
            return MediaOption(id: "page-" + item.id, title: "Auf der Seite: \(item.kind.label)",
                               detail: [item.displayName, item.hidden ? "versteckt" : nil].compactMap { $0 }.joined(separator: " · "),
                               kind: item.kind,
                               files: [MediaFile(candidates: [item.url], ext: item.kind == .stream || ext.isEmpty ? "mp4" : ext)],
                               nameSuffix: item.kind.label)
        }
    }

    private func download(_ options: [MediaOption], from media: ExtractedMedia) {
        guard !options.isEmpty else { return }
        let base = FileDownloads.safe(media.fileBaseName)
        var started: [String] = []
        for option in options {
            for (i, file) in option.files.enumerated() {
                guard let first = file.candidates.first else { continue }
                var name = base
                if options.count > 1, let suffix = option.nameSuffix { name += " (\(suffix))" }
                if option.files.count > 1 { name += " \(i + 1)" }
                let id = files.download(first, name: name + "." + file.ext, page: media.page, userAgent: media.userAgent,
                                        headers: option.headers, alternatives: Array(file.candidates.dropFirst()), audio: file.audio,
                                        thumbnail: media.thumbnail, site: media.site == .web ? nil : media.site.name,
                                        target: library.downloadTarget, isPrivate: request.isPrivate, quiet: true)
                started.append(id)
            }
        }
        Haptics.success()
        withAnimation(.snappy) { jobs = started }
    }

    private func openInBrowser() {
        dismiss()
        BrowserModel.shared.open(request.url, findMedia: true, isPrivate: request.isPrivate)
    }
}
