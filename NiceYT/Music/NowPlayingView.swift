import AVKit
import MediaPlayer
import SwiftUI

/// Full-screen music player: cover, synced lyrics or queue, scrubber, controls, volume.
struct NowPlayingView: View {
    @EnvironmentObject private var music: MusicPlayer
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var store: MusicStore

    enum Panel { case cover, lyrics, queue }
    @State private var panel: Panel = .cover

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                if let track = music.current {
                    Group {
                        switch panel {
                        case .cover:
                            cover(track)
                        case .lyrics:
                            VStack(spacing: 14) {
                                compactInfo(track)
                                LyricsPanel(track: track, live: music.live)
                            }
                        case .queue:
                            VStack(spacing: 14) {
                                compactInfo(track)
                                QueueList()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))

                    VStack(spacing: 18) {
                        if panel == .cover { titleRow(track) }
                        MusicScrubber(live: music.live)
                        controls
                        VolumeSlider().frame(height: 34)
                        bottomBar(track)
                    }
                    .padding(.top, 18)
                } else {
                    ContentUnavailableView("Nichts in der Wiedergabe", systemImage: "music.note")
                        .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, max(12, geo.safeAreaInsets.bottom > 0 ? 4 : 16))
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .background { NowPlayingBackground(url: music.current?.coverURL(500)) }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: panel)
        .overlay(alignment: .top) {
            if let toast = music.toastText {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { music.showNowPlaying = false } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.bold))
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .accessibilityLabel("Schließen")
            Spacer()
            VStack(spacing: 1) {
                Text(music.isOffline ? "OFFLINE" : "WIRD GESPIELT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.6))
                if let album = music.current?.album, !album.isEmpty {
                    Text(album).font(.footnote.weight(.semibold)).lineLimit(1)
                }
            }
            .frame(maxWidth: 220)
            Spacer()
            if let track = music.current {
                Menu {
                    TrackMenu(track: track, list: music.queue)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.bold))
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: Cover

    private func cover(_ track: DZTrack) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { RemoteImage(url: track.coverURL(1000)) }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                if music.isLoading {
                    ProgressView().controlSize(.large).tint(.white)
                        .frame(width: 70, height: 70)
                        .glassEffect(.regular, in: .circle)
                }
            }
            .shadow(color: .black.opacity(0.45), radius: music.isPlaying ? 28 : 14, y: music.isPlaying ? 18 : 8)
            .scaleEffect(music.isPlaying ? 1 : 0.84)
            .animation(.spring(response: 0.5, dampingFraction: 0.72), value: music.isPlaying)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 30).onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    if v.translation.width < -60 { music.next() } else if v.translation.width > 60 { music.previous() }
                }
            )
            .onTapGesture(count: 2) { store.toggleFavorite(track) }
            .contextMenu { TrackMenu(track: track, list: music.queue) }
            .id(track.id)
            .transition(.opacity)
            .padding(.vertical, 8)
    }

    private func compactInfo(_ track: DZTrack) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: track.coverURL(250))
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.fullTitle).font(.headline).lineLimit(1)
                Text(track.artistLine).font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer(minLength: 8)
            favoriteButton(track, size: 38)
        }
        .padding(.top, 6)
    }

    private func titleRow(_ track: DZTrack) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(track.fullTitle)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                    if track.explicit {
                        Image(systemName: "e.square.fill").font(.footnote).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Button {
                    if let id = track.artistId { MusicRouter.shared.open(.artist(id)) }
                } label: {
                    Text(track.artistLine)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(track.artistId == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            favoriteButton(track, size: 44)
        }
    }

    @ViewBuilder private func favoriteButton(_ track: DZTrack, size: CGFloat) -> some View {
        if !track.isYouTube {
            let isFav = store.isFavorite(track.id)
            Button { store.toggleFavorite(track) } label: {
                Image(systemName: isFav ? "heart.fill" : "heart")
                    .font(size > 40 ? .title3 : .body)
                    .foregroundStyle(isFav ? Color.pink : Color.white)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isFav)
                    .frame(width: size, height: size)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFav ? "Aus Lieblingssongs entfernen" : "Zu Lieblingssongs")
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 0) {
            controlButton(systemImage: "shuffle", size: 19, active: music.shuffle) { music.toggleShuffle() }
                .accessibilityLabel("Zufallswiedergabe")
            Spacer(minLength: 0)
            controlButton(systemImage: "backward.fill", size: 28) { music.previous() }
                .accessibilityLabel("Zurück")
            Spacer(minLength: 0)
            Button { music.togglePlay() } label: {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 78, height: 78)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(music.isPlaying ? "Pause" : "Abspielen")
            Spacer(minLength: 0)
            controlButton(systemImage: "forward.fill", size: 28) { music.next() }
                .accessibilityLabel("Weiter")
            Spacer(minLength: 0)
            controlButton(systemImage: music.repeatMode == .one ? "repeat.1" : "repeat", size: 19,
                          active: music.repeatMode != .off) { music.cycleRepeat() }
                .accessibilityLabel("Wiederholen")
        }
    }

    private func controlButton(systemImage: String, size: CGFloat, active: Bool? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active == false ? Color.white.opacity(0.55) : Color.white)
                .frame(width: 48, height: 48)
                .background {
                    if active == true { Circle().fill(.white.opacity(0.18)) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func bottomBar(_ track: DZTrack) -> some View {
        HStack(spacing: 0) {
            panelButton(.lyrics, systemImage: "quote.bubble")
                .accessibilityLabel("Songtext")
            Spacer(minLength: 0)
            AirPlayButton().frame(width: 44, height: 44)
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                downloadButton(track)
                if let q = music.quality {
                    Text(q.badge)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 44, height: 44)
            Spacer(minLength: 0)
            Group {
                if let file = downloads.file(for: track.id) {
                    ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") }
                } else {
                    ShareLink(item: track.shareURL) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .font(.title3)
            .frame(width: 44, height: 44)
            Spacer(minLength: 0)
            panelButton(.queue, systemImage: "list.bullet")
                .accessibilityLabel("Warteschlange")
        }
        .buttonStyle(.plain)
    }

    private func panelButton(_ target: Panel, systemImage: String) -> some View {
        Button {
            Haptics.selection()
            panel = panel == target ? .cover : target
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background {
                    if panel == target { Circle().fill(.white.opacity(0.2)) }
                }
        }
    }

    @ViewBuilder private func downloadButton(_ track: DZTrack) -> some View {
        if downloads.isDownloaded(track.id) {
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                .accessibilityLabel("Heruntergeladen")
        } else if let p = downloads.progress[track.id] {
            ProgressRing(value: p).frame(width: 22, height: 22)
        } else {
            Button { downloads.download(track) } label: {
                Image(systemName: "arrow.down.circle").font(.title3)
            }
            .accessibilityLabel("Herunterladen")
        }
    }
}

/// Blurred cover behind the player; as a background it never influences the layout.
private struct NowPlayingBackground: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color.black
            RemoteImage(url: url)
                .scaleEffect(1.5)
                .blur(radius: 60)
                .opacity(0.85)
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.35), .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: url)
    }
}

