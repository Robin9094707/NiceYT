import SwiftUI
import UIKit
import WebKit

/// Something downloadable the browser found on a page.
struct MediaItem: Identifiable, Hashable {
    let url: URL
    var kind: MediaKind
    var label: String?
    var hidden = false
    var id: String { url.absoluteString }

    var displayName: String {
        let last = url.lastPathComponent
        if let label, !label.isEmpty, label.count < 60 { return label }
        return last.isEmpty || last == "/" ? (url.host ?? url.absoluteString) : last
    }
}

/// The media element that is playing with sound on the page (for "save what's playing").
struct PlayingMedia: Equatable {
    let url: URL?
    let kind: MediaKind
    let title: String
    let poster: URL?
    let link: URL?
}

// MARK: - Tab

/// One browser tab: its own web view (normal tabs share cookies and logins, private tabs
/// share a separate in-memory store) plus the state the toolbar shows.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id: UUID
    let isPrivate: Bool
    let webView: WKWebView
    @Published fileprivate(set) var title = ""
    @Published fileprivate(set) var url: URL?
    @Published fileprivate(set) var progress: Double = 0
    @Published fileprivate(set) var isLoading = false
    @Published fileprivate(set) var canGoBack = false
    @Published fileprivate(set) var canGoForward = false
    @Published fileprivate(set) var desktopMode = false
    @Published fileprivate(set) var zoom: Double = 1
    @Published var media: [MediaItem] = []
    @Published var playing: PlayingMedia?
    @Published var showStart = true
    @Published var snapshot: UIImage?
    @Published var loadError: String?
    /// Opens the download assistant as soon as media is found (links opened "to download").
    var autoShowMedia = false
    /// Last time the tab was shown or navigated (automatic closing).
    var lastActive = Date()
    /// State of a tab restored from the last session; loaded when the tab is shown.
    fileprivate var pendingRestore: (url: URL, state: Data?)?
    private var observers: [NSKeyValueObservation] = []

    var userAgent: String { desktopMode ? BrowserModel.desktopUA : BrowserModel.mobileUA }
    var host: String? { url?.host?.replacingOccurrences(of: "www.", with: "") }
    var isBlank: Bool { showStart && url == nil && pendingRestore == nil }

    fileprivate init(id: UUID = UUID(), configuration: WKWebViewConfiguration, isPrivate: Bool, delegate: BrowserModel) {
        self.id = id
        self.isPrivate = isPrivate
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        let web = webView
        web.customUserAgent = BrowserModel.mobileUA
        web.navigationDelegate = delegate
        web.uiDelegate = delegate
        web.allowsBackForwardNavigationGestures = true
        web.allowsLinkPreview = true
        web.isInspectable = true
        web.isFindInteractionEnabled = true
        web.scrollView.keyboardDismissMode = .interactive
        web.backgroundColor = .systemBackground
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pulledToRefresh(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        observers = [
            web.observe(\.estimatedProgress) { [weak self] w, _ in MainActor.assumeIsolated { self?.progress = w.estimatedProgress } },
            web.observe(\.isLoading) { [weak self] w, _ in MainActor.assumeIsolated { self?.isLoading = w.isLoading } },
            web.observe(\.canGoBack) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoBack = w.canGoBack } },
            web.observe(\.canGoForward) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoForward = w.canGoForward } },
            web.observe(\.title) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let t = w.title ?? ""
                    guard t != self.title, !t.isEmpty || self.url == nil else { return }
                    self.title = t
                    if !self.isPrivate, let u = w.url { BrowserLibrary.shared.updateTitle(t, for: u) }
                }
            },
            web.observe(\.url) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self, let u = w.url, u != self.url else { return }
                    if u.host != self.url?.host || u.path != self.url?.path {
                        self.media = []
                        self.playing = nil
                    }
                    self.url = u
                }
            }
        ]
    }

    @objc private func pulledToRefresh(_ control: UIRefreshControl) {
        webView.reload()
        Haptics.tap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { control.endRefreshing() }
    }

    func load(_ url: URL) {
        pendingRestore = nil
        showStart = false
        loadError = nil
        media = []
        webView.load(URLRequest(url: url))
    }

    fileprivate func restore(url: URL, title: String, state: Data?, lastActive: Date?) {
        pendingRestore = (url, state)
        if let lastActive { self.lastActive = lastActive }
        self.url = url
        self.title = title
        showStart = false
    }

    /// Loads a restored tab the first time it's shown.
    func activate() {
        guard let restore = pendingRestore else { return }
        pendingRestore = nil
        showStart = false
        if let state = restore.state {
            webView.interactionState = state
            if webView.url == nil { webView.load(URLRequest(url: restore.url)) }
        } else {
            webView.load(URLRequest(url: restore.url))
        }
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() } else if !showStart { showStart = true }
    }

    func goForward() {
        if showStart, webView.url != nil { showStart = false } else { webView.goForward() }
    }

    func reload() {
        if isLoading { webView.stopLoading() } else if webView.url != nil { loadError = nil; webView.reload() }
    }

    func setDesktop(_ on: Bool) {
        desktopMode = on
        webView.customUserAgent = userAgent
        webView.reload()
        Haptics.selection()
    }

    func setZoom(_ value: Double) {
        zoom = value
        webView.pageZoom = value
        Haptics.selection()
    }

    func findInPage() {
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    /// Runs the media detector once more (e.g. after the video started playing).
    func rescan() {
        webView.evaluateJavaScript("window.__niceScan && window.__niceScan()")
    }

    func takeSnapshot() {
        guard !showStart, webView.window != nil, webView.bounds.width > 0 else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: 360)
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                if let image { self?.snapshot = image }
            }
        }
    }

    fileprivate func tearDown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        observers = []
        webView.removeFromSuperview()
    }
}

