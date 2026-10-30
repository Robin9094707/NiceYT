import SwiftUI

/// The "Musik" tab: Deezer start page, search and navigation.
struct MusicView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var music: MusicPlayer
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var router = MusicRouter.shared
    @ObservedObject private var request = MusicSearchRequest.shared
    @State private var query = ""
    @State private var results = DZSearchResult()
    @State private var isSearching = false
    @State private var scope: SearchScope = .all
    @State private var confirmLogout = false

    enum SearchScope: String, CaseIterable, Identifiable {
        case all, tracks, albums, artists, playlists
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Alle"
            case .tracks: return "Songs"
            case .albums: return "Alben"
            case .artists: return "Künstler"
            case .playlists: return "Playlists"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if store.user == nil {
                    if store.isRestoring {
                        ProgressView("Verbinde mit Deezer …").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        DeezerLoginView()
                    }
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults
                } else {
                    home
                }
            }
            .navigationTitle("Musik")
            .toolbar { if store.user != nil { ToolbarItem(placement: .topBarTrailing) { accountMenu } } }
            .navigationDestination(for: MusicRoute.self) { MusicRouteView(route: $0) }
            .modifier(MusicSearchable(enabled: store.user != nil, query: $query))
            .task(id: query) { await search() }
            .confirmationDialog("Von Deezer abmelden?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) { Task { await store.logout() } }
            } message: {
                Text("Heruntergeladene Songs bleiben auf dem Gerät.")
            }
        }
        .task { await store.restore() }
        .onChange(of: request.token) {
            router.path = NavigationPath()
            query = request.query
        }
    }

    // MARK: Account

    private var accountMenu: some View {
        Menu {
            if let u = store.user {
                Section(u.name + (u.offerName.map { " · \($0)" } ?? "")) {
                    Label(u.canStreamLossless ? "FLAC verfügbar" : u.canStreamHQ ? "320 kbit/s verfügbar" : "128 kbit/s",
                          systemImage: "waveform")
                }
            }
            Picker(selection: $settings.musicStreamQuality) {
                ForEach(DZQuality.allCases) { Text($0.label).tag($0) }
            } label: {
                Label("Streaming-Qualität", systemImage: "antenna.radiowaves.left.and.right")
            }
            .pickerStyle(.menu)
            Picker(selection: $settings.musicDownloadQuality) {
                ForEach(DZQuality.allCases) { Text($0.label).tag($0) }
            } label: {
                Label("Download-Qualität", systemImage: "arrow.down.circle")
            }
            .pickerStyle(.menu)
            Button("Abmelden", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLogout = true }
        } label: {
            if let url = store.user?.pictureURL {
                Avatar(url: url, size: 30)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
    }

    // MARK: Home

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let problem = store.sessionProblem {
                    HStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark").font(.title3).foregroundStyle(.orange)
                        Text(problem).font(.footnote)
                        Spacer(minLength: 0)
                        Button("Erneut") { Task { await store.retrySession() } }
                            .buttonStyle(.glass)
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(12)
                    .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 18))
                }
                quickTiles
                if !store.playlists.isEmpty {
                    shelf("Deine Playlists") {
                        ForEach(store.playlists) { p in
                            NavigationLink(value: MusicRoute.playlist(p.id)) {
                                CollectionTile(title: p.title, subtitle: p.trackCount.map { "\($0) Songs" }, image: p.pictureURL(500))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { CollectionMenu(shareURL: p.shareURL, load: { try await Deezer.shared.playlist(p.id).1 }) }
                        }
                    }
                }
                if !downloads.items.isEmpty {
                    shelf("Zuletzt heruntergeladen") {
                        ForEach(downloads.items.prefix(12)) { d in
                            Button {
                                music.play(downloads.items.map(\.track), startAt: downloads.items.firstIndex(of: d) ?? 0)
                            } label: {
                                CollectionTile(title: d.track.fullTitle, subtitle: d.track.artist, image: d.track.coverURL(500))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { TrackMenu(track: d.track) }
                        }
                    }
                }
                if !store.chartPlaylists.isEmpty {
                    shelf("Angesagte Playlists") {
                        ForEach(store.chartPlaylists) { p in
                            NavigationLink(value: MusicRoute.playlist(p.id)) {
                                CollectionTile(title: p.title, subtitle: p.owner, image: p.pictureURL(500))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { CollectionMenu(shareURL: p.shareURL, load: { try await Deezer.shared.playlist(p.id).1 }) }
                        }
                    }
                }
                if !store.charts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink(value: MusicRoute.charts) {
                            sectionTitle("Top-Charts", chevron: true)
                        }
                        .buttonStyle(.plain)
                        LazyVStack(spacing: 4) {
                            ForEach(Array(store.charts.prefix(10).enumerated()), id: \.element.id) { i, t in
                                TrackRow(track: t, list: store.charts, number: i + 1)
                            }
                        }
                    }
                }
                if store.isLoadingHome, store.charts.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                } else if let e = store.homeError {
                    ErrorState(message: e) { Task { await store.loadHome(force: true) } }
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .refreshable { await store.loadHome(force: true) }
    }

    private var quickTiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            NavigationLink(value: MusicRoute.favorites) {
                QuickTile(title: "Lieblingssongs", subtitle: "\(store.favorites.count) Songs", icon: "heart.fill",
                          colors: [.pink, .purple])
            }
            NavigationLink(value: MusicRoute.downloads) {
                QuickTile(title: "Downloads", subtitle: downloads.items.isEmpty ? "Offline hören" : "\(downloads.items.count) Songs",
                          icon: "arrow.down.circle.fill", colors: [.teal, .blue])
            }
            Button { playFlow() } label: {
                QuickTile(title: "Mix für dich", subtitle: "Flow starten", icon: "sparkles", colors: [.orange, .red])
            }
            Button {
                guard !store.charts.isEmpty else { return }
                music.play(store.charts, shuffled: true)
                music.showNowPlaying = true
            } label: {
                QuickTile(title: "Charts-Shuffle", subtitle: "Top 50 gemischt", icon: "shuffle", colors: [.indigo, .mint])
            }
        }
        .buttonStyle(.plain)
    }

    private func playFlow() {
        Haptics.impact()
        Task {
            do {
                let tracks = try await Deezer.shared.flow()
                music.play(tracks)
                music.showNowPlaying = true
            } catch {
                music.toast(error.localizedDescription)
            }
        }
    }

    private func shelf<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(title, chevron: false)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
            }
            .scrollClipDisabled()
        }
    }

    private func sectionTitle(_ title: String, chevron: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.title3.weight(.bold))
            if chevron { Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary) }
        }
    }

    // MARK: Search

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, store.user != nil else { results = DZSearchResult(); return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        let r = try? await Deezer.shared.search(q)
        guard !Task.isCancelled else { return }
        results = r ?? DZSearchResult()
        isSearching = false
    }

    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(SearchScope.allCases) { s in
                                Chip(title: s.title, selected: scope == s) { withAnimation(.snappy) { scope = s } }
                            }
                        }
                    }
                }
                .scrollClipDisabled()

                if isSearching && results.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }

                if (scope == .all || scope == .artists), !results.artists.isEmpty {
                    if scope == .all {
                        shelf("Künstler") { artistTiles }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 18) { artistTiles }
                    }
                }
                if (scope == .all || scope == .tracks), !results.tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if scope == .all { sectionTitle("Songs", chevron: false).padding(.bottom, 4) }
                        LazyVStack(spacing: 4) {
                            ForEach(scope == .all ? Array(results.tracks.prefix(8)) : results.tracks) { t in
                                TrackRow(track: t, list: results.tracks)
                            }
                        }
                    }
                }
                if (scope == .all || scope == .albums), !results.albums.isEmpty {
                    if scope == .all {
                        shelf("Alben") { albumTiles }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) { albumTiles }
                    }
                }
                if (scope == .all || scope == .playlists), !results.playlists.isEmpty {
                    if scope == .all {
                        shelf("Playlists") { playlistTiles }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) { playlistTiles }
                    }
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder private var artistTiles: some View {
        ForEach(results.artists) { a in
            NavigationLink(value: MusicRoute.artist(a.id)) {
                VStack(spacing: 8) {
                    RemoteImage(url: a.pictureURL(500))
                        .frame(width: 120, height: 120)
                        .clipShape(Circle())
                    Text(a.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let f = a.fans { Text("\(f.compact) Fans").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(width: 130)
            }
            .buttonStyle(.plain)
            .contextMenu {
                ShareLink(item: a.shareURL) { Label("Künstler teilen", systemImage: "square.and.arrow.up") }
            }
        }
    }

    @ViewBuilder private var albumTiles: some View {
        ForEach(results.albums) { a in
            NavigationLink(value: MusicRoute.album(a.id)) {
                CollectionTile(title: a.title, subtitle: [a.artist, a.year].compactMap { $0 }.joined(separator: " · "),
                               image: a.coverURL(500))
            }
            .buttonStyle(.plain)
            .contextMenu { CollectionMenu(shareURL: a.shareURL, load: { try await Deezer.shared.album(a.id).1 }) }
        }
    }

    @ViewBuilder private var playlistTiles: some View {
        ForEach(results.playlists) { p in
            NavigationLink(value: MusicRoute.playlist(p.id)) {
                CollectionTile(title: p.title, subtitle: p.trackCount.map { "\($0) Songs" }, image: p.pictureURL(500))
            }
            .buttonStyle(.plain)
            .contextMenu { CollectionMenu(shareURL: p.shareURL, load: { try await Deezer.shared.playlist(p.id).1 }) }
        }
    }
}

/// `.searchable` only once signed in (the login page has no use for it).
private struct MusicSearchable: ViewModifier {
    let enabled: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, Alben, Künstler")
        } else {
            content
        }
    }
}

