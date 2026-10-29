import AVKit
import Combine
import SwiftUI

struct ShortItem: Identifiable, Hashable {
    let id: String
    var video: Video
}

@MainActor
final class ShortsModel: ObservableObject {
    @Published var items: [ShortItem] = []
    @Published var currentID: String?
    @Published private(set) var players: [String: AVPlayer] = [:]
    @Published private(set) var streams: [String: StreamInfo] = [:]
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published var paused = false
    @Published var openRequest = UUID()

    private var sequence: String?
    private var loadingMore = false
    private var active = false
    private var loopObservers: [String: AnyCancellable] = [:]

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
            await loadMore()
            if currentID == nil { currentID = items.first?.id }
            if active { activateCurrent() }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
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
        for id in ids where !existing.contains(id) {
            items.append(ShortItem(id: id, video: Video(id: id, title: "", isShort: true)))
        }
    }

    /// Opens the Shorts tab at `video`, followed by the rest of `list`.
    func open(_ video: Video, from list: [Video]) {
        let start = list.firstIndex(of: video) ?? 0
        let ordered = Array(list[start...]) + Array(list[..<start])
        let newItems = ordered.map { ShortItem(id: $0.id, video: $0) }
        let ids = Set(newItems.map(\.id))
        items = newItems + items.filter { !ids.contains($0.id) }
        currentID = video.id
        openRequest = UUID()
        if active { activateCurrent() }
    }

    // MARK: Playback

    func setActive(_ value: Bool) {
        active = value
        if value {
            activateCurrent()
        } else {
            players.values.forEach { $0.pause() }
        }
    }

    func currentChanged() {
        paused = false
        activateCurrent()
        if let id = currentID, let idx = items.firstIndex(where: { $0.id == id }), idx >= items.count - 4 {
            Task { await loadMore() }
        }
    }

    func togglePause() {
        guard let id = currentID, let p = players[id] else { return }
        if p.timeControlStatus == .playing { p.pause(); paused = true } else { p.play(); paused = false }
    }

    private func activateCurrent() {
        guard let id = currentID, let idx = items.firstIndex(where: { $0.id == id }) else { return }
        for (key, p) in players where key != id { p.pause(); p.seek(to: .zero) }
        prepare(id, autoplay: active)
        if idx + 1 < items.count { prepare(items[idx + 1].id, autoplay: false) }
        // Drop players far away from the current position.
        let keep = Set(items[max(0, idx - 1)...min(items.count - 1, idx + 2)].map(\.id))
        for key in players.keys where !keep.contains(key) {
            players[key]?.pause()
            players[key] = nil
            loopObservers[key] = nil
        }
    }

    private func prepare(_ id: String, autoplay: Bool) {
        if let p = players[id] {
            if autoplay, active, currentID == id { p.play() }
            return
        }
        let player = AVPlayer()
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        players[id] = player
        loopObservers[id] = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak player] note in
                guard let player, (note.object as? AVPlayerItem) === player.currentItem else { return }
                player.seek(to: .zero)
                player.play()
            }
        Task {
            do {
                let s = try await YouTube.stream(id)
                streams[id] = s
                if let i = items.firstIndex(where: { $0.id == id }) {
                    var v = items[i].video
                    if v.title.isEmpty { v.title = s.title }
                    v.channelName = s.author
                    v.channelId = s.channelId
                    if let views = Int(s.viewCount ?? "") { v.views = views.compact + " Aufrufe" }
                    items[i].video = v
                }
                let asset = AVURLAsset(url: s.hlsURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": s.userAgent]])
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                if active, currentID == id, !paused { player.play() }
            } catch {
                if currentID == id { self.error = error.localizedDescription }
            }
        }
    }
}
