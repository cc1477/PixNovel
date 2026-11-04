import SwiftUI

/// 我的：仿 Pixiv「个人首页」——模糊头像头部 + 分组入口列表
struct LibraryView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var library: LocalLibrary
    @StateObject private var authors = FollowingAuthorsModel()
    @State private var confirmLogout = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                profileHeader

                if let last = library.history.first {
                    group("继续阅读") { continueCard(last) }
                }

                group(nil) {
                    NavigationLink { BookmarksView() } label: {
                        MenuRow(icon: "heart.fill", color: .pink, title: "收藏")
                    }
                    divider
                    NavigationLink { HistoryView() } label: {
                        MenuRow(icon: "clock.fill", color: .blue, title: "浏览记录",
                                detail: library.history.isEmpty ? nil : "\(library.history.count)")
                    }
                }

                group("关联") {
                    NavigationLink { FollowingAuthorsList(model: authors) } label: {
                        MenuRow(icon: "person.2.fill", color: .teal, title: "关注的作者",
                                detail: authors.users.isEmpty ? nil : "\(authors.users.count)")
                    }
                    if let uid = session.account?.userId, let id = Int(uid) {
                        divider
                        NavigationLink(value: Route.user(id)) {
                            MenuRow(icon: "person.text.rectangle.fill", color: .indigo, title: "我的作品")
                        }
                    }
                }

                group("其他") {
                    NavigationLink { SettingsView() } label: {
                        MenuRow(icon: "gearshape.fill", color: .gray, title: "设置")
                    }
                    divider
                    Button { confirmLogout = true } label: {
                        MenuRow(icon: "rectangle.portrait.and.arrow.right", color: .red, title: "退出登录", chevron: false)
                    }
                }
            }
            .padding(.bottom, 100)
        }
        .background(Color(.systemGroupedBackground))
        .ignoresSafeArea(edges: .top)
        .buttonStyle(.plain)
        .tint(.purple)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if authors.users.isEmpty, let uid = session.account?.userId { await authors.refresh(userId: uid) }
        }
        .confirmationDialog("确定退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await session.logout() } }
        }
        .pixivDestinations()
    }

    private var divider: some View {
        Divider().padding(.leading, 60)
    }

    /// 手动实现的分组卡片
    private func group<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 20)
            }
            VStack(spacing: 0) { content() }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 16)
        }
    }

    // MARK: 头部（通栏，延伸到状态栏）

    private var profileHeader: some View {
        let acc = session.account
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                PximgImage(url: acc?.avatar)
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.3), radius: 6)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(acc?.name ?? "未登录").font(.title2.bold()).lineLimit(1)
                        if acc?.isPremium == true { PillTag("Premium", .orange) }
                    }
                    if let uid = acc?.userId, let id = Int(uid) {
                        NavigationLink(value: Route.user(id)) {
                            HStack(spacing: 3) {
                                Text("查看自己的个人页面")
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                stat("\(library.history.count)", "已读作品")
                Rectangle().fill(.white.opacity(0.25)).frame(width: 0.5, height: 28)
                stat("\(authors.users.count)\(authors.users.count >= 30 ? "+" : "")", "关注")
                Rectangle().fill(.white.opacity(0.25)).frame(width: 0.5, height: 28)
                stat(String(format: "%.0f%%", averageProgress * 100), "平均进度")
            }
            .padding(.vertical, 12)
            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .padding(.horizontal, 20)
        .padding(.top, topInset + 28)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                PximgImage(url: acc?.avatar)
                    .scaleEffect(1.6)
                    .blur(radius: 40)
                    .saturation(1.4)
                LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
        }
    }

    private var topInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.safeAreaInsets.top ?? 47
    }

    private var averageProgress: Double {
        let h = library.history.prefix(50)
        guard !h.isEmpty else { return 0 }
        return h.map(\.percent).reduce(0, +) / Double(h.count)
    }

    private func stat(_ v: String, _ t: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.headline.monospacedDigit())
            Text(t).font(.caption2).opacity(0.85)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 继续阅读

    private func continueCard(_ r: ReadingRecord) -> some View {
        NavigationLink(value: Route.reader(r.novel)) {
            HStack(spacing: 14) {
                PximgImage(url: r.novel.imageUrls?.medium)
                    .frame(width: 60, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.novel.title).font(.headline).lineLimit(2)
                    Text(r.novel.user.name).font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: r.percent).tint(.purple)
                    Text("已读 \(Int(r.percent * 100))% · \(RelativeTime.string(r.updatedAt))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.purple)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
    }
}

struct MenuRow: View {
    let icon: String
    let color: Color
    let title: String
    var detail: String? = nil
    var chevron = true
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary) }
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - 收藏

struct BookmarksView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case publicBM = "公开", privateBM = "私密"
        var id: String { rawValue }
        var restrict: String { self == .publicBM ? "public" : "private" }
    }
    @EnvironmentObject var session: SessionStore
    @State private var kind: Kind = .publicBM
    // 收藏夹不按中文 / R18 筛选
    @StateObject private var publicModel = NovelListModel(contentFilter: false) { throw PixivError.notLoggedIn }
    @StateObject private var privateModel = NovelListModel(contentFilter: false) { throw PixivError.notLoggedIn }

    private var model: NovelListModel { kind == .publicBM ? publicModel : privateModel }

    var body: some View {
        NovelListContent(model: model)
            .safeAreaInset(edge: .top, spacing: 0) {
                GlassHeader {
                    Picker("", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker(selection: kind == .publicBM ? $publicModel.localSort : $privateModel.localSort) {
                            Text("收藏时间").tag(HotMetric?.none)
                            ForEach(HotMetric.allCases) { m in Label(m.title, systemImage: m.icon).tag(HotMetric?.some(m)) }
                        } label: { Label("排序", systemImage: "arrow.up.arrow.down") }
                    } label: { Image(systemName: "arrow.up.arrow.down.circle") }
                }
            }
            .task(id: kind) {
                guard let uid = session.account?.userId, model.rawCount == 0 else { return }
                let r = kind.restrict
                model.setLoader { try await PixivAPI.shared.bookmarks(userId: uid, restrict: r) }
                await model.refresh()
            }
    }
}

// MARK: - 浏览记录

struct HistoryView: View {
    @EnvironmentObject var library: LocalLibrary
    @State private var confirmClear = false

    var body: some View {
        List {
            if library.history.isEmpty {
                Text("还没有阅读记录").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            ForEach(library.history) { r in
                NavigationLink(value: Route.reader(r.novel)) {
                    HStack(spacing: 12) {
                        PximgImage(url: r.novel.imageUrls?.medium)
                            .frame(width: 48, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                if r.novel.isR18 { PillTag("R18", .red) }
                                Text(r.novel.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            }
                            Text(r.novel.user.name).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                ProgressView(value: r.percent).frame(maxWidth: 120)
                                Text("\(Int(r.percent * 100))%").font(.caption2.monospacedDigit())
                                Spacer()
                                Text(RelativeTime.string(r.updatedAt)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) { library.remove(r.id) }
                    NavigationLink(value: Route.novel(r.novel)) { Text("详情") }.tint(.blue)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("浏览记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空", role: .destructive) { confirmClear = true }.disabled(library.history.isEmpty)
            }
        }
        .confirmationDialog("清空全部浏览记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { library.clear() }
        }
    }
}
