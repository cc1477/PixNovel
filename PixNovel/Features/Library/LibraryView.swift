import SwiftUI

/// 我的：仿 Pixiv「个人首页」——模糊头像头部 + 分组入口列表
struct LibraryView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var library: LocalLibrary
    @StateObject private var authors = FollowingAuthorsModel()
    @State private var confirmLogout = false

    var body: some View {
        List {
            Section {
                profileHeader
                    .listRowInsets(EdgeInsets())
            }
            .listSectionSeparator(.hidden)

            if let last = library.history.first {
                Section {
                    continueCard(last)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                } header: { Text("继续阅读") }
            }

            Section {
                NavigationLink { BookmarksView() } label: {
                    MenuRow(icon: "heart.fill", color: .pink, title: "收藏")
                }
                NavigationLink { HistoryView() } label: {
                    MenuRow(icon: "clock.fill", color: .blue, title: "浏览记录", detail: library.history.isEmpty ? nil : "\(library.history.count)")
                }
            }

            Section("关联") {
                NavigationLink { FollowingAuthorsList(model: authors) } label: {
                    MenuRow(icon: "person.2.fill", color: .teal, title: "关注的作者")
                }
                if let uid = session.account?.userId, let id = Int(uid) {
                    NavigationLink(value: Route.user(id)) {
                        MenuRow(icon: "person.text.rectangle.fill", color: .indigo, title: "我的作品")
                    }
                }
            }

            Section("其他") {
                NavigationLink { SettingsView() } label: {
                    MenuRow(icon: "gearshape.fill", color: .gray, title: "设置")
                }
                Button { confirmLogout = true } label: {
                    MenuRow(icon: "rectangle.portrait.and.arrow.right", color: .red, title: "退出登录")
                }
                .foregroundStyle(.primary)
            }
        }
        .listStyle(.insetGrouped)
        .tint(.purple)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(edges: .top)
        .task {
            if authors.users.isEmpty, let uid = session.account?.userId { await authors.refresh(userId: uid) }
        }
        .confirmationDialog("确定退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await session.logout() } }
        }
        .pixivDestinations()
    }

    // MARK: 头部

    private var profileHeader: some View {
        let acc = session.account
        return ZStack(alignment: .bottomLeading) {
            // 模糊头像做背景
            GeometryReader { geo in
                PximgImage(url: acc?.avatar)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: 30)
                    .overlay(Color.black.opacity(0.35))
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    PximgImage(url: acc?.avatar)
                        .frame(width: 68, height: 68)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(acc?.name ?? "未登录").font(.title2.bold())
                            if acc?.isPremium == true { PillTag("Premium", .orange) }
                        }
                        if let uid = acc?.userId, let id = Int(uid) {
                            NavigationLink(value: Route.user(id)) {
                                HStack(spacing: 2) {
                                    Text("查看自己的个人页面")
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                                .font(.subheadline)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer()
                }
                HStack(spacing: 0) {
                    stat("\(library.history.count)", "已读作品")
                    stat("\(authors.users.count)\(authors.users.count >= 30 ? "+" : "")", "关注")
                    stat(String(format: "%.0f%%", averageProgress * 100), "平均进度")
                }
                .padding(.vertical, 10)
                .glassBackground(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.top, 70)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
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
            }
        }
    }
}

struct MenuRow: View {
    let icon: String
    let color: Color
    let title: String
    var detail: String? = nil
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
        }
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
