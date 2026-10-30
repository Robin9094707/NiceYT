import AVKit
import SwiftUI

/// Full-screen music player with cover, scrubber, controls, queue and sharing.
struct NowPlayingView: View {
    @EnvironmentObject private var music: MusicPlayer
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false

    var body: some View {
        ZStack {
            background
            if let track = music.current {
                VStack(spacing: 20) {
                    Capsule().fill(.white.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 8)
                    if showQueue {
                        QueueList()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        Spacer(minLength: 0)
                        cover(track)
                        Spacer(minLength: 0)
                    }
                    titleRow(track)
                    MusicScrubber(live: music.live)
                    controls
                    bottomBar(track)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 12)
            } else {
                ContentUnavailableView("Nichts in der Wiedergabe", systemImage: "music.note")
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showQueue)
        .overlay(alignment: .top) {
            if let toast = music.toastText {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var background: some View {
        ZStack {
            Color.black
            RemoteImage(url: music.current?.coverURL(500))
                .scaleEffect(1.6)
                .blur(radius: 70)
                .opacity(0.9)
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: music.current?.id)
    }

    private func cover(_ track: DZTrack) -> some View {
        RemoteImage(url: track.coverURL(1000))
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
            .scaleEffect(music.isPlaying ? 1 : 0.86)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: music.isPlaying)
            .overlay {
                if music.isLoading {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 30).onEnded { v in
                    if v.translation.width < -60 { music.next() } else if v.translation.width > 60 { music.previous() }
                }
            )
            .contextMenu { TrackMenu(track: track, list: music.queue) }
            .frame(maxWidth: 380)
    }

    private func titleRow(_ track: DZTrack) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.fullTitle)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Button {
                    if let id = track.artistId { MusicRouter.shared.open(.artist(id)) }
                } label: {
                    Text(track.artistLine).font(.title3).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { store.toggleFavorite(track) } label: {
                Image(systemName: store.isFavorite(track.id) ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(store.isFavorite(track.id) ? Color.pink : Color.white)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: store.isFavorite(track.id))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lieblingssong")
        }
    }

    private var controls: some View {
        HStack {
            Button { music.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(music.shuffle ? Color.accentColor : Color.white.opacity(0.75))
            }
            Spacer()
            Button { music.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
            Spacer()
            Button { music.togglePlay() } label: {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 84, height: 84)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            Spacer()
            Button { music.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
            Spacer()
            Button { music.cycleRepeat() } label: {
                Image(systemName: music.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(music.repeatMode == .off ? Color.white.opacity(0.75) : Color.accentColor)
            }
        }
        .buttonStyle(.plain)
    }

    private func bottomBar(_ track: DZTrack) -> some View {
        HStack(spacing: 18) {
            if let q = music.quality {
                Text(music.isOffline ? "OFFLINE · \(q.badge)" : q.badge)
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1))
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            downloadButton(track)
            if let file = downloads.file(for: track.id) {
                ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up").font(.title3) }
            } else {
                ShareLink(item: track.shareURL) { Image(systemName: "square.and.arrow.up").font(.title3) }
            }
            AirPlayButton().frame(width: 30, height: 30)
            Button { Haptics.selection(); showQueue.toggle() } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(showQueue ? Color.accentColor : Color.white)
            }
        }
        .buttonStyle(.plain)
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
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: geo.size.width * value / duration)
                }
                .frame(height: dragValue == nil ? 6 : 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if dragValue == nil { Haptics.selection() }
                            dragValue = min(max(0, g.location.x / geo.size.width), 1) * duration
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
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    static func format(_ t: Double) -> String {
        guard t.isFinite else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct QueueList: View {
    @EnvironmentObject private var music: MusicPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Als Nächstes").font(.headline)
                Spacer()
                Text("\(music.upNext.count) Songs").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            List {
                ForEach(Array(music.upNext.enumerated()), id: \.element.id) { i, t in
                    HStack(spacing: 12) {
                        RemoteImage(url: t.coverURL(250))
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.fullTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(t.artistLine).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { music.jump(to: music.index + 1 + i) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                }
                .onDelete { music.removeFromQueue($0) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity)
    }
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
