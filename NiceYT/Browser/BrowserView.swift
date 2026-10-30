import SwiftUI
import WebKit

/// Sheets the browser opens.
enum BrowserSheet: String, Identifiable {
    case bookmarks, history, library, websiteData, settings
    var id: String { rawValue }
}

// MARK: - Browser screen

struct BrowserScreen: View {
    @ObservedObject private var model = BrowserModel.shared
    @ObservedObject private var files = FileDownloads.shared
    @EnvironmentObject private var player: PlayerModel
    @State private var sheet: BrowserSheet?

    var body: some View {
        BrowserTabView(tab: model.current, sheet: $sheet)
            .fullScreenCover(isPresented: $model.showTabs) { TabOverview() }
            .sheet(item: $sheet) { which in
                BrowserSheetView(sheet: which)
                    .environmentObject(FileDownloads.shared)
            }
            .sheet(item: $model.nativeMedia) { NativeMediaSheet(item: $0) }
            .youTubeDownloadSheet(active: model.isPresented && sheet == nil)
            .downloadAssistantSheet(active: model.isPresented && sheet == nil && model.nativeMedia == nil)
            .confirmations(active: model.isPresented && sheet == nil)
            .overlay(alignment: .top) { statusPill }
            .appLocked()
            .preferredColorScheme(model.current.isPrivate ? .dark : nil)
    }

    /// Toasts and running downloads (the app's own toast sits below the browser).
    @ViewBuilder private var statusPill: some View {
        Group {
            if let toast = player.toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .allowsHitTesting(false)
            } else if files.runningCount > 0, let job = files.activeJobs.first(where: { !$0.failed }) {
                HStack(spacing: 10) {
                    ProgressRing(value: job.progress).frame(width: 18, height: 18)
                    Text(files.runningCount > 1 ? "\(files.runningCount) Downloads laufen" : job.name)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular.interactive(), in: .capsule)
                .onTapGesture { sheet = .library }
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 40)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.snappy, value: player.toast)
        .animation(.snappy, value: files.runningCount)
    }
}

// MARK: - Tab

private struct BrowserTabView: View {
    @ObservedObject var tab: BrowserTab
    @Binding var sheet: BrowserSheet?
    @ObservedObject private var model = BrowserModel.shared
    @ObservedObject private var library = BrowserLibrary.shared
    @FocusState private var addressFocused: Bool
    @State private var address = ""
    @State private var remote: [String] = []