/// Seek bar with elapsed / remaining time; only it observes the position.
struct MusicScrubber: View {
    @ObservedObject var live: MusicLive
    @State private var dragValue: Double?

    var body: some View {
        let duration = max(live.duration, 1)
        let value = dragValue ?? min(live.time, duration)
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(dragValue == nil ? 0.85 : 1))
                        .frame(width: max(0, geo.size.width * value / duration))
                }
                .frame(height: dragValue == nil ? 6 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if dragValue == nil { Haptics.selection() }
                            dragValue = min(max(0, g.location.x / max(1, geo.size.width)), 1) * duration
                        }
                        .onEnded { _ in
                            if let v = dragValue { MusicPlayer.shared.seek(to: v) }
                            Haptics.tap()
                            dragValue = nil
                        }
                )
                .animation(.spring(response: 0.25), value: dragValue == nil)
            }
            .frame(height: 22)
            HStack {
                Text(Self.format(value))
                Spacer()
                Text("-" + Self.format(max(0, duration - value)))
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    static func format(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Song text from Deezer; synced lyrics follow the music and can be tapped to seek.
private struct LyricsPanel: View {
    let track: DZTrack
    @ObservedObject var live: MusicLive
    @State private var lyrics: DZLyrics?
    @State private var loadedId: String?
    @State private var isLoading = false

    private var currentLine: Int? {
        guard let lyrics, lyrics.isSynced else { return nil }
        return lyrics.lines.lastIndex { ($0.time ?? .infinity) <= live.time + 0.3 }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().tint(.white)
            } else if let lyrics, !lyrics.lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: lyrics.isSynced ? 18 : 6) {
                            ForEach(lyrics.lines) { line in
                                let active = currentLine == line.id
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(lyrics.isSynced ? .title2.weight(.bold) : .body.weight(.medium))
                                    .foregroundStyle(.white.opacity(lyrics.isSynced ? (active ? 1 : 0.38) : 0.9))
                                    .scaleEffect(active ? 1.0 : 0.97, anchor: .leading)
                                    .animation(.easeOut(duration: 0.25), value: active)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                                    .onTapGesture {
                                        if let t = line.time {
                                            Haptics.tap()
                                            MusicPlayer.shared.seek(to: t)
                                        }
                                    }
                            }
                            if let c = lyrics.copyright, !c.isEmpty {
                                Text(c).font(.caption2).foregroundStyle(.white.opacity(0.45)).padding(.top, 10)
                            }
                        }
                        .padding(.vertical, 40)
                    }
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                                 .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .onChange(of: currentLine) { _, line in
                        guard let line else { return }
                        withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(line, anchor: .center) }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "quote.bubble").font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                    Text("Für diesen Song gibt es keinen Songtext.").font(.callout).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: track.id) { await load() }
    }

    private func load() async {
        guard loadedId != track.id else { return }
        lyrics = nil
        guard !track.isYouTube else { loadedId = track.id; return }
        isLoading = true
        lyrics = try? await Deezer.shared.lyrics(track.id)
        loadedId = track.id
        isLoading = false
    }
}

