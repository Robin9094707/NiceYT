import SwiftUI

@main
struct NiceYTApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared
    @StateObject private var account = AccountStore()
    @StateObject private var player = PlayerModel()
    @StateObject private var shorts = ShortsModel()
    @StateObject private var music = MusicPlayer.shared
    @StateObject private var musicStore = MusicStore.shared
    @StateObject private var downloads = DownloadStore.shared
    @StateObject private var ytDownloads = YouTubeDownloads.shared

    init() {
        URLCache.shared = URLCache(memoryCapacity: 96 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(account)
                .environmentObject(player)
                .environmentObject(shorts)
                .environmentObject(music)
                .environmentObject(musicStore)
                .environmentObject(downloads)
                .environmentObject(ytDownloads)
        }
    }
}
