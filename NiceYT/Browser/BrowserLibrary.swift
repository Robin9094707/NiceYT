import SwiftUI

struct Bookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
    /// Shown as a tile on the start page.
    var isFavorite = false
    var date = Date()
}

struct HistoryEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
    var date: Date
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckDuckGo, bing, ecosia, startpage, brave

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .ecosia: return "Ecosia"
        case .startpage: return "Startpage"
        case .brave: return "Brave Search"
        }
    }

    func url(for query: String) -> URL? {
        let base: String
        switch self {
        case .google: base = "https://www.google.com/search"
        case .duckDuckGo: base = "https://duckduckgo.com/"
        case .bing: base = "https://www.bing.com/search"
        case .ecosia: base = "https://www.ecosia.org/search"
        case .startpage: base = "https://www.startpage.com/do/search"
        case .brave: base = "https://search.brave.com/search"
        }
        var c = URLComponents(string: base)
        c?.queryItems = [.init(name: "q", value: query)]
        return c?.url
    }

    /// OpenSearch suggestion endpoint (["query", ["s1", "s2" …]]).
    func suggestionsURL(for query: String) -> URL? {
        var c: URLComponents?
        switch self {
        case .duckDuckGo:
            c = URLComponents(string: "https://duckduckgo.com/ac/")
            c?.queryItems = [.init(name: "q", value: query), .init(name: "type", value: "list")]
        case .bing:
            c = URLComponents(string: "https://api.bing.com/osjson.aspx")
            c?.queryItems = [.init(name: "query", value: query)]
        default:
            c = URLComponents(string: "https://suggestqueries.google.com/complete/search")
            c?.queryItems = [.init(name: "client", value: "firefox"), .init(name: "hl", value: AppSettings.hl),
                             .init(name: "q", value: query)]
        }
        return c?.url
    }

    /// The query of a results page of this engine (shown instead of the long URL).
    func query(in url: URL) -> String? {
        guard let host = url.host?.lowercased(), let name = host.split(separator: ".").dropLast().last,
              ["google", "duckduckgo", "bing", "ecosia", "startpage", "brave"].contains(String(name)) || host.hasPrefix("search.brave")
        else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" || $0.name == "query" }?.value
    }
}

/// Where the address bar sits.
enum BarPosition: String, CaseIterable, Identifiable {
    case top, bottom
    var id: String { rawValue }
    var label: String { self == .top ? "Oben" : "Unten" }
}

/// Bookmarks, history and browser preferences (persisted on the device).
@MainActor
final class BrowserLibrary: ObservableObject {
    static let shared = BrowserLibrary()
    private let d = UserDefaults.standard

    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var history: [HistoryEntry] = []

    @Published var searchEngine: SearchEngine { didSet { d.set(searchEngine.rawValue, forKey: "searchEngine") } }
    @Published var barPosition: BarPosition { didSet { d.set(barPosition.rawValue, forKey: "barPosition") } }
    @Published var adBlock: Bool { didSet { d.set(adBlock, forKey: "adBlock"); BrowserModel.shared.updateContentBlocking() } }
    /// Sites on which the ad blocker is switched off.
    @Published var adBlockExceptions: Set<String> {
        didSet { d.set(Array(adBlockExceptions), forKey: "adBlockExceptions"); BrowserModel.shared.updateContentBlocking() }
    }
    /// Small download button on every video and audio player of a page.
    @Published var mediaButtons: Bool { didSet { d.set(mediaButtons, forKey: "mediaButtons"); BrowserModel.shared.updateUserScripts() } }
    /// Removes "open in app" banners and similar clutter on social sites.
    @Published var cleanSocial: Bool { didSet { d.set(cleanSocial, forKey: "cleanSocial"); BrowserModel.shared.updateUserScripts() } }
    @Published var downloadTarget: DownloadTarget { didSet { d.set(downloadTarget.rawValue, forKey: "downloadTarget") } }
    /// The assistant starts the best option right away (shared links, pasted links).
    @Published var quickDownload: Bool { didSet { d.set(quickDownload, forKey: "quickDownload") } }
    @Published var lockWithFaceID: Bool { didSet { d.set(lockWithFaceID, forKey: "browserLock") } }
    /// Restore the open tabs when the app starts again.
    @Published var restoreTabs: Bool { didSet { d.set(restoreTabs, forKey: "restoreTabs") } }

