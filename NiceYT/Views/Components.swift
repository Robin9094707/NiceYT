import SwiftUI

// MARK: - Navigation

enum Route: Hashable {
    case channel(String)
    case playlist(String)
    case history
    case watchLater
    case liked
    case myPlaylists
    case subscriptionsList
    case library
    case downloads
    case fileDownloads
}

struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .channel(let id): ChannelView(channelId: id)
        case .playlist(let id): PlaylistView(playlistId: id)
        case .history: BrowseFeedView(title: "Verlauf", browseId: "FEhistory")
        case .watchLater: PlaylistView(playlistId: "WL")
        case .liked: PlaylistView(playlistId: "LL")
        case .myPlaylists: BrowseFeedView(title: "Playlists", browseId: "FEplaylist_aggregation")
        case .subscriptionsList: SubscribedChannelsView()
        case .library: LibraryView()
        case .downloads: DownloadedVideosView()
        case .fileDownloads: MediaLibraryView()
        }
    }
}

extension View {
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { RouteDestination(route: $0) }
    }
}

// MARK: - Feed loading

@MainActor
final class FeedLoader: ObservableObject {
    @Published private(set) var items: [FeedItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = false
    /// Increments with every loaded page, so the "load more" trigger re-arms itself.
    @Published private(set) var pageCount = 0
    private var continuation: String?
    private var loadingMore = false
    private let first: () async throws -> FeedPage
    private let more: (String) async throws -> FeedPage

    init(first: @escaping () async throws -> FeedPage,
         more: @escaping (String) async throws -> FeedPage = YouTube.browseMore) {
        self.first = first
        self.more = more
    }

    var isEmpty: Bool { items.isEmpty }

    func load(force: Bool = false) async {
        if !force && (!items.isEmpty || isLoading) { return }
        isLoading = true
        error = nil
        do {
            let page = try await first()
            items = page.items
            continuation = page.continuation
            hasMore = continuation != nil
            pageCount += 1
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    func loadMore() async {
        guard let token = continuation, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await more(token) else { return }
        let existing = Set(items.map(\.id))
        items += page.items.filter { !existing.contains($0.id) }
        // Stop when YouTube keeps returning the same token.
        continuation = page.continuation == token ? nil : page.continuation
        hasMore = continuation != nil
        pageCount += 1
    }
}

// MARK: - Images

/// Memory cache + de-duplicated downloads for thumbnails and avatars
/// (disk caching comes from the shared URLCache).
@MainActor
final class ImagePipeline {
    static let shared = ImagePipeline()
    private let cache = NSCache<NSURL, UIImage>()
    private var running: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 160 * 1024 * 1024
    }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        if let task = running[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
            request.setValue("image/webp,image/jpeg,image/*", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400,
                  let image = UIImage(data: data) else { return nil }
            return await image.byPreparingForDisplay() ?? image
        }
        running[url] = task
        let image = await task.value
        running[url] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }
}

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        let shown = loadedURL == url ? image : url.flatMap { ImagePipeline.shared.cached($0) }
        ZStack {
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; loadedURL = nil; return }
            if let hit = ImagePipeline.shared.cached(url) {
                image = hit
                loadedURL = url
                return
            }
            let loaded = await ImagePipeline.shared.load(url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
                loadedURL = url
            }
        }
    }
}

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 36

    var body: some View {
        RemoteImage(url: url)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

struct Thumbnail: View {
    let video: Video
    var cornerRadius: CGFloat = 18

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { RemoteImage(url: video.bestThumbnail) }
            .overlay(alignment: .bottom) {
                if let progress = PositionStore.progress(video.id), progress > 0.02 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.35))
                            Rectangle().fill(Color.red).frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if video.isLive {
                    Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .glassEffect(.regular.tint(.red.opacity(0.8)), in: .capsule)
                        .padding(8)
                } else if let d = video.duration {
                    Text(d)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.35), in: .capsule)
                        .glassEffect(.regular, in: .capsule)
                        .padding(8)
                }
            }
    }
}

