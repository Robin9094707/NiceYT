import SwiftUI
import WebKit

/// Removes the data of one service (or everything) for a fresh start.
@MainActor
enum DataReset {
    static func youTube(account: AccountStore) async {
        account.signOut()
        for key in ["searchHistory", "visitorData", "accountInfo"] { UserDefaults.standard.removeObject(forKey: key) }
        PositionStore.clear()
        YouTubeDownloads.shared.deleteAll()
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        URLCache.shared.removeAllCachedResponses()
    }

    static func deezer(includeDownloads: Bool) async {
        await MusicStore.shared.logout()
        if includeDownloads { DownloadStore.shared.delete { $0.track.isDeezer } }
    }

    static func spotify(includeDownloads: Bool) async {
        await MusicStore.shared.disconnectSpotify()
        Spotify.clientId = nil
        if includeDownloads { DownloadStore.shared.delete { $0.track.isSpotify } }
    }

    static func everything(account: AccountStore) async {
        await youTube(account: account)
        await deezer(includeDownloads: true)
        await spotify(includeDownloads: true)
        MusicPlayer.shared.stop()
        DownloadStore.shared.deleteAll()
        YouTubeDownloads.shared.deleteAll()
        for key in ["cookies", "deezerARL", "spotifyRefreshToken"] { Keychain.remove(key) }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for url in (try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: url) }
        for url in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: url) }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        DebugLog.log("Alle Daten gelöscht")
    }
}

struct DataResetView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var store: MusicStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var ytDownloads: YouTubeDownloads
    @State private var deezerDownloads = false
    @State private var spotifyDownloads = false
    @State private var pending: Target?
    @State private var working = false
    @State private var done: String?

    enum Target: Identifiable {
        case youTube, deezer, spotify, everything
        var id: Self { self }
    }

    var body: some View {
        Form {
            Section {
                resetButton("YouTube-Daten löschen", icon: "play.rectangle", target: .youTube)
            } header: {
                Text("YouTube")
            } footer: {
                Text("Meldet dich ab und löscht Cookies, Suchverlauf, Weiterschauen-Positionen und \(ytDownloads.videos.count) heruntergeladene Videos.")
            }

            Section {
                Toggle("Auch Deezer-Downloads löschen", isOn: $deezerDownloads)
                resetButton(store.user == nil ? "Deezer-Daten löschen" : "Deezer abmelden & Daten löschen",
                            icon: "waveform", target: .deezer)
            } header: {
                Text("Deezer")
            } footer: {
                Text("Löscht den gespeicherten ARL-Cookie und das Konto. \(downloads.items.filter { $0.track.isDeezer }.count) Songs stammen von Deezer.")
            }

            Section {
                Toggle("Auch Spotify-Downloads löschen", isOn: $spotifyDownloads)
                resetButton(store.spotifyUser == nil ? "Spotify-Daten löschen" : "Spotify trennen & Daten löschen",
                            icon: "dot.radiowaves.left.and.right", target: .spotify)
            } header: {
                Text("Spotify")
            } footer: {
                Text("Löscht die Spotify-Anmeldung (auch die Client-ID). \(downloads.items.filter { $0.track.isSpotify }.count) Songs stammen aus Spotify.")
            }

            Section {
                resetButton("Alles löschen & neu anfangen", icon: "trash.fill", target: .everything)
            } footer: {
                Text("Entfernt alle Konten, Downloads, Einstellungen und Caches – als wäre die App neu installiert. Danach die App einmal neu starten.")
            }

            if let done {
                Section { Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .navigationTitle("Daten löschen")
        .disabled(working)
        .overlay { if working { ProgressView().controlSize(.large) } }
        .confirmationDialog(title(pending), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { target in
            Button("Endgültig löschen", role: .destructive) { run(target) }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Das kann nicht rückgängig gemacht werden.")
        }
    }

    private func resetButton(_ title: String, icon: String, target: Target) -> some View {
        Button(role: .destructive) {
            Haptics.warning()
            pending = target
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private func title(_ target: Target?) -> String {
        switch target {
        case .youTube: return "Alle YouTube-Daten löschen?"
        case .deezer: return deezerDownloads ? "Deezer-Daten und -Downloads löschen?" : "Deezer-Daten löschen?"
        case .spotify: return spotifyDownloads ? "Spotify-Daten und -Downloads löschen?" : "Spotify-Daten löschen?"
        case .everything: return "Wirklich alles löschen?"
        case nil: return ""
        }
    }

    private func run(_ target: Target) {
        working = true
        Task {
            switch target {
            case .youTube: await DataReset.youTube(account: account)
            case .deezer: await DataReset.deezer(includeDownloads: deezerDownloads)
            case .spotify: await DataReset.spotify(includeDownloads: spotifyDownloads)
            case .everything: await DataReset.everything(account: account)
            }
            working = false
            pending = nil
            Haptics.success()
            done = target == .everything ? "Alles gelöscht – bitte die App einmal neu starten." : "Gelöscht."
        }
    }
}