    var body: some View {
        ZStack {
            BrowserWebView(webView: tab.webView)
                .opacity(tab.showStart ? 0 : 1)
            if tab.showStart {
                StartPage(tab: tab, sheet: $sheet)
                    .transition(.opacity)
            } else if let error = tab.loadError {
                errorCard(error)
            }
            if addressFocused {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { addressFocused = false }
                    .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .animation(.snappy(duration: 0.25), value: addressFocused)
        .animation(.snappy, value: tab.showStart)
        .onChange(of: addressFocused) { _, focused in
            if focused { address = tab.showStart ? "" : (tab.url?.absoluteString ?? "") }
        }
        .task(id: address) { await loadSuggestions() }
    }

    // MARK: Bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if addressFocused {
                suggestions
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let playing = tab.playing, !tab.showStart {
                playingPill(playing)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if !addressFocused {
                        roundButton("xmark", label: "Browser schließen") { model.isPresented = false }
                        roundButton("chevron.backward", label: "Zurück", disabled: !tab.canGoBack && tab.showStart) { tab.goBack() }
                            .contextMenu {
                                if tab.canGoForward || (tab.showStart && tab.url != nil) {
                                    Button("Vorwärts", systemImage: "chevron.forward") { tab.goForward() }
                                }
                                ForEach(Array(tab.webView.backForwardList.backList.reversed().prefix(10)), id: \.self) { item in
                                    Button(item.title?.isEmpty == false ? item.title! : (item.url.host ?? item.url.absoluteString)) {
                                        tab.webView.go(to: item)
                                    }
                                }
                            }
                    }
                    addressPill
                    if addressFocused {
                        Button("Abbrechen") { addressFocused = false }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 4)
                    } else {
                        tabsButton
                        menuButton
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background {
            if !tab.showStart {
                Rectangle().fill(.bar).ignoresSafeArea(edges: .bottom)
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)))
            }
        }
    }

    private var displayText: String {
        if tab.showStart { return tab.isPrivate ? "Privat suchen oder Adresse" : "Suchen oder Adresse eingeben" }
        if let url = tab.url, let q = library.searchEngine.query(in: url) ?? SearchEngine.google.query(in: url) { return q }
        return tab.host ?? tab.title
    }

    private var addressPill: some View {
        HStack(spacing: 8) {
            if addressFocused {
                Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(.secondary)
                TextField("Suchen oder Adresse eingeben", text: $address)
                    .focused($addressFocused)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .font(.callout)
                    .onSubmit { go(address) }
                if !address.isEmpty {
                    Button { address = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            } else {
                Image(systemName: siteIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tab.isPrivate ? Color.purple : Color.secondary)
                Text(displayText)
                    .font(.subheadline.weight(tab.showStart ? .regular : .semibold))
                    .foregroundStyle(tab.showStart ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                if !tab.showStart {
                    downloadButton
                    Button { tab.reload() } label: {
                        Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 28, height: 34)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.isLoading ? "Laden stoppen" : "Neu laden")
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, addressFocused ? 12 : 6)
        .frame(height: 46)
        .overlay(alignment: .bottom) {
            if tab.isLoading, !tab.showStart, !addressFocused {
                GeometryReader { geo in
                    Capsule().fill(.tint).frame(width: max(8, geo.size.width * tab.progress), height: 2.5)
                }
                .frame(height: 2.5)
                .padding(.horizontal, 18)
                .animation(.easeOut, value: tab.progress)
            }
        }
        .glassEffect(tab.isPrivate ? .regular.tint(.purple.opacity(0.25)).interactive() : .regular.interactive(), in: .capsule)
        .contentShape(.capsule)
        .onTapGesture { if !addressFocused { addressFocused = true } }
    }

    private var siteIcon: String {
        if tab.isPrivate { return "hand.raised.fill" }
        if tab.showStart { return "magnifyingglass" }
        return tab.url?.scheme == "https" ? "lock.fill" : "exclamationmark.triangle.fill"
    }

    private var downloadButton: some View {
        let count = tab.media.filter { $0.kind != .image }.count
        let supported = tab.url.map { MediaSite($0) != .web } ?? false
        return Button { model.openAssistant(for: tab) } label: {
            Image(systemName: count > 0 || supported ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(count > 0 || supported ? Color.accentColor : Color.secondary)
                .symbolEffect(.bounce, value: count)
                .frame(width: 32, height: 34)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(min(count, 99))")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.red, in: .capsule)
                            .offset(x: 2, y: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Download-Assistent")
    }

    private func roundButton(_ icon: String, label: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 46, height: 46)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(label)
    }

    private var tabsButton: some View {
        Button { model.showTabOverview() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(lineWidth: 1.8)
                    .frame(width: 21, height: 21)
                Text("\(min(model.tabs.filter { $0.isPrivate == tab.isPrivate }.count, 99))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .frame(width: 46, height: 46)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Tabs")
        .contextMenu {
            Button("Neuer Tab", systemImage: "plus.square.on.square") { model.newTab(isPrivate: false) }
            Button("Neuer privater Tab", systemImage: "hand.raised") { model.newTab(isPrivate: true) }
            Divider()
            Button("Tab schließen", systemImage: "xmark", role: .destructive) { model.close(tab) }
        }
    }

    private var menuButton: some View {
        let url = tab.showStart ? nil : tab.url
        let bookmark = library.bookmark(for: url)
        return Menu {
            Section {
                Button("Neuer Tab", systemImage: "plus.square.on.square") { model.newTab(isPrivate: tab.isPrivate) }
                if !tab.isPrivate {
                    Button("Neuer privater Tab", systemImage: "hand.raised") { model.newTab(isPrivate: true) }
                }
            }
            if let url {
                Section {
                    Button("Download-Assistent", systemImage: "wand.and.stars") { model.openAssistant(for: tab) }
                    Button(bookmark == nil ? "Lesezeichen hinzufügen" : "Lesezeichen entfernen",
                           systemImage: bookmark == nil ? "bookmark" : "bookmark.slash") {
                        if let bookmark { library.deleteBookmark(bookmark.id); Haptics.tap() } else { library.addBookmark(title: tab.title, url: url) }
                    }
                    Button(bookmark?.isFavorite == true ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen",
                           systemImage: bookmark?.isFavorite == true ? "star.slash" : "star") {
                        if let bookmark { library.toggleFavorite(bookmark.id) } else { library.addBookmark(title: tab.title, url: url, favorite: true) }
                    }
                    Button("Auf der Seite suchen", systemImage: "doc.text.magnifyingglass") { tab.findInPage() }
                    ShareLink(item: url) { Label("Teilen", systemImage: "square.and.arrow.up") }
                    Button("Link kopieren", systemImage: "link") {
                        UIPasteboard.general.url = url
                        Haptics.success()
                    }
                }
                Section {
                    Toggle(isOn: Binding(get: { tab.desktopMode }, set: { tab.setDesktop($0) })) {
                        Label("Desktop-Website", systemImage: "desktopcomputer")
                    }
                    Toggle(isOn: Binding(get: { model.isAdBlockActive(on: tab) }, set: { _ in model.toggleAdBlock(on: tab) })) {
                        Label("Werbeblocker auf \(ContentBlocker.site(of: url) ?? "dieser Seite")", systemImage: "shield.lefthalf.filled")
                    }
                    Menu {
                        ForEach([0.75, 0.85, 1.0, 1.15, 1.3, 1.5], id: \.self) { z in
                            Button {
                                tab.setZoom(z)
                            } label: {
                                if abs(tab.zoom - z) < 0.01 { Label("\(Int(z * 100)) %", systemImage: "checkmark") } else { Text("\(Int(z * 100)) %") }
                            }
                        }
                    } label: { Label("Textgröße · \(Int(tab.zoom * 100)) %", systemImage: "textformat.size") }
                    if tab.canGoForward {
                        Button("Vorwärts", systemImage: "chevron.forward") { tab.goForward() }
                    }
                    Button("In Safari öffnen", systemImage: "safari") { UIApplication.shared.open(url) }
                }
            }
            Section {
                Button("Lesezeichen", systemImage: "book") { sheet = .bookmarks }
                Button("Verlauf", systemImage: "clock") { sheet = .history }
                Button("Mediathek", systemImage: "square.stack.fill") { sheet = .library }
                Button("Website-Daten & Cookies", systemImage: "list.bullet.rectangle") { sheet = .websiteData }
                Button("Browser-Einstellungen", systemImage: "gearshape") { sheet = .settings }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .frame(width: 46, height: 46)
                .contentShape(.circle)
        }
        .menuOrder(.priority)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Mehr")
    }

    // MARK: Suggestions

    private var suggestions: some View {
        let text = address.trimmingCharacters(in: .whitespaces)
        let local = library.suggestions(for: text, limit: 4)
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if text.isEmpty {
                    HStack(spacing: 10) {
                        PasteButton(payloadType: String.self) { strings in
                            Task { @MainActor in
                                if let s = strings.first { go(s) }
                            }
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                        Text("Link einfügen und öffnen").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    if !library.favorites.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(library.favorites) { b in
                                    Button { go(b.url.absoluteString) } label: { SiteTile(title: b.title, url: b.url, size: 46) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                        }
                    }
                } else {
                    suggestionRow(icon: "magnifyingglass", title: "„\(text)“", subtitle: "Mit \(library.searchEngine.name) suchen") {
                        go(text)
                    }
                    if let url = BrowserModel.url(from: text), MediaSite(url) != .web || MediaKind(fileExtension: url.pathExtension) != .file {
                        suggestionRow(icon: "arrow.down.circle.fill", title: "Herunterladen", subtitle: url.host ?? text) {
                            addressFocused = false
                            LinkRouter.shared.download(url, isPrivate: tab.isPrivate)
                        }
                    }
                    ForEach(local) { s in
                        suggestionRow(icon: s.isBookmark ? "book.fill" : "clock.arrow.circlepath", title: s.title,
                                      subtitle: s.url.absoluteString.replacingOccurrences(of: "https://", with: ""), favicon: s.url) {
                            go(s.url.absoluteString)
                        }
                    }
                    ForEach(remote.filter { $0.lowercased() != text.lowercased() }.prefix(5), id: \.self) { s in
                        suggestionRow(icon: "magnifyingglass", title: s, subtitle: nil) { go(s) }
                    }
                }
            }
            .padding(6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 340)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func suggestionRow(icon: String, title: String, subtitle: String?, favicon: URL? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if let favicon {
                        RemoteImage(url: BrowserLibrary.favicon(for: favicon)).frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Image(systemName: icon).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func loadSuggestions() async {
        let q = address.trimmingCharacters(in: .whitespaces)
        guard addressFocused, q.count >= 2, !q.contains("://"), let url = library.searchEngine.suggestionsURL(for: q) else {
            remote = []
            return
        }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        let j = JSON(data: data)
        remote = j[1].array.compactMap(\.string)
    }

    private func go(_ text: String) {
        addressFocused = false
        model.submit(text, in: tab)
    }

    // MARK: Overlays

    private func playingPill(_ playing: PlayingMedia) -> some View {
        HStack(spacing: 10) {
            Image(systemName: playing.kind == .audio ? "waveform" : "play.rectangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, isActive: playing.kind == .audio)
            VStack(alignment: .leading, spacing: 0) {
                Text(playing.kind == .audio ? "Ton wird abgespielt" : "Video wird abgespielt").font(.caption2).foregroundStyle(.secondary)
                Text(playing.title.isEmpty ? (tab.host ?? "") : playing.title).font(.footnote.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                if let src = playing.url {
                    let kind = MediaKind(fileExtension: src.pathExtension) == .stream ? MediaKind.stream : playing.kind
                    model.presentNative(src, kind: kind, title: playing.title, poster: playing.poster, tab: tab)
                } else if let target = playing.link ?? tab.url {
                    DownloadAssistant.shared.start(target, pageMedia: tab.media, page: tab.url, userAgent: tab.userAgent,
                                                   isPrivate: tab.isPrivate, autoStart: false)
                }
            } label: {
                Label("Speichern", systemImage: "arrow.down.circle.fill").font(.footnote.weight(.semibold))
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            Button { tab.playing = nil } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 40)).foregroundStyle(.orange)
            Text("Seite kann nicht geladen werden").font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Erneut versuchen", systemImage: "arrow.clockwise") {
                tab.loadError = nil
                if tab.webView.url != nil { tab.webView.reload() } else if let url = tab.url { tab.load(url) }
            }
            .buttonStyle(.glassProminent)
        }
        .padding(26)
        .frame(maxWidth: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(24)
    }
}

/// Hosts the selected tab's web view (swapped in place when the tab changes).
struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        attach(to: container)
    }

    private func attach(to container: UIView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}

/// Favicon tile (start page, favourites).
struct SiteTile: View {
    let title: String
    let url: URL
    var size: CGFloat = 60

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                RemoteImage(url: BrowserLibrary.favicon(for: url))
                    .frame(width: size * 0.5, height: size * 0.5)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
            }
            .frame(width: size, height: size)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: size * 0.28))
            Text(title).font(.caption).lineLimit(1).frame(width: size + 16)
        }
    }
}

// MARK: - Start page

private struct StartPage: View {
    @ObservedObject var tab: BrowserTab
    @Binding var sheet: BrowserSheet?
    @ObservedObject private var library = BrowserLibrary.shared
    @ObservedObject private var files = FileDownloads.shared
    @ObservedObject private var model = BrowserModel.shared
    @State private var link = ""
    @FocusState private var linkFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                if tab.isPrivate { privateInfo }
                downloadBox
                if !library.favorites.isEmpty {
                    section("Favoriten") {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(library.favorites) { b in
                                Button { tab.load(b.url) } label: { SiteTile(title: b.title, url: b.url) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("In neuem Tab öffnen", systemImage: "plus.square.on.square") { model.newTab(b.url, isPrivate: tab.isPrivate) }
                                        Button("Aus Favoriten entfernen", systemImage: "star.slash") { library.toggleFavorite(b.id) }
                                        Button("Lesezeichen löschen", systemImage: "trash", role: .destructive) { library.deleteBookmark(b.id) }
                                    }
                            }
                        }
                    }
                }
                let frequent = tab.isPrivate ? [] : library.frequentSites(limit: 8)
                if !frequent.isEmpty {
                    section("Häufig besucht") {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(frequent) { s in
                                Button { tab.load(s.url) } label: { SiteTile(title: s.title, url: s.url) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Zu Favoriten", systemImage: "star") { library.addBookmark(title: s.title, url: s.url, favorite: true) }
                                    }
                            }
                        }
                    }
                }
                if !files.files.isEmpty { recentDownloads }
                shareTip
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 30)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(background.ignoresSafeArea())
    }

    private var background: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(colors: tab.isPrivate ? [.purple.opacity(0.35), .clear] : [.accentColor.opacity(0.16), .purple.opacity(0.08), .clear],
                           startPoint: .top, endPoint: .center)
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: tab.isPrivate ? "hand.raised.fill" : "sparkles")
                .font(.title.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(LinearGradient(colors: tab.isPrivate ? [.purple, .indigo] : [.accentColor, .purple],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .purple.opacity(0.35), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.isPrivate ? "Privat surfen" : "Nova")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text(tab.isPrivate ? "Kein Verlauf, keine Cookies nach dem Schließen" : "Browser · Downloader · Mediathek")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { model.isPresented = false } label: {
                Image(systemName: "chevron.down").font(.headline).frame(width: 40, height: 40)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Browser schließen")
        }
    }

    private var privateInfo: some View {
        Label("Private Tabs teilen keine Anmeldungen mit normalen Tabs. Alles wird gelöscht, sobald du den letzten privaten Tab schließt.",
              systemImage: "eye.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(14)
            .glassEffect(.regular.tint(.purple.opacity(0.2)), in: .rect(cornerRadius: 20))
    }

    private var downloadBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(.tint)
                Text("Download-Assistent").font(.headline)
            }
            Text("TikTok, Instagram, Facebook, X, Reddit, Vimeo oder ein Datei-Link – einfügen und fertig, ganz ohne Browser.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Link einfügen …", text: $link)
                    .focused($linkFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(process)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Color.primary.opacity(0.06), in: .capsule)
                if link.isEmpty {
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in
                            link = strings.first ?? ""
                            process()
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                } else {
                    Button(action: process) {
                        Image(systemName: "arrow.down").font(.headline).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private var recentDownloads: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { sheet = .library } label: {
                HStack(spacing: 6) {
                    Text("Mediathek").font(.title3.weight(.bold))
                    Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(files.files.count) Dateien").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(files.files.prefix(10)) { f in
                        Button { sheet = .library } label: {
                            MediaThumb(file: f)
                                .frame(width: 92, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(alignment: .bottomLeading) {
                                    Image(systemName: f.kind.icon)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 2)
                                        .padding(7)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private var shareTip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Direkt aus TikTok & Co.", systemImage: "square.and.arrow.up.on.square").font(.headline)
            Text("In TikTok, Instagram, Facebook … auf „Teilen“ tippen und Nova wählen (ggf. unter „Mehr“ aktivieren). Der Download startet sofort – oder kopier den Link einfach, Nova erkennt ihn beim Öffnen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold))
            content()
        }
    }

    private func process() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        linkFocused = false
        guard !text.isEmpty else { return }
        if let url = BrowserModel.url(from: text) ?? LinkRouter.firstURL(in: text) {
            Haptics.impact()
            link = ""
            LinkRouter.shared.download(url, isPrivate: tab.isPrivate)
        } else {
            model.submit(text, in: tab)
        }
    }
}

// MARK: - Tab overview

private struct TabOverview: View {
    @ObservedObject private var model = BrowserModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showPrivate = false

    private var tabs: [BrowserTab] { showPrivate ? model.privateTabs : model.normalTabs }

    var body: some View {
        NavigationStack {
            ScrollView {
                if tabs.isEmpty {
                    ContentUnavailableView {
                        Label(showPrivate ? "Privates Surfen" : "Keine Tabs", systemImage: showPrivate ? "hand.raised.fill" : "square.on.square")
                    } description: {
                        Text(showPrivate ? "Private Tabs speichern keinen Verlauf und vergessen Anmeldungen, sobald du sie schließt." : "")
                    } actions: {
                        Button("Neuer Tab", systemImage: "plus") { newTab() }.buttonStyle(.glassProminent)
                    }
                    .padding(.top, 80)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                    ForEach(tabs) { tab in
                        TabCard(tab: tab, selected: tab.id == model.selectedID) {
                            model.select(tab)
                            dismiss()
                        } onClose: {
                            withAnimation(.snappy) { model.close(tab) }
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(16)
                .animation(.snappy, value: tabs.count)
            }
            .background((showPrivate ? Color.black : Color(.secondarySystemBackground)).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Tabs", selection: $showPrivate) {
                        Text("\(model.normalTabs.count) Tabs").tag(false)
                        Text("Privat").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if !tabs.isEmpty {
                            Button("Alle \(tabs.count) Tabs schließen", systemImage: "xmark.square", role: .destructive) {
                                withAnimation(.snappy) { model.closeAllTabs(isPrivate: showPrivate) }
                            }
                        }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                GlassEffectContainer(spacing: 10) {
                    HStack {
                        Button { newTab() } label: {
                            Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 52, height: 52)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("Neuer Tab")
                        Spacer()
                        Button { dismiss() } label: {
                            Text("Fertig").font(.headline).padding(.horizontal, 22).frame(height: 52)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                }
            }
        }
        .preferredColorScheme(showPrivate ? .dark : nil)
        .onAppear { showPrivate = model.current.isPrivate }
    }

    private func newTab() {
        model.newTab(isPrivate: showPrivate)
        dismiss()
    }
}

private struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    @State private var drag: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if tab.showStart, tab.url == nil {
                    Image(systemName: "sparkles").font(.caption2)
                } else {
                    RemoteImage(url: BrowserLibrary.favicon(for: tab.url))
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(tab.showStart && tab.url == nil ? "Startseite" : (tab.title.isEmpty ? (tab.host ?? "Tab") : tab.title))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.caption2.weight(.bold)).frame(width: 22, height: 22)
                        .background(.thinMaterial, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tab schließen")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            ZStack {
                Color(.systemBackground)
                if let image = tab.snapshot, !(tab.showStart && tab.url == nil) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: tab.isPrivate ? "hand.raised.fill" : "sparkles")
                            .font(.title)
                            .foregroundStyle(.tint)
                        if let host = tab.host { Text(host).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            .aspectRatio(0.72, contentMode: .fit)
            .clipped()
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .offset(x: drag)
        .opacity(1 - Double(min(abs(drag), 200)) / 300)
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { v in if abs(v.translation.width) > abs(v.translation.height) { drag = v.translation.width } }
                .onEnded { v in
                    if abs(v.translation.width) > 110 { onClose() } else { withAnimation(.snappy) { drag = 0 } }
                }
        )
        .contextMenu {
            Button("Schließen", systemImage: "xmark", role: .destructive, action: onClose)
            if let url = tab.url {
                Button("Link kopieren", systemImage: "link") { UIPasteboard.general.url = url }
            }
        }
    }
}
