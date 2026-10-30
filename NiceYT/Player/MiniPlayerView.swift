import SwiftUI

/// Lives in the tab bar's bottom accessory (the iOS 26 Liquid Glass "now playing" slot).
struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var music: MusicPlayer
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if music.current != nil, music.isFocused || player.current == nil {
            MusicMiniPlayer()
        } else if let video = player.current {
            HStack(spacing: 10) {
                ZStack {
                    RemoteImage(url: video.bestThumbnail)
                    VideoLayer(player: player.player, gravity: .resizeAspectFill)
                        .opacity(player.isLoading ? 0 : 1)
                }
                .frame(width: placement == .inline ? 44 : 64, height: placement == .inline ? 28 : 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(player.stream?.title ?? video.title)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    if placement != .inline {
                        Text(player.stream?.author ?? video.channelName ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)

                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Abspielen")

                if placement != .inline {
                    Button { player.playNext() } label: {
                        Image(systemName: "forward.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Nächstes Video")

                    Button { withAnimation { player.close() } } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .frame(width: 28, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Schließen")
                }
            }
            .padding(.horizontal, 10)
            .overlay(alignment: .bottom) {
                MiniProgressBar(live: player.live)
                    .frame(height: 2)
                    .padding(.horizontal, 14)
            }
            .contentShape(Rectangle())
            .onTapGesture { player.presentPlayer() }
            .contextMenu {
                Button("Player öffnen", systemImage: "arrow.up.left.and.arrow.down.right") { player.presentPlayer() }
                Button("Nächstes Video", systemImage: "forward.fill") { player.playNext() }
                ShareLink(item: video.shareURL) { Label("Teilen", systemImage: "square.and.arrow.up") }
                Button("Schließen", systemImage: "xmark", role: .destructive) { withAnimation { player.close() } }
            }
            .accessibilityAction(named: "Player öffnen") { player.presentPlayer() }
        } else {
            HStack {
                Image(systemName: "play.rectangle.fill").foregroundStyle(.tint)
                Text("NicePlay").font(.footnote.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
        }
    }
}

/// Observes only the playback progress, so the rest of the mini player stays still.
private struct MiniProgressBar: View {
    @ObservedObject var live: PlayerLive

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(.tint)
                .frame(width: geo.size.width * live.progress, height: 2)
        }
    }
}
