import SwiftUI
import WebKit

/// Wraps the browser's sheets in a navigation stack with a "Fertig" button.
struct BrowserSheetView: View {
    let sheet: BrowserSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch sheet {
                case .bookmarks: BookmarksView(onOpen: open)
                case .history: HistoryView(onOpen: open)
                case .library: MediaLibraryView()
                case .websiteData: WebsiteDataView()
                case .settings: BrowserSettingsView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .confirmations(active: true)
    }

    private func open(_ url: URL, newTab: Bool) {
        let model = BrowserModel.shared
        if newTab { model.newTab(url, isPrivate: model.current.isPrivate) } else { model.current.load(url) }
        dismiss()
    }
}

// MARK: - Bookmarks

struct BookmarksView: View {
    var onOpen: (URL, Bool) -> Void
    @ObservedObject private var library = BrowserLibrary.shared
    @State private var search = ""
    @State private var editing: Bookmark?

    private var shown: [Bookmark] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return library.bookmarks }
        return library.bookmarks.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.url.absoluteString.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if library.bookmarks.isEmpty {
                ContentUnavailableView("Keine Lesezeichen", systemImage: "book",
                                       description: Text("Im Browser über ⋯ → „Lesezeichen hinzufügen“ speichern."))
                    .listRowBackground(Color.clear)
            }
            ForEach(shown) { b in
                Button { onOpen(b.url, false) } label: {
                    HStack(spacing: 12) {
                        RemoteImage(url: BrowserLibrary.favicon(for: b.url))
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text(b.url.host ?? b.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if b.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Löschen", systemImage: "trash", role: .destructive) { library.deleteBookmark(b.id) }
                    Button("Bearbeiten", systemImage: "pencil") { editing = b }.tint(.blue)
                }
                .swipeActions(edge: .leading) {
                    Button(b.isFavorite ? "Kein Favorit" : "Favorit", systemImage: b.isFavorite ? "star.slash" : "star") {
                        library.toggleFavorite(b.id)
                    }
                    .tint(.yellow)
                }
                .contextMenu {
                    Button("In neuem Tab öffnen", systemImage: "plus.square.on.square") { onOpen(b.url, true) }
                    Button("Bearbeiten", systemImage: "pencil") { editing = b }
                    Button(b.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten", systemImage: "star") { library.toggleFavorite(b.id) }
                    Button("Link kopieren", systemImage: "link") { UIPasteboard.general.url = b.url }
                    Button("Löschen", systemImage: "trash", role: .destructive) { library.deleteBookmark(b.id) }
                }
            }
            .onMove { library.moveBookmarks(from: $0, to: $1) }
        }
        .searchable(text: $search, prompt: "Lesezeichen durchsuchen")
        .navigationTitle("Lesezeichen")
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        .sheet(item: $editing) { BookmarkEditor(bookmark: $0) }
    }
}

private struct BookmarkEditor: View {
    @State var bookmark: Bookmark
    @State private var link = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel", text: $bookmark.title)
                    TextField("Adresse", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section { Toggle("Auf der Startseite (Favorit)", isOn: $bookmark.isFavorite) }
            }
            .navigationTitle("Lesezeichen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if let url = BrowserModel.url(from: link) { bookmark.url = url }
                        BrowserLibrary.shared.update(bookmark)
                        Haptics.success()
                        dismiss()
                    }
                    .disabled(bookmark.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { link = bookmark.url.absoluteString }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - History

struct HistoryView: View {
    var onOpen: (URL, Bool) -> Void
    @ObservedObject private var library = BrowserLibrary.shared
    @State private var search = ""
    @State private var confirmClear = false

    private struct DayGroup: Identifiable {
        let day: Date
        var entries: [HistoryEntry]
        var id: Date { day }
    }

    private var groups: [DayGroup] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? library.history : library.history.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.url.absoluteString.localizedCaseInsensitiveContains(q)
        }
        let calendar = Calendar.current
        var out: [DayGroup] = []
        for entry in list.prefix(1500) {
            let day = calendar.startOfDay(for: entry.date)
            if out.last?.day == day { out[out.count - 1].entries.append(entry) } else { out.append(DayGroup(day: day, entries: [entry])) }
        }
        return out
    }

