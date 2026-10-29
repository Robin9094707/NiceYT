import SwiftUI

@MainActor
final class ChannelModel: ObservableObject {
    @Published var page: ChannelPage?
    @Published var error: String?
    @Published var selectedTab: String?
    @Published var isSubscribed = false
    let feed: FeedLoader
    let channelId: String
    private var params: String? = "EgZ2aWRlb3PyBgQKAjoA"

    init(channelId: String) {
        self.channelId = channelId
        weak var holder: ChannelModel?
        feed = FeedLoader(first: {
            guard let model = holder else { return FeedPage() }
            return try await model.fetch()
        })
        holder = self
    }

    private func fetch() async throws -> FeedPage {
        var id = channelId
        if id.hasPrefix("@") || id.hasPrefix("http") {
            let url = id.hasPrefix("http") ? id : "https://www.youtube.com/\(id)"
            id = try await YouTube.resolveHandle(url) ?? id
        }
        let p = try await YouTube.channel(id, params: params)
        if page == nil || page?.tabs.isEmpty == true { page = p } else { page?.feed = p.feed }
        if page?.channel.name.isEmpty == false { error = nil }
        isSubscribed = p.isSubscribed
        selectedTab = p.tabs.first(where: \.selected)?.title ?? selectedTab
        return p.feed
    }

    func select(_ tab: ChannelPage.TabInfo) async {
        selectedTab = tab.title
        params = tab.params
        await feed.load(force: true)
    }

    func toggleSubscribe() async {
        let id = page?.channel.id ?? channelId
        let new = !isSubscribed
        isSubscribed = new
        do { try await YouTube.setSubscribed(id, new) } catch { isSubscribed = !new; self.error = error.localizedDescription }
    }
}

struct ChannelView: View {
    @EnvironmentObject private var account: AccountStore
    @StateObject private var model: ChannelModel
    private static let tabOrder = ["Videos", "Shorts", "Live", "Playlists", "Podcasts", "Veröffentlichungen", "Releases"]

    init(channelId: String) {
        _model = StateObject(wrappedValue: ChannelModel(channelId: channelId))
    }

    var body: some View {
        FeedScroll(loader: model.feed, compact: model.selectedTab == "Playlists") { header }
            .navigationTitle(model.page?.channel.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let page = model.page, let url = URL(string: "https://www.youtube.com/channel/\(page.channel.id)") {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
    }

    @ViewBuilder private var header: some View {
        if let page = model.page {
            VStack(alignment: .leading, spacing: 14) {
                if let banner = page.banner {
                    Color.clear
                        .frame(height: 96)
                        .overlay { RemoteImage(url: banner) }
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                HStack(spacing: 14) {
                    Avatar(url: page.channel.avatar, size: 76)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(page.channel.name).font(.title2.weight(.bold)).lineLimit(2)
                        Text([page.channel.handle, page.channel.subscribers, page.videoCount].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if let d = page.description, !d.isEmpty {
                    Text(d).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
                if account.isSignedIn {
                    Button {
                        Task { await model.toggleSubscribe() }
                    } label: {
                        Label(model.isSubscribed ? "Abonniert" : "Abonnieren",
                              systemImage: model.isSubscribed ? "bell.fill" : "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(model.isSubscribed ? .gray : .accentColor)
                }
                tabBar(page)
            }
        }
    }

    private func tabBar(_ page: ChannelPage) -> some View {
        let tabs = page.tabs
            .filter { Self.tabOrder.contains($0.title) || $0.params?.contains("EgZ2aWRlb3") == true }
        return ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(tabs) { tab in
                        Chip(title: tab.title, selected: tab.title == model.selectedTab) {
                            Task { await model.select(tab) }
                        }
                    }
                }
            }
        }
        .scrollClipDisabled()
    }
}

struct PlaylistView: View {
    let playlistId: String
    @EnvironmentObject private var player: PlayerModel
    @StateObject private var loader: FeedLoader
    @StateObject private var holder: PageHolder

    final class PageHolder: ObservableObject {
        @Published var page: PlaylistPage?
    }

    init(playlistId: String) {
        self.playlistId = playlistId
        let h = PageHolder()
        _holder = StateObject(wrappedValue: h)
        _loader = StateObject(wrappedValue: FeedLoader(first: {
            let p = try await YouTube.playlist(playlistId)
            await MainActor.run { h.page = p }
            return p.feed
        }))
    }

    private var videos: [Video] { loader.items.compactMap(\.video) }

    var body: some View {
        FeedScroll(loader: loader, compact: true, emptyText: "Diese Playlist ist leer", playAsQueue: true) {
            if let page = holder.page {
                VStack(alignment: .leading, spacing: 14) {
                    if let thumb = page.thumbnail {
                        Color.clear
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .overlay { RemoteImage(url: thumb) }
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                    }
                    Text(page.title).font(.title2.weight(.bold))
                    if let s = page.subtitle {
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Button {
                            if let first = videos.first { player.play(first, queue: videos) }
                        } label: {
                            Label("Abspielen", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.glassProminent)
                        Button {
                            let shuffled = videos.shuffled()
                            if let first = shuffled.first { player.play(first, queue: shuffled) }
                        } label: {
                            Label("Zufällig", systemImage: "shuffle").frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                    }
                    .font(.headline)
                }
            }
        }
        .navigationTitle(holder.page?.title ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
    }
}
