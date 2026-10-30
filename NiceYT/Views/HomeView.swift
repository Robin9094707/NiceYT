import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: AppSettings
    @State private var topic: Topic = .forYou
    @StateObject private var loaders = HomeLoaders()
    @State private var showAccount = false

    enum Topic: String, CaseIterable, Identifiable {
        case forYou, music, gaming, news, sports, tech, movies, podcasts, comedy, learning
        var id: String { rawValue }
        var title: String {
            switch self {
            case .forYou: return "Für dich"
            case .music: return "Musik"
            case .gaming: return "Gaming"
            case .news: return "Nachrichten"
            case .sports: return "Sport"
            case .tech: return "Tech"
            case .movies: return "Filme & Trailer"
            case .podcasts: return "Podcasts"
            case .comedy: return "Comedy"
            case .learning: return "Wissen"
            }
        }
        var icon: String {
            switch self {
            case .forYou: return "sparkles"
            case .music: return "music.note"
            case .gaming: return "gamecontroller.fill"
            case .news: return "newspaper.fill"
            case .sports: return "sportscourt.fill"
            case .tech: return "cpu.fill"
            case .movies: return "film.fill"
            case .podcasts: return "mic.fill"
            case .comedy: return "theatermasks.fill"
            case .learning: return "graduationcap.fill"
            }
        }
        var query: String {
            switch self {
            case .forYou: return ""
            case .music: return "Musik neu"
            case .gaming: return "Gaming"
            case .news: return "Nachrichten heute"
            case .sports: return "Sport Highlights"
            case .tech: return "Tech Review"
            case .movies: return "Trailer"
            case .podcasts: return "Podcast"
            case .comedy: return "Comedy"
            case .learning: return "Wissen Doku"
            }
        }
    }

    var body: some View {
        NavigationStack {
            FeedScroll(loader: loaders.loader(for: topic)) {
                VStack(alignment: .leading, spacing: 16) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                ForEach(Topic.allCases) { t in
                                    Chip(title: t.title, systemImage: t.icon, selected: t == topic) {
                                        withAnimation(.snappy) { topic = t }
                                    }
                                }
                            }
                        }
                    }
                    .scrollClipDisabled()
                    if !account.isSignedIn && topic == .forYou {
                        SignInPrompt()
                    }
                }
            }
            .id("\(topic.rawValue)-\(loaders.generation)")
            .navigationTitle("NicePlay")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .symbolEffect(.bounce, value: topic)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAccount = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Einstellungen")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { BrowserModel.shared.open(nil) } label: { Image(systemName: "arrow.down.app") }
                        .accessibilityLabel("Downloader & Browser")
                }
                ToolbarItem(placement: .topBarTrailing) { LibraryButton() }
            }
            .sheet(isPresented: $showAccount) { SettingsView() }
            .withRoutes()
        }
        .onChange(of: account.isSignedIn) { loaders.reset() }
        .onChange(of: settings.language) { loaders.reset() }
        .onChange(of: settings.region) { loaders.reset() }
    }
}

@MainActor
final class HomeLoaders: ObservableObject {
    private var cache: [HomeView.Topic: FeedLoader] = [:]
    @Published private(set) var generation = 0

    func loader(for topic: HomeView.Topic) -> FeedLoader {
        if let l = cache[topic] { return l }
        let l: FeedLoader
        if topic == .forYou {
            l = FeedLoader(first: {
                let page = try await YouTube.home()
                if page.items.isEmpty { return try await YouTube.explore("Trends") }
                return page
            }, more: { token in
                // Home continuations are browse; the signed-out fallback uses search.
                if let p = try? await YouTube.browseMore(token), !p.items.isEmpty { return p }
                return try await YouTube.searchMore(token)
            })
        } else {
            let q = topic.query
            l = FeedLoader(first: { try await YouTube.explore(q) }, more: YouTube.searchMore)
        }
        cache[topic] = l
        return l
    }

    func reset() {
        cache = [:]
        generation += 1
    }
}

struct BrowseFeedView: View {
    let title: String
    @StateObject private var loader: FeedLoader

    init(title: String, browseId: String, params: String? = nil) {
        self.title = title
        _loader = StateObject(wrappedValue: FeedLoader(first: { try await YouTube.browse(browseId, params: params) }))
    }

    var body: some View {
        FeedScroll(loader: loader, compact: true)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
    }
}
