import AuthenticationServices
import SwiftUI
import WebKit

/// Connects a Spotify account: normal sign-in on spotify.com (the web player's session is
/// used), or – optionally – the official API with an own Client ID.
struct SpotifyLoginView: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var showWeb = false
    @State private var clientId = Spotify.clientId ?? ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 50, weight: .semibold))
                            .foregroundStyle(.green)
                            .frame(width: 106, height: 106)
                            .glassEffect(.regular, in: .circle)
                        Text("Spotify verbinden").font(.title.weight(.bold))
                        Text("Deine Playlists, Lieblingssongs und Alben aus Spotify. Abgespielt und heruntergeladen wird der passende Song über Deezer (per ISRC, bis FLAC) – oder über YouTube, wenn Deezer nicht verbunden ist.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 10)

                    Button { showWeb = true } label: {
                        HStack {
                            if isWorking { ProgressView().controlSize(.small) }
                            Label("Bei Spotify anmelden", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.green)
                    .controlSize(.large)
                    .disabled(isWorking)

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }

                    DisclosureGroup("Alternative: eigene Client-ID (offizielle API)", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Falls die normale Anmeldung einmal nicht klappt: Lege auf developer.spotify.com eine App an, trage als Redirect URI **\(Spotify.redirectURI)** ein und füge hier die Client-ID ein. (Seit 2026 verlangt Spotify dafür ein Premium-Konto, max. 5 Nutzer.)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            TextField("Client-ID", text: $clientId)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.body, design: .monospaced))
                                .padding(12)
                                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                            Button("Mit Client-ID anmelden") { Task { await clientLogin() } }
                                .buttonStyle(.glass)
                                .disabled(clientId.trimmingCharacters(in: .whitespaces).count < 20 || isWorking)
                        }
                        .padding(.top, 8)
                    }
                    .padding(16)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Spotify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark") { dismiss() }
                }
            }
            .sheet(isPresented: $showWeb) {
                SpotifyWebLoginSheet { token, expires in
                    showWeb = false
                    Task { await webLogin(token, expires) }
                }
            }
        }
    }

    private func webLogin(_ token: String, _ expires: Date?) async {
        isWorking = true
        error = nil
        do {
            let user = try await Spotify.shared.useWebToken(token, expiresAt: expires)
            await store.connectSpotify(user)
            dismiss()
        } catch {
            self.error = "Anmeldung nicht bestätigt: \(error.localizedDescription)"
            Haptics.error()
        }
        isWorking = false
    }

    private func clientLogin() async {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        error = nil
        defer { isWorking = false }
        let verifier = Spotify.makeVerifier()
        let url = Spotify.authorizeURL(clientId: id, challenge: Spotify.challenge(for: verifier))
        do {
            let callback = try await webAuth.authenticate(using: url, callbackURLScheme: "niceyt",
                                                          preferredBrowserSession: .shared)
            guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
                error = "Spotify hat die Anmeldung abgelehnt."
                return
            }
            let user = try await Spotify.shared.completeClientLogin(code: code, verifier: verifier, clientId: id)
            await store.connectSpotify(user)
            dismiss()
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}

/// spotify.com login in a web view; the web player's token is handed over once signed in.
struct SpotifyWebLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onToken: (String, Date?) -> Void

    var body: some View {
        NavigationStack {
            SpotifyLoginWebView(onToken: onToken)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Bei Spotify anmelden")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen", systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }
}

private struct SpotifyLoginWebView: UIViewRepresentable {
    var onToken: (String, Date?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: SpotifyWebSession.shared.configuration())
        web.customUserAgent = SpotifyWebSession.userAgent
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        context.coordinator.web = web
        SpotifyWebSession.shared.onToken = { token, expires in context.coordinator.received(token, expires) }
        web.load(URLRequest(url: URL(string: "https://accounts.spotify.com/de/login?continue=https%3A%2F%2Fopen.spotify.com%2F")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        SpotifyWebSession.shared.onToken = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onToken: (String, Date?) -> Void
        weak var web: WKWebView?
        private var done = false
        private var checking = false

        init(onToken: @escaping (String, Date?) -> Void) { self.onToken = onToken }

        /// Only a token of a signed-in user counts (the web player also has anonymous ones).
        func received(_ token: String, _ expires: Date?) {
            guard !done, !checking else { return }
            checking = true
            Task {
                var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
                req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                let status = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode ?? 0
                checking = false
                guard status == 200, !done else { return }
                done = true
                onToken(token, expires)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // After signing in Spotify may stay on the account page: open the player.
            if let host = webView.url?.host, host.contains("accounts.spotify.com"),
               webView.url?.path.contains("status") == true {
                webView.load(URLRequest(url: URL(string: "https://open.spotify.com/")!))
            }
        }
    }
}