// MARK: - Cards

struct VideoCard: View {
    @EnvironmentObject private var player: PlayerModel
    let video: Video

    var body: some View {
        Button { player.play(video) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Thumbnail(video: video, cornerRadius: 22)
                HStack(alignment: .top, spacing: 12) {
                    if video.channelId != nil || video.channelAvatar != nil {
                        ChannelAvatarLink(video: video)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(video.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(video.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { VideoMenu(video: video) }
    }
}

struct ChannelAvatarLink: View {
    let video: Video

    var body: some View {
        if let id = video.channelId {
            NavigationLink(value: Route.channel(id)) {
                Avatar(url: video.channelAvatar, size: 36)
            }
            .buttonStyle(.plain)
        } else {
            Avatar(url: video.channelAvatar, size: 36)
        }
    }
}

struct VideoRow: View {
    @EnvironmentObject private var player: PlayerModel
    let video: Video
    var present = true
    var queue: [Video]? = nil

    var body: some View {
        Button {
            if let queue { player.play(video, queue: queue, present: present) } else { player.play(video, present: present) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Thumbnail(video: video, cornerRadius: 14)
                    .frame(width: 168)
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let c = video.channelName {
                        Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text([video.views, video.published].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { VideoMenu(video: video) }
    }
}

struct VideoMenu: View {
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var account: AccountStore
    let video: Video

    var body: some View {
        Section {
            Button("Abspielen", systemImage: "play.fill") { player.play(video) }
            Button("Im Mini-Player abspielen", systemImage: "pip") { player.play(video, present: false) }
            if player.current != nil, player.current?.id != video.id {
                Button("Als Nächstes abspielen", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    player.playNextInQueue(video)
                }
                Button("Zur Warteschlange", systemImage: "text.badge.plus") { player.addToQueue(video) }
            }
        }
        Section {
            if account.isSignedIn {
                Button("Später ansehen", systemImage: "clock") {
                    Task {
                        do {
                            try await YouTube.addToWatchLater(video.id)
                            Haptics.success()
                            player.showToast("Zu „Später ansehen“ hinzugefügt")
                        } catch {
                            Haptics.error()
                            player.showToast(error.localizedDescription)
                        }
                    }
                }
            }
            Button("Herunterladen …", systemImage: "arrow.down.circle") {
                YouTubeDownloads.shared.request = video
            }
            Button("Song auf Deezer suchen", systemImage: "music.note") {
                MusicSearchRequest.shared.search(video.title)
            }
        }
        Section {
            ShareLink(item: video.shareURL) { Label("Teilen", systemImage: "square.and.arrow.up") }
            Button("Link kopieren", systemImage: "link") {
                UIPasteboard.general.url = video.shareURL
                Haptics.success()
                player.showToast("Link kopiert")
            }
        }
    }
}

struct ShortCard: View {
    @EnvironmentObject private var player: PlayerModel
    let video: Video
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Color.clear
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay { RemoteImage(url: video.thumbnail ?? URL(string: "https://i.ytimg.com/vi/\(video.id)/oar2.jpg")) }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                        if let v = video.views {
                            Text(v).font(.caption2).opacity(0.85)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Als Short ansehen", systemImage: "bolt.horizontal.fill") { onTap() }
            VideoMenu(video: video)
        } preview: {
            RemoteImage(url: video.thumbnail ?? URL(string: "https://i.ytimg.com/vi/\(video.id)/oar2.jpg"))
                .frame(width: 270, height: 480)
        }
    }
}

struct ChannelRow: View {
    let channel: Channel

    var body: some View {
        NavigationLink(value: Route.channel(channel.id)) {
            HStack(spacing: 14) {
                Avatar(url: channel.avatar, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name).font(.headline).lineLimit(1)
                    Text([channel.handle, channel.subscribers].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .contextMenu {
            let url = URL(string: "https://www.youtube.com/channel/\(channel.id)")!
            ShareLink(item: url) { Label("Kanal teilen", systemImage: "square.and.arrow.up") }
            Button("Link kopieren", systemImage: "link") {
                UIPasteboard.general.url = url
                Haptics.success()
            }
        }
    }
}

struct PlaylistRow: View {
    @EnvironmentObject private var player: PlayerModel
    let playlist: Playlist

    var body: some View {
        Group {
            if playlist.isMix, let first = playlist.firstVideoId {
                Button { player.play(Video(id: first, title: "")) } label: { content }
            } else {
                NavigationLink(value: Route.playlist(playlist.id)) { content }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let first = playlist.firstVideoId {
                Button("Abspielen", systemImage: "play.fill") { player.play(Video(id: first, title: "")) }
            }
            let url = URL(string: "https://www.youtube.com/playlist?list=\(playlist.id)")!
            ShareLink(item: url) { Label("Playlist teilen", systemImage: "square.and.arrow.up") }
            Button("Link kopieren", systemImage: "link") {
                UIPasteboard.general.url = url
                Haptics.success()
                player.showToast("Link kopiert")
            }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { RemoteImage(url: playlist.thumbnail) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Label(playlist.videoCount ?? "Playlist", systemImage: playlist.isMix ? "dot.radiowaves.left.and.right" : "list.bullet")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                        .padding(6)
                }
                .frame(width: 168)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let c = playlist.channelName {
                    Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Feed

/// Renders a list of feed items; consecutive Shorts are grouped into a horizontal shelf.
/// On wide screens (landscape, iPad) videos are laid out in several columns.
struct FeedSections: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var shorts: ShortsModel
    let items: [FeedItem]
    var compact = false
    var playAsQueue = false
    var columns = 1

    private var queue: [Video]? {
        guard playAsQueue else { return nil }
        return items.compactMap { if case .video(let v) = $0 { return v } else { return nil } }
    }

    private enum Section: Identifiable {
        case item(FeedItem)
        case row([FeedItem])
        case shorts([Video])
        var id: String {
            switch self {
            case .item(let i): return i.id
            case .row(let r): return "row-" + (r.first?.id ?? "")
            case .shorts(let v): return "shelf-" + (v.first?.id ?? "")
            }
        }
    }

    private var sections: [Section] {
        var out: [Section] = []
        var shelf: [Video] = []
        var row: [FeedItem] = []
        func flushRow() {
            guard !row.isEmpty else { return }
            out.append(columns > 1 ? .row(row) : .item(row[0]))
            row = []
        }
        for item in items {
            if case .short(let v) = item {
                if !settings.hideShorts { shelf.append(v) }
                continue
            }
            if !shelf.isEmpty {
                flushRow()
                out.append(.shorts(shelf))
                shelf = []
            }
            if columns > 1, case .video = item {
                row.append(item)
                if row.count == columns { flushRow() }
            } else {
                flushRow()
                out.append(.item(item))
            }
        }
        flushRow()
        if !shelf.isEmpty { out.append(.shorts(shelf)) }
        return out
    }

    var body: some View {
        ForEach(sections) { section in
            switch section {
            case .item(let item):
                cell(item)
            case .row(let row):
                HStack(alignment: .top, spacing: compact ? 14 : 18) {
                    ForEach(row) { item in
                        cell(item).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    ForEach(row.count..<columns, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
            case .shorts(let videos):
                ShortsShelf(videos: videos) { v in shorts.open(v, from: videos) }
            }
        }
    }

    @ViewBuilder private func cell(_ item: FeedItem) -> some View {
        switch item {
        case .video(let v):
            if compact { VideoRow(video: v, queue: queue) } else { VideoCard(video: v) }
        case .channel(let c):
            ChannelRow(channel: c)
        case .playlist(let p):
            PlaylistRow(playlist: p)
        case .short:
            EmptyView()
        }
    }
}

struct ShortsShelf: View {
    let videos: [Video]
    var onTap: (Video) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Shorts", systemImage: "bolt.horizontal.fill")
                .font(.title3.weight(.bold))
                .symbolRenderingMode(.multicolor)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(videos) { v in
                        ShortCard(video: v) { onTap(v) }
                            .frame(width: 150)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}

struct FeedScroll<Header: View>: View {
    @ObservedObject var loader: FeedLoader
    var compact = false
    var emptyText = "Nichts gefunden"
    var playAsQueue = false
    @ViewBuilder var header: () -> Header
    @State private var width: CGFloat = 0

    /// Number of columns that fit the current width (1 on a portrait iPhone).
    private var columns: Int {
        let usable = width - 32
        guard usable > 0 else { return 1 }
        return compact ? (usable > 760 ? 2 : 1) : max(1, min(4, Int((usable + 18) / 340)))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: compact ? 14 : 24) {
                header()
                if loader.isLoading && loader.isEmpty {
                    ForEach(0..<4, id: \.self) { _ in SkeletonCard(compact: compact) }
                } else if let error = loader.error, loader.isEmpty {
                    ErrorState(message: error) { Task { await loader.load(force: true) } }
                } else if loader.isEmpty {
                    ContentUnavailableView(emptyText, systemImage: "play.slash")
                        .padding(.top, 60)
                } else {
                    FeedSections(items: loader.items, compact: compact, playAsQueue: playAsQueue, columns: columns)
                    if loader.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                            .task(id: loader.pageCount) { await loader.loadMore() }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .refreshable { await loader.load(force: true) }
        .task { await loader.load() }
    }
}

extension FeedScroll where Header == EmptyView {
    init(loader: FeedLoader, compact: Bool = false, emptyText: String = "Nichts gefunden") {
        self.init(loader: loader, compact: compact, emptyText: emptyText) { EmptyView() }
    }
}

struct SkeletonCard: View {
    var compact = false
    @State private var pulse = false

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 14).frame(width: 168, height: 94)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).frame(height: 12)
                        RoundedRectangle(cornerRadius: 4).frame(width: 100, height: 10)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 22).aspectRatio(16 / 9, contentMode: .fit)
                    HStack(spacing: 12) {
                        Circle().frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 4).frame(height: 12)
                            RoundedRectangle(cornerRadius: 4).frame(width: 140, height: 10)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.quaternary)
        .opacity(pulse ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(), value: pulse)
        .onAppear { pulse = true }
    }
}

struct ErrorState: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Erneut versuchen", systemImage: "arrow.clockwise", action: retry)
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

struct Chip: View {
    let title: String
    var systemImage: String?
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button {
            if !selected { Haptics.selection() }
            action()
        } label: {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

struct SignInPrompt: View {
    @State private var showLogin = false
    var title = "Melde dich an"
    var message = "Abos, Empfehlungen, Verlauf und Playlists – alles wie gewohnt, nur ohne Werbung."

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text(title).font(.title2.weight(.bold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showLogin = true
            } label: {
                Label("Mit Google anmelden", systemImage: "g.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .sheet(isPresented: $showLogin) { GoogleLoginView() }
    }
}

/// Avatar in the toolbar that opens "Du" (history, watch later, likes, playlists).
struct LibraryButton: View {
    @EnvironmentObject private var account: AccountStore

    var body: some View {
        NavigationLink(value: Route.library) {
            if let avatar = account.info?.avatar {
                Avatar(url: avatar, size: 30)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityLabel("Du – Bibliothek")
    }
}

// MARK: - Share sheet

/// Presents the system share sheet from anywhere (e.g. from confirmation dialogs,
/// where `ShareLink` isn't available).
@MainActor
enum ShareSheet {
    static func present(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController ?? scene.windows.first?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        Haptics.soft()
        // Wait for a dismissing dialog/menu to get out of the way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            var host = top
            while let presented = host.presentedViewController, !presented.isBeingDismissed { host = presented }
            host.present(controller, animated: true)
        }
    }
}
