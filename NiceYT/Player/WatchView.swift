import SwiftUI

struct WatchView: View {
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.verticalSizeClass) private var vSize
    @State private var showComments = false
    @State private var showDescription = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geo in
                if vSize == .compact || player.isFullscreen {
                    // Landscape: video fills the screen.
                    videoArea.frame(width: geo.size.width, height: geo.size.height)
                        .ignoresSafeArea()
                } else {
                    VStack(spacing: 0) {
                        videoArea
                            .frame(width: geo.size.width, height: geo.size.width * 9 / 16)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                infoSection
                                relatedSection
                            }
                            .padding(16)
                        }
                        .scrollEdgeEffectStyle(.soft, for: .top)
                    }
                }
            }
            .background(vSize == .compact || player.isFullscreen ? Color.black : Color(.systemBackground))
            .statusBarHidden(vSize == .compact || player.isFullscreen)
            .persistentSystemOverlays(vSize == .compact || player.isFullscreen ? .hidden : .automatic)
            .toolbar(.hidden, for: .navigationBar)
            .withRoutes()
            .overlay(alignment: .top) { toastView }
        }
        .sheet(isPresented: $showComments) {
            if let token = player.details?.commentsToken {
                CommentsView(token: token, count: player.details?.commentCount)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
        .sheet(isPresented: $showDescription) {
            DescriptionSheet()
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Video

    private var videoArea: some View {
        ZStack {
            Color.black
            if let error = player.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.orange)
                    Text(error).font(.callout).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Erneut versuchen", systemImage: "arrow.clockwise") { player.retry() }
                        .buttonStyle(.glass)
                }
                .padding()
            } else {
                SystemPlayerView()
                if player.isLoading {
                    if let video = player.current {
                        RemoteImage(url: video.bestThumbnail).opacity(0.6)
                    }
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            if let caption = player.currentCaption {
                VStack {
                    Spacer()
                    Text(caption)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
                        .padding(.bottom, 44)
                        .padding(.horizontal, 20)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay { gestureHUD }
        .overlay(alignment: .topLeading) {
            if vSize != .compact && !player.isFullscreen {
                Button { player.isPresented = false } label: {
                    Image(systemName: "chevron.down")
                        .font(.headline)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if player.error == nil {
                let full = vSize == .compact || player.isFullscreen
                Button {
                    player.setFullscreen(!full)
                } label: {
                    Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(full ? 20 : 10)
            }
        }
    }

    // MARK: Gesture feedback

    @ViewBuilder private var gestureHUD: some View {
        switch player.hud {
        case .seek(let seconds):
            HStack {
                if seconds > 0 { Spacer() }
                Label("\(seconds > 0 ? "+" : "")\(seconds) s", systemImage: seconds > 0 ? "goforward" : "gobackward")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 40)
                if seconds < 0 { Spacer() }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .allowsHitTesting(false)
        case .volume(let v):
            levelHUD(icon: v == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", value: Double(v))
        case .brightness(let b):
            levelHUD(icon: "sun.max.fill", value: b)
        case nil:
            EmptyView()
        }
    }

    private func levelHUD(icon: String, value: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
            ProgressView(value: value).frame(width: 120).tint(.white)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
    }

    // MARK: Info

    private var video: Video? { player.current }
    private var details: WatchDetails? { player.details }

    @ViewBuilder private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(details?.title.nilIfEmpty ?? player.stream?.title ?? video?.title ?? "")
                .font(.title3.weight(.bold))
                .lineLimit(3)
            Button { showDescription = true } label: {
                HStack(spacing: 6) {
                    Text([details?.views ?? video?.views, details?.date ?? video?.published].compactMap { $0 }.joined(separator: " · "))
                    Text("…mehr").fontWeight(.semibold).foregroundStyle(.primary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .buttonStyle(.plain)
        }

        channelBar
        actionBar
        if details?.commentsToken != nil { commentsTeaser }
    }

    private var channelBar: some View {
        HStack(spacing: 12) {
            let channelId = details?.channel?.id ?? video?.channelId
            Group {
                if let channelId {
                    NavigationLink(value: Route.channel(channelId)) { channelLabel }
                } else {
                    channelLabel
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if channelId != nil {
                Button {
                    if account.isSignedIn { player.toggleSubscribe() } else { player.showToast("Zum Abonnieren bitte anmelden") }
                } label: {
                    Label(player.isSubscribed ? "Abonniert" : "Abonnieren",
                          systemImage: player.isSubscribed ? "bell.fill" : "plus")
                        .font(.subheadline.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassProminent)
                .tint(player.isSubscribed ? .gray : .accentColor)
            }
        }
    }

    private var channelLabel: some View {
        HStack(spacing: 10) {
            Avatar(url: details?.channel?.avatar ?? video?.channelAvatar, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(details?.channel?.name ?? player.stream?.author ?? video?.channelName ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subs = details?.channel?.subscribers {
                    Text(subs).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var actionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        Button { player.toggleLike("LIKE") } label: {
                            Label(likeLabel, systemImage: player.likeStatus == "LIKE" ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .padding(.horizontal, 14).padding(.vertical, 9)
                        }
                        Divider().frame(height: 20)
                        Button { player.toggleLike("DISLIKE") } label: {
                            Label(dislikeLabel, systemImage: player.likeStatus == "DISLIKE" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                .padding(.horizontal, 14).padding(.vertical, 9)
                        }
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)

                    if let v = video {
                        ShareLink(item: v.shareURL) {
                            pill("Teilen", "square.and.arrow.up")
                        }
                    }
                    if account.isSignedIn {
                        Button { player.watchLater() } label: { pill("Später", "clock") }
                    }
                    Menu {
                        Picker("Qualität", selection: Binding(get: { player.quality }, set: { player.setQuality($0) })) {
                            ForEach(VideoQuality.allCases) { q in Text(q.label).tag(q) }
                        }
                    } label: { pill(player.quality == .auto ? "Auto" : player.quality.rawValue + "p", "sparkles.tv") }

                    if !player.captionTracks.isEmpty {
                        Menu {
                            Button("Aus") { Task { await player.selectCaption(nil) } }
                            ForEach(player.captionTracks) { t in
                                Button(t.name) { Task { await player.selectCaption(t) } }
                            }
                        } label: { pill(player.captionTrack == nil ? "Untertitel" : player.captionTrack!.languageCode.uppercased(),
                                        player.captionTrack == nil ? "captions.bubble" : "captions.bubble.fill") }
                    }
                    if let source = player.sourceLabel {
                        pill(source, "antenna.radiowaves.left.and.right")
                    }
                    if !player.segments.isEmpty {
                        pill("\(player.segments.count) SponsorBlock", "forward.end.circle")
                    }
                    if let v = video {
                        Button { UIPasteboard.general.url = v.shareURL; player.showToast("Link kopiert") } label: { pill("Link", "link") }
                    }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
            }
        }
        .scrollClipDisabled()
    }

    private func pill(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var likeLabel: String {
        if let d = player.dislikes, settings.dislikes { return d.likes.compact }
        return details?.likeText ?? "Mag ich"
    }

    private var dislikeLabel: String {
        if let d = player.dislikes, settings.dislikes { return d.dislikes.compact }
        return ""
    }

    private var commentsTeaser: some View {
        Button { showComments = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Kommentare").font(.subheadline.weight(.bold))
                    if let c = details?.commentCount { Text(c).font(.subheadline).foregroundStyle(.secondary) }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                if let teaser = details?.commentPreview, !teaser.text.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Avatar(url: teaser.authorAvatar, size: 24)
                        Text(teaser.text).font(.footnote).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    // MARK: Related

    @ViewBuilder private var relatedSection: some View {
        if !player.upNext.isEmpty {
            HStack {
                Label("Playlist", systemImage: "list.bullet").font(.headline)
                Spacer()
                Text("\(player.upNext.count) weitere").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            ForEach(player.upNext.prefix(25)) { v in
                VideoRow(video: v, present: true, queue: player.queue)
            }
        }
        if let related = details?.related {
            Text("Als Nächstes").font(.headline).padding(.top, 4)
            ForEach(related) { item in
                switch item {
                case .video(let v): VideoRow(video: v)
                case .playlist(let p): PlaylistRow(playlist: p)
                case .channel(let c): ChannelRow(channel: c)
                case .short(let v): VideoRow(video: v)
                }
            }
            if details?.relatedContinuation != nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task { await player.loadMoreRelated() }
            }
        } else if player.error == nil {
            ForEach(0..<4, id: \.self) { _ in SkeletonCard(compact: true) }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast = player.toast {
            Text(toast)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct DescriptionSheet: View {
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(player.details?.title ?? player.stream?.title ?? "")
                        .font(.title3.weight(.bold))
                    HStack(spacing: 10) {
                        stat(player.details?.views ?? player.stream?.viewCount ?? "–", "Aufrufe")
                        stat(player.details?.date ?? "–", "Datum")
                        if let d = player.dislikes {
                            stat(d.likes.compact, "Likes")
                            stat(d.dislikes.compact, "Dislikes")
                        }
                    }
                    Text(attributed(player.details?.description.nilIfEmpty ?? player.stream?.description ?? ""))
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(20)
            }
            .navigationTitle("Beschreibung")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    /// Makes plain URLs in the description tappable.
    private func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        let ns = text as NSString
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url,
                  let r = Range(m.range, in: text),
                  let lower = AttributedString.Index(r.lowerBound, within: result),
                  let upper = AttributedString.Index(r.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