    var body: some View {
        List {
            if library.history.isEmpty {
                ContentUnavailableView("Kein Verlauf", systemImage: "clock", description: Text("Besuchte Seiten erscheinen hier (private Tabs nicht)."))
                    .listRowBackground(Color.clear)
            }
            ForEach(groups) { group in
                Section(header: Text(title(for: group.day))) {
                    ForEach(group.entries) { entry in
                        Button { onOpen(entry.url, false) } label: {
                            HStack(spacing: 12) {
                                RemoteImage(url: BrowserLibrary.favicon(for: entry.url))
                                    .frame(width: 24, height: 24)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title.isEmpty ? (entry.url.host ?? "") : entry.title)
                                        .font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                    Text(entry.url.absoluteString.replacingOccurrences(of: "https://", with: ""))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Text(entry.date, style: .time).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .swipeActions { Button("Löschen", systemImage: "trash", role: .destructive) { library.deleteHistory([entry.id]) } }
                        .contextMenu {
                            Button("In neuem Tab öffnen", systemImage: "plus.square.on.square") { onOpen(entry.url, true) }
                            Button("Lesezeichen hinzufügen", systemImage: "bookmark") { library.addBookmark(title: entry.title, url: entry.url) }
                            Button("Link kopieren", systemImage: "link") { UIPasteboard.general.url = entry.url }
                            Button("Löschen", systemImage: "trash", role: .destructive) { library.deleteHistory([entry.id]) }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Verlauf durchsuchen")
        .navigationTitle("Verlauf")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Löschen") { confirmClear = true }.disabled(library.history.isEmpty)
            }
        }
        .confirmationDialog("Verlauf löschen", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Letzte Stunde", role: .destructive) { library.clearHistory(since: Date().addingTimeInterval(-3600)) }
            Button("Heute", role: .destructive) { library.clearHistory(since: Calendar.current.startOfDay(for: Date())) }
            Button("Heute und gestern", role: .destructive) {
                library.clearHistory(since: Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())))
            }
            Button("Gesamter Verlauf", role: .destructive) { library.clearHistory() }
        } message: {
            Text("Cookies und Website-Daten bleiben erhalten – die löschst du unter „Website-Daten“.")
        }
    }

    private func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Heute" }
        if calendar.isDateInYesterday(day) { return "Gestern" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

// MARK: - Website data & cookies

/// Cookies and stored data of every site, deletable one by one.
struct WebsiteDataView: View {
    @State private var sites: [Site] = []
    @State private var loading = true
    @State private var search = ""
    @State private var confirmAll = false

    struct Site: Identifiable, Hashable {
        let domain: String
        var cookies: [HTTPCookie]
        var record: WKWebsiteDataRecord?
        var id: String { domain }

        var summary: String {
            var parts: [String] = []
            if !cookies.isEmpty { parts.append("\(cookies.count) Cookie\(cookies.count == 1 ? "" : "s")") }
            let types = record?.dataTypes ?? []
            if types.contains(WKWebsiteDataTypeLocalStorage) || types.contains(WKWebsiteDataTypeIndexedDBDatabases) { parts.append("Speicher") }
            if types.contains(WKWebsiteDataTypeDiskCache) || types.contains(WKWebsiteDataTypeMemoryCache) { parts.append("Cache") }
            if types.contains(WKWebsiteDataTypeServiceWorkerRegistrations) { parts.append("Service Worker") }
            return parts.isEmpty ? "Daten" : parts.joined(separator: " · ")
        }
    }

    private var shown: [Site] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? sites : sites.filter { $0.domain.contains(q) }
    }

    var body: some View {
        List {
            Section {
                ForEach(shown) { site in
                    NavigationLink {
                        SiteDataView(site: site) { await reload() }
                    } label: {
                        HStack(spacing: 12) {
                            RemoteImage(url: BrowserLibrary.favicon(for: URL(string: "https://\(site.domain)")))
                                .frame(width: 26, height: 26)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site.domain).font(.subheadline.weight(.medium))
                                Text(site.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Löschen", systemImage: "trash", role: .destructive) { Task { await delete(site) } }
                    }
                }
            } header: {
                if !sites.isEmpty { Text("\(sites.count) Websites") }
            } footer: {
                Text("Gilt für normale Tabs. Private Tabs speichern nichts dauerhaft. Abgemeldet wirst du nur auf Seiten, deren Cookies du löschst.")
            }
        }
        .overlay {
            if loading { ProgressView() } else if sites.isEmpty {
                ContentUnavailableView("Keine Website-Daten", systemImage: "checkmark.shield")
            }
        }
        .searchable(text: $search, prompt: "Website suchen")
        .navigationTitle("Website-Daten")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Alle löschen", role: .destructive) { confirmAll = true }.disabled(sites.isEmpty)
            }
        }
        .confirmationDialog("Alle Cookies und Website-Daten löschen?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Alle löschen", role: .destructive) {
                Task {
                    await BrowserModel.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                    Haptics.warning()
                    await reload()
                }
            }
        } message: {
            Text("Du wirst auf allen Websites im Browser abgemeldet.")
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        let store = BrowserModel.dataStore
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let cookies = await store.httpCookieStore.allCookies()
        var map: [String: Site] = [:]
        for r in records {
            let d = Self.base(r.displayName)
            map[d, default: Site(domain: d, cookies: [], record: nil)].record = r
        }
        for c in cookies {
            let d = Self.base(c.domain)
            map[d, default: Site(domain: d, cookies: [], record: nil)].cookies.append(c)
        }
        sites = map.values.sorted { $0.domain < $1.domain }
        loading = false
    }

    private func delete(_ site: Site) async {
        let store = BrowserModel.dataStore
        for c in site.cookies { await store.httpCookieStore.deleteCookie(c) }
        if let record = site.record { await store.removeData(ofTypes: record.dataTypes, for: [record]) }
        Haptics.warning()
        await reload()
    }

    static func base(_ domain: String) -> String {
        var d = domain.lowercased()
        if d.hasPrefix(".") { d.removeFirst() }
        if d.hasPrefix("www.") { d.removeFirst(4) }
        return ContentBlocker.site(of: URL(string: "https://" + d)) ?? d
    }
}

private struct SiteDataView: View {
    @State var site: WebsiteDataView.Site
    var onChange: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var shownValue: String?

    var body: some View {
        List {
            Section {
                Button(role: .destructive) {
                    Task {
                        let store = BrowserModel.dataStore
                        for c in site.cookies { await store.httpCookieStore.deleteCookie(c) }
                        if let record = site.record { await store.removeData(ofTypes: record.dataTypes, for: [record]) }
                        Haptics.warning()
                        await onChange()
                        dismiss()
                    }
                } label: {
                    Label("Alle Daten dieser Website löschen", systemImage: "trash")
                }
            } footer: {
                Text(site.summary)
            }
            if !site.cookies.isEmpty {
                Section("Cookies") {
                    ForEach(site.cookies, id: \.self) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(c.name).font(.subheadline.weight(.semibold).monospaced()).lineLimit(1)
                                Spacer()
                                if c.isSecure { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                                if c.isHTTPOnly { Text("HTTP").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                            }
                            Text(shownValue == c.name + c.domain ? c.value : String(c.value.prefix(42)) + (c.value.count > 42 ? "…" : ""))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(shownValue == c.name + c.domain ? nil : 1)
                            Text("\(c.domain) · \(c.expiresDate.map { "bis " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "Sitzung")")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                        .onTapGesture { shownValue = shownValue == c.name + c.domain ? nil : c.name + c.domain }
                        .swipeActions {
                            Button("Löschen", systemImage: "trash", role: .destructive) {
                                Task {
                                    await BrowserModel.dataStore.httpCookieStore.deleteCookie(c)
                                    site.cookies.removeAll { $0 == c }
                                    Haptics.tap()
                                    await onChange()
                                }
                            }
                        }
                        .contextMenu {
                            Button("Wert kopieren", systemImage: "doc.on.doc") { UIPasteboard.general.string = c.value }
                        }
                    }
                }
            }
        }
        .navigationTitle(site.domain)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Settings

struct BrowserSettingsView: View {
    @ObservedObject private var library = BrowserLibrary.shared
    @ObservedObject private var lock = AppLock.shared

    var body: some View {
        Form {
            Section("Suche") {
                Picker("Suchmaschine", selection: $library.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
            }

            Section {
                Toggle(isOn: $library.adBlock) { Label("Werbeblocker", systemImage: "shield.lefthalf.filled") }
                if !library.adBlockExceptions.isEmpty {
                    NavigationLink {
                        List {
                            ForEach(library.adBlockExceptions.sorted(), id: \.self) { site in Text(site) }
                                .onDelete { idx in
                                    let sorted = library.adBlockExceptions.sorted()
                                    for i in idx { library.adBlockExceptions.remove(sorted[i]) }
                                }
                        }
                        .navigationTitle("Ausnahmen")
                    } label: {
                        LabeledContent("Ausnahmen", value: "\(library.adBlockExceptions.count)")
                    }
                }
            } header: {
                Text("Schutz")
            } footer: {
                Text("Blockiert Werbung und Tracker von über 100 bekannten Werbenetzwerken. Auf einzelnen Seiten über ⋯ → Werbeblocker abschaltbar.")
            }

            Section {
                Toggle(isOn: $library.mediaButtons) { Label("Download-Knopf an Videos", systemImage: "arrow.down.circle") }
                Toggle(isOn: $library.quickDownload) { Label("Beste Qualität sofort laden", systemImage: "bolt.fill") }
                Picker(selection: $library.downloadTarget) {
                    ForEach(DownloadTarget.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                } label: {
                    Label("Zusätzlich sichern in", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Der Knopf erscheint oben rechts an jedem Video- und Audio-Player einer Seite. „Sofort laden“ startet bei geteilten und eingefügten Links direkt den empfohlenen Download.")
            }

            Section {
                Toggle(isOn: Binding(get: { library.lockWithFaceID }, set: { on in Task { await lock.setEnabled(on) } })) {
                    Label("Mit \(lock.biometry.name) sperren", systemImage: lock.biometry.icon)
                }
                Toggle(isOn: $library.restoreTabs) { Label("Tabs beim Start wiederherstellen", systemImage: "square.on.square") }
            } header: {
                Text("Privatsphäre")
            } footer: {
                Text("Die Sperre schützt Browser und Mediathek. Passwörter und Passkeys aus dem iCloud-Schlüsselbund oder anderen Passwort-Apps füllst du über die Taste über der Tastatur aus.")
            }

            Section {
                NavigationLink { WebsiteDataView() } label: { Label("Website-Daten & Cookies", systemImage: "list.bullet.rectangle") }
                Button(role: .destructive) {
                    ConfirmCenter.shared.ask("Verlauf löschen?", message: "Lesezeichen und Cookies bleiben erhalten.") { library.clearHistory() }
                } label: {
                    Label("Verlauf löschen", systemImage: "clock.badge.xmark")
                }
            }
        }
        .navigationTitle("Browser")
    }
}
