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

/// Values that change many times per second. Kept out of `PlayerModel` so that the
/// feeds (which observe the model) don't re-render while a video is playing.
@MainActor
final class PlayerLive: ObservableObject {
    @Published var progress: Double = 0
    @Published var caption: String?
    @Published var hud: PlayerModel.GestureHUD?
    /// Vertical offset while the player is dragged down to minimise it.
    @Published var dragOffset: CGFloat = 0
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
    @Published var toast: String?
    @Published var likeStatus: String?
    @Published var isSubscribed = false
    @Published private(set) var captionTrack: CaptionTrack?
    @Published private(set) var quality: VideoQuality = AppSettings.shared.quality
    @Published private(set) var sourceLabel: String?
    @Published var isFullscreen = false
    /// Zoom to fill the screen in fullscreen (pinch gesture).
    @Published var videoFill = false
    @Published private(set) var queue: [Video] = []
    /// Audio languages of the current video (original / AI-dubbed translations).
    @Published private(set) var audioChoices: [AudioChoice] = []

    enum GestureHUD: Equatable {
        case seek(Int)
        case volume(Float)
        case brightness(Double)
    }

    let player = AVPlayer()
    let live = PlayerLive()
    private let settings = AppSettings.shared
    private var captionCues: [CaptionCue] = []
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var skipped = Set<Double>()
    private var watchedMarked = false
    private var artwork: MPMediaItemArtwork?
    private var toastTask: Task<Void, Never>?
    private var activeProxy: HLSProxy?
    private var hudTask: Task<Void, Never>?
    private var lastSavedPosition: Double = 0
    /// Sources that broke off during playback of the current video.
    private var failedSources = Set<String>()
    private var currentSourceKey: String?
    private var recoveries = 0
    private var hlsAudioGroup: AVMediaSelectionGroup?

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        player.allowsExternalPlayback = true
        // Otherwise AVPlayer picks the audio language by the device settings (often an AI dub).
        player.appliesMediaSelectionCriteriaAutomatically = false
        applyBackgroundPolicy()

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                let playing = status == .playing
                if playing != self.isPlaying { self.isPlaying = playing }
                // A video took over: music pauses and the lock screen shows the video.
                if playing { MusicPlayer.shared.yieldFocus() }
                self.updateNowPlaying()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.didFinish()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.newErrorLogEntryNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let item = note.object as? AVPlayerItem, item === self?.player.currentItem,
                      let event = item.errorLog()?.events.last else { return }
                DebugLog.log("⚠︎ Wiedergabe: \(event.errorStatusCode) \(event.errorComment ?? "") \(DebugLog.short(event.uri.flatMap(URL.init(string:))))")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let e = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                DebugLog.log("✖︎ Abbruch: \(e?.domain ?? "") \(e?.code ?? 0) \(e?.localizedDescription ?? "")")
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.recoverPlayback()
            }
            .store(in: &cancellables)

        // A stream that was fine at first can still fail later (e.g. expired segments).
        player.publisher(for: \.currentItem?.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard status == .failed else { return }
                self?.recoverPlayback()
            }
            .store(in: &cancellables)

        settings.$backgroundPlay
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyBackgroundPolicy() }
            .store(in: &cancellables)

        setupRemoteCommands()
    }

    private func applyBackgroundPolicy() {
        player.audiovisualBackgroundPlaybackPolicy = AppSettings.shared.backgroundPlay ? .continuesIfPossible : .pauses
    }

    // MARK: Loading

    /// Plays `video`; `queue` (e.g. a playlist) determines what comes next.
    func play(_ video: Video, queue newQueue: [Video], present: Bool = true) {
        queue = newQueue
        play(video, present: present, keepQueue: true)
    }

    func play(_ video: Video, present: Bool = true, keepQueue: Bool = false) {
        if !keepQueue, !queue.contains(where: { $0.id == video.id }) { queue = [] }
        if current?.id == video.id, error == nil {
            if present { presentPlayer() }
            player.play()
            return
        }
        loadTask?.cancel()
        MusicPlayer.shared.yieldFocus()
        current = video
        stream = nil
        details = nil
        dislikes = nil
        segments = []
        error = nil
        isLoading = true
        live.progress = 0
        live.caption = nil
        captionCues = []
        captionTrack = nil
        skipped = []
        watchedMarked = false
        artwork = nil
        likeStatus = nil
        isSubscribed = false
        quality = settings.quality
        sourceLabel = nil
        lastSavedPosition = 0
        failedSources = []
        currentSourceKey = nil
        recoveries = 0
        hlsAudioGroup = nil
        audioChoices = []
        if present { presentPlayer() }
        player.pause()
        player.replaceCurrentItem(with: nil)
        activeProxy = nil
        loadTask = Task { await load(video) }
    }

    func presentPlayer() {
        live.dragOffset = 0
        isPresented = true
    }

    func retry() {
        guard let video = current else { return }
        error = nil
        isLoading = true
        failedSources = []
        recoveries = 0
        loadTask?.cancel()
        loadTask = Task { await load(video) }
    }

    /// Playback broke off after it had started: continue at the same position with
    /// another source instead of leaving a dead player.
    private func recoverPlayback() {
        guard let video = current, !isLoading, error == nil, let key = currentSourceKey else { return }
        let position = player.currentTime().seconds
        currentSourceKey = nil
        failedSources.insert(key)
        guard recoveries < 3 else {
            player.pause()
            error = "Die Wiedergabe wurde unterbrochen. Tippe auf „Erneut versuchen“."
            return
        }
        recoveries += 1
        DebugLog.log("↻ Wiedergabe abgebrochen (\(key)) – neue Quelle ab \(Int(position)) s")
        showToast("Verbindung unterbrochen – wird neu geladen")
        isLoading = true
        loadTask?.cancel()
        loadTask = Task { await load(video, startAt: position.isFinite && position > 1 ? position : nil, reloadDetails: false) }
    }

    private func load(_ video: Video, startAt: Double? = nil, reloadDetails: Bool = true) async {
        let id = video.id
        let detailsTask: Task<WatchDetails?, Never>? = reloadDetails ? Task { try? await YouTube.watch(id) } : nil

        let prepared = await StreamResolver.firstPlayable(id, excluding: failedSources) { candidate in
            guard !Task.isCancelled, self.current?.id == id else { return false }
            return await self.tryPlay(candidate, startAt: startAt)
        }
        guard !Task.isCancelled, current?.id == id else { return }
        if let prepared {
            let s = prepared.info
            stream = s
            sourceLabel = prepared.label
            currentSourceKey = s.sourceKey
            if var v = current {
                if v.title.isEmpty { v.title = s.title }
                if v.channelName == nil, !s.author.isEmpty { v.channelName = s.author }
                if v.channelId == nil { v.channelId = s.channelId }
                current = v
            }
            isLoading = false
            updateNowPlaying()
            Task { await loadArtwork(for: video) }
        } else {
            error = "Wiedergabe fehlgeschlagen. Details unter Einstellungen → Diagnose."
            isLoading = false
        }

        guard reloadDetails else { return }
        if let d = await detailsTask?.value, current?.id == id {
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

    /// Hands a candidate to AVPlayer and waits until it is really playable.
    private func tryPlay(_ candidate: PreparedStream, startAt: Double? = nil) async -> Bool {
        let item = AVPlayerItem(asset: candidate.asset)
        apply(quality, to: item)
        item.externalMetadata = metadataItems(title: candidate.info.title, artist: candidate.info.author)
        activeProxy = candidate.proxy
        // A resumed video only starts after the seek, so its beginning doesn't flash up.
        let id = current?.id
        let resume = startAt ?? (settings.resumePlayback ? id.flatMap(PositionStore.position) : nil)
        player.replaceCurrentItem(with: item)
        if resume == nil { player.play() }
        guard await StreamResolver.waitUntilReady(item, label: candidate.label) else { return false }
        hlsAudioGroup = await StreamResolver.applyAudioPreference(item, info: candidate.info)
        refreshAudioChoices(candidate.info)
        if let resume {
            _ = await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            if current?.id == id { player.play() }
            if startAt == nil {
                let m = Int(resume) / 60, sec = Int(resume) % 60
                showToast(String(format: "Fortgesetzt bei %d:%02d", m, sec))
            }
        }
        return true
    }

    // MARK: Audio tracks

    private func refreshAudioChoices(_ info: StreamInfo? = nil) {
        guard let info = info ?? stream else { audioChoices = []; return }
        if let group = hlsAudioGroup, let item = player.currentItem {
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            let selectedLanguage = selected.map { StreamResolver.language(of: $0).lowercased() }
            // Several audio groups (bitrates) list the same languages – show each once.
            var seen = Set<String>()
            audioChoices = group.options.enumerated().compactMap { i, option in
                let language = StreamResolver.language(of: option).lowercased()
                guard seen.insert(language.isEmpty ? option.displayName : language).inserted else { return nil }
                let rendition = StreamResolver.rendition(of: option, info: info)
                var title = Locale(identifier: "de").localizedString(forIdentifier: language).flatMap { $0.isEmpty ? nil : $0 }
                    ?? option.displayName
                if rendition?.isOriginal ?? StreamResolver.isOriginal(option, info: info) {
                    title += " (Original)"
                } else if rendition?.isDubbed == true {
                    title += " (KI-Übersetzung)"
                }
                let isSelected = option == selected || (!language.isEmpty && language == selectedLanguage)
                return AudioChoice(id: "hls-\(i)", title: title, isSelected: isSelected)
            }
            .sorted { ($0.title.contains("(Original)") ? 0 : 1, $0.title) < ($1.title.contains("(Original)") ? 0 : 1, $1.title) }
        } else if info.audioTracks.count > 1 {
            audioChoices = info.audioTracks.map { t in
                var title = t.name
                if t.isOriginal, !title.lowercased().contains("original") { title += " (Original)" }
                return AudioChoice(id: t.id, title: title, isSelected: t.url == info.audioURL)
            }
        } else {
            audioChoices = []
        }
    }

    /// Switches the audio language, keeping the playback position.
    func selectAudio(_ choice: AudioChoice) {
        guard !choice.isSelected else { return }
        Haptics.selection()
        if let group = hlsAudioGroup, let item = player.currentItem,
           let index = Int(choice.id.dropFirst(4)), choice.id.hasPrefix("hls-"), group.options.indices.contains(index) {
            item.select(group.options[index], in: group)
            refreshAudioChoices()
            showToast("Tonspur: \(choice.title)")
            return
        }
        guard var info = stream, let track = info.audioTracks.first(where: { $0.id == choice.id }),
              let id = current?.id else { return }
        info.audioURL = track.url
        let time = player.currentTime()
        let wasPlaying = isPlaying
        showToast("Tonspur: \(choice.title)")
        Task {
            guard let prepared = await StreamResolver.prepare(info), current?.id == id else {
                showToast("Diese Tonspur ist gerade nicht verfügbar")
                return
            }
            let item = AVPlayerItem(asset: prepared.asset)
            apply(quality, to: item)
            item.externalMetadata = metadataItems(title: info.title, artist: info.author)
            player.replaceCurrentItem(with: item)
            guard await StreamResolver.waitUntilReady(item, label: prepared.label), current?.id == id else { return }
            _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
            stream = info
            refreshAudioChoices(info)
        }
    }

    // MARK: Controls

    func togglePlay() {
        Haptics.tap()
        if isPlaying { player.pause() } else { player.play() }
    }

    func close() {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        stream = nil
        details = nil
        error = nil
        isLoading = false
        queue = []
        activeProxy = nil
        currentSourceKey = nil
        hlsAudioGroup = nil
        audioChoices = []
        live.progress = 0
        live.caption = nil
        isPresented = false
        if isFullscreen { setFullscreen(false) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func playNext() {
        if let id = current?.id, let idx = queue.firstIndex(where: { $0.id == id }), idx + 1 < queue.count {
            play(queue[idx + 1], present: isPresented, keepQueue: true)
            return
        }
        guard let next = details?.related.compactMap({ item -> Video? in
            if case .video(let v) = item, !v.isLive { return v }
            return nil
        }).first else { return }
        play(next, present: isPresented)
    }

    var upNext: [Video] {
        guard let id = current?.id, let idx = queue.firstIndex(where: { $0.id == id }) else { return [] }
        return Array(queue[(idx + 1)...])
    }

    // MARK: Gestures

    func gestureSeek(forward: Bool) {
        Haptics.tap()
        let step = Double(settings.seekInterval)
        seek(by: forward ? step : -step)
        let previous: Int
        if case .seek(let v) = live.hud, (v > 0) == forward { previous = v } else { previous = 0 }
        showHUD(.seek(previous + (forward ? Int(step) : -Int(step))))
    }

    func showHUD(_ value: GestureHUD) {
        hudTask?.cancel()
        live.hud = value
        hudTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut) { live.hud = nil }
        }
    }

    /// Enters or leaves fullscreen. On iPhone this also rotates the interface;
    /// leaving works as well when the landscape layout came from turning the device.
    func setFullscreen(_ on: Bool) {
        let wasFullscreen = isFullscreen
        if on != wasFullscreen { Haptics.soft() }
        withAnimation(.smooth(duration: 0.3)) {
            isFullscreen = on
            if !on { videoFill = false }
        }
        if on || wasFullscreen || Orientation.isLandscape {
            Orientation.set(landscape: on)
        }
    }

    /// The device was turned back to portrait while in fullscreen.
    func fullscreenEndedByRotation() {
        guard isFullscreen else { return }
        withAnimation(.smooth(duration: 0.3)) {
            isFullscreen = false
            videoFill = false
        }
    }

    /// Minimises the player into the mini player.
    func minimize() {
        if isFullscreen { setFullscreen(false) }
        isPresented = false
    }

    func setQuality(_ q: VideoQuality) {
        Haptics.selection()
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
        if let id = current?.id { PositionStore.remove(id) }
        guard settings.autoplayNext else { return }
        playNext()
    }

    // MARK: Social actions

    func toggleLike(_ status: String) {
        guard let id = current?.id else { return }
        let new = likeStatus == status ? "INDIFFERENT" : status
        let old = likeStatus
        likeStatus = new
        if new == "INDIFFERENT" { Haptics.tap() } else { Haptics.like() }
        Task {
            do { try await YouTube.setLike(id, status: new) } catch {
                likeStatus = old
                Haptics.error()
                showToast(error.localizedDescription)
            }
        }
    }

    func toggleSubscribe() {
        guard let cid = details?.channel?.id ?? current?.channelId else { return }
        let new = !isSubscribed
        isSubscribed = new
        if new { Haptics.success() } else { Haptics.tap() }
        Task {
            do {
                try await YouTube.setSubscribed(cid, new)
                showToast(new ? "Abonniert" : "Abo beendet")
            } catch {
                isSubscribed = !new
                Haptics.error()
                showToast(error.localizedDescription)
            }
        }
    }

    func watchLater() {
        guard let id = current?.id else { return }
        Task {
            do {
                try await YouTube.addToWatchLater(id)
                Haptics.success()
                showToast("Zu „Später ansehen“ hinzugefügt")
            } catch {
                Haptics.error()
                showToast(error.localizedDescription)
            }
        }
    }

    /// Inserts `video` right after the current one.
    func playNextInQueue(_ video: Video) {
        enqueue(video, next: true)
    }

    /// Appends `video` to the end of the queue.
    func addToQueue(_ video: Video) {
        enqueue(video, next: false)
    }

    private func enqueue(_ video: Video, next: Bool) {
        guard let current else {
            play(video)
            return
        }
        guard video.id != current.id else { return }
        if !queue.contains(where: { $0.id == current.id }) { queue = [current] }
        queue.removeAll { $0.id == video.id }
        let index = queue.firstIndex { $0.id == current.id } ?? 0
        if next { queue.insert(video, at: index + 1) } else { queue.append(video) }
        Haptics.success()
        showToast(next ? "Wird als Nächstes abgespielt" : "Zur Warteschlange hinzugefügt")
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
        live.caption = nil
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
            let p = min(1, max(0, time / duration))
            if abs(p - live.progress) > 0.0005 { live.progress = p }
            if abs(time - lastSavedPosition) > 5, let id = current?.id, stream?.isLive != true {
                lastSavedPosition = time
                PositionStore.save(id, position: time, duration: duration)
            }
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
            if cue?.text != live.caption { live.caption = cue?.text }
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
        guard let video = current, !MusicPlayer.shared.isFocused else { return }
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
        // One set of handlers for both players: whoever has the focus gets the command.
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerModel, MPRemoteCommandEvent) -> Void) {
            command.addTarget { [weak self] event in
                MainActor.assumeIsolated {
                    if MusicPlayer.shared.isFocused {
                        MusicPlayer.shared.handleRemote(command, event: event)
                        return
                    }
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
        on(c.previousTrackCommand) { m, _ in m.seek(by: -m.player.currentTime().seconds) }
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
            self.presentPlayer()
            completionHandler(true)
        }
    }

    nonisolated func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
        false
    }
}
