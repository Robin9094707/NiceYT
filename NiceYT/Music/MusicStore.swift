import SwiftUI

/// Deezer account state and the data of the music start page.
@MainActor
final class MusicStore: ObservableObject {
    static let shared = MusicStore()

    @Published private(set) var user: DZUser?
    @Published private(set) var isRestoring = Deezer.storedARL != nil
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var playlists: [DZPlaylist] = []
    @Published private(set) var charts: [DZTrack] = []
    @Published private(set) var chartPlaylists: [DZPlaylist] = []
    @Published private(set) var isLoadingHome = false
    @Published private(set) var homeError: String?
    private var homeLoaded = false

    var isLoggedIn: Bool { user != nil }

    func restore() async {
        guard user == nil else { return }
        isRestoring = Deezer.storedARL != nil
        user = await Deezer.shared.restore()
        isRestoring = false
        if user != nil { await loadHome() }
    }

    func login(arl: String) async throws {
        let u = try await Deezer.shared.login(arl: arl)
        user = u
        Haptics.success()
        homeLoaded = false
        await loadHome()
    }

    func logout() async {
        await Deezer.shared.logout()
        MusicPlayer.shared.stop()
        user = nil
        favorites = []
        playlists = []
        charts = []
        chartPlaylists = []
        homeLoaded = false
        Haptics.warning()
    }

    func loadHome(force: Bool = false) async {
        guard user != nil, force || !homeLoaded, !isLoadingHome else { return }
        isLoadingHome = true
        homeError = nil
        async let fav = Deezer.shared.favoriteIds()
        async let lists = try? Deezer.shared.userPlaylists()
        async let top = try? Deezer.shared.chartTracks(limit: 50)
        async let topLists = Deezer.shared.chartPlaylists(limit: 20)
        favorites = await fav
        playlists = await lists ?? playlists
        charts = await top ?? charts
        chartPlaylists = await topLists
        if charts.isEmpty, playlists.isEmpty { homeError = "Deezer ist gerade nicht erreichbar." }
        homeLoaded = true
        isLoadingHome = false
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ track: DZTrack) {
        let on = !favorites.contains(track.id)
        if on { favorites.insert(track.id); Haptics.like() } else { favorites.remove(track.id); Haptics.tap() }
        Task {
            do {
                try await Deezer.shared.setFavorite(track.id, on)
                MusicPlayer.shared.toast(on ? "Zu Lieblingssongs hinzugefügt" : "Aus Lieblingssongs entfernt")
            } catch {
                if on { favorites.remove(track.id) } else { favorites.insert(track.id) }
                Haptics.error()
                MusicPlayer.shared.toast(error.localizedDescription)
            }
        }
    }
}
