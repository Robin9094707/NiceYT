import SwiftUI
import WebKit

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var isSignedIn = CookieJar.shared.isSignedIn
    @Published private(set) var info: AccountInfo?
    @Published var subscriptions: [Channel] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: "accountInfo"),
           let cached = try? JSONDecoder().decode(AccountInfo.self, from: data) {
            info = cached
        }
        if isSignedIn { Task { await refresh() } }
    }

    func signIn(with cookies: [String: String]) async {
        CookieJar.shared.replace(with: cookies)
        isSignedIn = CookieJar.shared.isSignedIn
        await refresh()
    }

    func refresh() async {
        guard CookieJar.shared.isSignedIn else { return }
        if let account = try? await YouTube.account() {
            info = account
            UserDefaults.standard.set(try? JSONEncoder().encode(account), forKey: "accountInfo")
        }
        if let subs = try? await YouTube.subscribedChannels() {
            subscriptions = subs
        }
    }

    func signOut() {
        CookieJar.shared.clear()
        InnerTube.shared.visitorData = nil
        UserDefaults.standard.removeObject(forKey: "accountInfo")
        isSignedIn = false
        info = nil
        subscriptions = []
        Task { await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) }
    }

    /// Parses either a raw `Cookie:` header or a Netscape cookies.txt export.
    static func parseCookies(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = text.components(separatedBy: .newlines)
        if lines.contains(where: { $0.components(separatedBy: "\t").count >= 7 }) {
            for line in lines {
                var l = line
                if l.hasPrefix("#HttpOnly_") { l = String(l.dropFirst("#HttpOnly_".count)) }
                if l.hasPrefix("#") { continue }
                let f = l.components(separatedBy: "\t")
                guard f.count >= 7, f[0].contains("youtube.com") else { continue }
                result[f[5]] = f[6].trimmingCharacters(in: .whitespaces)
            }
        } else {
            var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.lowercased().hasPrefix("cookie:") { t = String(t.dropFirst(7)) }
            for pair in t.components(separatedBy: ";") {
                guard let eq = pair.firstIndex(of: "=") else { continue }
                let name = pair[..<eq].trimmingCharacters(in: .whitespaces)
                let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { result[name] = value }
            }
        }
        return result
    }
}

// MARK: - Google sign-in web view

struct GoogleLoginView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var showCookieImport = false
    @State private var finishing = false

    var body: some View {
        NavigationStack {
            ZStack {
                LoginWebView(isLoading: $isLoading) { cookies in
                    guard !finishing else { return }
                    finishing = true
                    Task {
                        await account.signIn(with: cookies)
                        dismiss()
                    }
                }
                .ignoresSafeArea(edges: .bottom)

                if isLoading || finishing {
                    ProgressView(finishing ? "Anmeldung wird abgeschlossen…" : "")
                        .padding(24)
                        .glassEffect(.regular, in: .rect(cornerRadius: 24))
                }
            }
            .navigationTitle("Mit Google anmelden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Cookies importieren", systemImage: "doc.on.clipboard") { showCookieImport = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $showCookieImport) {
                CookieImportView { dismiss() }
            }
        }
    }
}

struct LoginWebView: UIViewRepresentable {
    @Binding var isLoading: Bool
    var onSignedIn: ([String: String]) -> Void

    static let signInURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Dm%26hl%3Dde%26next%3Dhttps%253A%252F%252Fm.youtube.com%252F&hl=de")!

    /// A real Safari user agent; Google rejects sign-ins from user agents that look embedded.
    static let safariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = Self.safariUA
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: Self.signInURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: LoginWebView
        private var done = false
        init(_ parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            check(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        private func check(_ webView: WKWebView) {
            guard !done, let host = webView.url?.host, host.hasSuffix("youtube.com") else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let yt = cookies.filter { $0.domain.hasSuffix("youtube.com") }
                var dict: [String: String] = [:]
                for c in yt { dict[c.name] = c.value }
                guard dict["SAPISID"] != nil || dict["__Secure-3PAPISID"] != nil else { return }
                self.done = true
                DispatchQueue.main.async { self.parent.onSignedIn(dict) }
            }
        }
    }
}

struct CookieImportView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 220)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Cookie-Header oder cookies.txt")
                } footer: {
                    Text("Alternative zur Web-Anmeldung: Exportiere die Cookies von youtube.com aus einem Browser, in dem du angemeldet bist (z. B. mit der Erweiterung „Get cookies.txt“), und füge sie hier ein. Benötigt werden u. a. SAPISID, SID, HSID und SSID.")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Cookies importieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anmelden", systemImage: "checkmark") {
                        let cookies = AccountStore.parseCookies(text)
                        guard cookies["SAPISID"] != nil || cookies["__Secure-3PAPISID"] != nil else {
                            error = "Kein SAPISID-Cookie gefunden."
                            return
                        }
                        Task {
                            await account.signIn(with: cookies)
                            dismiss()
                            onDone()
                        }
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
    }
}