    private var saveTask: Task<Void, Never>?

    private static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Browser", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }
    private static var bookmarksURL: URL { folder.appendingPathComponent("bookmarks.json") }
    private static var historyURL: URL { folder.appendingPathComponent("history.json") }

    static let defaultFavorites: [(String, String)] = [
        ("TikTok", "https://www.tiktok.com"),
        ("Instagram", "https://www.instagram.com"),
        ("Facebook", "https://m.facebook.com"),
        ("X", "https://x.com"),
        ("Reddit", "https://www.reddit.com"),
        ("Wikipedia", "https://de.wikipedia.org"),
        ("Google", "https://www.google.com"),
        ("Vimeo", "https://vimeo.com")
    ]

    private init() {
        d.register(defaults: [
            "searchEngine": SearchEngine.google.rawValue,
            "barPosition": BarPosition.top.rawValue,
            "adBlock": true,
            "mediaButtons": true,
            "cleanSocial": true,
            "downloadTarget": DownloadTarget.library.rawValue,
            "quickDownload": true,
            "browserLock": false,
            "restoreTabs": true
        ])
        searchEngine = SearchEngine(rawValue: d.string(forKey: "searchEngine") ?? "") ?? .google
        barPosition = BarPosition(rawValue: d.string(forKey: "barPosition") ?? "") ?? .top
        adBlock = d.bool(forKey: "adBlock")
        adBlockExceptions = Set(d.stringArray(forKey: "adBlockExceptions") ?? [])
        mediaButtons = d.bool(forKey: "mediaButtons")
        cleanSocial = d.bool(forKey: "cleanSocial")
        downloadTarget = DownloadTarget(rawValue: d.string(forKey: "downloadTarget") ?? "") ?? .library
        quickDownload = d.bool(forKey: "quickDownload")
        lockWithFaceID = d.bool(forKey: "browserLock")
        restoreTabs = d.bool(forKey: "restoreTabs")

        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: Self.bookmarksURL), let list = try? decoder.decode([Bookmark].self, from: data) {
            bookmarks = list
        } else if !d.bool(forKey: "favoritesSeeded") {
            bookmarks = Self.defaultFavorites.compactMap { name, link in
                URL(string: link).map { Bookmark(title: name, url: $0, isFavorite: true) }
            }
            d.set(true, forKey: "favoritesSeeded")
            writeBookmarks()
        }
        if let data = try? Data(contentsOf: Self.historyURL), let list = try? decoder.decode([HistoryEntry].self, from: data) {
            history = list
        }
    }

    // MARK: Bookmarks

    var favorites: [Bookmark] { bookmarks.filter(\.isFavorite) }

    func bookmark(for url: URL?) -> Bookmark? {
        guard let url else { return nil }
        return bookmarks.first { Self.same($0.url, url) }
    }

    func addBookmark(title: String, url: URL, favorite: Bool = false) {
        if let i = bookmarks.firstIndex(where: { Self.same($0.url, url) }) {
            bookmarks[i].isFavorite = bookmarks[i].isFavorite || favorite
        } else {
            bookmarks.insert(Bookmark(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url, isFavorite: favorite), at: 0)
        }
        writeBookmarks()
        Haptics.success()
    }

    func update(_ bookmark: Bookmark) {
        guard let i = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[i] = bookmark
        writeBookmarks()
    }

    func toggleFavorite(_ id: UUID) {
        guard let i = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[i].isFavorite.toggle()
        writeBookmarks()
        Haptics.selection()
    }

    func deleteBookmark(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        writeBookmarks()
    }

    func moveBookmarks(from source: IndexSet, to destination: Int) {
        bookmarks.move(fromOffsets: source, toOffset: destination)
        writeBookmarks()
    }

    private func writeBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) { try? data.write(to: Self.bookmarksURL, options: .atomic) }
    }

    // MARK: History

    func record(_ url: URL, title: String) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if let first = history.first, Self.same(first.url, url), Date().timeIntervalSince(first.date) < 1800 {
            history[0].date = Date()
            if !title.isEmpty { history[0].title = title }
        } else {
            history.insert(HistoryEntry(title: title, url: url, date: Date()), at: 0)
            if history.count > 5000 { history.removeLast(history.count - 5000) }
        }
        scheduleSave()
    }

    /// Titles often arrive after the navigation finished.
    func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty, let i = history.prefix(5).firstIndex(where: { Self.same($0.url, url) }),
              history[i].title != title else { return }
        history[i].title = title
        scheduleSave()
    }

    func deleteHistory(_ ids: Set<UUID>) {
        history.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    /// Removes the history since `date` (everything for nil).
    func clearHistory(since date: Date? = nil) {
        if let date { history.removeAll { $0.date >= date } } else { history = [] }
        scheduleSave()
        Haptics.warning()
    }

    func clearAll() {
        history = []
        bookmarks = []
        try? FileManager.default.removeItem(at: Self.folder)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let list = history
            let url = Self.historyURL
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
            }.value
        }
    }

    // MARK: Suggestions

    struct Suggestion: Identifiable, Hashable {
        let title: String
        let url: URL
        let isBookmark: Bool
        var id: String { url.absoluteString }
    }

    /// Bookmarks and visited pages matching what's being typed.
    func suggestions(for text: String, limit: Int = 5) -> [Suggestion] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 1 else { return [] }
        var seen = Set<String>()
        var out: [Suggestion] = []
        func matches(_ title: String, _ url: URL) -> Bool {
            title.lowercased().contains(q) || url.absoluteString.lowercased().replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "www.", with: "").hasPrefix(q) || (url.host?.lowercased().contains(q) ?? false)
        }
        for b in bookmarks where matches(b.title, b.url) && seen.insert(Self.key(b.url)).inserted {
            out.append(Suggestion(title: b.title, url: b.url, isBookmark: true))
            if out.count >= limit { return out }
        }
        for h in history where matches(h.title, h.url) && seen.insert(Self.key(h.url)).inserted {
            out.append(Suggestion(title: h.title.isEmpty ? (h.url.host ?? "") : h.title, url: h.url, isBookmark: false))
            if out.count >= limit { break }
        }
        return out
    }

    /// Most visited sites of the last weeks (start page).
    func frequentSites(limit: Int = 8) -> [Suggestion] {
        var counts: [String: (count: Int, entry: HistoryEntry)] = [:]
        let since = Date().addingTimeInterval(-60 * 60 * 24 * 30)
        for h in history where h.date > since {
            guard let host = h.url.host?.replacingOccurrences(of: "www.", with: "") else { continue }
            if let existing = counts[host] {
                counts[host] = (existing.count + 1, existing.entry)
            } else {
                counts[host] = (1, h)
            }
        }
        let favoriteHosts = Set(favorites.compactMap { $0.url.host?.replacingOccurrences(of: "www.", with: "") })
        return counts.filter { !favoriteHosts.contains($0.key) && $0.value.count > 1 }
            .sorted { $0.value.count > $1.value.count }
            .prefix(limit)
            .compactMap { host, value in
                let root = URL(string: "\(value.entry.url.scheme ?? "https")://\(value.entry.url.host ?? host)") ?? value.entry.url
                return Suggestion(title: host, url: root, isBookmark: false)
            }
    }

    static func key(_ url: URL) -> String {
        var s = url.absoluteString.lowercased()
        for prefix in ["https://", "http://", "www."] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func same(_ a: URL, _ b: URL) -> Bool { key(a) == key(b) }

    /// Small site icon (Google's favicon service).
    static func favicon(for url: URL?) -> URL? {
        guard let host = url?.host else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128")
    }
}
