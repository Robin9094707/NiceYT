import AVKit
import Combine
import SwiftUI

struct ShortItem: Identifiable, Hashable {
    let id: String
    var video: Video
}

/// Playback progress of the visible Short (separate so only the progress bar redraws).
@MainActor
final class ShortsProgress: ObservableObject {
    @Published var value: Double = 0
}

@MainActor
final class ShortsModel: ObservableObject {
    enum LoadState: Equatable { case loading, ready, failed }

    @Published var items: [ShortItem] = []
    @Published var currentID: String?
    @Published private(set) var players: [String: AVPlayer] = [:]
    @Published private(set) var states: [String: LoadState] = [:]
    @Published private(set) var details: [String: WatchDetails] = [:]
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published var paused = false
    @Published var openRequest = UUID()
    /// Drives the comments sheet.
    @Published var commentsItem: ShortItem?
    @Published private(set) var commentsLoadingID: String?
    @Published private(set) var likes: [String: Bool] = [:]
    @Published private(set) var subscribed: [String: Bool] = [:]

    let progress = ShortsProgress()

    private var sequence: String?
    private var loadingMore = false
    private var tabActive = false
    private var pushed = false
    private var active: Bool { tabActive && !pushed }
    private var loopObservers: [String: AnyCancellable] = [:]
    private var proxies: [String: HLSProxy] = [:]
    private var loadTasks: [String: Task<Void, Never>] = [:]
    private var detailTasks: [String: Task<WatchDetails?, Never>] = [:]
    private var commentTokens: [String: String] = [:]
    private var timeObserver: (player: AVPlayer, token: Any)?

    // MARK: Feed

    func loadIfNeeded() async {
        guard items.isEmpty, !isLoading else { return }
        isLoading = true
        error = nil
        do {
            let start = try await YouTube.shortsStart()
            if let first = start.first {
                append([first])
                if currentID == nil { currentID = first }
            }
            sequence = start.sequence
            // Start the first Short right away; the rest of the feed loads meanwhile.
            if active { activateCurrent() }
            await loadMore()
            if currentID == nil { currentID = items.first?.id }
            if items.isEmpty { error = "Keine Shorts gefunden." }
            if active { activateCurrent() }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func reload() async {
        items = []
        currentID = nil
        sequence = nil
        error = nil
        for key in Array(players.keys) { drop(key) }
        states = [:]
        await loadIfNeeded()
    }

    func loadMore() async {
        guard let seq = sequence, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let result = try? await YouTube.shortsSequence(seq) else { return }
        append(result.ids)
        sequence = result.next
    }

    private func append(_ ids: [String]) {
        let existing = Set(items.map(\.id))
        var added = Set<String>()
        for id in ids where !existing.contains(id) && added.insert(id).inserted {
            items.append(ShortItem(id: id, video: Video(id: id, title: "", isShort: true)))
        }
    }

    /// Opens the Shorts tab at `video`, followed by the rest of `list`.
    func open(_ video: Video, from list: [Video]) {
        let start = list.firstIndex(of: video) ?? 0
        let ordered = Array(list[start...]) + Array(list[..<start])
        var seen = Set<String>()
        let newItems = ordered.filter { seen.insert($0.id).inserted }.map { ShortItem(id: $0.id, video: $0) }
        let ids = Set(newItems.map(\.id))
        items = newItems + items.filter { !ids.contains($0.id) }
        currentID = video.id
        paused = false
        openRequest = UUID()
        if active { activateCurrent() }
        if sequence == nil, !isLoading {
            // Continue with recommendations after the opened shelf.
            Task {
                if let start = try? await YouTube.shortsStart() { sequence = start.sequence }
                await loadMore()
            }
        }
    }

    // MARK: Activity

    /// The Shorts tab is (not) on screen.
    func setTabActive(_ value: Bool) {
        tabActive = value
        updateActivity()
    }

    /// A page (e.g. a channel) was pushed on top of the Shorts.
    func setPushed(_ value: Bool) {
        pushed = value
        updateActivity()
    }

    private func updateActivity() {
        if active {
            activateCurrent()
        } else {
            players.values.forEach { $0.pause() }
        }
    }

    func currentChanged() {
        paused = false
        progress.value = 0
        activateCurrent()
        if let id = currentID, let idx = items.firstIndex(where: { $0.id == id }), idx >= items.count - 4 {
            Task { await loadMore() }
        }
    }

    func togglePause() {
        guard let id = currentID, let p = players[id] else { return }
        if p.timeControlStatus == .playing || p.rate > 0 {
            p.pause()
            paused = true
        } else {
            p.play()
            paused = false
        }
    }

    func retry(_ id: String) {
        drop(id)
        states[id] = nil
        if currentID == id { activateCurrent() } else { prepare(id, autoplay: false) }
    }

    // MARK: Playback

    private func activateCurrent() {
        guard let id = currentID, let idx = items.firstIndex(where: { $0.id == id }) else { return }
        for (key, p) in players where key != id {
            p.pause()
            if p.currentTime().seconds > 0 { p.seek(to: .zero) }
        }
        prepare(id, autoplay: active)
        observeProgress(of: players[id])
        loadDetails(id)
        // Preload the following Shorts so swiping on is instant.
        for next in items[(idx + 1)...].prefix(2) { prepare(next.id, autoplay: false) }
        if idx + 1 < items.count { loadDetails(items[idx + 1].id) }
        // Drop players far away from the current position.
        let keep = Set(items[max(0, idx - 1)...min(items.count - 1, idx + 2)].map(\.id))
        for key in Array(players.keys) where !keep.contains(key) { drop(key) }
    }

    private func drop(_ id: String) {
        loadTasks[id]?.cancel()
        loadTasks[id] = nil
        players[id]?.pause()
        players[id]?.replaceCurrentItem(with: nil)
        players[id] = nil
        loopObservers[id] = nil
        proxies[id] = nil
        if states[id] != .failed { states[id] = nil }
    }

    private func prepare(_ id: String, autoplay: Bool) {
        if let p = players[id] {
            if autoplay, active, currentID == id, !paused, states[id] == .ready { p.play() }
            return
        }
        // A Short that failed is only retried on request.
        if states[id] == .failed { return }
        let player = AVPlayer()
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        player.preventsDisplaySleepDuringVideoPlayback = true
        players[id] = player
        states[id] = .loading
        loopObservers[id] = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak player] note in
                guard let player, (note.object as? AVPlayerItem) === player.currentItem else { return }
                player.seek(to: .zero)
                player.play()
            }
        loadTasks[id] = Task { [weak self] in
            let prepared = await StreamResolver.firstPlayable(id) { candidate in
                guard !Task.isCancelled else { return false }
                self?.proxies[id] = candidate.proxy
                let item = AVPlayerItem(asset: candidate.asset)
                item.preferredForwardBufferDuration = 4
                player.replaceCurrentItem(with: item)
                return await StreamResolver.waitUntilReady(item, label: candidate.label)
            }
            guard let self, !Task.isCancelled, self.players[id] === player else { return }
            self.loadTasks[id] = nil
            guard let prepared else {
                player.replaceCurrentItem(with: nil)
                self.states[id] = .failed
                return
            }
            self.proxies[id] = prepared.proxy
            self.states[id] = .ready
            self.apply(prepared.info, to: id)
            if self.active, self.currentID == id, !self.paused {
                player.play()
                self.observeProgress(of: player)
            }
        }
    }

