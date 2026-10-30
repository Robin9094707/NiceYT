import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Nova" in the share sheet of TikTok, Instagram, Safari …: takes the shared link and
/// hands it straight to the download assistant of the app.
final class ShareViewController: UIViewController {
    private let state = ShareState()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: ShareCard(state: state, onDone: { [weak self] in self?.finish() },
                                                           onBrowser: { [weak self] in self?.handOver(to: "browser") }))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { @MainActor in
            let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            state.url = await Self.findURL(in: items)
            if state.url == nil {
                state.phase = .noLink
            } else {
                handOver(to: "download")
            }
        }
    }

    private func handOver(to action: String) {
        guard let url = state.url else { return }
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        guard let target = URL(string: "nova://\(action)?url=\(encoded)") else { return }
        // Fallback if iOS doesn't let the extension open the app: Nova finds the copied link.
        UIPasteboard.general.url = url
        if openApp(target) {
            state.phase = .opened
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.finish() }
        } else {
            state.phase = .copied
        }
    }

    /// Share extensions can't call `UIApplication.shared.open`; the responder chain still leads to
    /// the application object, whose method is called through the Objective-C runtime.
    private func openApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        var responder: UIResponder? = self
        while let current = responder {
            if current !== self, current.responds(to: selector), let method = current.method(for: selector) {
                let open = unsafeBitCast(method, to: OpenURL.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private static func findURL(in items: [NSExtensionItem]) async -> URL? {
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
                return url
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
            let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            if let text, let url = firstURL(in: text) { return url }
        }
        for item in items {
            if let text = item.attributedContentText?.string, let url = firstURL(in: text) { return url }
        }
        return nil
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }
}

@MainActor
final class ShareState: ObservableObject {
    enum Phase { case working, opened, copied, noLink }
    @Published var url: URL?
    @Published var phase: Phase = .working
}

private struct ShareCard: View {
    @ObservedObject var state: ShareState
    var onDone: () -> Void
    var onBrowser: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                ZStack {
                    LinearGradient(colors: [.pink, .purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: icon).font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text(title).font(.title3.weight(.bold))
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if state.phase == .working || state.phase == .opened {
                    ProgressView()
                } else {
                    VStack(spacing: 10) {
                        if state.phase == .copied {
                            Button(action: onBrowser) {
                                Text("Im Browser öffnen").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        Button(action: onDone) {
                            Text("Fertig").font(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.large)
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.2).ignoresSafeArea().onTapGesture(perform: onDone))
    }

    private var icon: String {
        switch state.phase {
        case .working, .opened: return "arrow.down"
        case .copied: return "doc.on.clipboard"
        case .noLink: return "link.badge.plus"
        }
    }

    private var title: String {
        switch state.phase {
        case .working: return "Wird an Nova übergeben …"
        case .opened: return "Download startet in Nova"
        case .copied: return "Link kopiert"
        case .noLink: return "Kein Link gefunden"
        }
    }

    private var message: String {
        switch state.phase {
        case .working, .opened: return state.url?.host ?? ""
        case .copied: return "Öffne Nova – der Link wird erkannt und mit einem Tipp geladen."
        case .noLink: return "Teile einen Beitrag als Link, z. B. über „Link kopieren“ oder „Teilen über …“."
        }
    }
}
