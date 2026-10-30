import SwiftUI

/// Album, playlist, favourites or charts as a track list with a large header.
struct TrackListView: View {
    enum Source: Hashable {
        case album(String), playlist(String), favorites, charts
    }

    @EnvironmentObject private var music: MusicPlayer
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var store: MusicStore
    let source: Source

    @State private var tracks: [DZTrack] = []
    @State private var title = ""
    @State private var subtitle = ""
    @State private var detail = ""
    @State private var image: URL?
    @State private var shareURL: URL?
    @State private var isLoading = true
    @State private var error: String?
    @State private var filter = ""

    private var shown: [DZTrack] {
        guard !filter.isEmpty else { return tracks }
        return tracks.filter { $0.title.localizedCaseInsensitiveContains(filter) || $0.artistLine.localizedCaseInsensitiveContains(filter) }
    }

    private var isAlbum: Bool { if case .album = source { return true } else { return false } }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if isLoading && tracks.isEmpty {
                    ProgressView().padding(.top, 30)
                } else if let error, tracks.isEmpty {
                    ErrorState(message: error) { Task { await load() } }
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                            TrackRow(track: t, list: shown, number: isAlbum ? (t.trackNumber ?? i + 1) : nil, showCover: !isAlbum)
                        }
                    }
                    if !tracks.isEmpty {
                        Text(footer).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "In der Liste suchen")
        .toolbar {
            if let shareURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareURL) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .refreshable { await load() }
        .task { if tracks.isEmpty { await load() } }
    }

    private var footer: String {
        let minutes = tracks.reduce(0) { $0 + $1.duration } / 60
        let time = minutes >= 60 ? "\(minutes / 60) Std. \(minutes % 60) Min." : "\(minutes) Min."
        return [detail, "\(tracks.count) Songs, \(time)"].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var header: some View {
        VStack(spacing: 14) {
            Group {
                if source == .favorites {
                    LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay { Image(systemName: "heart.fill").font(.system(size: 80)).foregroundStyle(.white) }
                } else {
                    RemoteImage(url: image)
                }
            }
            .frame(width: 230, height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 10)

            VStack(spacing: 4) {
                Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            if !tracks.isEmpty { actionBar }
        }
    }

    private var actionBar: some View {
        let missing = tracks.filter { !downloads.isDownloaded($0.id) }
        let running = tracks.filter { downloads.isQueued($0.id) }.count
        return HStack(spacing: 12) {
            Button {
                music.play(tracks)
                music.showNowPlaying = true
            } label: {
                Label("Abspielen", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            Button {
                music.play(tracks, shuffled: true)
                music.showNowPlaying = true
            } label: {
                Label("Zufall", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            Button {
                if missing.isEmpty { music.toast("Alle Songs sind schon offline verfügbar") } else { downloads.download(all: missing) }
            } label: {
                Group {
                    if running > 0 {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: missing.isEmpty ? "checkmark.circle.fill" : "arrow.down.circle")
                    }
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .accessibilityLabel(missing.isEmpty ? "Heruntergeladen" : "Alle herunterladen")
        }
        .font(.headline)
        .controlSize(.large)
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            switch source {
            case .album(let id):
                let (album, list) = try await Deezer.shared.album(id)
                tracks = list
                title = album?.title ?? "Album"
                subtitle = [album?.artist, album?.type, album?.year].compactMap { $0 }.joined(separator: " · ")
                detail = album?.label.map { "℗ \($0)" } ?? ""
                image = album?.coverURL(1000)
                shareURL = album?.shareURL
            case .playlist(let id):
                let (playlist, list) = try await Deezer.shared.playlist(id)
                tracks = list
                title = playlist?.title ?? "Playlist"
                subtitle = playlist?.owner.map { "von \($0)" } ?? ""
                detail = playlist?.description ?? ""
                image = playlist?.pictureURL(1000) ?? list.first?.coverURL(1000)
                shareURL = playlist?.shareURL
            case .favorites:
                title = "Lieblingssongs"
                subtitle = store.user?.name ?? ""
                tracks = try await Deezer.shared.favoriteTracks()
            case .charts:
                title = "Top-Charts"
                subtitle = "Die 100 meistgehörten Songs"
                image = tracks.first?.coverURL(1000)
                tracks = try await Deezer.shared.chartTracks(limit: 100)
                image = tracks.first?.coverURL(1000)
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Artist

struct ArtistView: View {
    @EnvironmentObject private var music: MusicPlayer
    let artistId: String
    @State private var artist: DZArtist?
    @State private var top: [DZTrack] = []
    @State private var albums: [DZAlbum] = []
    @State private var error: String?
    @State private var showAllTop = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 10) {
                    RemoteImage(url: artist?.pictureURL(1000))
                        .frame(width: 190, height: 190)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    Text(artist?.name ?? "").font(.title.weight(.bold))
                    if let f = artist?.fans { Text("\(f.compact) Fans").font(.subheadline).foregroundStyle(.secondary) }
                    if !top.isEmpty {
                        HStack(spacing: 12) {
                            Button { music.play(top); music.showNowPlaying = true } label: {
                                Label("Abspielen", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            Button { music.play(top, shuffled: true); music.showNowPlaying = true } label: {
                                Label("Zufall", systemImage: "shuffle").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        }
                        .font(.headline)
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity)

                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Beliebte Songs").font(.title3.weight(.bold))
                        LazyVStack(spacing: 4) {
                            ForEach(Array(top.prefix(showAllTop ? 50 : 5).enumerated()), id: \.element.id) { i, t in
                                TrackRow(track: t, list: top, number: i + 1)
                            }
                        }
                        if top.count > 5 {
                            Button(showAllTop ? "Weniger anzeigen" : "Mehr anzeigen") {
                                withAnimation(.snappy) { showAllTop.toggle() }
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Diskografie").font(.title3.weight(.bold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                            ForEach(albums) { a in
                                NavigationLink(value: MusicRoute.album(a.id)) {
                                    CollectionTile(title: a.title, subtitle: [a.type, a.year].compactMap { $0 }.joined(separator: " · "),
                                                   image: a.coverURL(500))
                                }
                                .buttonStyle(.plain)
                                .contextMenu { CollectionMenu(shareURL: a.shareURL, load: { try await Deezer.shared.album(a.id).1 }) }
                            }
                        }
                    }
                }
                if let error { ErrorState(message: error) { Task { await load() } } }
            }
            .padding(16)
        }
        .navigationTitle(artist?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let a = artist {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: a.shareURL) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .task { if artist == nil { await load() } }
    }

    private func load() async {
        error = nil
        do {
            let (a, t, al) = try await Deezer.shared.artist(artistId)
            artist = a
            top = t
            albums = al
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Downloads

struct DownloadsView: View {
    @EnvironmentObject private var music: MusicPlayer
    @EnvironmentObject private var downloads: DownloadStore
    @State private var filter = ""
    @State private var confirmDeleteAll = false

    private var shown: [DownloadedTrack] {
        guard !filter.isEmpty else { return downloads.items }
        return downloads.items.filter {
            $0.track.title.localizedCaseInsensitiveContains(filter) || $0.track.artistLine.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        List {
            if downloads.items.isEmpty && downloads.progress.isEmpty {
                ContentUnavailableView("Noch keine Downloads",
                                       systemImage: "arrow.down.circle",
                                       description: Text("Halte einen Song gedrückt oder tippe auf „…“ → „Herunterladen“. Die Dateien kannst du danach in jede App teilen."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    HStack(spacing: 12) {
                        Button {
                            music.play(shown.map(\.track))
                            music.showNowPlaying = true
                        } label: {
                            Label("Abspielen", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        Button {
                            music.play(shown.map(\.track), shuffled: true)
                            music.showNowPlaying = true
                        } label: {
                            Label("Zufall", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    .font(.headline)
                    .controlSize(.large)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                if !downloads.progress.isEmpty {
                    Section("Wird heruntergeladen (\(downloads.progress.count))") {
                        ForEach(downloads.progress.keys.sorted(), id: \.self) { id in
                            HStack(spacing: 12) {
                                ProgressRing(value: downloads.progress[id] ?? 0).frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(downloads.active[id]?.fullTitle ?? "Song").font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(downloads.active[id]?.artistLine ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Abbrechen") { downloads.cancel(id) }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section {
                    ForEach(shown) { d in
                        TrackRow(track: d.track, list: shown.map(\.track))
                            .swipeActions(edge: .trailing) {
                                Button("Löschen", systemImage: "trash", role: .destructive) { downloads.delete(d.id) }
                            }
                            .swipeActions(edge: .leading) {
                                ShareLink(item: d.url) { Label("Teilen", systemImage: "square.and.arrow.up") }
                                    .tint(.blue)
                            }
                    }
                } header: {
                    Text("\(downloads.items.count) Songs · \(ByteCountFormatter.string(fromByteCount: downloads.totalSize, countStyle: .file))")
                } footer: {
                    Text("Die Dateien (mit Cover und Tags) findest du auch in der Dateien-App unter „Auf meinem iPhone › NicePlay › Musik“. Nach links wischen zum Teilen, nach rechts zum Löschen.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Downloads")
        .searchable(text: $filter, prompt: "Downloads durchsuchen")
        .toolbar {
            if !downloads.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(items: shown.map(\.url)) { Label("Alle teilen", systemImage: "square.and.arrow.up.on.square") }
                        Button("Alle löschen", systemImage: "trash", role: .destructive) { confirmDeleteAll = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .confirmationDialog("Alle Downloads löschen?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Alle löschen", role: .destructive) { downloads.deleteAll() }
        }
    }
}
