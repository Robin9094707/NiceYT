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

/// The in-app browser: one persistent web view with its own cookie store, a media
/// detector (players, network requests, links and URLs hidden in page data) and downloads.
@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    static let shared = BrowserModel()
    static let storeId = UUID(uuidString: "9B0F6C1E-2A4D-4E7B-8C3F-5D6E7F8A9B01")!
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    @Published var isPresented = false
    @Published var addressText = ""
    @Published private(set) var currentURL: URL?
    @Published private(set) var title = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var desktopMode = false
    @Published private(set) var media: [MediaItem] = []
    @Published var showMedia = false
    @Published var showStart = true
    /// Opens the media list automatically once something is found (after "Link einfügen").
    var autoShowMedia = false

    private var observers: [NSKeyValueObservation] = []
    private var downloads: [ObjectIdentifier: (temp: URL, name: String, source: URL?, job: String)] = [:]
    private var downloadObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]

    var userAgent: String { desktopMode ? Self.desktopUA : Self.mobileUA }

    static var dataStore: WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: storeId) }

    private(set) lazy var webView: WKWebView = {
        let controller = WKUserContentController()
        controller.add(self, name: "niceMedia")
        controller.addUserScript(WKUserScript(source: Self.sniffer, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = Self.dataStore
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = userAgent
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = true
        observers = [
            web.observe(\.estimatedProgress) { [weak self] w, _ in MainActor.assumeIsolated { self?.progress = w.estimatedProgress } },
            web.observe(\.isLoading) { [weak self] w, _ in MainActor.assumeIsolated { self?.isLoading = w.isLoading } },
            web.observe(\.canGoBack) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoBack = w.canGoBack } },
            web.observe(\.canGoForward) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoForward = w.canGoForward } },
            web.observe(\.title) { [weak self] w, _ in MainActor.assumeIsolated { self?.title = w.title ?? "" } },
            web.observe(\.url) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let u = w.url, u != self.currentURL {
                        if u.host != self.currentURL?.host || u.path != self.currentURL?.path { self.media = [] }
                        self.currentURL = u
                        self.addressText = u.absoluteString
                    }
                }
            }
        ]
        return web
    }()

    // MARK: Navigation

    func open(_ url: URL?, findMedia: Bool = false) {
        isPresented = true
        if let url {
            autoShowMedia = findMedia
            load(url)
        }
    }

    func load(_ url: URL) {
        showStart = false
        media = []
        webView.load(URLRequest(url: url))
    }

    /// Address bar input: URL or web search.
    func submit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let url = Self.url(from: t) {
            load(url)
        } else {
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [.init(name: "q", value: t)]
            if let url = c.url { load(url) }
        }
    }

    static func url(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return URL(string: t) }
        if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t), u.host?.contains(".") == true { return u }
        return nil
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { isLoading ? webView.stopLoading() : webView.reload() }

    func setDesktop(_ on: Bool) {
        desktopMode = on
        webView.customUserAgent = userAgent
        webView.reload()
        Haptics.selection()
    }

    func showStartPage() {
        showStart = true
        webView.stopLoading()
    }

    /// Runs the detector once more (e.g. after the video started playing).
    func rescan() {
        webView.evaluateJavaScript("window.__niceScan && window.__niceScan()")
        Haptics.tap()
    }

    // MARK: Requests outside the web view

    /// Headers to fetch `url` like the page would: its cookies, referer, user agent.
    static func requestHeaders(for url: URL, page: URL?, userAgent: String) async -> [String: String] {
        let cookies = await dataStore.httpCookieStore.allCookies()
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

    func download(_ item: MediaItem) {
        FileDownloads.shared.download(item.url, name: nil, page: currentURL, userAgent: userAgent)
    }

    // MARK: Media messages

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        let j = JSON(data: Data(text.utf8))
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
            guard let kind = Self.classify(url, hint: hint), !media.contains(where: { $0.url == url }) else { continue }
            media.append(MediaItem(url: url, kind: kind, label: label, hidden: hint == "hidden"))
            added = true
        }
        guard added else { return }
        media.sort { order($0.kind) < order($1.kind) }
        if autoShowMedia, media.contains(where: { $0.kind != .image }) {
            autoShowMedia = false
            Haptics.success()
            showMedia = true
        }
    }

    private func order(_ k: MediaKind) -> Int {
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        guard let url = navigationAction.request.url else { return .allow }
        // Tapped YouTube links play in the app's own player.
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false,
           YouTubeLink.videoId(from: url.absoluteString) != nil {
            LinkRouter.shared.open(url)
            return .cancel
        }
        if let scheme = url.scheme, !["http", "https", "about", "blob", "data"].contains(scheme) { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if !navigationResponse.canShowMIMEType || disposition.lowercased().contains("attachment") { return .download }
        return .allow
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
        downloads[ObjectIdentifier(download)] = (temp, name, download.originalRequest?.url, job)
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
        FileDownloads.shared.finishExternal(info.job, file: info.temp, name: info.name, source: info.source, page: currentURL)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        downloadObservers[key] = nil
        guard let info = downloads.removeValue(forKey: key) else { return }
        FileDownloads.shared.failExternal(info.job, error: error)
    }

    // MARK: WKUIDelegate

    /// Links that want a new window open in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        guard let link = elementInfo.linkURL else { return nil }
        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { suggested in
            let download = UIAction(title: "Herunterladen", image: UIImage(systemName: "arrow.down.circle")) { _ in
                MainActor.assumeIsolated {
                    FileDownloads.shared.download(link, page: self.currentURL, userAgent: self.userAgent)
                }
            }
            let copy = UIAction(title: "Link kopieren", image: UIImage(systemName: "link")) { _ in
                UIPasteboard.general.url = link
                MainActor.assumeIsolated { Haptics.success() }
            }
            let open = UIAction(title: "Öffnen", image: UIImage(systemName: "safari")) { _ in
                MainActor.assumeIsolated { self.load(link) }
            }
            return UIMenu(children: [open, download, copy] + suggested)
        }
        return config
    }

    // MARK: Detector

    private static let sniffer = #"""
    (function () {
      'use strict';
      if (window.__niceSniffer) return;
      window.__niceSniffer = true;
      var seen = {};
      var queue = [];
      var MEDIA = /\.(mp4|m4v|mov|webm|mkv|m3u8|mpd|mp3|m4a|aac|wav|flac|ogg|opus|zip|rar|7z|pdf|apk|ipa|dmg|exe|pkg|epub|docx?|xlsx?|pptx?|csv|torrent)(\?|#|$)/i;
      var KEYS = /"(playAddr|downloadAddr|play_addr|download_addr|playable_url|playable_url_quality_hd|browser_native_hd_url|browser_native_sd_url|video_url|videoUrl|contentUrl|hd_src|sd_src|hd_src_no_ratelimit|sd_src_no_ratelimit|stream_url|hls_url|hlsUrl|dash_url|audio_url|mp4_url|file_url|download_url|downloadUrl)"\s*:\s*"(https?:[^"]+)"/g;
      var URLRX = /https?:(?:\\?\/){2}[^\s"'<>()\\]+?\.(?:mp4|m4v|mov|webm|m3u8|mpd|mp3|m4a|aac|flac|ogg|wav|zip|rar|7z|pdf|apk|ipa|dmg)(?:\?[^\s"'<>\\]*)?/gi;
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
      function scan() {
        try {
          document.querySelectorAll('video, audio').forEach(function (v) {
            var s = v.currentSrc || v.src;
            if (s && !/^blob:/.test(s)) add(s, v.tagName.toLowerCase(), 'Player');
            v.querySelectorAll('source').forEach(function (x) { add(x.src, v.tagName.toLowerCase(), 'Player'); });
          });
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
      document.addEventListener('play', function (e) {
        var v = e.target;
        if (v && v.currentSrc && !/^blob:/.test(v.currentSrc)) add(v.currentSrc, 'video', 'Wiedergabe');
      }, true);
    })();
    """#
}
