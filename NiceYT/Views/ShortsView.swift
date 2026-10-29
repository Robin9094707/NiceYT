import SwiftUI

struct ShortsView: View {
    @EnvironmentObject private var shorts: ShortsModel

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if shorts.items.isEmpty {
                    if let e = shorts.error {
                        ErrorState(message: e) { Task { await shorts.loadIfNeeded() } }
                    } else {
                        ProgressView().tint(.white).controlSize(.large)
                    }
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(shorts.items) { item in
                                ShortPage(item: item)
                                    .containerRelativeFrame([.horizontal, .vertical])
                                    .id(item.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $shorts.currentID)
                    .scrollIndicators(.hidden)
                    .ignoresSafeArea()
                    .onChange(of: shorts.currentID) { shorts.currentChanged() }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .withRoutes()
        }
        .preferredColorScheme(.dark)
        .task { await shorts.loadIfNeeded() }
    }
}

struct ShortPage: View {
    @EnvironmentObject private var shorts: ShortsModel
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var account: AccountStore
    let item: ShortItem
    @State private var liked = false
    @State private var commentsToken: String?
    @State private var showComments = false

    @State private var heartBurst = 0
    @State private var showHeart = false

    var body: some View {
        // Color.black defines the page size; media is layered as overlays so wide
        // thumbnails can never stretch the page (and push the buttons off-screen).
        Color.black
            .overlay {
                RemoteImage(url: URL(string: "https://i.ytimg.com/vi/\(item.id)/oar2.jpg"))
                    .blur(radius: shorts.players[item.id]?.currentItem == nil ? 0 : 20)
            }
            .overlay {
                if let p = shorts.players[item.id] {
                    VideoLayer(player: p, gravity: .resizeAspectFill)
                }
            }
            .clipped()
            .overlay {
                if shorts.paused && shorts.currentID == item.id {
                    Image(systemName: "play.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                        .frame(width: 88, height: 88)
                        .glassEffect(.regular, in: .circle)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay {
                if showHeart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(.red.gradient)
                        .shadow(radius: 10)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { doubleTapLike() }
            .onTapGesture { withAnimation(.spring) { shorts.togglePause() } }
            .overlay(alignment: .bottomLeading) { info }
            .overlay(alignment: .bottomTrailing) { actions }
            .sheet(isPresented: $showComments) {
                if let commentsToken {
                    CommentsView(token: commentsToken, count: nil)
                        .presentationDetents([.medium, .large])
                }
            }
    }

    private func doubleTapLike() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { showHeart = true }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeOut) { showHeart = false }
        }
        guard !liked else { return }
        guard account.isSignedIn else { player.showToast("Zum Liken bitte anmelden"); return }
        liked = true
        let id = item.id
        Task { try? await YouTube.setLike(id, status: "LIKE") }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = item.video.channelName {
                Group {
                    if let cid = item.video.channelId {
                        NavigationLink(value: Route.channel(cid)) { channelLabel(name) }
                    } else {
                        channelLabel(name)
                    }
                }
                .buttonStyle(.plain)
            }
            Text(item.video.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(3)
            if let v = item.video.views {
                Text(v).font(.caption).opacity(0.8)
            }
        }
        .foregroundStyle(.white)
        .shadow(radius: 4)
        .padding(.leading, 16)
        .padding(.trailing, 84)
        .padding(.bottom, 110)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .frame(height: 320)
                .allowsHitTesting(false)
        }
    }

    private func channelLabel(_ name: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(.white.opacity(0.25)).frame(width: 30, height: 30)
                .overlay(Text(String(name.drop(while: { $0 == "@" }).prefix(1)).uppercased()).font(.caption.bold()))
            Text(name).font(.subheadline.weight(.bold))
        }
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 14) {
                actionButton(liked ? "hand.thumbsup.fill" : "hand.thumbsup", "Like") {
                    guard account.isSignedIn else { player.showToast("Bitte anmelden"); return }
                    liked.toggle()
                    let id = item.id, status = liked ? "LIKE" : "INDIFFERENT"
                    Task { try? await YouTube.setLike(id, status: status) }
                }
                actionButton("text.bubble", "Kommentare") {
                    Task {
                        if commentsToken == nil {
                            commentsToken = try? await YouTube.watch(item.id).commentsToken
                        }
                        showComments = commentsToken != nil
                    }
                }
                ShareLink(item: item.video.shareURL) {
                    icon("arrowshape.turn.up.right")
                }
                .buttonStyle(.plain)
                actionButton("rectangle.portrait.and.arrow.right", "Im Player öffnen") {
                    shorts.setActive(false)
                    player.play(item.video)
                }
            }
        }
        .padding(.trailing, 14)
        .padding(.bottom, 110)
    }

    private func actionButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(systemImage) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func icon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}