// MARK: - Browser

/// The full browser: tabs (normal and private), one shared cookie store for normal tabs,
/// ad blocking, a media detector (players, network requests, URLs hidden in page data),
/// download buttons on players and WebKit downloads.
@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    static let shared = BrowserModel()
    static let storeId = UUID(uuidString: "9B0F6C1E-2A4D-4E7B-8C3F-5D6E7F8A9B01")!
    nonisolated static let mobileUA = UserAgents.mobile
    nonisolated static let desktopUA = UserAgents.desktop
    static let dataStore = WKWebsiteDataStore(forIdentifier: storeId)

    @Published var isPresented = false {
        didSet {
            if isPresented {
                closeStaleTabs()
                current.activate()
                current.lastActive = Date()
            } else {
                current.lastActive = Date()
                saveTabs()
            }
        }
    }
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var selectedID: UUID?
    @Published var showTabs = false
    /// Bumped when a fresh tab wants the keyboard in its address bar.
    @Published private(set) var focusRequest = 0
    /// Media opened in the native player sheet.
    @Published var nativeMedia: NativeMediaItem?

    private let content = WKUserContentController()
    private var privateStore: WKWebsiteDataStore?
    private var downloads: [ObjectIdentifier: (temp: URL, name: String, source: URL?, page: URL?, job: String)] = [:]
    private var downloadObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var saveTask: Task<Void, Never>?

    private override init() {
        super.init()
        content.add(self, name: "niceMedia")
        content.add(self, name: "novaAction")
        updateUserScripts()
        updateContentBlocking()
        restoreTabs()
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BrowserModel.shared.saveTabs() }
        }
    }

    /// The selected tab (there is always at least one).
    var current: BrowserTab {
        if let t = tabs.first(where: { $0.id == selectedID }) { return t }
        if let last = tabs.last { return last }
        let tab = makeTab(isPrivate: false)
        tabs = [tab]
        selectedID = tab.id
        return tab
    }

    var normalTabs: [BrowserTab] { tabs.filter { !$0.isPrivate } }
    var privateTabs: [BrowserTab] { tabs.filter(\.isPrivate) }

    func tab(for webView: WKWebView) -> BrowserTab? { tabs.first { $0.webView === webView } }

    func store(isPrivate: Bool) -> WKWebsiteDataStore {
        guard isPrivate else { return Self.dataStore }
        if let privateStore { return privateStore }
        let store = WKWebsiteDataStore.nonPersistent()
        privateStore = store
        return store
    }

    private func configuration(isPrivate: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.websiteDataStore = store(isPrivate: isPrivate)
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio]
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        return config
    }

    private func makeTab(isPrivate: Bool, configuration: WKWebViewConfiguration? = nil, id: UUID = UUID()) -> BrowserTab {
        BrowserTab(id: id, configuration: configuration ?? self.configuration(isPrivate: isPrivate), isPrivate: isPrivate, delegate: self)
    }

    // MARK: Tabs

    func open(_ url: URL?, findMedia: Bool = false, isPrivate: Bool = false) {
        isPresented = true
        guard let url else { return }
        let tab = current.isBlank && current.isPrivate == isPrivate ? current : newTab(isPrivate: isPrivate)
        tab.autoShowMedia = findMedia
        tab.load(url)
        select(tab)
    }

    @discardableResult
    func newTab(_ url: URL? = nil, isPrivate: Bool = false, select shouldSelect: Bool = true,
                configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = makeTab(isPrivate: isPrivate, configuration: configuration)
        if let i = tabs.firstIndex(where: { $0.id == selectedID }) {
            tabs.insert(tab, at: i + 1)
        } else {
            tabs.append(tab)
        }
        if let url { tab.load(url) }
        if shouldSelect { select(tab) }
        if url == nil, configuration == nil, shouldSelect { focusRequest += 1 }
        scheduleTabSave()
        return tab
    }

    func select(_ tab: BrowserTab) {
        if selectedID != tab.id {
            current.takeSnapshot()
            current.lastActive = Date()
        }
        selectedID = tab.id
        tab.lastActive = Date()
        tab.activate()
    }

    /// Closes tabs that weren't used within the chosen time (never the selected one).
    func closeStaleTabs() {
        guard let limit = BrowserLibrary.shared.tabLifetime.seconds else { return }
        let stale = tabs.filter { $0.id != selectedID && Date().timeIntervalSince($0.lastActive) > limit }
        guard !stale.isEmpty else { return }
        for tab in stale { tab.tearDown() }
        let ids = Set(stale.map(\.id))
        tabs.removeAll { ids.contains($0.id) }
        if privateTabs.isEmpty { privateStore = nil }
        DebugLog.log("Browser: \(stale.count) unbenutzte Tabs geschlossen")
        scheduleTabSave()
    }

    func close(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.tearDown()
        tabs.remove(at: i)
        if selectedID == tab.id {
            let sameKind = tabs.filter { $0.isPrivate == tab.isPrivate }
            let next = sameKind.last(where: { tabs.firstIndex(of: $0) ?? 0 < i }) ?? sameKind.first ?? tabs.last
            selectedID = next?.id
        }
        if tabs.isEmpty {
            let fresh = makeTab(isPrivate: false)
            tabs = [fresh]
            selectedID = fresh.id
        }
        if privateTabs.isEmpty { privateStore = nil }
        Haptics.tap()
        scheduleTabSave()
    }

    /// Closes all tabs of one kind (or all of them).
    func closeAllTabs(isPrivate: Bool? = nil) {
        for tab in tabs where isPrivate == nil || tab.isPrivate == isPrivate { tab.tearDown() }
        tabs.removeAll { isPrivate == nil || $0.isPrivate == isPrivate }
        if tabs.isEmpty {
            let fresh = makeTab(isPrivate: false)
            tabs = [fresh]
        }
        if !tabs.contains(where: { $0.id == selectedID }) { selectedID = tabs.last?.id }
        if privateTabs.isEmpty { privateStore = nil }
        scheduleTabSave()
    }

    func moveTab(_ tab: BrowserTab, before other: BrowserTab) {
        guard let from = tabs.firstIndex(of: tab), let to = tabs.firstIndex(of: other), from != to else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: tabs.firstIndex(of: other) ?? to)
        scheduleTabSave()
    }

    func showTabOverview() {
        current.takeSnapshot()
        Haptics.soft()
        // The snapshot is taken asynchronously; give it a moment before the overview covers the page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.showTabs = true }
    }

    /// Address bar input: URL or web search.
    func submit(_ text: String, in tab: BrowserTab) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let url = Self.url(from: t) ?? BrowserLibrary.shared.searchEngine.url(for: t) { tab.load(url) }
    }

    static func url(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: t) }
        if lower.hasPrefix("about:") { return URL(string: t) }
        if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t), let host = u.host, host.contains("."),
           let tld = host.split(separator: ".").last, tld.count >= 2, tld.allSatisfy(\.isLetter) {
            return u
        }
        if lower.hasPrefix("localhost") { return URL(string: "http://" + t) }
        return nil
    }

    /// Opens the download assistant for what's on the tab right now.
    func openAssistant(for tab: BrowserTab) {
        guard let url = tab.url, !tab.showStart else { return }
        Haptics.impact()
        DownloadAssistant.shared.start(url, pageMedia: tab.media, page: url, userAgent: tab.userAgent, isPrivate: tab.isPrivate,
                                       autoStart: false)
    }

    func presentNative(_ url: URL, kind: MediaKind, title: String, poster: URL?, tab: BrowserTab?) {
        Haptics.soft()
        nativeMedia = NativeMediaItem(url: url, kind: kind, title: title, poster: poster, page: tab?.url,
                                      userAgent: tab?.userAgent ?? Self.mobileUA, isPrivate: tab?.isPrivate ?? false)
    }

    // MARK: Scripts & blocking

    func updateUserScripts() {
        content.removeAllUserScripts()
        let flags = "window.__novaButtons = \(BrowserLibrary.shared.mediaButtons);"
        content.addUserScript(WKUserScript(source: flags, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        content.addUserScript(WKUserScript(source: Self.sniffer, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    func updateContentBlocking() {
        let enabled = BrowserLibrary.shared.adBlock
        let exceptions = BrowserLibrary.shared.adBlockExceptions
        Task {
            let list = enabled ? await ContentBlocker.ruleList(exceptions: exceptions) : nil
            content.removeAllContentRuleLists()
            if let list { content.add(list) }
        }
    }

    func isAdBlockActive(on tab: BrowserTab) -> Bool {
        guard BrowserLibrary.shared.adBlock else { return false }
        guard let site = ContentBlocker.site(of: tab.url) else { return true }
        return !BrowserLibrary.shared.adBlockExceptions.contains(site)
    }

    func toggleAdBlock(on tab: BrowserTab) {
        let lib = BrowserLibrary.shared
        guard let site = ContentBlocker.site(of: tab.url) else { return }
        if !lib.adBlock {
            lib.adBlock = true
            lib.adBlockExceptions.remove(site)
        } else if lib.adBlockExceptions.contains(site) {
            lib.adBlockExceptions.remove(site)
        } else {
            lib.adBlockExceptions.insert(site)
        }
        Haptics.selection()
        // The new rules apply after compiling; reload once they're in place.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            tab.webView.reload()
        }
    }

    // MARK: Requests outside the web view

    /// Headers to fetch `url` like the page would: its cookies, referer, user agent.
    static func requestHeaders(for url: URL, page: URL?, userAgent: String, isPrivate: Bool = false) async -> [String: String] {
        let cookies = await shared.store(isPrivate: isPrivate).httpCookieStore.allCookies()
        let host = url.host?.lowercased() ?? ""
        let matching = cookies.filter { c in
            let domain = c.domain.lowercased().hasPrefix(".") ? String(c.domain.lowercased().dropFirst()) : c.domain.lowercased()
            return host == domain || host.hasSuffix("." + domain)
        }
        var headers = HTTPCookie.requestHeaderFields(with: matching)
        headers["User-Agent"] = userAgent
        if let page {
            headers["Referer"] = page.absoluteString
            if let scheme = page.scheme, let h = page.host { headers["Origin"] = "\(scheme)://\(h)" }
        }
        return headers
    }

    /// All cookies of a site (for extractors that call the site's API).
    static func cookies(for host: String, isPrivate: Bool = false) async -> [HTTPCookie] {
        let all = await shared.store(isPrivate: isPrivate).httpCookieStore.allCookies()
        let h = host.lowercased()
        return all.filter { c in
            let domain = c.domain.lowercased().hasPrefix(".") ? String(c.domain.lowercased().dropFirst()) : c.domain.lowercased()
            return h == domain || h.hasSuffix("." + domain) || domain.hasSuffix("." + h)
        }
    }

    // MARK: Persisting tabs

    private struct StoredTab: Codable {
        let id: UUID
        let url: URL
        let title: String
        let state: Data?
        var lastActive: Date?
    }

    private struct StoredSession: Codable {
        let tabs: [StoredTab]
        let selected: UUID?
    }

    private static var sessionURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Browser", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tabs.json")
    }

    private func restoreTabs() {
        if BrowserLibrary.shared.restoreTabs, let data = try? Data(contentsOf: Self.sessionURL),
           let session = try? JSONDecoder().decode(StoredSession.self, from: data) {
            for stored in session.tabs {
                let tab = makeTab(isPrivate: false, id: stored.id)
                tab.restore(url: stored.url, title: stored.title, state: stored.state, lastActive: stored.lastActive)
                tabs.append(tab)
            }
            selectedID = session.selected.flatMap { id in tabs.first { $0.id == id }?.id } ?? tabs.last?.id
        }
        if tabs.isEmpty {
            let tab = makeTab(isPrivate: false)
            tabs = [tab]
            selectedID = tab.id
        }
    }

    private func scheduleTabSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveTabs()
        }
    }

    func saveTabs() {
        guard BrowserLibrary.shared.restoreTabs else {
            try? FileManager.default.removeItem(at: Self.sessionURL)
            return
        }
        let stored: [StoredTab] = normalTabs.compactMap { tab in
            guard let url = tab.pendingRestore?.url ?? tab.webView.url ?? tab.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !tab.showStart || tab.pendingRestore != nil else { return nil }
            let state = tab.pendingRestore?.state ?? (tab.webView.interactionState as? Data)
            return StoredTab(id: tab.id, url: url, title: tab.title, state: state, lastActive: tab.lastActive)
        }
        let selected = current.isPrivate ? stored.last?.id : selectedID
        if let data = try? JSONEncoder().encode(StoredSession(tabs: stored, selected: selected)) {
            try? data.write(to: Self.sessionURL, options: .atomic)
        }
    }

    // MARK: Media messages

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, let web = message.webView, let tab = tab(for: web) else { return }
        let j = JSON(data: Data(text.utf8))
        if message.name == "novaAction" {
            handleAction(j, tab: tab)
            return
        }
        var added = false
        for entry in j["items"].array {
            guard let raw = entry["u"].string, var url = URL(string: raw) else { continue }
            let hint = entry["k"].string ?? ""
            var label = entry["l"].string
            // Facebook/Instagram DASH pieces: without the byte range it's the whole track.
            if url.query?.contains("bytestart=") == true, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                c.queryItems = c.queryItems?.filter { $0.name != "bytestart" && $0.name != "byteend" }
                url = c.url ?? url
                label = "DASH-Spur (Bild oder Ton)"
            }
            guard let kind = Self.classify(url, hint: hint), !tab.media.contains(where: { $0.url == url }) else { continue }
            tab.media.append(MediaItem(url: url, kind: kind, label: label, hidden: hint == "hidden"))
            added = true
        }
        guard added else { return }
        tab.media.sort { Self.order($0.kind) < Self.order($1.kind) }
        if tab.autoShowMedia, tab.media.contains(where: { $0.kind != .image }), tab.id == selectedID, isPresented {
            tab.autoShowMedia = false
            Haptics.success()
            openAssistant(for: tab)
        }
    }

    private func handleAction(_ j: JSON, tab: BrowserTab) {
        let raw = j["u"].string ?? ""
        let src = URL(string: raw).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        let kind: MediaKind = j["k"].string == "audio" ? .audio : .video
        let poster = j["poster"].string.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let link = j["link"].string.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let frame = j["f"].string.flatMap(URL.init(string:))
        let title = j["t"].string ?? tab.title
        switch j["action"].string {
        case "media":
            if let frame, YouTubeLink.videoId(from: frame.absoluteString) != nil {
                LinkRouter.shared.download(frame)
            } else if let src {
                let k = MediaKind(fileExtension: src.pathExtension) == .stream ? MediaKind.stream : kind
                presentNative(src, kind: k, title: title, poster: poster, tab: tab)
            } else if let target = link ?? tab.url {
                // Streamed through MediaSource (blob:) – the assistant takes the post apart.
                Haptics.impact()
                DownloadAssistant.shared.start(target, pageMedia: tab.media, page: tab.url, userAgent: tab.userAgent,
                                               isPrivate: tab.isPrivate, autoStart: false)
            }
        case "playing":
            tab.playing = PlayingMedia(url: src, kind: kind, title: title, poster: poster, link: link)
        case "stopped":
            tab.playing = nil
        default:
            break
        }
    }

    private static func order(_ k: MediaKind) -> Int {
        switch k {
        case .video: return 0
        case .stream: return 1
        case .audio: return 2
        case .file: return 3
        case .image: return 4
        }
    }

    static func classify(_ url: URL, hint: String) -> MediaKind? {
        guard url.scheme?.hasPrefix("http") == true else { return nil }
        let kind = MediaKind(fileExtension: url.pathExtension)
        if kind == .image { return hint == "image" ? .image : nil }
        if kind != .file { return kind }
        let s = url.absoluteString.lowercased()
        if s.contains("mime_type=video") || s.contains("/video/") && hint != "file" && hint != "" { return .video }
        if s.contains("mime_type=audio") { return .audio }
        switch hint {
        case "video": return .video
        case "audio": return .audio
        case "file": return url.pathExtension.isEmpty ? nil : .file
        case "hidden", "net": return url.pathExtension.isEmpty ? nil : .file
        default: return nil
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.preferredContentMode = tab(for: webView)?.desktopMode == true ? .desktop : .mobile
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        guard let url = navigationAction.request.url else { return (.allow, preferences) }
        let scheme = url.scheme?.lowercased() ?? ""
        // Tapped YouTube links play in the app's own player.
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false,
           YouTubeLink.videoId(from: url.absoluteString) != nil {
            LinkRouter.shared.open(url)
            return (.cancel, preferences)
        }
        if ["http", "https", "about", "blob", "data"].contains(scheme) { return (.allow, preferences) }
        // Phone, mail, App Store … open outside; the sites' own app links (snssdk…, fb://) are ignored.
        let external = ["tel", "mailto", "sms", "facetime", "facetime-audio", "maps", "itms-apps", "itms-appss"]
        if external.contains(scheme), navigationAction.navigationType == .linkActivated || navigationAction.targetFrame?.isMainFrame == true {
            _ = await UIApplication.shared.open(url)
        }
        return (.cancel, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let response = navigationResponse.response
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if !navigationResponse.canShowMIMEType || disposition.lowercased().contains("attachment") { return .download }
        // A video or song opened directly plays in the native player (with a download button).
        if navigationResponse.isForMainFrame, let url = response.url, let mime = response.mimeType?.lowercased(),
           mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime.contains("mpegurl"), let tab = tab(for: webView) {
            let kind: MediaKind = mime.contains("mpegurl") ? .stream : mime.hasPrefix("audio/") ? .audio : .video
            presentNative(url, kind: kind, title: response.suggestedFilename ?? FileDownloads.displayName(for: url), poster: nil, tab: tab)
            if webView.backForwardList.currentItem == nil { tab.showStart = true }
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab(for: webView)?.loadError = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.loadError = nil
        tab.lastActive = Date()
        if !tab.isPrivate, let url = webView.url { BrowserLibrary.shared.record(url, title: webView.title ?? "") }
        scheduleTabSave()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }

    private func failed(_ webView: WKWebView, _ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        // Frame load interrupted (downloads, policy changes) and media handled by a plug-in.
        if ns.domain == "WebKitErrorDomain", [101, 102, 204].contains(ns.code) { return }
        tab(for: webView)?.loadError = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let name = FileDownloads.safe(suggestedFilename)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        let job = FileDownloads.shared.startExternal(name: name, source: download.originalRequest?.url)
        let page = download.webView.flatMap { tab(for: $0)?.url }
        downloads[ObjectIdentifier(download)] = (temp, name, download.originalRequest?.url, page, job)
        downloadObservers[ObjectIdentifier(download)] = download.progress.observe(\.fractionCompleted) { p, _ in
            let value = p.fractionCompleted
            Task { @MainActor in FileDownloads.shared.updateExternal(job, progress: value) }
        }
        return temp
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        downloadObservers[key] = nil
        guard let info = downloads.removeValue(forKey: key) else { return }
        FileDownloads.shared.finishExternal(info.job, file: info.temp, name: info.name, source: info.source, page: info.page)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        downloadObservers[key] = nil
        guard let info = downloads.removeValue(forKey: key) else { return }
        FileDownloads.shared.failExternal(info.job, error: error)
    }

    // MARK: WKUIDelegate

    /// Links and scripts that want a new window get a new tab (keeps login pop-ups working).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        let opener = tab(for: webView)
        let tab = newTab(isPrivate: opener?.isPrivate ?? false, configuration: configuration)
        tab.showStart = false
        if opener?.desktopMode == true { tab.setDesktop(true) }
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab = tab(for: webView) { close(tab) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done.resume() })
            present(alert) { done.resume() }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in done.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done.resume(returning: true) })
            present(alert) { done.resume(returning: false) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            let alert = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in done.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                done.resume(returning: alert?.textFields?.first?.text ?? "")
            })
            present(alert) { done.resume(returning: nil) }
        }
    }

    /// Shows a page dialog on top; `failed` runs if there is nothing to show it on.
    private func present(_ alert: UIAlertController, failed: () -> Void) {
        guard let top = FileSaver.topController() else {
            failed()
            return
        }
        top.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        guard let link = elementInfo.linkURL else { return nil }
        let isPrivate = tab(for: webView)?.isPrivate ?? false
        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { suggested in
            let newTab = UIAction(title: "In neuem Tab öffnen", image: UIImage(systemName: "plus.square.on.square")) { _ in
                MainActor.assumeIsolated { _ = BrowserModel.shared.newTab(link, isPrivate: isPrivate) }
            }
            let background = UIAction(title: "Im Hintergrund öffnen", image: UIImage(systemName: "square.on.square.dashed")) { _ in
                MainActor.assumeIsolated {
                    _ = BrowserModel.shared.newTab(link, isPrivate: isPrivate, select: false)
                    Haptics.success()
                }
            }
            let privateTab = UIAction(title: "In privatem Tab öffnen", image: UIImage(systemName: "hand.raised")) { _ in
                MainActor.assumeIsolated { _ = BrowserModel.shared.newTab(link, isPrivate: true) }
            }
            let download = UIAction(title: "Herunterladen", image: UIImage(systemName: "arrow.down.circle")) { _ in
                MainActor.assumeIsolated { LinkRouter.shared.download(link, page: webView.url, isPrivate: isPrivate) }
            }
            let copy = UIAction(title: "Link kopieren", image: UIImage(systemName: "link")) { _ in
                UIPasteboard.general.url = link
                MainActor.assumeIsolated { Haptics.success() }
            }
            let share = UIAction(title: "Teilen …", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                MainActor.assumeIsolated { ShareSheet.present([link]) }
            }
            let open = UIMenu(options: .displayInline, children: isPrivate ? [newTab, background] : [newTab, background, privateTab])
            let rest = UIMenu(options: .displayInline, children: [download, copy, share])
            return UIMenu(children: [open, rest] + suggested)
        }
        return config
    }

    // MARK: Detector

    static let sniffer = #"""
    (function () {
      'use strict';
      if (window.__niceSniffer) return;
      window.__niceSniffer = true;
      var seen = {};
      var queue = [];
      var MEDIA = /\.(mp4|m4v|mov|webm|mkv|m3u8|mpd|mp3|m4a|aac|wav|flac|ogg|opus|zip|rar|7z|pdf|apk|ipa|dmg|exe|pkg|epub|docx?|xlsx?|pptx?|csv|torrent)(\?|#|$)/i;
      var KEYS = /"(playAddr|downloadAddr|play_addr|download_addr|playable_url|playable_url_quality_hd|browser_native_hd_url|browser_native_sd_url|video_url|videoUrl|contentUrl|hd_src|sd_src|hd_src_no_ratelimit|sd_src_no_ratelimit|stream_url|hls_url|hlsUrl|dash_url|audio_url|mp4_url|file_url|download_url|downloadUrl|progressive_url)"\s*:\s*"(https?:[^"]+)"/g;
      var URLRX = /https?:(?:\\?\/){2}[^\s"'<>()\\]+?\.(?:mp4|m4v|mov|webm|m3u8|mpd|mp3|m4a|aac|flac|ogg|wav|zip|rar|7z|pdf|apk|ipa|dmg)(?:\?[^\s"'<>\\]*)?/gi;
      var LINKS = 'a[href*="/video/"], a[href*="/videos/"], a[href*="/reel/"], a[href*="/reels/"], a[href*="/p/"], a[href*="/watch"], a[href*="/status/"], a[href*="/comments/"], a[href*="/photo/"]';
      function norm(u) {
        try {
          if (!u) return null;
          u = String(u).replace(/\\u0026/g, '&').replace(/\\u003d/g, '=').replace(/\\u002F/gi, '/').replace(/\\\//g, '/').replace(/&amp;/g, '&');
          if (/^(blob|data|javascript|mailto):/i.test(u)) return null;
          if (u.indexOf('//') === 0) u = location.protocol + u;
          return new URL(u, location.href).href;
        } catch (e) { return null; }
      }
      var timer = null;
      function flush() {
        timer = null;
        if (!queue.length) return;
        try { window.webkit.messageHandlers.niceMedia.postMessage(JSON.stringify({ items: queue.splice(0), title: document.title })); } catch (e) {}
      }
      function act(o) {
        try { window.webkit.messageHandlers.novaAction.postMessage(JSON.stringify(o)); } catch (e) {}
      }
      function add(u, k, l) {
        u = norm(u);
        if (!u || u.length < 12 || seen[u]) return;
        seen[u] = 1;
        queue.push({ u: u, k: k || '', l: (l || '').toString().slice(0, 80) });
        if (!timer) timer = setTimeout(flush, 400);
      }
      function mediaType(ct) { return /^(video|audio)\//i.test(ct) || /mpegurl|dash\+xml|zip|pdf|octet-stream/i.test(ct); }
      var of = window.fetch;
      if (of) {
        window.fetch = function (input, init) {
          var u = typeof input === 'string' ? input : (input && input.url) || '';
          var p = of.apply(this, arguments);
          try {
            if (MEDIA.test(u)) add(u, 'net');
            else p.then(function (r) {
              try { var ct = r.headers.get('content-type') || ''; if (mediaType(ct)) add(r.url || u, ct.split('/')[0]); } catch (e) {}
            }).catch(function () {});
          } catch (e) {}
          return p;
        };
      }
      var oo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u) {
        try { this.__niceU = u; if (MEDIA.test(String(u))) add(u, 'net'); } catch (e) {}
        return oo.apply(this, arguments);
      };
      var os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function () {
        var x = this;
        try {
          x.addEventListener('load', function () {
            try { var ct = x.getResponseHeader('content-type') || ''; if (mediaType(ct)) add(x.responseURL || x.__niceU, ct.split('/')[0]); } catch (e) {}
          });
        } catch (e) {}
        return os.apply(this, arguments);
      };

      // Players: source, poster and the post they belong to (feeds of TikTok, Instagram, Facebook, X …).
      function srcOf(v) {
        var s = v.currentSrc || v.src || '';
        if (!s) { var x = v.querySelector && v.querySelector('source[src]'); if (x) s = x.src; }
        return s;
      }
      function permalink(v) {
        var n = v;
        for (var i = 0; i < 14 && n; i++) {
          n = n.parentElement;
          if (!n) break;
          try {
            if (n.tagName === 'A' && n.matches(LINKS)) return n.href;
            var a = n.querySelector(LINKS);
            if (a) return a.href;
          } catch (e) { return ''; }
        }
        return '';
      }
      function info(v, action) {
        return { action: action, u: srcOf(v), k: v.tagName.toLowerCase(), poster: v.poster || '', t: document.title || '',
                 link: permalink(v), f: location.href };
      }

      // Download buttons on players.
      var overlay = null, tracked = [], raf = 0;
      var ICON = '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11"/><path d="M7 11l5 5 5-5"/><path d="M5 20h14"/></svg>';
      function attach(v) {
        if (!window.__novaButtons || v.__nova) return;
        var root = document.body || document.documentElement;
        if (!root) return;
        if (!overlay || !overlay.isConnected) {
          overlay = document.createElement('div');
          overlay.setAttribute('style', 'position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none');
          root.appendChild(overlay);
        }
        var b = document.createElement('div');
        b.innerHTML = ICON;
        b.setAttribute('role', 'button');
        b.setAttribute('aria-label', 'Herunterladen');
        b.setAttribute('style', 'position:fixed;display:none;width:36px;height:36px;border-radius:18px;align-items:center;justify-content:center;background:rgba(18,18,22,.52);-webkit-backdrop-filter:blur(16px) saturate(180%);backdrop-filter:blur(16px) saturate(180%);border:.5px solid rgba(255,255,255,.3);box-shadow:0 4px 14px rgba(0,0,0,.3);pointer-events:auto;cursor:pointer;-webkit-tap-highlight-color:transparent;transition:transform .15s ease');
        var sx = 0, sy = 0, st = 0;
        function fire(e) {
          e.preventDefault(); e.stopPropagation();
          if (e.stopImmediatePropagation) e.stopImmediatePropagation();
          act(info(v, 'media'));
        }
        b.addEventListener('touchstart', function (e) {
          var t = e.touches[0]; sx = t.clientX; sy = t.clientY; st = Date.now(); b.style.transform = 'scale(.86)';
          e.stopPropagation();
        }, { passive: true });
        b.addEventListener('touchend', function (e) {
          b.style.transform = '';
          var t = e.changedTouches[0];
          if (Math.abs(t.clientX - sx) < 12 && Math.abs(t.clientY - sy) < 12 && Date.now() - st < 800) fire(e);
        }, { passive: false });
        b.addEventListener('click', fire, true);
        v.__nova = b;
        overlay.appendChild(b);
        tracked.push(v);
        schedule();
      }
      function layout() {
        raf = 0;
        var full = document.fullscreenElement || document.webkitFullscreenElement;
        for (var i = tracked.length - 1; i >= 0; i--) {
          var v = tracked[i], b = v.__nova;
          if (!b) { tracked.splice(i, 1); continue; }
          if (!v.isConnected || !window.__novaButtons) { b.remove(); v.__nova = null; tracked.splice(i, 1); continue; }
          var r = v.getBoundingClientRect();
          var audio = v.tagName === 'AUDIO';
          var ok = !full && r.bottom > 40 && r.top < innerHeight - 40 && r.right > 0 && r.left < innerWidth &&
            (audio ? r.width >= 100 && r.height >= 20 : r.width >= 150 && r.height >= 100);
          if (ok) { try { ok = getComputedStyle(v).visibility !== 'hidden'; } catch (e) {} }
          if (!ok) { b.style.display = 'none'; continue; }
          b.style.display = 'flex';
          b.style.left = Math.min(innerWidth - 46, Math.max(6, r.right - 46)) + 'px';
          b.style.top = (audio ? r.top + (r.height - 36) / 2 : Math.min(innerHeight - 46, Math.max(10, r.top + 10))) + 'px';
        }
      }
      function schedule() { if (!raf) raf = requestAnimationFrame(layout); }
      window.addEventListener('scroll', schedule, { passive: true, capture: true });
      window.addEventListener('resize', schedule, { passive: true });

      function scan() {
        try {
          document.querySelectorAll('video, audio').forEach(function (v) {
            var s = v.currentSrc || v.src;
            if (s && !/^blob:/.test(s)) add(s, v.tagName.toLowerCase(), 'Player');
            v.querySelectorAll('source').forEach(function (x) { add(x.src, v.tagName.toLowerCase(), 'Player'); });
            attach(v);
          });
          schedule();
          document.querySelectorAll('a[href]').forEach(function (a) {
            var h = a.getAttribute('href') || '';
            if (MEDIA.test(h) || a.hasAttribute('download')) add(a.href, 'file', a.getAttribute('download') || (a.textContent || '').trim());
          });
          document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[property="og:video:secure_url"], meta[property="og:audio"], meta[name="twitter:player:stream"]').forEach(function (m) {
            add(m.content, 'video', 'Seiten-Video');
          });
          var og = document.querySelector('meta[property="og:image"]');
          if (og) add(og.content, 'image', 'Vorschaubild');
          var html = document.documentElement.innerHTML;
          if (html.length < 8000000) {
            var m;
            KEYS.lastIndex = 0;
            while ((m = KEYS.exec(html))) add(m[2], 'hidden', m[1]);
            URLRX.lastIndex = 0;
            while ((m = URLRX.exec(html))) add(m[0], 'hidden');
          }
          (performance.getEntriesByType('resource') || []).forEach(function (e) { if (MEDIA.test(e.name)) add(e.name, 'net'); });
        } catch (e) {}
      }
      window.__niceScan = scan;
      document.addEventListener('DOMContentLoaded', scan);
      window.addEventListener('load', scan);
      setInterval(scan, 2500);

      // What's playing with sound right now.
      var current = null;
      function playing(v) { current = v; act(info(v, 'playing')); }
      document.addEventListener('play', function (e) {
        var v = e.target;
        if (!v || !v.tagName) return;
        attach(v);
        var s = srcOf(v);
        if (s && !/^blob:/.test(s)) add(s, v.tagName.toLowerCase(), 'Wiedergabe');
        if (!v.muted && v.volume > 0) playing(v);
      }, true);
      function stopped(e) {
        if (e.target === current) { current = null; act({ action: 'stopped' }); }
      }
      document.addEventListener('pause', stopped, true);
      document.addEventListener('ended', stopped, true);
      document.addEventListener('volumechange', function (e) {
        var v = e.target;
        if (!v || !v.tagName) return;
        if (v === current && (v.muted || v.volume === 0)) { current = null; act({ action: 'stopped' }); }
        else if (v !== current && !v.paused && !v.muted && v.volume > 0) playing(v);
      }, true);
    })();
    """#
}
