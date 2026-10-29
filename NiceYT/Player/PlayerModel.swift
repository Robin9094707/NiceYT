import AVKit
import Combine
import MediaPlayer
import SwiftUI
import UIKit

struct CaptionCue: Hashable {
    let start: Double
    let end: Double
    let text: String
}

/// Owns the single AVPlayer for long-form videos and everything around it
/// (metadata, SponsorBlock, captions, remote commands, mini player state).
@MainActor
final class PlayerModel: NSObject, ObservableObject {
    @Published private(set) var current: Video?
    @Published private(set) var stream: StreamInfo?
    @Published private(set) var details: WatchDetails?
    @Published private(set) var dislikes: DislikeInfo?
    @Published private(set) var segments: [SponsorSegment] = []
    @Published var isPresented = false
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published var toast: String?
    @Published var likeStatus: String?
    @Published var isSubscribed = false
    @Published private(set) var captionTrack: CaptionTrack?
    @Published private(set) var currentCaption: String?
    @Published private(set) var quality: VideoQuality = AppSettings.shared.quality

    let player = AVPlayer()
    private let settings = AppSettings.shared
    private var captionCues: [CaptionCue] = []
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var skipped = Set<Double>()
    private var watchedMarked = false
    private var artwork: MPMediaItemArtwork?
    private var toastTask: Task<Void, Never>?

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        player.allowsExternalPlayback = true
        applyBackgroundPolicy()

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }

        player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.isPlaying = status == .playing
                self?.updateNowPlaying()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.didFinish()
            }
            .store(in: &cancellables)

        settings.$backgroundPlay
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyBackgroundPolicy() }
            .store(in: &cancellables)

        setupRemoteCommands()
    }

    private func applyBackgroundPolicy() {
        player.audiovisualBackgroundPlaybackPolicy = AppSettings.shared.backgroundPlay ? .continuesIfPossible : .pauses
    }

    // MARK: Loading

    func play(_ video: Video, present: Bool = true) {
        if current?.id == video.id, error == nil {
            if present { isPresented = true }
            player.play()
            return
        }
        loadTask?.cancel()
        current = video
        stream = nil
        details = nil
        dislikes = nil
        segments = []
        error = nil
        isLoading = true
        progress = 0
        captionCues = []
        captionTrack = nil
        currentCaption = nil
        skipped = []
        watchedMarked = false
        artwork = nil
        likeStatus = nil
        isSubscribed = false
        quality = settings.quality
        if present { isPresented = true }
        player.replaceCurrentItem(with: nil)
        loadTask = Task { await load(video) }
    }

    func retry() {
        guard let video = current else { return }
        error = nil
        isLoading = true
        loadTask?.cancel()
        loadTask = Task { await load(video) }
    }

    private func load(_ video: Video) async {
        let id = video.id
        let detailsTask = Task { try? await YouTube.watch(id) }

        do {
            let s = try await YouTube.stream(id)
            guard !Task.isCancelled, current?.id == id else { return }
            stream = s
            if var v = current {
                if v.title.isEmpty { v.title = s.title }
                if v.channelName == nil { v.channelName = s.author }
                if v.channelId == nil { v.channelId = s.channelId }
                current = v
            }
            let asset = AVURLAsset(url: s.hlsURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": s.userAgent]])
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 0
            apply(quality, to: item)
            item.externalMetadata = metadataItems(title: s.title, artist: s.author)
            player.replaceCurrentItem(with: item)
            player.play()
            isLoading = false
            updateNowPlaying()
            Task { await loadArtwork(for: video) }
        } catch {
            guard current?.id == id else { return }
            self.error = error.localizedDescription
            isLoading = false
        }

        if let d = await detailsTask.value, current?.id == id {
            details = d
            likeStatus = d.likeStatus
            isSubscribed = d.isSubscribed
            if var v = current {
                if v.channelAvatar == nil { v.channelAvatar = d.channel?.avatar }
                if v.channelId == nil { v.channelId = d.channel?.id }
                if v.title.isEmpty { v.title = d.title }
                current = v
            }
        }

        let wantsSegments = settings.sponsorBlock
        let categories = settings.sponsorCategories
        let wantsDislikes = settings.dislikes
        async let seg: [SponsorSegment] = wantsSegments ? Community.sponsorSegments(id, categories: categories) : []
        async let dis: DislikeInfo? = wantsDislikes ? Community.dislikes(id) : nil
        let segmentsResult = await seg
        let dislikeResult = await dis
        guard current?.id == id else { return }
        segments = segmentsResult
        dislikes = dislikeResult

        if settings.captions, captionTrack == nil, let track = preferredCaption() {
            await selectCaption(track)
        }
    }

    func loadMoreRelated() async {
        guard let token = details?.relatedContinuation, let id = current?.id else { return }
        details?.relatedContinuation = nil
        guard let page = try? await YouTube.relatedMore(token), current?.id == id else { return }
        let existing = Set(details?.related.map(\.id) ?? [])
        details?.related += page.items.filter { !existing.contains($0.id) }
        details?.relatedContinuation = page.continuation
    }

    // MARK: Controls

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
    }

    func close() {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        stream = nil
        details = nil
        isPresented = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func playNext() {
        guard let next = details?.related.compactMap({ item -> Video? in
            if case .video(let v) = item, !v.isLive { return v }
            return nil
        }).first else { return }
        play(next, present: isPresented)
    }

    func setQuality(_ q: VideoQuality) {
        quality = q
        if let item = player.currentItem { apply(q, to: item) }
        showToast("Qualität: \(q.label)")
    }

    private func apply(_ q: VideoQuality, to item: AVPlayerItem) {
        item.preferredMaximumResolution = q.maxSize
        item.preferredPeakBitRate = 0
    }

    func seek(by seconds: Double) {
        let t = player.currentTime().seconds + seconds
        player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600))
    }

    private func didFinish() {
        guard settings.autoplayNext else { return }
        playNext()
    }

    // MARK: Social actions

    func toggleLike(_ status: String) {
        guard let id = current?.id else { return }
        let new = likeStatus == status ? "INDIFFERENT" : status
        let old = likeStatus
        likeStatus = new
        Task {
            do { try await YouTube.setLike(id, status: new) } catch {
                likeStatus = old
                showToast(error.localizedDescription)
            }
        }
    }

    func toggleSubscribe() {
        guard let cid = details?.channel?.id ?? current?.channelId else { return }
        let new = !isSubscribed
        isSubscribed = new
        Task {
            do {
                try await YouTube.setSubscribed(cid, new)
                showToast(new ? "Abonniert" : "Abo beendet")
            } catch {
                isSubscribed = !new
                showToast(error.localizedDescription)
            }
        }
    }

    func watchLater() {
        guard let id = current?.id else { return }
        Task {
            do {
                try await YouTube.addToWatchLater(id)
                showToast("Zu „Später ansehen“ hinzugefügt")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.spring) { toast = text }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.spring) { toast = nil }
        }
    }

    // MARK: Captions

    var captionTracks: [CaptionTrack] { stream?.captions ?? [] }

    private func preferredCaption() -> CaptionTrack? {
        let lang = AppSettings.hl
        return captionTracks.first { $0.languageCode.hasPrefix(lang) && !$0.isAuto }
            ?? captionTracks.first { !$0.isAuto }
            ?? captionTracks.first
    }

    func selectCaption(_ track: CaptionTrack?) async {
        captionTrack = track
        captionCues = []
        currentCaption = nil
        guard let track,
              var comps = URLComponents(url: track.url, resolvingAgainstBaseURL: false) else { return }
        comps.queryItems = (comps.queryItems ?? []).filter { $0.name != "fmt" } + [.init(name: "fmt", value: "json3")]
        guard let url = comps.url, let j = try? await InnerTube.shared.getJSON(url) else { return }
        captionCues = j["events"].array.compactMap { e in
            guard let start = e["tStartMs"].double else { return nil }
            let text = e["segs"].array.compactMap { $0["utf8"].string }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let duration = e["dDurationMs"].double ?? 2000
            return CaptionCue(start: start / 1000, end: (start + duration) / 1000, text: text)
        }
    }

    // MARK: Tick

    private func tick(_ time: Double) {
        guard time.isFinite else { return }
        if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            progress = time / duration
        }

        if settings.sponsorBlock {
            for s in segments where time >= s.start && time < s.end - 0.5 && !skipped.contains(s.start) {
                skipped.insert(s.start)
                player.seek(to: CMTime(seconds: s.end, preferredTimescale: 600))
                let name = AppSettings.allSponsorCategories.first { $0.id == s.category }?.label ?? "Segment"
                showToast("\(name) übersprungen")
                break
            }
        }

        if !captionCues.isEmpty {
            let cue = captionCues.last { time >= $0.start && time < $0.end }
            if cue?.text != currentCaption { currentCaption = cue?.text }
        }

        if !watchedMarked, time > 5, let id = current?.id {
            watchedMarked = true
            Task.detached { await YouTube.markWatched(id) }
        }
    }

    // MARK: Now playing

    private func metadataItems(title: String, artist: String) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        return [item(.commonIdentifierTitle, title), item(.commonIdentifierArtist, artist)]
    }

    private func loadArtwork(for video: Video) async {
        var data = try? await URLSession.shared.data(from: video.maxThumbnail).0
        if data == nil || UIImage(data: data!) == nil || UIImage(data: data!)!.size.width < 200 {
            data = try? await URLSession.shared.data(from: video.bestThumbnail).0
        }
        guard current?.id == video.id, let data, let image = UIImage(data: data) else { return }
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        let m = AVMutableMetadataItem()
        m.identifier = .commonIdentifierArtwork
        m.value = (image.jpegData(compressionQuality: 0.8) ?? data) as NSData
        m.dataType = kCMMetadataBaseDataType_JPEG as String
        m.extendedLanguageTag = "und"
        player.currentItem?.externalMetadata.append(m)
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard let video = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: stream?.title ?? video.title,
            MPMediaItemPropertyArtist: stream?.author ?? video.channelName ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(player.rate) : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if let d = player.currentItem?.duration.seconds, d.isFinite { info[MPMediaItemPropertyPlaybackDuration] = d }
        if stream?.isLive == true { info[MPNowPlayingInfoPropertyIsLiveStream] = true }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerModel, MPRemoteCommandEvent) -> Void) {
            command.addTarget { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    action(self, event)
                }
                return .success
            }
        }
        on(c.playCommand) { m, _ in m.player.play() }
        on(c.pauseCommand) { m, _ in m.player.pause() }
        on(c.togglePlayPauseCommand) { m, _ in m.togglePlay() }
        on(c.nextTrackCommand) { m, _ in m.playNext() }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        on(c.skipForwardCommand) { m, _ in m.seek(by: 10) }
        on(c.skipBackwardCommand) { m, _ in m.seek(by: -10) }
        on(c.changePlaybackPositionCommand) { m, event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return }
            m.player.seek(to: CMTime(seconds: e.positionTime, preferredTimescale: 600))
            m.updateNowPlaying()
        }
    }
}

// MARK: - Picture in Picture

extension PlayerModel: AVPlayerViewControllerDelegate {
    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                          restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            self.isPresented = true
            completionHandler(true)
        }
    }

    nonisolated func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
        false
    }
}