struct MusicRouteView: View {
    let route: MusicRoute

    var body: some View {
        switch route {
        case .album(let id): TrackListView(source: .album(id))
        case .playlist(let id): TrackListView(source: .playlist(id))
        case .favorites: TrackListView(source: .favorites)
        case .charts: TrackListView(source: .charts)
        case .artist(let id): ArtistView(artistId: id)
        case .downloads: DownloadsView()
        }
    }
}

// MARK: - Tiles

struct QuickTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let colors: [Color]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        .contentShape(Rectangle())
    }
}

struct CollectionTile: View {
    let title: String
    let subtitle: String?
    let image: URL?
    var size: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: image)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: size, alignment: .leading)
    }
}

/// Long-press menu of an album or playlist tile.
struct CollectionMenu: View {
    @EnvironmentObject private var music: MusicPlayer
    @EnvironmentObject private var downloads: DownloadStore
    let shareURL: URL
    let load: () async throws -> [DZTrack]

    var body: some View {
        Button("Abspielen", systemImage: "play.fill") { run { music.play($0) } }
        Button("Zufallswiedergabe", systemImage: "shuffle") { run { music.play($0, shuffled: true) } }
        Button("Alle herunterladen", systemImage: "arrow.down.circle") { run { downloads.download(all: $0) } }
        ShareLink(item: shareURL) { Label("Teilen", systemImage: "square.and.arrow.up") }
    }

