import WebKit

/// One-time removal of data older versions left behind.
@MainActor
enum LegacyCleanup {
    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "spotifyRemoved") else { return }
        d.set(true, forKey: "spotifyRemoved")
        // Version 2.0: the Spotify connection is gone – its login, token and web session too.
        Keychain.remove("spotifyRefreshToken")
        for key in ["spotifyMode", "spotifyClientId", "spotifyUser"] { d.removeObject(forKey: key) }
        if let id = UUID(uuidString: "6E1C3A52-5D1B-4C1E-9C55-3F1D1F2B7A01") {
            Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        }
    }
}
