import SwiftUI
import WebKit

/// Connects a Deezer account – via the Deezer website (the `arl` cookie is picked up
/// automatically) or by pasting the `arl` cookie by hand.
struct DeezerLoginView: View {
    @EnvironmentObject private var store: MusicStore
    @State private var arl = ""
    @State private var showWebLogin = false
    @State private var showHelp = false
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [.pink, .purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 110, height: 110)
                        .glassEffect(.regular, in: .circle)
                    Text("Deezer verbinden").font(.title.weight(.bold))
                    Text("Melde dich mit deinem Deezer-Premium-Konto an: Musik in bis zu FLAC-Qualität streamen, herunterladen und direkt in andere Apps teilen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                if Deezer.storedARL != nil {
                    Button {
                        isWorking = true
                        error = nil
                        Task {
                            await store.retrySession()
                            if store.user == nil { error = "Deezer hat nicht geantwortet. Prüfe die Verbindung und versuche es nochmal." }
                            isWorking = false
                        }
                    } label: {
                        HStack {
                            if isWorking { ProgressView().controlSize(.small) }
                            Label("Gespeicherte Anmeldung verbinden", systemImage: "arrow.clockwise")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(isWorking)
                }

                Button { showWebLogin = true } label: {
                    Label("Bei Deezer anmelden", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                HStack {
                    Rectangle().fill(.quaternary).frame(height: 1)
                    Text("oder ARL-Cookie").font(.caption.weight(.semibold)).foregroundStyle(.secondary).fixedSize()
                    Rectangle().fill(.quaternary).frame(height: 1)
                }

                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        SecureField("ARL einfügen", text: $arl)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                            .submitLabel(.go)
                            .onSubmit { submit(arl) }
                        Button {
                            if let s = UIPasteboard.general.string { arl = s; Haptics.tap() }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Aus Zwischenablage einfügen")
                    }
                    .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))

                    Button { submit(arl) } label: {
                        HStack {
                            if isWorking { ProgressView().controlSize(.small) }
                            Text("Mit ARL anmelden").font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(arl.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                }

                DisclosureGroup("Wo finde ich meinen ARL?", isExpanded: $showHelp) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Öffne deezer.com am Computer und melde dich an.")
                        Text("2. Entwicklertools öffnen (F12) → „Application“/„Speicher“ → Cookies → https://www.deezer.com.")
                        Text("3. Den Wert des Cookies „arl“ (192 Zeichen) kopieren und hier einfügen.")
                        Text("Der ARL wird nur im Schlüsselbund dieses Geräts gespeichert. Er ist wie ein Passwort – gib ihn nicht weiter.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showWebLogin) {
            DeezerWebLoginSheet { cookie in
                showWebLogin = false
                submit(cookie)
            }
        }
    }

    private func submit(_ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, !isWorking else { return }
        isWorking = true
        error = nil
        Task {
            do {
                try await store.login(arl: v)
            } catch {
                self.error = error.localizedDescription
                Haptics.error()
            }
            isWorking = false
        }
    }
}

struct DeezerWebLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    var onARL: (String) -> Void

    var body: some View {
        NavigationStack {
            DeezerLoginWebView(isLoading: $isLoading, onARL: onARL)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if isLoading { ProgressView().padding(.top, 12) }
                }
                .navigationTitle("Bei Deezer anmelden")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen", systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }
}

/// Deezer's own login page; once signed in, the `arl` cookie is handed over.
struct DeezerLoginWebView: UIViewRepresentable {
    @Binding var isLoading: Bool
    var onARL: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = LoginWebView.safariUA
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: URL(string: "https://www.deezer.com/de/login")!))
        context.coordinator.startPolling(web)
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: DeezerLoginWebView
        private var timer: Timer?
        private var done = false

        init(_ parent: DeezerLoginWebView) { self.parent = parent }

        func startPolling(_ web: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self, weak web] _ in
                guard let self, let web else { return }
                self.check(web)
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

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
            guard !done else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                guard !self.done,
                      let arl = cookies.first(where: { $0.name == "arl" && $0.domain.hasSuffix("deezer.com") })?.value,
                      arl.count > 100 else { return }
                self.done = true
                self.stop()
                DispatchQueue.main.async { self.parent.onARL(arl) }
            }
        }
    }
}

