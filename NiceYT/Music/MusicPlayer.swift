import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

/// Playback position of the music player (kept separate so lists don't re-render while playing).
@MainActor
final class MusicLive: ObservableObject {
    @Published var time: Double = 0
    @Published var duration: Double = 0
}

/// Plays Deezer songs – streamed and decrypted on the fly, or from the downloads.
@MainActor
final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()

    enum RepeatMode { case off, all, one }

    @Published private(set) var queue: [DZTrack] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var quality: DZQuality?
    @Published private(set) var isOffline = false
    /// Music (not a video) owns the lock screen and the mini player.
    @Published private(set) var isFocused = false
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published var showNowPlaying = false
    @Published private(set) var toastText: String?

    let live = MusicLive()
    let player = AVPlayer()
    /// Called when music starts, so videos and Shorts can stop.
    var onStart: (() -> Void)?

    private var loader: DeezerStreamLoader?
    private var loadTask: Task<Void, Never>?
    private var unshuffled: [DZTrack] = []
    private var cancellables = Set<AnyCancellable>()
    private var timeObserver: Any?
    private var artwork: MPMediaItemArtwork?
    private var toastTask: Task<Void, Never>?
    private var recoveries = 0

    var current: DZTrack? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [DZTrack] { queue.indices.contains(index + 1) ? Array(queue[(index + 1)...]) : [] }

    private init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = time.seconds
                if t.isFinite, abs(t - self.live.time) > 0.2 { self.live.time = t }
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - self.live.duration) > 0.5 {
                    self.live.duration = d
                    self.updateNowPlaying()
                }
            }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                let playing = status == .playing
                if playing != self.isPlaying { self.isPlaying = playing }
                if playing { self.claimFocus() }
                if self.isFocused { self.updateNowPlaying() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.advance()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                // Stream broke off: reload the song at the same position (a few times at most).
                guard self.recoveries < 3 else { self.toast("Wiedergabe unterbrochen"); return }
                self.recoveries += 1
                let position = self.player.currentTime().seconds
                self.startCurrent(at: position.isFinite ? position : nil, recovering: true)
            }
            .store(in: &cancellables)
    }

    // MARK: Queue

    func play(_ tracks: [DZTrack], startAt: Int = 0, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        unshuffled = tracks
        if shuffled {
            var rest = tracks
            let first = rest.remove(at: Int.random(in: 0..<rest.count))
            queue = [first] + rest.shuffled()
            index = 0
        } else {
            queue = tracks
            index = min(max(0, startAt), tracks.count - 1)
        }
        shuffle = shuffled
        Haptics.tap()
        startCurrent()
    }

    func playNext(_ track: DZTrack) {
        guard current != nil else { play([track]); return }
        queue.removeAll { $0.id == track.id && $0.id != current?.id }
        index = queue.firstIndex { $0.id == current?.id } ?? index
        queue.insert(track, at: index + 1)
        unshuffled.append(track)
        Haptics.success()
        toast("Wird als Nächstes gespielt")
    }

    func addToQueue(_ track: DZTrack) {
        guard current != nil else { play([track]); return }
        queue.append(track)
        unshuffled.append(track)
        Haptics.success()
        toast("Zur Warteschlange hinzugefügt")
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        Haptics.tap()
        startCurrent()
    }

    func removeFromQueue(_ offsets: IndexSet) {
        // Offsets refer to `upNext`.
        let ids = offsets.compactMap { upNext.indices.contains($0) ? upNext[$0].id : nil }
        queue.removeAll { t in ids.contains(t.id) && t.id != current?.id }
        index = queue.firstIndex { $0.id == current?.id } ?? 0
    }

    /// Reorders `upNext` (offsets refer to it).
    func moveInQueue(from source: IndexSet, to destination: Int) {
        guard queue.indices.contains(index) else { return }
        var next = upNext
        next.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + next
        Haptics.selection()
    }

    func toggleShuffle() {
        guard let cur = current else { return }
        shuffle.toggle()
        if shuffle {
            let rest = queue.filter { $0.id != cur.id }.shuffled()
            queue = [cur] + rest
            index = 0
        } else {
            queue = unshuffled.isEmpty ? queue : unshuffled
            index = queue.firstIndex { $0.id == cur.id } ?? 0
        }
        Haptics.selection()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        Haptics.selection()
    }

    // MARK: Controls

    func togglePlay() {
        Haptics.tap()
        if isPlaying { player.pause() } else { resume() }
    }

    func resume() {
        guard current != nil else { return }
        if player.currentItem == nil { startCurrent() } else { player.play() }
    }

    func pause() { player.pause() }

    func next() {
        guard !queue.isEmpty else { return }
        Haptics.tap()
        if index + 1 < queue.count {
            index += 1
        } else {
            index = 0
        }
        startCurrent()
    }

    func previous() {
        Haptics.tap()
        if player.currentTime().seconds > 3 || index == 0 {
            seek(to: 0)
            return
        }
        index -= 1
        startCurrent()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
        live.time = seconds
    }

    func skip(by seconds: Double) {
        seek(to: player.currentTime().seconds + seconds)
    }

    /// Stops music completely (mini player disappears).
    func stop() {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        loader?.invalidate()
        loader = nil
        queue = []
        index = 0
        isLoading = false
        showNowPlaying = false
        if isFocused {
            isFocused = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    /// A video started: music pauses and hands over the lock screen.
    func yieldFocus() {
        guard isFocused else { return }
        player.pause()
        isFocused = false
    }

    private func claimFocus() {
        if !isFocused { isFocused = true }
        onStart?()
    }

    private func advance() {
        if repeatMode == .one {
            seek(to: 0)
            player.play()
            return
        }
        if index + 1 < queue.count {
            index += 1
            startCurrent()
        } else if repeatMode == .all {
            index = 0
            startCurrent()
        } else {
            player.pause()
            seek(to: 0)
        }
    }

    // MARK: Loading

    private func startCurrent(at position: Double? = nil, recovering: Bool = false) {
        loadTask?.cancel()
        guard let track = current else { return }
        if !recovering { recoveries = 0 }
        claimFocus()
        isLoading = true
        live.time = position ?? 0
        live.duration = Double(track.duration)
        artwork = nil
        player.pause()
        updateNowPlaying()
        loadTask = Task { await load(track, at: position) }
    }

    private func load(_ track: DZTrack, at position: Double?) async {
        Task { await loadArtwork(track) }
        if let file = DownloadStore.shared.file(for: track.id) {
            isOffline = true
            quality = file.quality
            let item = AVPlayerItem(url: file.url)
            if await start(item, at: position, label: "Datei") { return }
        }
        isOffline = false
        guard !track.isYouTube else {
            isLoading = false
            toast("Die Datei von „\(track.title)“ ist nicht mehr vorhanden")
            return
        }
        var wanted = AppSettings.shared.musicStreamQuality
        for _ in 0..<2 {
            do {
                let media = try await Deezer.shared.mediaURL(for: track, quality: wanted)
                guard !Task.isCancelled, current?.id == track.id else { return }
                let loader = DeezerStreamLoader(source: media.url, trackId: media.track.id, quality: media.quality)
                let asset = AVURLAsset(url: DeezerStreamLoader.assetURL(trackId: media.track.id, quality: media.quality))
                asset.resourceLoader.setDelegate(loader, queue: loader.queue)
                self.loader?.invalidate()
                self.loader = loader
                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = 20
                if await start(item, at: position, label: media.quality.rawValue) {
                    quality = media.quality
                    return
                }
                guard !Task.isCancelled, current?.id == track.id else { return }
                // FLAC through the resource loader failed: MP3 always works.
                guard media.quality == .flac else { throw DeezerError.noStream }
                wanted = .mp3_320
            } catch {
                guard !Task.isCancelled, current?.id == track.id else { return }
                isLoading = false
                Haptics.error()
                toast("„\(track.title)“: \(error.localizedDescription)")
                return
            }
        }
    }

    private func start(_ item: AVPlayerItem, at position: Double?, label: String) async -> Bool {
        player.replaceCurrentItem(with: item)
        if position == nil { player.play() }
        let started = Date()
        while Date().timeIntervalSince(started) < 20 {
            if Task.isCancelled { return false }
            switch item.status {
            case .readyToPlay:
                DebugLog.log("♫ Deezer \(label) bereit nach \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                if let position {
                    _ = await player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                    player.play()
                }
                isLoading = false
                updateNowPlaying()
                return true
            case .failed:
                DebugLog.log("♫ Deezer \(label) fehlgeschlagen: \(item.error?.localizedDescription ?? "?")")
                return false
            default:
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        DebugLog.log("♫ Deezer \(label): Zeitüberschreitung")
        return false
    }

    // MARK: Toast

    func toast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.spring) { toastText = text }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(.spring) { toastText = nil }
        }
    }

    // MARK: Now playing

    private func loadArtwork(_ track: DZTrack) async {
        guard let url = track.coverURL(1000),
              let data = try? await URLSession.shared.data(from: url).0,
              let image = UIImage(data: data), current?.id == track.id else { return }
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        updateNowPlaying()
    }

    func updateNowPlaying() {
        guard isFocused, let track = current else { return }
        let time = player.currentTime().seconds
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.fullTitle,
            MPMediaItemPropertyArtist: track.artistLine,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: live.duration > 0 ? live.duration : Double(track.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time.isFinite ? time : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Remote commands (lock screen, headphones, CarPlay) while music has the focus.
    func handleRemote(_ command: MPRemoteCommand, event: MPRemoteCommandEvent) {
        let c = MPRemoteCommandCenter.shared()
        switch command {
        case c.playCommand: resume()
        case c.pauseCommand: pause()
        case c.togglePlayPauseCommand: if isPlaying { pause() } else { resume() }
        case c.nextTrackCommand: next()
        case c.previousTrackCommand: previous()
        case c.skipForwardCommand: skip(by: 15)
        case c.skipBackwardCommand: skip(by: -15)
        case c.changePlaybackPositionCommand:
            if let e = event as? MPChangePlaybackPositionCommandEvent { seek(to: e.positionTime) }
        default: break
        }
    }
}

/// Opens the music tab with a search (e.g. "Song auf Deezer suchen" on a video).
@MainActor
final class MusicSearchRequest: ObservableObject {
    static let shared = MusicSearchRequest()
    @Published private(set) var query = ""
    @Published private(set) var token = 0

    func search(_ raw: String) {
        query = Self.clean(raw)
        token += 1
        Haptics.tap()
    }

    /// Strips video noise like "(Official Music Video)", "[4K]" or "| Lyrics".
    static func clean(_ title: String) -> String {
        var s = title
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#, #"(?i)\b(official|offizielles?|music|musik|video|lyrics?|audio|visualizer|hd|4k)\b"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.components(separatedBy: CharacterSet(charactersIn: "|#")).first ?? s
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–")))
    }
}

/// Navigation inside the music tab, reachable from menus anywhere (now playing sheet …).
@MainActor
final class MusicRouter: ObservableObject {
    static let shared = MusicRouter()
    @Published var path = NavigationPath()
    /// Bumped to bring the music tab to the front.
    @Published private(set) var showTab = 0

    func open(_ route: MusicRoute) {
        MusicPlayer.shared.showNowPlaying = false
        path.append(route)
        showTab += 1
    }
}

enum MusicRoute: Hashable {
    case album(String)
    case playlist(String)
    case artist(String)
    case favorites
    case charts
    case downloads
}
