import SwiftUI

@MainActor
final class CommentsModel: ObservableObject {
    @Published var comments: [Comment] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var sortOptions: [(title: String, token: String)] = []
    @Published var sortIndex = 0
    @Published var countText: String?
    private var continuation: String?
    private var loadingMore = false
    let token: String

    init(token: String) { self.token = token }

    var hasMore: Bool { continuation != nil }

    func load(_ token: String? = nil) async {
        isLoading = true
        error = nil
        do {
            let page = try await YouTube.comments(token ?? self.token)
            comments = page.comments
            continuation = page.continuation
            if !page.sortOptions.isEmpty { sortOptions = page.sortOptions }
            if let c = page.countText { countText = c }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func loadMore() async {
        guard let c = continuation, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await YouTube.comments(c) else { return }
        let existing = Set(comments.map(\.id))
        comments += page.comments.filter { !existing.contains($0.id) }
        continuation = page.continuation
    }

    func sort(_ index: Int) async {
        guard sortOptions.indices.contains(index) else { return }
        sortIndex = index
        await load(sortOptions[index].token)
    }
}

struct CommentsView: View {
    @StateObject private var model: CommentsModel
    let count: String?

    init(token: String, count: String?) {
        _model = StateObject(wrappedValue: CommentsModel(token: token))
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
                    } else {
                        ForEach(model.comments) { c in CommentRow(comment: c) }
                        if model.hasMore {
                            ProgressView().frame(maxWidth: .infinity).task { await model.loadMore() }
                        }
                    }
                }
                .padding(16)
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
            .withRoutes()
        }
        .task { if model.comments.isEmpty { await model.load() } }
    }
}

struct CommentRow: View {
    let comment: Comment
    var showReplies = true
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
                    .textSelection(.enabled)
                HStack(spacing: 14) {
                    Label(comment.likes ?? "", systemImage: "hand.thumbsup")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        ForEach(replies) { r in CommentRow(comment: r, showReplies: false) }
                        if repliesToken != nil {
                            Button("Weitere Antworten") { Task { await loadReplies() } }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                        }
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
        guard let page = try? await YouTube.comments(token) else { return }
        replies += page.comments
        repliesToken = page.continuation
    }
}
