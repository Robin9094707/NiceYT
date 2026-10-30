import AVKit
import QuickLook
import SwiftUI
import WebKit

/// Opens links from anywhere in the right place: YouTube → player, Deezer/Spotify → music,
/// everything else → browser with media detection.
@MainActor
final class LinkRouter: ObservableObject {
    static let shared = LinkRouter()
    /// Video the root view should play.
    @Published var playRequest: Video?
    /// A link sits in the clipboard (banner "öffnen?").
    @Published var clipboardHasLink = false
    private var lastChange: Int {
        get { UserDefaults.standard.integer(forKey: "clipboardChange") }
        set { UserDefaults.standard.set(newValue, forKey: "clipboardChange") }
    }

    func open(_ url: URL) {
        let text = url.absoluteString
        if let id = YouTubeLink.videoId(from: text) {
            BrowserModel.shared.isPresented = false
            playRequest = Video(id: id, title: "", isShort: text.contains("/shorts/"))
            return
        }
        if let route = DeezerLink.route(from: text) {
            BrowserModel.shared.isPresented = false
            MusicRouter.shared.open(route)
            return
        }
        if let spotify = Self.spotifyRoute(url), MusicStore.shared.isSpotifyConnected {
            BrowserModel.shared.isPresented = false
            switch spotify {
            case .track(let id):
                Task {
                    if let j = try? await Spotify.shared.get("tracks/\(id)"), let t = DZTrack(spotify: j) {
                        MusicPlayer.shared.play([t])
                        MusicPlayer.shared.showNowPlaying = true
                    }
                }
            case .route(let r):
                MusicRouter.shared.open(r)
            }
            return
        }
        BrowserModel.shared.open(url, findMedia: true)
    }

    /// niceyt://open?url=…, youtube://…, vnd.youtube:…
    func handle(scheme url: URL) {
        if let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "url" })?.value, let u = URL(string: target) ?? BrowserModel.url(from: target) {
            open(u)
        } else {
            open(url)
        }
    }

    private enum SpotifyTarget { case track(String), route(MusicRoute) }

    private static func spotifyRoute(_ url: URL) -> SpotifyTarget? {
        guard url.host?.contains("spotify.com") == true else { return nil }
        let parts = url.path.split(separator: "/").map(String.init).filter { !$0.hasPrefix("intl-") }
        guard parts.count >= 2 else { return nil }
        switch parts[0] {
        case "track": return .track(parts[1])
        case "playlist": return .route(.spotifyPlaylist(parts[1]))
        case "album": return .route(.spotifyAlbum(parts[1]))
        default: return nil
        }
    }

    // MARK: Clipboard

    /// Looks (without reading it, so iOS doesn't ask) whether the clipboard holds a new link.
    func checkClipboard() {
        let board = UIPasteboard.general
        guard board.changeCount != lastChange else { return }
        board.detectPatterns(for: [.probableWebURL]) { result in
            let found = (try? result.get())?.contains(.probableWebURL) ?? false
            Task { @MainActor in
                if found { withAnimation(.spring) { self.clipboardHasLink = true } }
            }
        }
    }

    func openClipboard() {
        let board = UIPasteboard.general
        lastChange = board.changeCount
        withAnimation(.spring) { clipboardHasLink = false }
        if let url = board.url ?? board.string.flatMap({ BrowserModel.url(from: $0) ?? Self.firstURL(in: $0) }) {
            Haptics.impact()
            open(url)
        }
    }

    func dismissClipboard() {
        lastChange = UIPasteboard.general.changeCount
        withAnimation(.spring) { clipboardHasLink = false }
    }

    static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }
}

// MARK: - Browser screen

struct BrowserScreen: View {
    @ObservedObject private var model = BrowserModel.shared
    @EnvironmentObject private var files: FileDownloads
    @FocusState private var addressFocused: Bool
    @State private var showDownloads = false

