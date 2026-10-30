import SwiftUI

@MainActor
final class CommentsModel: ObservableObject {
    @Published var comments: [Comment] = []
    @Published var isLoading = true
    @Published var error: String?
    @Published var sortOptions: [(title: String, token: String)] = []
    @Published var sortIndex = 0
    @Published var countText: String?
    /// Increments with every loaded page, so the "load more" trigger re-arms itself.
    @Published private(set) var pageCount = 0
    /// Comment being answered in the composer (nil = new comment).
    @Published var replyTarget: Comment?
    @Published private(set) var isSending = false
    @Published var sendError: String?
    /// Replies written in this session, shown under their comment.
    @Published private(set) var ownReplies: [String: [Comment]] = [:]
    @Published private(set) var focusRequest = 0
    private var continuation: String?
    private var loadingMore = false
    private var createParams: String?
    private(set) var endpoint: String?
    let token: String
    let videoId: String?

    init(token: String, endpoint: String? = nil, videoId: String? = nil) {
        self.token = token
        self.endpoint = endpoint
        self.videoId = videoId
    }

    func reply(to comment: Comment) {
        replyTarget = comment
        focusRequest += 1
    }

    /// Sends the composer text as a comment or reply. Returns true on success.
    func send(_ text: String, as account: AccountInfo?) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let videoId, !text.isEmpty, !isSending else { return false }
        isSending = true
        defer { isSending = false }
        var own = Comment(id: "own-" + UUID().uuidString,
                          author: account?.handle ?? account?.name ?? "Du",
                          authorAvatar: account?.avatar,
                          text: text)
        own.published = "Gerade eben"
        own.isOwn = true
        do {
            if let target = replyTarget {
                try await YouTube.postReply(text, videoId: videoId, commentId: target.id, params: target.replyParams)
                ownReplies[target.id, default: []].append(own)
                replyTarget = nil
            } else {
                try await YouTube.postComment(text, videoId: videoId, params: createParams)
                withAnimation(.snappy) { comments.insert(own, at: 0) }
            }
            return true
        } catch {
            sendError = error.localizedDescription
            return false
        }
    }

    var hasMore: Bool { continuation != nil }

    func load(_ token: String? = nil) async {
        isLoading = true
        error = nil
        do {
            let page = try await YouTube.comments(token ?? self.token, endpoint: endpoint)
            endpoint = page.endpoint
            if let p = page.createParams { createParams = p }
            comments = page.comments
            continuation = page.continuation
            if !page.sortOptions.isEmpty { sortOptions = page.sortOptions }
            if let c = page.countText { countText = c }
            pageCount += 1
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code != .cancelled { self.error = error.localizedDescription }
        }
        isLoading = false
    }

    func loadMore() async {
        guard let c = continuation, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await YouTube.comments(c, endpoint: endpoint) else { return }
        let existing = Set(comments.map(\.id))
        comments += page.comments.filter { !existing.contains($0.id) }
        continuation = page.continuation
        pageCount += 1
    }

    func sort(_ index: Int) async {
        guard sortOptions.indices.contains(index), index != sortIndex || comments.isEmpty else { return }
        sortIndex = index
        comments = []
        continuation = nil
        await load(sortOptions[index].token)
    }
}

