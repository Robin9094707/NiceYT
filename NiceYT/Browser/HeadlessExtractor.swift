import UIKit
import WebKit

/// Last resort of the download assistant: opens the link in an invisible web view (with
/// the browser's logins), lets the page start its player muted and collects what the
/// media detector sees – works where a site hides its files from plain requests.
@MainActor
final class HeadlessExtractor: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    struct Result {
        var items: [MediaItem]
        var title: String
        var page: URL
        var poster: URL?
    }

    private let webView: WKWebView
    private var items: [MediaItem] = []
    private var poster: URL?

    /// Starts players muted and collects the poster, after the detector is in place.
    private static let starter = #"""
    (function () {
      function kick() {
        try {
          document.querySelectorAll('video, audio').forEach(function (v) {
            v.muted = true;
            if (v.paused) { var p = v.play(); if (p && p.catch) p.catch(function () {}); }
          });
          var og = document.querySelector('meta[property="og:image"]');
          if (og && og.content) window.webkit.messageHandlers.novaAction.postMessage(JSON.stringify({ action: 'poster', u: og.content }));
        } catch (e) {}
      }
      setInterval(kick, 1200);
      document.addEventListener('DOMContentLoaded', kick);
    })();
    """#

    private init(isPrivate: Bool) {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: "window.__novaButtons = false;", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: BrowserModel.sniffer, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Self.starter, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = BrowserModel.shared.store(isPrivate: isPrivate)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        super.init()
        controller.add(self, name: "niceMedia")
        controller.add(self, name: "novaAction")
        webView.customUserAgent = UserAgents.mobile
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
    }

    /// Loads `url` for up to `timeout` seconds; returns early once a video turned up.
    static func extract(_ url: URL, isPrivate: Bool, timeout: Double = 15) async -> Result {
        let extractor = HeadlessExtractor(isPrivate: isPrivate)
        return await extractor.run(url, timeout: timeout)
    }

    private func run(_ url: URL, timeout: Double) async -> Result {
        // Players only run in a view that is part of a window.
        if let window = FileSaver.topController()?.view.window {
            window.insertSubview(webView, at: 0)
        }
        defer {
            webView.stopLoading()
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.removeFromSuperview()
        }
        webView.load(URLRequest(url: url))
        let start = Date()
        var firstHit: Date?
        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { break }
            if firstHit == nil, items.contains(where: { $0.kind == .video || $0.kind == .stream }) { firstHit = Date() }
            // A moment longer after the first hit: better qualities often follow.
            if let firstHit, Date().timeIntervalSince(firstHit) > 2.5 { break }
        }
        func order(_ kind: MediaKind) -> Int {
            switch kind {
            case .video: return 0
            case .stream: return 1
            case .audio: return 2
            case .file: return 3
            case .image: return 4
            }
        }
        let sorted = items.filter { $0.kind != .image }.sorted { order($0.kind) < order($1.kind) }
        return Result(items: sorted, title: webView.title ?? "", page: webView.url ?? url, poster: poster)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        let j = JSON(data: Data(text.utf8))
        if message.name == "novaAction" {
            switch j["action"].string {
            case "poster":
                if poster == nil { poster = j["u"].string.flatMap(URL.init(string:)) }
            case "playing", "media":
                if let u = j["u"].string.flatMap(URL.init(string:)), u.scheme?.hasPrefix("http") == true {
                    add(u, kind: j["k"].string == "audio" ? .audio : .video, label: "Player")
                }
            default:
                break
            }
            return
        }
        for entry in j["items"].array {
            guard let raw = entry["u"].string, var url = URL(string: raw) else { continue }
            let hint = entry["k"].string ?? ""
            var label = entry["l"].string
            if url.query?.contains("bytestart=") == true, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                c.queryItems = c.queryItems?.filter { $0.name != "bytestart" && $0.name != "byteend" }
                url = c.url ?? url
                label = "DASH-Spur (Bild oder Ton)"
            }
            guard let kind = BrowserModel.classify(url, hint: hint) else { continue }
            add(url, kind: kind, label: label, hidden: hint == "hidden")
        }
    }

    private func add(_ url: URL, kind: MediaKind, label: String?, hidden: Bool = false) {
        guard !items.contains(where: { $0.url == url }) else { return }
        items.append(MediaItem(url: url, kind: kind, label: label, hidden: hidden))
    }
}
