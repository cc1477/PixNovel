import SwiftUI

/// 关注：顶部作者头像条 + 新作时间线
struct FollowingView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var settings: AppSettings
    @StateObject private var feed = NovelListModel { try await PixivAPI.shared.followNew() }
    @StateObject private var authors = FollowingAuthorsModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                authorStrip
                HStack {
                    Text("新作动态").font(.title3.bold())
                    Spacer()
                    Text(settings.filterSummary).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                ForEach(feed.items) { n in
                    NavigationLink(value: Route.novel(n)) {
                        TimelineRow(novel: n)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .contextMenu {
                        NavigationLink(value: Route.reader(n)) { Label("直接阅读", systemImage: "book") }
                        NavigationLink(value: Route.user(n.user.id)) { Label("作者主页", systemImage: "person") }
                    }
                    .onAppear { feed.loadMoreIfNeeded(n) }
                }
                Group {
                    if feed.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    } else if let e = feed.error {
                        Text(e).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity)
                    } else if feed.items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "person.2.slash").font(.largeTitle).foregroundStyle(.secondary)
                            Text(settings.filterActive ? "没有符合筛选条件的新作" : "关注的作者还没有新作")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await feed.refresh()
            await feed.fillUntil(20, maxPages: 8)
            if let uid = session.account?.userId { await authors.refresh(userId: uid) }
        }
        .tint(.teal)
        .navigationTitle("关注")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ContentFilterMenuItems()
                    Section("排序") {
                        Picker(selection: $feed.localSort) {
                            Text("发布时间").tag(HotMetric?.none)
                            ForEach(HotMetric.allCases) { m in Label(m.title, systemImage: m.icon).tag(HotMetric?.some(m)) }
                        } label: { Label("排序：\(feed.localSort?.title ?? "发布时间")", systemImage: "arrow.up.arrow.down") }
                    }
                } label: {
                    Image(systemName: settings.filterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .task {
            if feed.rawCount == 0 {
                await feed.refresh()
                await feed.fillUntil(20, maxPages: 8)
            }
        }
        .task {
            if authors.users.isEmpty, let uid = session.account?.userId { await authors.refresh(userId: uid) }
        }
        .onChange(of: settings.chineseOnly) { _ in refilter() }
        .onChange(of: settings.r18Mode) { _ in refilter() }
        .pixivDestinations()
    }

    private func refilter() {
        feed.reapply()
        Task { await feed.fillUntil(20, maxPages: 8) }
    }

    private var authorStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("关注的作者").font(.title3.bold())
                Spacer()
                NavigationLink {
                    FollowingAuthorsList(model: authors)
                } label: {
                    HStack(spacing: 2) { Text("全部"); Image(systemName: "chevron.right") }.font(.subheadline)
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(authors.users.prefix(30)) { p in
                        NavigationLink(value: Route.user(p.user.id)) {
                            VStack(spacing: 6) {
                                PximgImage(url: p.user.profileImageUrls?.medium)
                                    .frame(width: 56, height: 56)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(isRecent(p) ? Color.teal : Color.clear, lineWidth: 2.5).padding(-3))
                                Text(p.user.name).font(.caption2).lineLimit(1).frame(width: 64)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if authors.users.isEmpty && authors.loading {
                        ForEach(0..<5, id: \.self) { _ in
                            Circle().fill(Color.secondary.opacity(0.15)).frame(width: 56, height: 56)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 3)
            }
        }
    }

    /// 7 天内有新作的作者头像加高亮圈
    private func isRecent(_ p: UserPreview) -> Bool {
        guard let d = (p.novels ?? []).compactMap(\.created).max() else { return false }
        return Date().timeIntervalSince(d) < 7 * 86400
    }
}

/// 全部关注作者
struct FollowingAuthorsList: View {
    @ObservedObject var model: FollowingAuthorsModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        List {
            ForEach(model.users) { p in
                NavigationLink(value: Route.user(p.user.id)) {
                    HStack(alignment: .top, spacing: 12) {
                        PximgImage(url: p.user.profileImageUrls?.medium)
                            .frame(width: 44, height: 44).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.user.name).font(.headline)
                            if let latest = (p.novels ?? []).compactMap(\.created).max() {
                                Text("最近更新：\(RelativeTime.string(latest))").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach((p.novels ?? []).filter(settings.contentFilter.accept).prefix(3)) { n in
                                Text("· \(n.title)").font(.subheadline).lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear { if p.id == model.users.last?.id { Task { await model.loadMore() } } }
            }
            if model.loading { ProgressView().frame(maxWidth: .infinity) }
            if let e = model.error { Text(e).font(.footnote).foregroundStyle(.red) }
        }
        .listStyle(.plain)
        .navigationTitle("关注的作者")
        .navigationBarTitleDisplayMode(.inline)
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
