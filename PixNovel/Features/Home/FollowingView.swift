import SwiftUI

/// 关注：关注作者的新作 + 关注作者列表
struct FollowingView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case feed = "新作动态", authors = "关注的作者"
        var id: String { rawValue }
    }

    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var settings: AppSettings
    @State private var tab: Tab = .feed
    @StateObject private var feed = NovelListModel { try await PixivAPI.shared.followNew() }
    @StateObject private var authors = FollowingAuthorsModel()

    var body: some View {
        Group {
            switch tab {
            case .feed:
                NovelListContent(model: feed)
            case .authors:
                authorList
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                ContentFilterBar(status: tab == .feed ? "\(feed.items.count)/\(feed.rawCount) 篇" : nil)
            }
            .padding(.horizontal).padding(.bottom, 8)
            .background(.bar)
        }
        .navigationTitle("关注")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if tab == .feed { ModelSortMenu(model: feed, defaultTitle: "发布时间") }
            }
        }
        .task {
            if feed.rawCount == 0 {
                await feed.refresh()
                await feed.fillUntil(20, maxPages: 8)
            }
        }
        .task(id: tab) {
            if tab == .authors, authors.users.isEmpty, let uid = session.account?.userId {
                await authors.refresh(userId: uid)
            }
        }
        .onChange(of: settings.chineseOnly) { _ in refilter() }
        .onChange(of: settings.r18Mode) { _ in refilter() }
        .pixivDestinations()
    }

    private func refilter() {
        feed.reapply()
        Task { await feed.fillUntil(20, maxPages: 8) }
    }

    private var authorList: some View {
        List {
            ForEach(authors.users) { p in
                let novels = (p.novels ?? []).filter(settings.contentFilter.accept)
                NavigationLink(value: Route.user(p.user.id)) {
                    HStack(alignment: .top, spacing: 12) {
                        PximgImage(url: p.user.profileImageUrls?.medium)
                            .frame(width: 44, height: 44).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.user.name).font(.headline)
                            if let latest = (p.novels ?? []).compactMap(\.created).max() {
                                Text("最近更新 \(latest, style: .relative)前").font(.caption).foregroundStyle(.secondary)
                            }
                            if novels.isEmpty {
                                Text((p.novels ?? []).isEmpty ? "暂无小说" : "最近作品不符合筛选条件")
                                    .font(.caption).foregroundStyle(.tertiary)
                            } else {
                                ForEach(novels.prefix(3)) { n in
                                    HStack(spacing: 4) {
                                        if n.isR18 { PillTag("R18", .red) }
                                        Text(n.title).font(.subheadline).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text("♥ \(NumberFmt.short(n.bookmarks))").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear { if p.id == authors.users.last?.id { Task { await authors.loadMore() } } }
            }
            if authors.loading { ProgressView().frame(maxWidth: .infinity) }
            if let e = authors.error { Text(e).font(.footnote).foregroundStyle(.red) }
            if !authors.loading && authors.users.isEmpty && authors.error == nil {
                Text("还没有关注任何作者").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .refreshable {
            if let uid = session.account?.userId { await authors.refresh(userId: uid) }
        }
    }
}

@MainActor
final class FollowingAuthorsModel: ObservableObject {
    @Published private(set) var users: [UserPreview] = []
    @Published private(set) var loading = false
    @Published var error: String?
    private var next: String?

    func refresh(userId: String) async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await PixivAPI.shared.following(userId: userId)
            users = r.userPreviews
            next = r.nextUrl
        } catch { self.error = error.localizedDescription }
    }

    func loadMore() async {
        guard let n = next, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let r: UserPreviewsResponse = try await PixivAPI.shared.get(next: n)
            let seen = Set(users.map(\.id))
            users += r.userPreviews.filter { !seen.contains($0.id) }
            next = r.nextUrl
        } catch { self.error = error.localizedDescription }
    }
}
