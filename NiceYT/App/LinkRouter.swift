import SwiftUI
import UIKit

/// Opens links from anywhere in the right place: YouTube → player, Deezer → music,
/// everything else → browser. `download` sends links to the download assistant instead.
@MainActor
final class LinkRouter: ObservableObject {
    static let shared = LinkRouter()
    /// Video the root view should play.
    @Published var playRequest: Video?
    /// A link sits in the clipboard (banner "laden / öffnen?").
    @Published var clipboardHasLink = false
    private var lastChange: Int {
        get { UserDefaults.standard.integer(forKey: "clipboardChange") }
        set { UserDefaults.standard.set(newValue, forKey: "clipboardChange") }
    }

    func open(_ url: URL) {
        let text = url.absoluteString
        if let id = YouTubeLink.videoId(from: text) {
            BrowserModel.shared.isPresented = false
            playRequest = Video(id: id, title: "", isShort: text.contains("/shorts/"))
            return
        }
        if let route = DeezerLink.route(from: text) {
            BrowserModel.shared.isPresented = false
            MusicRouter.shared.open(route)
            return
        }
        BrowserModel.shared.open(url)
    }

    /// Saves what's behind a link: YouTube → download sheet, anything else → assistant.
    func download(_ url: URL, page: URL? = nil, isPrivate: Bool = false) {
        if let id = YouTubeLink.videoId(from: url.absoluteString) {
            YouTubeDownloads.shared.request = Video(id: id, title: "")
            return
        }
        DownloadAssistant.shared.start(url, page: page, isPrivate: isPrivate)
    }

    /// nova://download?url=… (share extension), niceyt://open?url=…, youtube://…, vnd.youtube:…
    func handle(scheme url: URL) {
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "url" })?.value.flatMap { URL(string: $0) ?? BrowserModel.url(from: $0) }
        if ["niceyt", "nova"].contains(url.scheme?.lowercased() ?? "") {
            // The share extension also copies the link as a fallback – it's handled now.
            lastChange = UIPasteboard.general.changeCount
            clipboardHasLink = false
            switch url.host?.lowercased() {
            case "download":
                if let target { download(target) }
                return
            case "browser":
                if let target { BrowserModel.shared.open(target) }
                return
            default:
                break
            }
        }
        open(target ?? url)
    }

    // MARK: Clipboard

    /// Looks (without reading it, so iOS doesn't ask) whether the clipboard holds a new link.
    func checkClipboard() {
        let board = UIPasteboard.general
        guard board.changeCount != lastChange else { return }
        board.detectPatterns(for: [.probableWebURL]) { result in
            let found = (try? result.get())?.contains(.probableWebURL) ?? false
            Task { @MainActor in
                if found { withAnimation(.spring) { self.clipboardHasLink = true } }
            }
        }
    }

    private func takeClipboard() -> URL? {
        let board = UIPasteboard.general
        lastChange = board.changeCount
        withAnimation(.spring) { clipboardHasLink = false }
        return board.url ?? board.string.flatMap { BrowserModel.url(from: $0) ?? Self.firstURL(in: $0) }
    }

    func openClipboard() {
        guard let url = takeClipboard() else { return }
        Haptics.impact()
        open(url)
    }

    func downloadClipboard() {
        guard let url = takeClipboard() else { return }
        Haptics.impact()
        download(url)
    }

    func dismissClipboard() {
        lastChange = UIPasteboard.general.changeCount
        withAnimation(.spring) { clipboardHasLink = false }
    }

    static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }
}
