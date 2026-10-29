import SwiftUI

enum AppTab: Hashable {
    case home, shorts, subscriptions, library, search
}

struct RootView: View {
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var shorts: ShortsModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var account: AccountStore
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
            Tab("Du", systemImage: "person.crop.circle.fill", value: AppTab.library) {
                LibraryView()
            }
            Tab("Suche", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(MiniPlayerAccessory(enabled: player.current != nil && tab != .shorts))
        // Full-screen cover instead of a sheet: only that way the video can really use
        // the whole screen (landscape, swipe-up fullscreen). Dragging the video down
        // minimises it again.
        .fullScreenCover(isPresented: $player.isPresented) {
            PlayerContainer()
                .environmentObject(player)
                .environmentObject(shorts)
                .environmentObject(settings)
                .environmentObject(account)
                .tint(settings.accent.color)
                .presentationBackground(.clear)
        }
        .overlay(alignment: .top) {
            if let toast = player.toast, !player.isPresented {
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
            if new == .shorts { player.player.pause() }
            updateShorts()
        }
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
            if phase == .active { updateShorts() }
        }
        .onOpenURL { url in
            if let id = YouTubeLink.videoId(from: url.absoluteString) {
                player.play(Video(id: id, title: ""))
            }
        }
        .task {
            // Prepare the signature/n solver in the background so the first video starts fast.
            Task.detached(priority: .utility) { await NSolver.shared.prewarm() }
        }
        .tint(settings.accent.color)
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
        guard let comps = URLComponents(string: s), let host = comps.host?.lowercased() ?? (comps.scheme == "niceyt" ? "niceyt" : nil) else {
            return nil
        }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, v.count == 11 { return v }
        let parts = comps.path.split(separator: "/").map(String.init)
        if host.contains("youtu.be"), let first = parts.first, first.count == 11 { return first }
        if host.contains("youtube.com") || host == "niceyt" {
            if parts.count >= 2, ["shorts", "embed", "live", "v", "watch"].contains(parts[0]), parts[1].count == 11 {
                return parts[1]
            }
        }
        return nil
    }
}