    private func apply(_ s: StreamInfo, to id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var v = items[i].video
        if v.title.isEmpty { v.title = s.title }
        if !s.author.isEmpty, v.channelName == nil { v.channelName = s.author }
        if let c = s.channelId, v.channelId == nil { v.channelId = c }
        if v.views == nil, let views = Int(s.viewCount ?? "") { v.views = views.compact + " Aufrufe" }
        if v != items[i].video { items[i].video = v }
    }

    private func observeProgress(of player: AVPlayer?) {
        if let current = timeObserver {
            if current.player === player { return }
            current.player.removeTimeObserver(current.token)
            timeObserver = nil
        }
        guard let player else { return }
        let token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self, let player, let duration = player.currentItem?.duration.seconds,
                      duration.isFinite, duration > 0 else { return }
                self.progress.value = min(1, max(0, time.seconds / duration))
            }
        }
        timeObserver = (player, token)
    }

    // MARK: Details, likes, comments

    private func loadDetails(_ id: String) {
        guard details[id] == nil, detailTasks[id] == nil else { return }
        detailTasks[id] = Task { [weak self] in
            let d = try? await YouTube.watch(id)
            guard let self else { return d }
            if let d {
                self.details[id] = d
                if let i = self.items.firstIndex(where: { $0.id == id }) {
                    var v = self.items[i].video
                    if v.title.isEmpty, !d.title.isEmpty { v.title = d.title }
                    if let c = d.channel {
                        if v.channelName == nil || v.channelName?.isEmpty == true { v.channelName = c.name }
                        if v.channelId == nil { v.channelId = c.id }
                        if v.channelAvatar == nil { v.channelAvatar = c.avatar }
                    }
                    if v != self.items[i].video { self.items[i].video = v }
                }
            } else {
                // Allow a new attempt later.
                self.detailTasks[id] = nil
            }
            return d
        }
    }

    func isLiked(_ id: String) -> Bool {
        likes[id] ?? (details[id]?.likeStatus == "LIKE")
    }

    func setLiked(_ id: String, _ liked: Bool, toast: @escaping (String) -> Void) {
        guard CookieJar.shared.isSignedIn else { toast("Zum Liken bitte anmelden"); return }
        let old = isLiked(id)
        guard old != liked else { return }
        likes[id] = liked
        Task {
            do {
                try await YouTube.setLike(id, status: liked ? "LIKE" : "INDIFFERENT")
            } catch {
                likes[id] = old
                toast(error.localizedDescription)
            }
        }
    }

    func isSubscribed(_ channelId: String, videoId: String) -> Bool {
        subscribed[channelId] ?? details[videoId]?.isSubscribed ?? false
    }

    func toggleSubscribe(_ channelId: String, videoId: String, toast: @escaping (String) -> Void) {
        guard CookieJar.shared.isSignedIn else { toast("Zum Abonnieren bitte anmelden"); return }
        let new = !isSubscribed(channelId, videoId: videoId)
        subscribed[channelId] = new
        Task {
            do {
                try await YouTube.setSubscribed(channelId, new)
                toast(new ? "Abonniert" : "Abo beendet")
            } catch {
                subscribed[channelId] = !new
                toast(error.localizedDescription)
            }
        }
    }

    /// Fetches the comment token if needed and opens the comments sheet.
    func showComments(_ item: ShortItem, toast: @escaping (String) -> Void) {
        if commentTokens[item.id] != nil {
            commentsItem = item
            return
        }
        guard commentsLoadingID == nil else { return }
        commentsLoadingID = item.id
        loadDetails(item.id)
        let task = detailTasks[item.id]
        Task {
            var token = details[item.id]?.commentsToken
            if token == nil, let task { token = await task.value?.commentsToken }
            if token == nil { token = await YouTube.shortCommentsToken(item.id) }
            commentsLoadingID = nil
            if let token {
                commentTokens[item.id] = token
                commentsItem = item
            } else {
                toast("Kommentare sind für diesen Short deaktiviert")
            }
        }
    }

    func commentsToken(for id: String) -> String? { commentTokens[id] }
}
