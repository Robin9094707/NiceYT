import SwiftUI

enum AppTab: Hashable {
    case home, shorts, subscriptions, music, search
}

struct RootView: View {
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var shorts: ShortsModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var music: MusicPlayer
    @EnvironmentObject private var musicStore: MusicStore
    @EnvironmentObject private var downloads: DownloadStore
    @ObservedObject private var musicRouter = MusicRouter.shared
    @ObservedObject private var ytDownloads = YouTubeDownloads.shared
    @ObservedObject private var browser = BrowserModel.shared
    @ObservedObject private var links = LinkRouter.shared
    @ObservedObject private var musicSearch = MusicSearchRequest.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .home

    var body: some View {
        TabView(selection: $tab) {
            Tab("Start", systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab("Shorts", systemImage: "bolt.horizontal.circle.fill", value: AppTab.shorts) {
                ShortsView()
            }
            Tab("Abos", systemImage: "play.square.stack.fill", value: AppTab.subscriptions) {
                SubscriptionsView()
            }
            Tab("Musik", systemImage: "music.note", value: AppTab.music) {
                MusicView()
            }
            Tab("Suche", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .youTubeDownloadSheet(active: !player.isPresented && !browser.isPresented)
        .downloadAssistantSheet(active: !player.isPresented && !browser.isPresented && ytDownloads.request == nil)
        .confirmations(active: !player.isPresented && !music.showNowPlaying && ytDownloads.request == nil && !browser.isPresented)
        .background {
            Color.clear.fullScreenCover(isPresented: $browser.isPresented) {
                BrowserScreen()
                    .environmentObject(FileDownloads.shared)
                    .environmentObject(music)
                    .environmentObject(YouTubeDownloads.shared)
                    .environmentObject(player)
                    .environmentObject(settings)
                    .environmentObject(account)
                    .tint(settings.accent.color)
            }
        }
        .modifier(MiniPlayerAccessory(enabled: (player.current != nil || music.current != nil) && tab != .shorts))
        .sheet(isPresented: $music.showNowPlaying) {
            NowPlayingView()
                .environmentObject(music)
                .environmentObject(musicStore)
                .environmentObject(downloads)
                .tint(settings.accent.color)
                .presentationDragIndicator(.hidden)
                .presentationBackground(.black)
                .presentationCornerRadius(36)
        }
        // Full-screen cover instead of a sheet: only that way the video can really use
        // the whole screen (landscape, swipe-up fullscreen). Dragging the video down
        // minimises it again.
        .fullScreenCover(isPresented: $player.isPresented) {
            PlayerContainer()
                .environmentObject(player)
                .environmentObject(shorts)
                .environmentObject(music)
                .environmentObject(musicStore)
                .environmentObject(downloads)
                .environmentObject(YouTubeDownloads.shared)
                .environmentObject(settings)
                .environmentObject(account)
                .tint(settings.accent.color)
                .presentationBackground(.clear)
        }
        .overlay(alignment: .top) {
            if let toast = player.toast ?? (music.showNowPlaying ? nil : music.toastText), !player.isPresented {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: tab) { _, new in
            if new == .shorts {
                player.player.pause()
                music.pause()
            }
            updateShorts()
        }
        .onChange(of: musicRouter.showTab) { openMusicTab() }
        .onChange(of: musicSearch.token) { openMusicTab() }
        .onChange(of: shorts.openRequest) { tab = .shorts }
        .onChange(of: player.isPresented) { _, presented in
            if !presented {
                if player.isFullscreen { player.setFullscreen(false) }
                // Back on the Shorts tab the Shorts take over again.
                if tab == .shorts { player.player.pause() }
            }
            updateShorts()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                updateShorts()
                LinkRouter.shared.checkClipboard()
                Task { await UpdateChecker.shared.check() }
            } else if phase == .background {
                AppLock.shared.lock()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .novaMediaWillPlay)) { _ in
            player.player.pause()
            music.pause()
        }
        .onOpenURL { url in LinkRouter.shared.handle(scheme: url) }
        .onChange(of: links.playRequest) { _, video in
            guard let video else { return }
            links.playRequest = nil
            if video.isShort {
                shorts.open(video, from: [video])
            } else {
                player.play(video)
            }
        }
        .overlay(alignment: .bottom) {
            if links.clipboardHasLink, !browser.isPresented, !player.isPresented {
                HStack(spacing: 12) {
                    Image(systemName: "link.badge.plus").font(.title3).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Link in der Zwischenablage").font(.subheadline.weight(.semibold))
                        Text("Herunterladen oder in Nova öffnen").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button { links.openClipboard() } label: { Image(systemName: "safari").font(.subheadline.weight(.semibold)) }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Öffnen")
                    Button { links.downloadClipboard() } label: {
                        Label("Laden", systemImage: "arrow.down").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                    Button { links.dismissClipboard() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .padding(.horizontal, 12)
                .padding(.bottom, 120)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: Binding(get: { updates.prompt }, set: { updates.prompt = $0 })) { release in
            UpdateSheet(release: release)
        }
        .task {
            // Prepare the signature/n solver in the background so the first video starts fast.
            Task.detached(priority: .utility) { await NSolver.shared.prewarm() }
            YouTubeDownloads.shared.onToast = { [player] text in player.showToast(text) }
            FileDownloads.shared.onToast = { [player] text in player.showToast(text) }
            LinkRouter.shared.checkClipboard()
            // Music starting stops videos and Shorts.
            music.onStart = { [player] in
                player.player.pause()
                if tab == .shorts { tab = .music }
            }
            await musicStore.restore()
            await UpdateChecker.shared.check()
        }
        .tint(settings.accent.color)
    }

    private func openMusicTab() {
        if player.isPresented { player.minimize() }
        if tab != .music { tab = .music }
    }

    private func updateShorts() {
        let visible = tab == .shorts && !player.isPresented
        shorts.setTabActive(visible)
        Orientation.setPortraitOnly(visible)
    }
}

/// The Liquid Glass mini player in the tab bar accessory slot.
struct MiniPlayerAccessory: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: enabled) { MiniPlayerView() }
        } else {
            content.tabViewBottomAccessory { MiniPlayerView() }
        }
    }
}

enum YouTubeLink {
    /// Extracts a video id from watch, short, embed, live and youtu.be links (or niceyt:// links).
    static func videoId(from text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("vnd.youtube:") {
            let id = String(s.dropFirst("vnd.youtube:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if id.count == 11 { return id }
        }
        guard let comps = URLComponents(string: s),
              let host = comps.host?.lowercased() ?? (["niceyt", "youtube"].contains(comps.scheme ?? "") ? "niceyt" : nil) else {
            return nil
        }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, v.count == 11 { return v }
        let parts = comps.path.split(separator: "/").map(String.init)
        if host.contains("youtu.be"), let first = parts.first, first.count == 11 { return first }
        if host.contains("youtube.com") || host == "niceyt" || comps.scheme == "youtube" {
            if parts.count >= 2, ["shorts", "embed", "live", "v", "watch"].contains(parts[0]), parts[1].count == 11 {
                return parts[1]
            }
        }
        return nil
    }
}

enum DeezerLink {
    /// deezer.com/(de/)track|album|playlist|artist/<id> → music route.
    static func route(from text: String) -> MusicRoute? {
        guard let comps = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.host?.contains("deezer") == true else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        for (i, p) in parts.enumerated() where i + 1 < parts.count {
            let id = parts[i + 1]
            guard Int(id) != nil else { continue }
            switch p {
            case "album": return .album(id)
            case "playlist": return .playlist(id)
            case "artist": return .artist(id)
            default: continue
            }
        }
        return nil
    }
}
