import SwiftUI

struct ShortsView: View {
    @EnvironmentObject private var shorts: ShortsModel
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.black.ignoresSafeArea()
                if shorts.items.isEmpty {
                    if let e = shorts.error {
                        ErrorState(message: e) { Task { await shorts.reload() } }
                    } else {
                        ProgressView().tint(.white).controlSize(.large)
                    }
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(shorts.items) { item in
                                ShortPage(item: item, isCurrent: item.id == shorts.currentID)
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
            // Dark only for the Shorts themselves (preferredColorScheme would turn the whole app dark).
            .environment(\.colorScheme, .dark)
            .toolbarColorScheme(.dark, for: .tabBar)
            .toolbar(.hidden, for: .navigationBar)
            .withRoutes()
        }
        .onChange(of: path.count) { _, count in shorts.setPushed(count > 0) }
        .sheet(item: $shorts.commentsItem) { item in
            if let token = shorts.commentsToken(for: item.id) {
                CommentsView(token: token, count: shorts.details[item.id]?.commentCount, videoId: item.id)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
        .task { await shorts.loadIfNeeded() }
    }
}

struct ShortPage: View {
    @EnvironmentObject private var shorts: ShortsModel
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var account: AccountStore
    let item: ShortItem
    let isCurrent: Bool
    @State private var showHeart = false
    @State private var showActions = false

    private var state: ShortsModel.LoadState? { shorts.states[item.id] }
    private var details: WatchDetails? { shorts.details[item.id] }
    private var liked: Bool { shorts.isLiked(item.id) }

    var body: some View {
        // Color.black defines the page size; media is layered as overlays so wide
        // thumbnails can never stretch the page (and push the buttons off-screen).
        Color.black
            .overlay {
                RemoteImage(url: item.video.thumbnail ?? URL(string: "https://i.ytimg.com/vi/\(item.id)/oar2.jpg"))
            }
            .overlay {
                if let p = shorts.players[item.id] {
                    VideoLayer(player: p, gravity: .resizeAspectFill)
                        .opacity(state == .ready ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: state)
                }
            }
            .clipped()
            .overlay { statusOverlay }
            .overlay {
                if showHeart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(.red.gradient)
                        .shadow(radius: 10)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { doubleTapLike() }
            .onTapGesture {
                guard state == .ready else { return }
                withAnimation(.spring) { shorts.togglePause() }
            }
            .onLongPressGesture(minimumDuration: 0.45) {
                Haptics.impact()
                showActions = true
            }
            .confirmationDialog(item.video.title.isEmpty ? (details?.title ?? "Short") : item.video.title,
                                isPresented: $showActions, titleVisibility: .visible) { longPressActions }
            .overlay(alignment: .bottomLeading) { info }
            .overlay(alignment: .bottomTrailing) { actions }
            .overlay(alignment: .bottom) {
                if isCurrent, state == .ready {
                    ShortProgressBar(progress: shorts.progress)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 98)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder private var statusOverlay: some View {
        switch state {
        case .failed:
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Dieser Short konnte nicht geladen werden.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button("Erneut versuchen", systemImage: "arrow.clockwise") { shorts.retry(item.id) }
                        .buttonStyle(.glassProminent)
                    Button("Im Player", systemImage: "play.rectangle") { openInPlayer() }
                        .buttonStyle(.glass)
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(24)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .padding(32)
        case .loading where isCurrent:
            ProgressView().controlSize(.large).tint(.white)
                .allowsHitTesting(false)
        default:
            if shorts.paused, isCurrent {
                Image(systemName: "play.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .glassEffect(.regular, in: .circle)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }

    private func doubleTapLike() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { showHeart = true }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeOut) { showHeart = false }
        }
        if !liked { shorts.setLiked(item.id, true) { player.showToast($0) } } else { Haptics.tap() }
    }

    @ViewBuilder private var longPressActions: some View {
        Button(liked ? "„Mag ich“ entfernen" : "Mag ich") {
            shorts.setLiked(item.id, !liked) { player.showToast($0) }
        }
        Button("Kommentare") { shorts.showComments(item) { player.showToast($0) } }
        if let cid = channelId, account.isSignedIn {
            Button(shorts.isSubscribed(cid, videoId: item.id) ? "Abo beenden" : "Kanal abonnieren") {
                shorts.toggleSubscribe(cid, videoId: item.id) { player.showToast($0) }
            }
        }
        if account.isSignedIn {
            Button("Später ansehen") {
                Task {
                    do {
                        try await YouTube.addToWatchLater(item.id)
                        Haptics.success()
                        player.showToast("Zu „Später ansehen“ hinzugefügt")
                    } catch {
                        Haptics.error()
                        player.showToast(error.localizedDescription)
                    }
                }
            }
        }
        Button("Im Player öffnen") { openInPlayer() }
        Button("Song auf Deezer suchen") {
            shorts.setTabActive(false)
            MusicSearchRequest.shared.search(item.video.title.isEmpty ? (details?.title ?? "") : item.video.title)
        }
        Button("Teilen …") { ShareSheet.present([item.video.shareURL]) }
        Button("Link kopieren") {
            UIPasteboard.general.url = item.video.shareURL
            Haptics.success()
            player.showToast("Link kopiert")
        }
        Button("Abbrechen", role: .cancel) {}
    }

    private func openInPlayer() {
        shorts.setTabActive(false)
        player.play(item.video)
    }

    // MARK: Info

    private var channelId: String? { item.video.channelId ?? details?.channel?.id }
    private var channelName: String? {
        let name = item.video.channelName ?? details?.channel?.name
        return name?.isEmpty == false ? name : nil
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = channelName {
                HStack(spacing: 10) {
                    Group {
                        if let cid = channelId {
                            NavigationLink(value: Route.channel(cid)) { channelLabel(name) }
                        } else {
                            channelLabel(name)
                        }
                    }
                    .buttonStyle(.plain)
                    if let cid = channelId, account.isSignedIn {
                        let subscribed = shorts.isSubscribed(cid, videoId: item.id)
                        Button {
                            shorts.toggleSubscribe(cid, videoId: item.id) { player.showToast($0) }
                        } label: {
                            Text(subscribed ? "Abonniert" : "Abonnieren")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(subscribed ? Color.white : Color.black)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(subscribed ? Color.white.opacity(0.2) : Color.white, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(item.video.title.isEmpty ? (details?.title ?? "") : item.video.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(3)
            if let v = item.video.views ?? details?.views {
                Text(v).font(.caption).opacity(0.8)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 4)
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
            let avatar = item.video.channelAvatar ?? details?.channel?.avatar
            if avatar != nil {
                Avatar(url: avatar, size: 32)
            } else {
                Circle().fill(.white.opacity(0.25)).frame(width: 32, height: 32)
                    .overlay(Text(String(name.drop(while: { $0 == "@" }).prefix(1)).uppercased()).font(.caption.bold()))
            }
            Text(name).font(.subheadline.weight(.bold)).lineLimit(1)
        }
    }

    // MARK: Actions

    private var likeCount: String {
        guard let text = details?.likeText else { return "Mag ich" }
        let digits = text.filter(\.isNumber)
        if let n = Int(digits), digits.count == text.filter({ !$0.isWhitespace && $0 != "." && $0 != "," }).count {
            // Reflect the user's own (not yet reloaded) like in the count.
            let wasLiked = details?.likeStatus == "LIKE"
            return max(0, n + (liked ? 1 : 0) - (wasLiked ? 1 : 0)).compact
        }
        return text
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 16) {
                actionButton(liked ? "hand.thumbsup.fill" : "hand.thumbsup", likeCount, label: "Mag ich") {
                    shorts.setLiked(item.id, !liked) { player.showToast($0) }
                }
                actionButton("text.bubble", details?.commentCount ?? "Kommentare", label: "Kommentare",
                             loading: shorts.commentsLoadingID == item.id) {
                    shorts.showComments(item) { player.showToast($0) }
                }
                ShareLink(item: item.video.shareURL) {
                    VStack(spacing: 4) {
                        icon("arrowshape.turn.up.right")
                        caption("Teilen")
                    }
                }
                .buttonStyle(.plain)
                actionButton("rectangle.portrait.and.arrow.right", "Player", label: "Im Player öffnen") {
                    openInPlayer()
                }
            }
        }
        .padding(.trailing, 12)
        .padding(.bottom, 110)
    }

    private func actionButton(_ systemImage: String, _ text: String, label: String, loading: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    icon(systemImage).opacity(loading ? 0.4 : 1)
                    if loading { ProgressView().tint(.white) }
                }
                caption(text)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func icon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 48, height: 48)
            .glassEffect(.regular.interactive(), in: .circle)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 3)
            .lineLimit(1)
            .frame(maxWidth: 64)
    }
}

private struct ShortProgressBar: View {
    @ObservedObject var progress: ShortsProgress

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: geo.size.width * progress.value)
            }
        }
        .frame(height: 3)
    }
}