    private func run(_ action: @escaping ([DZTrack]) -> Void) {
        Task {
            do {
                let tracks = try await load()
                action(tracks)
            } catch {
                music.toast(error.localizedDescription)
            }
        }
    }
}

// MARK: - Track row

struct TrackRow: View {
    @EnvironmentObject private var music: MusicPlayer
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var store: MusicStore
    let track: DZTrack
    let list: [DZTrack]
    var number: Int? = nil
    var showCover = true

    private var isCurrent: Bool { music.current?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            if let number {
                Text("\(number)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
            }
            if showCover {
                RemoteImage(url: track.coverURL(250))
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.4))
                            Image(systemName: music.isPlaying ? "waveform" : "pause.fill")
                                .foregroundStyle(.white)
                                .symbolEffect(.variableColor.iterative, isActive: music.isPlaying)
                        }
                    }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.fullTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if downloads.isDownloaded(track.id) {
                        Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.green)
                    }
                    if track.explicit {
                        Text("E")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.background)
                            .frame(width: 13, height: 13)
                            .background(.secondary, in: RoundedRectangle(cornerRadius: 3))
                    }
                    Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let p = downloads.progress[track.id] {
                ProgressRing(value: p).frame(width: 22, height: 22)
            } else if store.isFavorite(track.id) {
                Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink)
            }
            Menu {
                TrackMenu(track: track, list: list)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if isCurrent {
                music.showNowPlaying = true
            } else {
                music.play(list, startAt: list.firstIndex(of: track) ?? 0)
            }
        }
        .contextMenu {
            TrackMenu(track: track, list: list)
        } preview: {
            TrackPreview(track: track)
        }
    }
}