struct QueueList: View {
    @EnvironmentObject private var music: MusicPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Als Nächstes").font(.headline)
                Spacer()
                Text("\(music.upNext.count) Songs").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            if music.upNext.isEmpty {
                Text(music.repeatMode == .all ? "Die Warteschlange beginnt von vorn." : "Keine weiteren Songs.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(music.upNext.enumerated()), id: \.element.id) { i, t in
                        HStack(spacing: 12) {
                            RemoteImage(url: t.coverURL(250))
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.fullTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(t.artistLine).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(t.durationText).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { music.jump(to: music.index + 1 + i) }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.15))
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    }
                    .onDelete { music.removeFromQueue($0) }
                    .onMove { music.moveInQueue(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.inactive))
            }
        }
    }
}

/// System volume slider (also controls AirPlay/Bluetooth volume).
private struct VolumeSlider: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.white.opacity(0.6))
            SystemVolumeView()
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .white
        view.setVolumeThumbImage(Self.thumb, for: .normal)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}

    private static let thumb: UIImage = {
        let size = CGSize(width: 14, height: 14)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }()
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemPink
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Music variant of the mini player in the tab bar accessory.
struct MusicMiniPlayer: View {
    @EnvironmentObject private var music: MusicPlayer
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let track = music.current {
            HStack(spacing: 10) {
                RemoteImage(url: track.coverURL(250))
                    .frame(width: placement == .inline ? 28 : 36, height: placement == .inline ? 28 : 36)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.fullTitle).font(.footnote.weight(.semibold)).lineLimit(1)
                    if placement != .inline {
                        Text(track.artistLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if music.isLoading {
                    ProgressView().controlSize(.small).frame(width: 32, height: 32)
                } else {
                    Button { music.togglePlay() } label: {
                        Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                            .font(.body.weight(.semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(music.isPlaying ? "Pause" : "Abspielen")
                }
                if placement != .inline {
                    Button { music.next() } label: {
                        Image(systemName: "forward.fill").font(.body.weight(.semibold)).frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Nächster Song")
                }
            }
            .padding(.horizontal, 10)
            .overlay(alignment: .bottom) {
                MiniMusicProgress(live: music.live).frame(height: 2).padding(.horizontal, 14)
            }
            .contentShape(Rectangle())
            .onTapGesture { music.showNowPlaying = true }
            .contextMenu {
                Button("Player öffnen", systemImage: "arrow.up.left.and.arrow.down.right") { music.showNowPlaying = true }
                TrackMenu(track: track, list: music.queue)
                Button("Wiedergabe beenden", systemImage: "xmark", role: .destructive) { withAnimation { music.stop() } }
            }
        }
    }
}

private struct MiniMusicProgress: View {
    @ObservedObject var live: MusicLive

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(.tint)
                .frame(width: live.duration > 0 ? geo.size.width * min(1, live.time / live.duration) : 0, height: 2)
        }
    }
}
