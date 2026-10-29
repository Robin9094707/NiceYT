import SwiftUI

/// Lives in the tab bar's bottom accessory (the iOS 26 Liquid Glass "now playing" slot).
struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let video = player.current {
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

                if placement != .inline {
                    Button { player.playNext() } label: {
                        Image(systemName: "forward.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)

                    Button { withAnimation { player.close() } } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .frame(width: 28, height: 32)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule()
                        .fill(.tint)
                        .frame(width: geo.size.width * player.progress, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 14)
            }
            .contentShape(Rectangle())
            .onTapGesture { player.isPresented = true }
        } else {
            HStack {
                Image(systemName: "play.rectangle.fill").foregroundStyle(.tint)
                Text("NiceYT").font(.footnote.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
        }
    }
}