struct TrackPreview: View {
    let track: DZTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemoteImage(url: track.coverURL(500))
                .frame(width: 260, height: 260)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.fullTitle).font(.headline).lineLimit(2)
                Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text([track.album, track.year].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 260)
    }
}

/// Long-press / "…" menu of a song.
struct TrackMenu: View {
    @EnvironmentObject private var music: MusicPlayer
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var store: MusicStore
    let track: DZTrack
    var list: [DZTrack] = []

    var body: some View {
        Section {
            if music.current?.id != track.id {
                Button("Abspielen", systemImage: "play.fill") {
                    if list.isEmpty { music.play([track]) } else { music.play(list, startAt: list.firstIndex(of: track) ?? 0) }
                }
            }
            if music.current != nil, music.current?.id != track.id {
                Button("Als Nächstes", systemImage: "text.line.first.and.arrowtriangle.forward") { music.playNext(track) }
                Button("Zur Warteschlange", systemImage: "text.badge.plus") { music.addToQueue(track) }
            }
            if !track.isYouTube {
                Button("Mix zu diesem Song", systemImage: "dot.radiowaves.left.and.right") { store.startMix(from: track) }
            }
        }
        if !track.isYouTube {
            Section {
                Button(store.isFavorite(track.id) ? "Aus Lieblingssongs entfernen" : "Zu Lieblingssongs",
                       systemImage: store.isFavorite(track.id) ? "heart.slash" : "heart") {
                    store.toggleFavorite(track)
                }
                if !store.playlists.isEmpty {
                    Menu {
                        ForEach(store.playlists) { p in
                            Button(p.title) { store.add(track, to: p) }
                        }
                    } label: {
                        Label("Zur Playlist hinzufügen", systemImage: "music.note.list")
                    }
                }
            }
        }
        Section {
            if downloads.isDownloaded(track.id) {
                Button("Download löschen", systemImage: "trash", role: .destructive) { downloads.delete(track.id) }
            } else if downloads.isQueued(track.id) {
                Button("Download abbrechen", systemImage: "xmark.circle") { downloads.cancel(track.id) }
            } else if !track.isYouTube {
                Button("Herunterladen", systemImage: "arrow.down.circle") { downloads.download(track) }
            }
        }
        if !track.isYouTube {
            Section {
                if let albumId = track.albumId {
                    Button("Album öffnen", systemImage: "square.stack") { MusicRouter.shared.open(.album(albumId)) }
                }
                if let artistId = track.artistId {
                    Button("Künstler öffnen", systemImage: "music.mic") { MusicRouter.shared.open(.artist(artistId)) }
                }
            }
        }
        Section {
            if let file = downloads.file(for: track.id) {
                ShareLink(item: file.url) { Label("Datei teilen", systemImage: "square.and.arrow.up.on.square") }
            }
            ShareLink(item: track.shareURL, subject: Text(track.fullTitle), message: Text("\(track.fullTitle) – \(track.artistLine)")) {
                Label("Link teilen", systemImage: "link")
            }
        }
    }
}

struct ProgressRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.03, value))
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: value)
        }
    }
}
