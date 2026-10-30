import SwiftUI

/// Deezer account state and the data of the music start page.
@MainActor
final class MusicStore: ObservableObject {
    static let shared = MusicStore()

    /// Shown immediately from the last session; verified against Deezer in the background.
    @Published private(set) var user: DZUser? = Deezer.storedARL != nil ? Deezer.cachedUser : nil
    @Published private(set) var isRestoring = Deezer.storedARL != nil && Deezer.cachedUser == nil
    /// The stored session couldn't be confirmed (kept, not deleted – shown as a hint).
    @Published private(set) var sessionProblem: String?
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var playlists: [DZPlaylist] = []
    @Published private(set) var charts: [DZTrack] = []
    @Published private(set) var chartPlaylists: [DZPlaylist] = []
    @Published private(set) var isLoadingHome = false
    @Published private(set) var homeError: String?
    /// Bumped whenever the favourites change (the favourites list reloads).
    @Published private(set) var favoritesVersion = 0
    // Spotify
    @Published private(set) var spotifyUser: SPUser? = Spotify.cachedUser
    @Published private(set) var spotifyPlaylists: [SPPlaylist] = []
    @Published private(set) var spotifyProblem: String?
    private var spotifyLoaded = false

    var isSpotifyConnected: Bool { spotifyUser != nil }
    var hasAnySource: Bool { user != nil || spotifyUser != nil }

    private var homeLoaded = false
    private var verified = false
    private var restoring = false

    var isLoggedIn: Bool { user != nil }

    func restore() async {
        guard !verified, !restoring, Deezer.storedARL != nil else {
            isRestoring = false
            return
        }
        restoring = true
        defer { restoring = false }
        if let u = await Deezer.shared.restore() {
            user = u
            verified = true
            sessionProblem = nil
            isRestoring = false
            await loadHome()
            return
        }
        isRestoring = false
        if user != nil {
            // Keep the account and its downloads; the next request tries again.
            sessionProblem = "Deezer ist gerade nicht erreichbar oder die Sitzung muss erneuert werden."
            await loadHome()
        }
    }

    /// Manual "try again" from the hint banner.
    func retrySession() async {
        verified = false
        sessionProblem = nil
        await restore()
    }

    func login(arl: String) async throws {
        let u = try await Deezer.shared.login(arl: arl)
        user = u
        verified = true
        sessionProblem = nil
        Haptics.success()
        homeLoaded = false
        await loadHome()
    }

    func logout() async {
        await Deezer.shared.logout()
        MusicPlayer.shared.stop()
        user = nil
        verified = false
        sessionProblem = nil
        favorites = []
        playlists = []
        charts = []
        chartPlaylists = []
        homeLoaded = false
        Haptics.warning()
    }

    func loadHome(force: Bool = false) async {
        guard user != nil, force || !homeLoaded, !isLoadingHome else { return }
        if force, !verified { await restore() }
        isLoadingHome = true
        homeError = nil
        async let fav = Deezer.shared.favoriteIds()
        async let lists = try? Deezer.shared.userPlaylists()
        async let top = try? Deezer.shared.chartTracks(limit: 50)
        async let topLists = Deezer.shared.chartPlaylists(limit: 20)
        let favIds = await fav
        if !favIds.isEmpty || favorites.isEmpty { favorites = favIds }
        playlists = await lists ?? playlists
        charts = await top ?? charts
        let tl = await topLists
        if !tl.isEmpty { chartPlaylists = tl }
        if charts.isEmpty, playlists.isEmpty { homeError = "Deezer ist gerade nicht erreichbar." } else { sessionProblem = nil }
        homeLoaded = true
        isLoadingHome = false
    }

    // MARK: Spotify

    func restoreSpotify() async {
        guard Spotify.mode != nil, !spotifyLoaded else { return }
        if let u = await Spotify.shared.restore() {
            spotifyUser = u
            spotifyProblem = nil
            await loadSpotify()
        } else if spotifyUser != nil {
            spotifyProblem = "Spotify-Sitzung konnte nicht erneuert werden."
        }
    }

    func connectSpotify(_ user: SPUser) async {
        spotifyUser = user
        spotifyProblem = nil
        Haptics.success()
        spotifyLoaded = false
        await loadSpotify()
    }

    func loadSpotify(force: Bool = false) async {
        guard spotifyUser != nil, force || !spotifyLoaded else { return }
        do {
            spotifyPlaylists = try await Spotify.shared.playlists()
            spotifyLoaded = true
            spotifyProblem = nil
        } catch {
            spotifyProblem = error.localizedDescription
        }
    }

    func disconnectSpotify() async {
        await Spotify.shared.logout()
        await SpotifyWebSession.clear()
        spotifyUser = nil
        spotifyPlaylists = []
        spotifyLoaded = false
        spotifyProblem = nil
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ track: DZTrack) {
        guard track.isDeezer else { return }
        let on = !favorites.contains(track.id)
        if on { favorites.insert(track.id); Haptics.like() } else { favorites.remove(track.id); Haptics.tap() }
        Task {
            do {
                try await Deezer.shared.setFavorite(track.id, on)
                favoritesVersion += 1
                MusicPlayer.shared.toast(on ? "Zu Lieblingssongs hinzugefügt" : "Aus Lieblingssongs entfernt")
            } catch {
                if on { favorites.remove(track.id) } else { favorites.insert(track.id) }
                Haptics.error()
                MusicPlayer.shared.toast(error.localizedDescription)
            }
        }
    }

    func add(_ track: DZTrack, to playlist: DZPlaylist) {
        Task {
            do {
                try await Deezer.shared.addToPlaylist(playlist.id, trackId: track.id)
                Haptics.success()
                MusicPlayer.shared.toast("Zu „\(playlist.title)“ hinzugefügt")
            } catch {
                Haptics.error()
                MusicPlayer.shared.toast(error.localizedDescription)
            }
        }
    }

    /// Starts a mix based on `track` (Deezer's track radio).
    func startMix(from track: DZTrack) {
        Haptics.impact()
        Task {
            do {
                let tracks: [DZTrack]
                if let videoId = track.youtubeId {
                    tracks = try await YouTubeMusic.radio(videoId)
                } else {
                    tracks = try await Deezer.shared.trackMix(track)
                }
                MusicPlayer.shared.play(tracks)
                MusicPlayer.shared.toast("Mix zu „\(track.title)“")
            } catch {
                MusicPlayer.shared.toast(error.localizedDescription)
            }
        }
    }
}