struct CommentsView: View {
    @EnvironmentObject private var account: AccountStore
    @StateObject private var model: CommentsModel
    let count: String?
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(token: String, count: String?, endpoint: String? = nil, videoId: String? = nil) {
        _model = StateObject(wrappedValue: CommentsModel(token: token, endpoint: endpoint, videoId: videoId))
        self.count = count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.sortOptions.count > 1 {
                        HStack(spacing: 8) {
                            ForEach(Array(model.sortOptions.enumerated()), id: \.offset) { i, option in
                                Chip(title: option.title, selected: i == model.sortIndex) {
                                    Task { await model.sort(i) }
                                }
                            }
                        }
                    }
                    if model.isLoading && model.comments.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if let e = model.error, model.comments.isEmpty {
                        ErrorState(message: e) { Task { await model.load() } }
                    } else if model.comments.isEmpty && model.pageCount > 0 {
                        ContentUnavailableView("Noch keine Kommentare", systemImage: "text.bubble",
                                               description: Text("Sei der Erste, der etwas dazu schreibt."))
                            .padding(.top, 30)
                    } else {
                        ForEach(model.comments) { c in CommentRow(comment: c, endpoint: model.endpoint) }
                        if model.hasMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .task(id: model.pageCount) { await model.loadMore() }
                        }
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if account.isSignedIn, model.videoId != nil { composer }
            }
            .navigationTitle("Kommentare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let c = model.countText ?? count {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text(c).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            .alert("Senden fehlgeschlagen", isPresented: Binding(get: { model.sendError != nil },
                                                                   set: { if !$0 { model.sendError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.sendError ?? "")
            }
            .withRoutes()
        }
        .environmentObject(model)
        .onChange(of: model.focusRequest) { composerFocused = true }
        .task { if model.comments.isEmpty { await model.load() } }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let target = model.replyTarget {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                    Text("Antwort an \(target.author)").lineLimit(1)
                    Spacer()
                    Button { model.replyTarget = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Antwort abbrechen")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Avatar(url: account.info?.avatar, size: 30)
                TextField(model.replyTarget == nil ? "Kommentar hinzufügen …" : "Antwort hinzufügen …",
                          text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.vertical, 5)
                Button {
                    let text = draft
                    Task {
                        if await model.send(text, as: account.info) {
                            draft = ""
                            composerFocused = false
                        }
                    }
                } label: {
                    Group {
                        if model.isSending {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up.circle.fill").font(.title2)
                        }
                    }
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
                .accessibilityLabel("Senden")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

struct CommentRow: View {
    @EnvironmentObject private var model: CommentsModel
    @EnvironmentObject private var account: AccountStore
    let comment: Comment
    var endpoint: String?
    var showReplies = true
    /// Thread the comment belongs to (answers always go to the thread).
    var thread: Comment?
    @State private var replies: [Comment] = []
    @State private var repliesToken: String?
    @State private var expanded = false
    @State private var loading = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let cid = comment.authorChannelId {
                    NavigationLink(value: Route.channel(cid)) { Avatar(url: comment.authorAvatar, size: 32) }
                        .buttonStyle(.plain)
                } else {
                    Avatar(url: comment.authorAvatar, size: 32)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(comment.author)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, comment.isCreator ? 7 : 0)
                        .padding(.vertical, comment.isCreator ? 2 : 0)
                        .background(comment.isCreator ? Color.accentColor.opacity(0.25) : Color.clear, in: .capsule)
                    if let p = comment.published {
                        Text(p).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(comment.text)
                    .font(.subheadline)
                    .contextMenu {
                        Button("Text kopieren", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = comment.text
                            Haptics.success()
                        }
                        ShareLink(item: comment.text) { Label("Teilen", systemImage: "square.and.arrow.up") }
                    }
                HStack(spacing: 14) {
                    Label(comment.likes ?? "", systemImage: "hand.thumbsup")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if account.isSignedIn, model.videoId != nil, !comment.isOwn || thread != nil {
                        Button("Antworten") { model.reply(to: thread ?? comment) }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                    }
                    if showReplies, comment.replyCount > 0, comment.repliesToken != nil {
                        Button {
                            Task { await toggleReplies() }
                        } label: {
                            HStack(spacing: 4) {
                                Text(expanded ? "Antworten ausblenden" : "\(comment.replyCount) Antworten")
                                if loading { ProgressView().controlSize(.mini) }
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(replies) { r in CommentRow(comment: r, endpoint: endpoint, showReplies: false, thread: comment) }
                        if repliesToken != nil {
                            Button("Weitere Antworten") { Task { await loadReplies() } }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.top, 6)
                }
                if showReplies, let own = model.ownReplies[comment.id], !own.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(own) { r in CommentRow(comment: r, endpoint: endpoint, showReplies: false, thread: comment) }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func toggleReplies() async {
        if expanded { expanded = false; return }
        if replies.isEmpty {
            repliesToken = comment.repliesToken
            await loadReplies()
        }
        withAnimation { expanded = true }
    }

    private func loadReplies() async {
        guard let token = repliesToken else { return }
        loading = true
        defer { loading = false }
        guard let page = try? await YouTube.comments(token, endpoint: endpoint) else { return }
        let existing = Set(replies.map(\.id))
        replies += page.comments.filter { !existing.contains($0.id) }
        repliesToken = page.continuation
    }
}
