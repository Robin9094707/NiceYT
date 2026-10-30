import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: PlayerModel
    @State private var text = ""
    @State private var submitted = ""
    @State private var filter: SearchFilter = .all
    @State private var suggestions: [String] = []
    @State private var history: [String] = UserDefaults.standard.stringArray(forKey: "searchHistory") ?? []
    @State private var loader: FeedLoader?

    var body: some View {
        NavigationStack {
            Group {
                if let loader, !submitted.isEmpty, text == submitted {
                    FeedScroll(loader: loader, compact: true) { filterBar }
                        .id(submitted + filter.rawValue)
                } else {
                    suggestionList
                }
            }
            .navigationTitle("Suche")
            .searchable(text: $text, prompt: "YouTube durchsuchen")
            .onSubmit(of: .search) { submit(text) }
            .task(id: text) {
                guard !text.isEmpty, text != submitted else { suggestions = []; return }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                suggestions = await YouTube.suggestions(text)
            }
            .withRoutes()
        }
        .onAppear {
            // The history may have been cleared in the settings.
            history = UserDefaults.standard.stringArray(forKey: "searchHistory") ?? []
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(SearchFilter.allCases) { f in
                        Chip(title: f.label, selected: f == filter) {
                            filter = f
                            run()
                        }
                    }
                }
            }
        }
        .scrollClipDisabled()
    }

    private var suggestionList: some View {
        List {
            if text.isEmpty {
                if !history.isEmpty {
                    Section {
                        ForEach(history, id: \.self) { h in
                            Button { submit(h) } label: {
                                Label(h, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                            }
                        }
                        .onDelete { idx in
                            history.remove(atOffsets: idx)
                            UserDefaults.standard.set(history, forKey: "searchHistory")
                        }
                    } header: {
                        HStack {
                            Text("Zuletzt gesucht")
                            Spacer()
                            Button("Löschen") {
                                history = []
                                UserDefaults.standard.set(history, forKey: "searchHistory")
                            }
                            .font(.caption)
                        }
                    }
                } else {
                    ContentUnavailableView("Suche nach Videos, Kanälen und Playlists",
                                           systemImage: "magnifyingglass",
                                           description: Text("Werbefrei – mit SponsorBlock und Dislikes."))
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(suggestions, id: \.self) { s in
                    Button { submit(s) } label: {
                        HStack {
                            Label(s, systemImage: "magnifyingglass").foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.left").foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func submit(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if let id = YouTubeLink.videoId(from: q) {
            player.play(Video(id: id, title: ""))
            return
        }
        // Any other link: Deezer into music, everything else into the browser/downloader.
        if let url = BrowserModel.url(from: q), q.contains("/") || q.hasPrefix("http") {
            LinkRouter.shared.open(url)
            return
        }
        text = q
        submitted = q
        history.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        history.insert(q, at: 0)
        history = Array(history.prefix(30))
        UserDefaults.standard.set(history, forKey: "searchHistory")
        run()
    }

    private func run() {
        let q = submitted, f = filter
        loader = FeedLoader(first: { try await YouTube.search(q, filter: f) }, more: YouTube.searchMore)
    }
}
