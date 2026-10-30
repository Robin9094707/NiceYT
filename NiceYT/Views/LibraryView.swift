import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var account: AccountStore
    @StateObject private var history = FeedLoader(first: { try await YouTube.browse("FEhistory") })
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if account.isSignedIn {
                    profileCard
                    recentHistory
                    GlassEffectContainer(spacing: 12) {
                        VStack(spacing: 12) {
                            LibraryRow(title: "Verlauf", icon: "clock.arrow.circlepath", route: .history)
                            LibraryRow(title: "Später ansehen", icon: "clock.fill", route: .watchLater)
                            LibraryRow(title: "Videos mit „Mag ich“", icon: "hand.thumbsup.fill", route: .liked)
                            LibraryRow(title: "Playlists", icon: "list.bullet.rectangle.fill", route: .myPlaylists)
                            LibraryRow(title: "Abonnierte Kanäle", icon: "person.2.fill", route: .subscriptionsList)
                        }
                    }
                } else {
                    SignInPrompt(title: "Deine Bibliothek",
                                 message: "Verlauf, „Später ansehen“, Likes und Playlists – synchronisiert mit deinem YouTube-Konto.")
                        .padding(.top, 30)
                }
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        Button { BrowserModel.shared.open(nil) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "arrow.down.app.fill").font(.title3).foregroundStyle(.tint).frame(width: 32)
                                Text("Downloader & Browser").font(.body.weight(.medium))
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                            }
                            .padding(16)
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)
                        LibraryRow(title: "Video-Downloads", icon: "arrow.down.circle.fill", route: .downloads)
                        LibraryRow(title: "Datei-Downloads", icon: "tray.and.arrow.down.fill", route: .fileDownloads)
                    }
                }
                featureCard
            }
            .padding(16)
        }
        .navigationTitle("Du")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task { if account.isSignedIn { await history.load() } }
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn { Task { await history.load(force: true) } }
        }
        .refreshable {
            await account.refresh()
            await history.load(force: true)
        }
    }

    private var profileCard: some View {
        HStack(spacing: 16) {
            Avatar(url: account.info?.avatar, size: 68)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.info?.name ?? "Angemeldet").font(.title2.weight(.bold))
                if let h = account.info?.handle {
                    Text(h).font(.subheadline).foregroundStyle(.secondary)
                }
                Text("\(account.subscriptions.count) Abos").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    @ViewBuilder private var recentHistory: some View {
        let videos = history.items.compactMap { item -> Video? in
            if case .video(let v) = item { return v }
            return nil
        }
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink(value: Route.history) {
                    HStack {
                        Text("Verlauf").font(.title3.weight(.bold))
                        Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(videos.prefix(15)) { v in
                            HistoryTile(video: v).frame(width: 180)
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    private var featureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("NicePlay Premium-Features", systemImage: "sparkles").font(.headline)
            Group {
                Label("Komplett werbefrei", systemImage: "nosign")
                Label("Immer Originalton statt KI-Übersetzung", systemImage: "waveform")
                Label("Deezer: streamen & in FLAC herunterladen", systemImage: "music.note")
                Label("Hintergrundwiedergabe & Bild-in-Bild", systemImage: "pip")
                Label("SponsorBlock überspringt Sponsoren", systemImage: "forward.end.alt")
                Label("Dislikes wieder sichtbar", systemImage: "hand.thumbsdown")
                Label("Bis zu 4K über natives HLS", systemImage: "4k.tv")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .rect(cornerRadius: 28))
    }
}

struct HistoryTile: View {
    @EnvironmentObject private var player: PlayerModel
    let video: Video

    var body: some View {
        Button { player.play(video) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Thumbnail(video: video, cornerRadius: 14)
                Text(video.title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                if let c = video.channelName {
                    Text(c).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { VideoMenu(video: video) }
    }
}

struct LibraryRow: View {
    let title: String
    let icon: String
    let route: Route

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                Text(title).font(.body.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(16)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}