    var body: some View {
        NavigationStack {
            ZStack {
                BrowserWebView(webView: model.webView)
                    .ignoresSafeArea(edges: .bottom)
                    .opacity(model.showStart ? 0 : 1)
                if model.showStart {
                    BrowserStartPage(showDownloads: $showDownloads)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if model.isLoading, !model.showStart {
                    GeometryReader { geo in
                        Capsule().fill(.tint).frame(width: geo.size.width * model.progress, height: 3)
                    }
                    .frame(height: 3)
                    .animation(.easeOut, value: model.progress)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showDownloads) { FileDownloadsView() }
        }
        .sheet(isPresented: $model.showMedia) { MediaSheet().environmentObject(files) }
        .youTubeDownloadSheet(active: model.isPresented)
        .confirmations(active: model.isPresented && !model.showMedia)
        .overlay(alignment: .top) {
            if let job = files.activeJobs.first {
                HStack(spacing: 10) {
                    ProgressRing(value: job.progress).frame(width: 18, height: 18)
                    Text(files.activeJobs.count > 1 ? "\(files.activeJobs.count) Downloads laufen" : job.name)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 4)
                .onTapGesture { showDownloads = true }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Suchen oder Link eingeben", text: $model.addressText)
                    .focused($addressFocused)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .font(.callout)
                    .onSubmit {
                        model.submit(model.addressText)
                        addressFocused = false
                    }
                if addressFocused {
                    Button {
                        if let s = UIPasteboard.general.string { model.addressText = s }
                    } label: { Image(systemName: "doc.on.clipboard") }
                } else if !model.showStart {
                    Button { model.reload() } label: {
                        Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .glassEffect(.regular.interactive(), in: .capsule)

            if !addressFocused {
                HStack {
                    barButton("xmark", label: "Schließen") { model.isPresented = false }
                    Spacer()
                    barButton("chevron.left", label: "Zurück", disabled: !model.canGoBack) { model.goBack() }
                    Spacer()
                    barButton("chevron.right", label: "Vor", disabled: !model.canGoForward) { model.goForward() }
                    Spacer()
                    Button {
                        Haptics.impact()
                        model.showMedia = true
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(model.media.contains { $0.kind != .image } ? Color.accentColor : Color.secondary)
                            .overlay(alignment: .topTrailing) {
                                let n = model.media.filter { $0.kind != .image }.count
                                if n > 0 {
                                    Text("\(n)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.red, in: .capsule)
                                        .offset(x: 10, y: -6)
                                }
                            }
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Gefundene Medien")
                    Spacer()
                    barButton("tray.and.arrow.down", label: "Downloads") { showDownloads = true }
                    Spacer()
                    Menu {
                        Button("Startseite", systemImage: "house") { model.showStartPage() }
                        Button("Medien erneut suchen", systemImage: "sparkle.magnifyingglass") { model.rescan() }
                        if let url = model.currentURL {
                            ShareLink(item: url) { Label("Seite teilen", systemImage: "square.and.arrow.up") }
                            Button("Link kopieren", systemImage: "link") {
                                UIPasteboard.general.url = url
                                Haptics.success()
                            }
                            Button("In Safari öffnen", systemImage: "safari") { UIApplication.shared.open(url) }
                        }
                        Toggle(isOn: Binding(get: { model.desktopMode }, set: { model.setDesktop($0) })) {
                            Label("Desktop-Version", systemImage: "desktopcomputer")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private func barButton(_ icon: String, label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).frame(width: 44, height: 44)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(label)
    }
}

struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Start page

private struct BrowserStartPage: View {
    @ObservedObject private var model = BrowserModel.shared
    @EnvironmentObject private var files: FileDownloads
    @Binding var showDownloads: Bool
    @State private var link = ""
    @State private var youTubeId: String?

    private let sites: [(String, String, String, Color)] = [
        ("TikTok", "https://www.tiktok.com", "music.note", .pink),
        ("Instagram", "https://www.instagram.com", "camera", .purple),
        ("Facebook", "https://m.facebook.com", "person.2", .blue),
        ("X", "https://x.com", "xmark", .primary),
        ("Reddit", "https://www.reddit.com", "bubble.left.and.bubble.right", .orange),
        ("Vimeo", "https://vimeo.com", "play.rectangle", .cyan),
        ("Dailymotion", "https://www.dailymotion.com", "play.tv", .indigo),
        ("SoundCloud", "https://soundcloud.com", "cloud", .orange),
        ("Pinterest", "https://www.pinterest.com", "pin", .red),
        ("Twitch", "https://www.twitch.tv", "gamecontroller", .purple),
        ("Archive.org", "https://archive.org", "building.columns", .gray),
        ("Google", "https://www.google.com", "magnifyingglass", .green)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloader").font(.largeTitle.weight(.bold))
                    Text("Link einfügen oder lossurfen – Videos, Audio und Dateien werden automatisch gefunden, auch versteckte.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        TextField("TikTok, Instagram, Facebook, YouTube, Datei-Link …", text: $link)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .onSubmit { process() }
                        Button {
                            if let s = UIPasteboard.general.string {
                                link = s
                                process()
                            }
                        } label: {
                            Label("Einfügen", systemImage: "doc.on.clipboard").font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))

                    if let id = youTubeId {
                        HStack(spacing: 10) {
                            Button {
                                LinkRouter.shared.open(URL(string: "https://youtu.be/\(id)")!)
                            } label: {
                                Label("Abspielen", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            Button {
                                YouTubeDownloads.shared.request = Video(id: id, title: "")
                            } label: {
                                Label("Herunterladen", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        }
                        .controlSize(.large)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Seiten").font(.title3.weight(.bold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 14)], spacing: 16) {
                        ForEach(sites, id: \.0) { site in
                            Button { model.load(URL(string: site.1)!) } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: site.2)
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(site.3)
                                        .frame(width: 58, height: 58)
                                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                                    Text(site.0).font(.caption).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button { showDownloads = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "tray.and.arrow.down.fill").font(.title2).foregroundStyle(.tint).frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downloads").font(.headline)
                            Text(files.files.isEmpty ? "Noch nichts geladen" :
                                 "\(files.files.count) Dateien · \(ByteCountFormatter.string(fromByteCount: files.totalSize, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Links aus anderen Apps", systemImage: "square.and.arrow.down.on.square").font(.headline)
                    Text("• Kopierte Links erkennt NicePlay automatisch beim Öffnen.\n• Teilen-Menü: In der Kurzbefehle-App einen Kurzbefehl „In NicePlay öffnen“ anlegen → „Im Share-Sheet anzeigen“ → Aktion „URL öffnen“ mit niceyt://open?url=[Kurzbefehleingabe].\n• YouTube-Links (youtube://) öffnen direkt in NicePlay, wenn die YouTube-App nicht installiert ist.\n• Verschlüsselte DRM-Streams (Netflix, Spotify …) lassen sich nicht speichern.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func process() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = BrowserModel.url(from: text) ?? LinkRouter.firstURL(in: text) else {
            if !text.isEmpty { model.submit(text) }
            return
        }
        Haptics.impact()
        if let id = YouTubeLink.videoId(from: url.absoluteString) {
            withAnimation(.snappy) { youTubeId = id }
            return
        }
        youTubeId = nil
        let kind = MediaKind(fileExtension: url.pathExtension)
        if kind != .file || ["zip", "pdf", "apk", "ipa", "dmg", "rar", "7z"].contains(url.pathExtension.lowercased()) {
            FileDownloads.shared.download(url, userAgent: model.userAgent)
            showDownloads = true
            return
        }
        LinkRouter.shared.open(url)
    }
}

// MARK: - Found media

private struct MediaSheet: View {
    @ObservedObject private var model = BrowserModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var preview: MediaItem?
    @State private var showImages = false

    private var shown: [MediaItem] { model.media.filter { showImages || $0.kind != .image } }

    var body: some View {
        NavigationStack {
            List {
                if shown.isEmpty {
                    ContentUnavailableView {
                        Label("Noch nichts gefunden", systemImage: "sparkle.magnifyingglass")
                    } description: {
                        Text("Starte das Video auf der Seite oder scrolle etwas – Medien werden laufend erkannt.")
                    } actions: {
                        Button("Erneut suchen") { model.rescan() }.buttonStyle(.glass)
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(shown) { item in
                    MediaRow(item: item, page: model.currentURL, userAgent: model.userAgent) {
                        model.download(item)
                    } onPreview: {
                        preview = item
                    }
                }
            }
            .navigationTitle(model.title.isEmpty ? "Gefundene Medien" : model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Erneut suchen", systemImage: "arrow.clockwise") { model.rescan() }
                        Toggle("Bilder anzeigen", isOn: $showImages)
                        Button("Alle Links kopieren", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = shown.map(\.url.absoluteString).joined(separator: "\n")
                            Haptics.success()
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(item: $preview) { item in MediaPreview(item: item, page: model.currentURL, userAgent: model.userAgent) }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct MediaRow: View {
    let item: MediaItem
    let page: URL?
    let userAgent: String
    var onDownload: () -> Void
    var onPreview: () -> Void
    @State private var size: Int64?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind.icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .glassEffect(.regular, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.kind.label)
                    if item.hidden { Text("versteckt").foregroundStyle(.orange) }
                    Text(item.url.host ?? "")
                    if let size, size > 0 { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Herunterladen", systemImage: "arrow.down.circle", action: onDownload)
                if item.kind == .video || item.kind == .audio || item.kind == .stream {
                    Button("Vorschau", systemImage: "play.circle", action: onPreview)
                }
                Button("Direktlink kopieren", systemImage: "link") {
                    UIPasteboard.general.url = item.url
                    Haptics.success()
                }
                ShareLink(item: item.url) { Label("Link teilen", systemImage: "square.and.arrow.up") }
            } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 36)
            }
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Herunterladen")
        }
        .contextMenu {
            Button("Herunterladen", systemImage: "arrow.down.circle", action: onDownload)
            Button("Direktlink kopieren", systemImage: "link") {
                UIPasteboard.general.url = item.url
                Haptics.success()
            }
        }
        .task(id: item.id) { size = await Self.probeSize(item.url, page: page, userAgent: userAgent) }
    }

    static func probeSize(_ url: URL, page: URL?, userAgent: String) async -> Int64? {
        guard MediaKind(fileExtension: url.pathExtension) != .stream else { return nil }
        let headers = await BrowserModel.requestHeaders(for: url, page: page, userAgent: userAgent)
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "HEAD"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let r = try? await URLSession.shared.data(for: req).1 as? HTTPURLResponse, r.statusCode < 400, r.expectedContentLength > 0 {
            return r.expectedContentLength
        }
        req.httpMethod = "GET"
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let r = try? await URLSession.shared.data(for: req).1 as? HTTPURLResponse,
              let range = r.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int64($0) }) else { return nil }
        return total
    }
}

private struct MediaPreview: View {
    let item: MediaItem
    let page: URL?
    let userAgent: String
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player { VideoPlayer(player: player) } else { ProgressView().tint(.white) }
            }
            .navigationTitle(item.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark") { player?.pause(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Laden", systemImage: "arrow.down.circle") {
                        FileDownloads.shared.download(item.url, page: page, userAgent: userAgent)
                        dismiss()
                    }
                }
            }
        }
        .task {
            let headers = await BrowserModel.requestHeaders(for: item.url, page: page, userAgent: userAgent)
            let asset = AVURLAsset(url: item.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = p
            p.play()
        }
    }
}

// MARK: - Downloads list

struct FileDownloadsView: View {
    @EnvironmentObject private var files: FileDownloads
    @State private var previewURL: URL?

    var body: some View {
        List {
            if !files.activeJobs.isEmpty {
                Section("Läuft") {
                    ForEach(files.activeJobs) { job in
                        HStack(spacing: 12) {
                            ProgressRing(value: job.failed ? 0 : job.progress).frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(job.failed ? job.status : "\(job.status) \(Int(job.progress * 100)) %")
                                    .font(.caption)
                                    .foregroundStyle(job.failed ? Color.orange : Color.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button { files.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            if files.files.isEmpty && files.activeJobs.isEmpty {
                ContentUnavailableView("Keine Downloads", systemImage: "tray",
                                       description: Text("Füge im Downloader einen Link ein oder tippe im Browser auf ⬇︎."))
                    .listRowBackground(Color.clear)
            }
            if !files.files.isEmpty {
                Section {
                    ForEach(files.files) { f in
                        Button { previewURL = f.url } label: {
                            HStack(spacing: 12) {
                                Image(systemName: f.kind.icon)
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 40, height: 40)
                                    .glassEffect(.regular, in: .rect(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text("\(f.kind.label) · \(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)) · \(URL(string: f.page ?? f.source)?.host ?? "")")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Löschen", systemImage: "trash", role: .destructive) { confirmDelete(f) }
                        }
                        .swipeActions(edge: .leading) {
                            ShareLink(item: f.url) { Label("Teilen", systemImage: "square.and.arrow.up") }.tint(.blue)
                        }
                        .contextMenu {
                            ShareLink(item: f.url) { Label("Teilen", systemImage: "square.and.arrow.up") }
                            Button("In Dateien sichern", systemImage: "folder") { FileSaver.saveToFiles([f.url]) }
                            if f.kind == .video || f.kind == .image {
                                Button("In Fotos sichern", systemImage: "photo.on.rectangle") {
                                    FileSaver.saveToPhotos(f.url) { files.onToast?($0) }
                                }
                            }
                            Button("Quelllink kopieren", systemImage: "link") {
                                UIPasteboard.general.string = f.source
                                Haptics.success()
                            }
                            Button("Löschen", systemImage: "trash", role: .destructive) { confirmDelete(f) }
                        }
                    }
                } header: {
                    Text("\(files.files.count) Dateien · \(ByteCountFormatter.string(fromByteCount: files.totalSize, countStyle: .file))")
                } footer: {
                    Text("Die Dateien liegen auch in der Dateien-App unter NicePlay › Downloads.")
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            if !files.files.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Alle in Dateien sichern", systemImage: "folder") { FileSaver.saveToFiles(files.files.map(\.url)) }
                        Button("Alle löschen", systemImage: "trash", role: .destructive) {
                            ConfirmCenter.shared.ask("Alle \(files.files.count) Downloads löschen?") { files.deleteAll() }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .quickLookPreview($previewURL)
    }

    private func confirmDelete(_ f: SavedFile) {
        ConfirmCenter.shared.ask("„\(f.name)“ löschen?", message: "Die Datei wird vom Gerät entfernt.") { files.delete(f.id) }
    }
}
