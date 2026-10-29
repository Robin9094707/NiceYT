import SwiftUI

struct SubscriptionsView: View {
    @EnvironmentObject private var account: AccountStore
    @StateObject private var loader = FeedLoader(first: { try await YouTube.subscriptionsFeed() })

    var body: some View {
        NavigationStack {
            Group {
                if account.isSignedIn {
                    FeedScroll(loader: loader, emptyText: "Keine neuen Videos") {
                        if !account.subscriptions.isEmpty { channelStrip }
                    }
                } else {
                    ScrollView {
                        SignInPrompt(title: "Deine Abos",
                                     message: "Melde dich an, um die neuesten Videos deiner abonnierten Kanäle zu sehen.")
                            .padding(16)
                            .padding(.top, 40)
                    }
                }
            }
            .navigationTitle("Abos")
            .toolbar {
                if account.isSignedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: Route.subscriptionsList) {
                            Image(systemName: "person.2.fill")
                        }
                    }
                }
            }
            .withRoutes()
        }
        .onChange(of: account.isSignedIn) { Task { await loader.load(force: true) } }
    }

    private var channelStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 14) {
                ForEach(account.subscriptions) { c in
                    NavigationLink(value: Route.channel(c.id)) {
                        VStack(spacing: 6) {
                            Avatar(url: c.avatar, size: 60)
                                .padding(3)
                                .glassEffect(.regular.interactive(), in: .circle)
                            Text(c.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 70)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }
}

struct SubscribedChannelsView: View {
    @EnvironmentObject private var account: AccountStore
    @State private var filter = ""

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(account.subscriptions.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { c in
                    ChannelRow(channel: c)
                }
            }
            .padding(16)
        }
        .searchable(text: $filter, prompt: "Kanäle filtern")
        .navigationTitle("Kanäle")
        .refreshable { await account.refresh() }
    }
}
