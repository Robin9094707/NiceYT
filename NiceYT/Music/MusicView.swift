import SwiftUI

/// The "Musik" tab: Deezer and/or Spotify, downloads – usable without any account too.
struct MusicView: View {
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var music: MusicPlayer
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ytDownloads: YouTubeDownloads
    @ObservedObject private var router = MusicRouter.shared
    @ObservedObject private var request = MusicSearchRequest.shared
    @State private var query = ""
    @State private var results = DZSearchResult()
    @State private var spResults = SPSearchResult()
    @State private var isSearching = false
    @State private var scope: SearchScope = .all
    @State private var searchSource: SearchSource = .deezer
    @State private var confirmLogout = false
    @State private var confirmSpotifyLogout = false
    @State private var showDeezerLogin = false
    @State private var showSpotifyLogin = false

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

    enum SearchSource: String, CaseIterable, Identifiable {
        case deezer, spotify
        var id: String { rawValue }
        var title: String { self == .deezer ? "Deezer" : "Spotify" }
    }

    /// Search goes to Spotify when only Spotify is connected (or chosen).
    private var effectiveSource: SearchSource {
        if store.user == nil { return .spotify }
        if store.spotifyUser == nil { return .deezer }
        return searchSource
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if !store.hasAnySource {
                    if store.isRestoring {
                        ProgressView("Verbinde …").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        welcome
                    }
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults
                } else {
                    home
                }
            }
            .navigationTitle("Musik")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { accountMenu } }
            .navigationDestination(for: MusicRoute.self) { MusicRouteView(route: $0) }
            .modifier(MusicSearchable(enabled: store.hasAnySource, query: $query))
            .task(id: "\(query)|\(effectiveSource.rawValue)") { await search() }
            .confirmationDialog("Von Deezer abmelden?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) { Task { await store.logout() } }
            } message: {
                Text("Heruntergeladene Songs bleiben auf dem Gerät.")
            }
            .confirmationDialog("Spotify trennen?", isPresented: $confirmSpotifyLogout, titleVisibility: .visible) {
                Button("Trennen", role: .destructive) { Task { await store.disconnectSpotify() } }
            } message: {
                Text("Heruntergeladene Songs bleiben auf dem Gerät.")
            }
            .sheet(isPresented: $showDeezerLogin) {
                NavigationStack {
                    DeezerLoginView()
                        .navigationTitle("Deezer")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Schließen", systemImage: "xmark") { showDeezerLogin = false }
                            }
                        }
                }
                .environmentObject(store)
            }
            .sheet(isPresented: $showSpotifyLogin) {
                SpotifyLoginView().environmentObject(store)
            }
        }
        .task {
            await store.restore()
            await store.restoreSpotify()
        }
        .onChange(of: store.user) { _, user in if user != nil { showDeezerLogin = false } }
        .onChange(of: request.token) {
            router.path = NavigationPath()
            query = request.query
        }
    }

    // MARK: Account

    private var accountMenu: some View {
        Menu {
            Section("Deezer") {
                if let u = store.user {
                    Label(u.name + " · " + (u.canStreamLossless ? "FLAC" : u.canStreamHQ ? "320 kbit/s" : "128 kbit/s"),
                          systemImage: "checkmark.circle.fill")
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
                    Button("Von Deezer abmelden", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmLogout = true
                    }
                } else {
                    Button("Deezer verbinden", systemImage: "plus.circle") { showDeezerLogin = true }
                }
            }
            Section("Spotify") {
                if let u = store.spotifyUser {
                    Label(u.name + (u.product.map { " · \($0.capitalized)" } ?? ""), systemImage: "checkmark.circle.fill")
                    Button("Spotify trennen", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmSpotifyLogout = true
                    }
                } else {
                    Button("Spotify verbinden", systemImage: "plus.circle") { showSpotifyLogin = true }
                }
            }
            Section {
                Button("Daten löschen …", systemImage: "trash") { router.path.append(MusicRoute.dataReset) }
            }
        } label: {
            if let url = store.user?.pictureURL ?? store.spotifyUser?.imageURL {
                Avatar(url: url, size: 30)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
    }

    // MARK: Welcome (no account)

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 50, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [.pink, .purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 104, height: 104)
                        .glassEffect(.regular, in: .circle)
                    Text("Deine Musik").font(.title.weight(.bold))
                    Text("Verbinde Deezer, Spotify oder beides. Deine Downloads kannst du jederzeit auch ohne Konto hören.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 16)

                VStack(spacing: 12) {
                    Button { showDeezerLogin = true } label: {
                        SourceCard(title: "Deezer verbinden", subtitle: "Streamen & herunterladen bis FLAC",
                                   icon: "waveform", colors: [.purple, .pink])
                    }
                    Button { showSpotifyLogin = true } label: {
                        SourceCard(title: "Spotify verbinden", subtitle: "Playlists & Lieblingssongs übernehmen",
                                   icon: "dot.radiowaves.left.and.right", colors: [.green, .mint])
                    }
                }
                .buttonStyle(.plain)

                offlineTiles

                Button { router.path.append(MusicRoute.dataReset) } label: {
                    Label("Daten löschen …", systemImage: "trash").font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private var offlineTiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            NavigationLink(value: MusicRoute.downloads) {
                QuickTile(title: "Downloads", subtitle: downloads.items.isEmpty ? "Offline hören" : "\(downloads.items.count) Songs",
                          icon: "arrow.down.circle.fill", colors: [.teal, .blue])
            }
            NavigationLink(value: MusicRoute.videoDownloads) {
                QuickTile(title: "Videos", subtitle: ytDownloads.videos.isEmpty ? "YouTube offline" : "\(ytDownloads.videos.count) Videos",
                          icon: "film.stack.fill", colors: [.red, .orange])
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Home

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let problem = store.sessionProblem {
                    banner(problem) { Task { await store.retrySession() } }
                }
                if let problem = store.spotifyProblem {
                    banner("Spotify: " + problem) { Task { await store.loadSpotify(force: true) } }
                }
                sourceChips
                quickTiles
                if !store.spotifyPlaylists.isEmpty {
                    shelf("Spotify-Playlists") {
                        ForEach(store.spotifyPlaylists) { p in
                            NavigationLink(value: MusicRoute.spotifyPlaylist(p.id)) {
                                CollectionTile(title: p.name, subtitle: p.trackCount.map { "\($0) Songs" } ?? p.owner, image: p.imageURL)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { CollectionMenu(shareURL: p.shareURL, load: { try await Spotify.shared.playlist(p.id).1 }) }
                        }
                    }
                }
                if !store.playlists.isEmpty {
                    shelf("Deezer-Playlists") {
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
                if store.user != nil {
                    if store.isLoadingHome, store.charts.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                    } else if let e = store.homeError {
                        ErrorState(message: e) { Task { await store.loadHome(force: true) } }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .refreshable {
            await store.loadHome(force: true)
            await store.loadSpotify(force: true)
        }
    }

    private func banner(_ text: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.title3).foregroundStyle(.orange)
            Text(text).font(.footnote)
            Spacer(minLength: 0)
            Button("Erneut", action: retry)
                .buttonStyle(.glass)
                .font(.footnote.weight(.semibold))
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 18))
    }

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Chip(title: store.user == nil ? "Deezer verbinden" : "Deezer",
                         systemImage: store.user == nil ? "plus.circle" : "checkmark.circle.fill",
                         selected: store.user != nil) {
                        if store.user == nil { showDeezerLogin = true }
                    }
                    Chip(title: store.spotifyUser == nil ? "Spotify verbinden" : "Spotify",
                         systemImage: store.spotifyUser == nil ? "plus.circle" : "checkmark.circle.fill",
                         selected: store.spotifyUser != nil) {
                        if store.spotifyUser == nil { showSpotifyLogin = true }
                    }
                    NavigationLink(value: MusicRoute.videoDownloads) {
                        Label("Videos", systemImage: "film.stack")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollClipDisabled()
    }

    private var quickTiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            if store.user != nil {
                NavigationLink(value: MusicRoute.favorites) {
                    QuickTile(title: "Lieblingssongs", subtitle: "\(store.favorites.count) Songs · Deezer", icon: "heart.fill",
                              colors: [.pink, .purple])
                }
            }
            if store.spotifyUser != nil {
                NavigationLink(value: MusicRoute.spotifyLiked) {
                    QuickTile(title: "Lieblingssongs", subtitle: "Spotify", icon: "heart.fill", colors: [.green, .teal])
                }
            }
            NavigationLink(value: MusicRoute.downloads) {
                QuickTile(title: "Downloads", subtitle: downloads.items.isEmpty ? "Offline hören" : "\(downloads.items.count) Songs",
                          icon: "arrow.down.circle.fill", colors: [.teal, .blue])
            }
            if store.user != nil {
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
        guard !q.isEmpty, store.hasAnySource else {
            results = DZSearchResult()
            spResults = SPSearchResult()
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        isSearching = true
        if effectiveSource == .spotify {
            let r = try? await Spotify.shared.search(q)
            guard !Task.isCancelled else { return }
            spResults = r ?? SPSearchResult()
        } else {
            let r = try? await Deezer.shared.search(q)
            guard !Task.isCancelled else { return }
            results = r ?? DZSearchResult()
        }
        isSearching = false
    }

    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if store.user != nil, store.spotifyUser != nil {
                    Picker("Quelle", selection: $searchSource) {
                        ForEach(SearchSource.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if effectiveSource == .spotify {
                    spotifyResults
                } else {
                    deezerResults
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder private var spotifyResults: some View {
        if isSearching && spResults.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else if spResults.isEmpty {
            ContentUnavailableView.search(text: query)
        }
        if !spResults.tracks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Songs", chevron: false).padding(.bottom, 4)
                LazyVStack(spacing: 4) {
                    ForEach(spResults.tracks) { t in TrackRow(track: t, list: spResults.tracks) }
                }
            }
        }
        if !spResults.albums.isEmpty {
            shelf("Alben") {
                ForEach(spResults.albums) { a in
                    NavigationLink(value: MusicRoute.spotifyAlbum(a.id)) {
                        CollectionTile(title: a.name, subtitle: [a.artist, a.year].compactMap { $0 }.joined(separator: " · "), image: a.imageURL)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { CollectionMenu(shareURL: a.shareURL, load: { try await Spotify.shared.album(a.id).1 }) }
                }
            }
        }
        if !spResults.playlists.isEmpty {
            shelf("Playlists") {
                ForEach(spResults.playlists) { p in
                    NavigationLink(value: MusicRoute.spotifyPlaylist(p.id)) {
                        CollectionTile(title: p.name, subtitle: p.owner, image: p.imageURL)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { CollectionMenu(shareURL: p.shareURL, load: { try await Spotify.shared.playlist(p.id).1 }) }
                }
            }
        }
    }

    @ViewBuilder private var deezerResults: some View {
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
        case .spotifyPlaylist(let id): TrackListView(source: .spotifyPlaylist(id))
        case .spotifyAlbum(let id): TrackListView(source: .spotifyAlbum(id))
        case .spotifyLiked: TrackListView(source: .spotifyLiked)
        case .videoDownloads: DownloadedVideosView()
        case .dataReset: DataResetView()
        }
    }
}

// MARK: - Tiles

struct SourceCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let colors: [Color]

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        .contentShape(Rectangle())
    }
}

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
            if track.isDeezer {
                Button("Mix zu diesem Song", systemImage: "dot.radiowaves.left.and.right") { store.startMix(from: track) }
            }
        }
        if track.isDeezer {
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
                Button("Download löschen", systemImage: "trash", role: .destructive) {
                    ConfirmCenter.shared.ask("„\(track.title)“ löschen?", message: "Die heruntergeladene Datei wird vom Gerät entfernt.") {
                        downloads.delete(track.id)
                    }
                }
            } else if downloads.isQueued(track.id) {
                Button("Download abbrechen", systemImage: "xmark.circle") { downloads.cancel(track.id) }
            } else if !track.isYouTube {
                Button("Herunterladen", systemImage: "arrow.down.circle") { downloads.download(track) }
            }
        }
        if track.isDeezer {
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
                Button("In Dateien sichern", systemImage: "folder") { FileSaver.saveToFiles([file.url]) }
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
