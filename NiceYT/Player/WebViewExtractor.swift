import Foundation
import WebKit

/// Last-resort stream source: loads the real YouTube watch page in a hidden WKWebView
/// (sharing the signed-in session) and captures the HLS manifest + PO token that the
/// official web player requests for itself. Same idea as SmartTubeIOS.
@MainActor
final class WebViewExtractor: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = WebViewExtractor()
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<StreamInfo?, Never>?
    private var currentId: String?
    private var timeout: Task<Void, Never>?

    private var queueTail: Task<Void, Never>?

    /// Extractions run one after another (there is only one web view).
    func extract(_ videoId: String, timeoutSeconds: Double = 15) async -> StreamInfo? {
        let previous = queueTail
        let task = Task { () -> StreamInfo? in
            await previous?.value
            if Task.isCancelled { return nil }
            return await self.run(videoId, timeoutSeconds: timeoutSeconds)
        }
        queueTail = Task { _ = await task.value }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func run(_ videoId: String, timeoutSeconds: Double) async -> StreamInfo? {
        finish(nil)
        currentId = videoId
        let wv = webView ?? makeWebView()
        webView = wv
        return await withCheckedContinuation { cont in
            continuation = cont
            var req = URLRequest(url: URL(string: "https://www.youtube.com/watch?v=\(videoId)")!)
            req.setValue("\(AppSettings.hl),en;q=0.8", forHTTPHeaderField: "Accept-Language")
            wv.load(req)
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled, let self, self.currentId == videoId else { return }
                DebugLog.log("[WebView] Zeitüberschreitung")
                self.finish(nil)
            }
        }
    }

    private func makeWebView() -> WKWebView {
        let controller = WKUserContentController()
        controller.add(self, name: "niceHLS")
        controller.addUserScript(WKUserScript(source: Self.interceptor, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsInlineMediaPlayback = true
        if let consent = HTTPCookie(properties: [
            .name: "SOCS", .value: "CAI", .domain: ".youtube.com", .path: "/", .secure: true,
            .expires: Date(timeIntervalSinceNow: 365 * 24 * 3600)
        ]) {
            config.websiteDataStore.httpCookieStore.setCookie(consent)
        }
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        wv.customUserAgent = Self.userAgent
        wv.navigationDelegate = self
        return wv
    }

    private func finish(_ info: StreamInfo?) {
        timeout?.cancel()
        timeout = nil
        let cont = continuation
        continuation = nil
        currentId = nil
        webView?.stopLoading()
        cont?.resume(returning: info)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        handle(text)
    }

    private func handle(_ text: String) {
        let j = JSON(data: Data(text.utf8))
        if let note = j["log"].string {
            DebugLog.log("[WebView] \(note)")
            return
        }
        guard let id = currentId, j["videoId"].string == nil || j["videoId"].string == id,
              let hls = j["hls"].string, let url = URL(string: hls) else { return }
        let pot = j["pot"].string
        DebugLog.log("[WebView] HLS gefunden (Quelle \(j["source"].string ?? "?"), PO-Token \(pot == nil ? "nein" : "ja"))")
        var info = StreamInfo(videoId: id, hlsURL: url, title: j["title"].string ?? "", author: j["author"].string ?? "",
                              channelId: nil, viewCount: nil, lengthSeconds: 0, description: "", isLive: false, captions: [])
        info.userAgent = Self.userAgent
        info.source = "WEBVIEW"
        info.poToken = pot
        finish(info)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DebugLog.log("[WebView] Ladefehler: \(error.localizedDescription)")
    }

    private static let interceptor = #"""
    (function () {
      'use strict';
      var sent = false;
      function post(obj) { try { window.webkit.messageHandlers.niceHLS.postMessage(JSON.stringify(obj)); } catch (e) {} }
      function pageId() { var m = location.href.match(/[?&]v=([^&#]+)/); return m ? m[1] : null; }
      function handle(data, body, source) {
        if (sent) return;
        try {
          var o = typeof data === 'string' ? JSON.parse(data) : data;
          if (!o) return;
          var ps = o.playabilityStatus ? o.playabilityStatus.status : '?';
          if (!o.streamingData || !o.streamingData.hlsManifestUrl) {
            post({ log: source + ': Status ' + ps + ', kein HLS' });
            return;
          }
          var pot = null;
          try { var b = JSON.parse(body || 'null'); pot = b && b.serviceIntegrityDimensions ? b.serviceIntegrityDimensions.poToken : null; } catch (e) {}
          var vd = o.videoDetails || {};
          sent = true;
          post({ hls: o.streamingData.hlsManifestUrl, pot: pot, source: source, videoId: vd.videoId || pageId(),
                 title: vd.title || '', author: vd.author || '' });
        } catch (e) {}
      }
      function isPlayer(u) { return u && String(u).indexOf('/youtubei/v1/player') !== -1; }
      var origFetch = window.fetch;
      window.fetch = function (input, init) {
        var u = typeof input === 'string' ? input : (input && (input.url || input.href)) || '';
        var body = init && typeof init.body === 'string' ? init.body : null;
        var p = origFetch.apply(this, arguments);
        if (isPlayer(u)) {
          p.then(function (r) { return r.clone().text().then(function (t) { handle(t, body, 'fetch'); }); }).catch(function () {});
        }
        return p;
      };
      var oOpen = XMLHttpRequest.prototype.open, oSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__nicePlayer = isPlayer(u); return oOpen.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function (body) {
        if (this.__nicePlayer) {
          var b = typeof body === 'string' ? body : null;
          this.addEventListener('load', function () { handle(this.responseText, b, 'xhr'); });
        }
        return oSend.apply(this, arguments);
      };
      document.addEventListener('DOMContentLoaded', function () {
        // Prefer the player's own request (it carries the PO token); fall back after a while.
        setTimeout(function () {
          if (window.ytInitialPlayerResponse) { handle(window.ytInitialPlayerResponse, null, 'initial'); }
        }, 8000);
      });
    })();
    """#
}
