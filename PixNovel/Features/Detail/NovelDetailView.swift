import SwiftUI

struct NovelDetailView: View {
    @State var novel: Novel
    @EnvironmentObject var library: LocalLibrary
    @EnvironmentObject var settings: AppSettings
    @State private var busy = false
    @State private var error: String?
    @State private var showComments = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    PximgImage(url: novel.imageUrls?.best)
                        .frame(width: 110, height: 154)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 3)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(novel.title).font(.title3.bold())
                        NavigationLink(value: Route.user(novel.user.id)) {
                            HStack(spacing: 6) {
                                PximgImage(url: novel.user.profileImageUrls?.medium)
                                    .frame(width: 22, height: 22).clipShape(Circle())
                                Text(novel.user.name).font(.subheadline)
                            }
                        }
                        if let d = novel.created {
                            Text(PixivDate.display.string(from: d)).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            if novel.isR18 { PillTag("R18", .red) }
                            if novel.isAI { PillTag("AI", .purple) }
                            if novel.isOriginal == true { PillTag("原创", .blue) }
                        }
                    }
                }

                statsGrid

                if let s = novel.series, let sid = s.id {
                    NavigationLink(value: Route.series(sid)) {
                        HStack {
                            Image(systemName: "books.vertical.fill")
                            Text("系列：\(s.title ?? "")").lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding(12)
                        .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .foregroundStyle(.teal)
                }

                HStack(spacing: 12) {
                    NavigationLink(value: Route.reader(novel)) {
                        Label(readLabel, systemImage: "book.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)

                    Button { Task { await toggleBookmark() } } label: {
                        Label(novel.isBookmarked == true ? "已收藏" : "收藏",
                              systemImage: novel.isBookmarked == true ? "heart.fill" : "heart")
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(.pink)
                    .disabled(busy)
                }
                .controlSize(.large)

                Button { showComments = true } label: {
                    HStack {
                        Image(systemName: "text.bubble.fill").foregroundStyle(.tint)
                        Text("评论区")
                        Text("\(novel.totalComments ?? 0)").foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                if let error { Text(error).font(.footnote).foregroundStyle(.red) }

                if let tags = novel.tags, !tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(tags, id: \.name) { t in
                            NavigationLink(value: Route.tag(t.name)) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("#\(t.name)").font(.subheadline)
                                    if let tr = t.translatedName { Text(tr).font(.caption2).foregroundStyle(.secondary) }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }

                let caption = NovelContentParser.plainCaption(novel.caption)
                if !caption.isEmpty {
                    Text(caption).font(.callout).textSelection(.enabled)
                }

                Link(destination: URL(string: "https://www.pixiv.net/novel/show.php?id=\(novel.id)")!) {
                    Label("在浏览器中打开", systemImage: "safari")
                }
                .font(.footnote)
            }
            .padding()
        }
        .navigationTitle("作品详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(item: URL(string: "https://www.pixiv.net/novel/show.php?id=\(novel.id)")!)
            }
        }
        .sheet(isPresented: $showComments) {
            CommentsView(novelId: novel.id, title: novel.title)
                .presentationDetents([.medium, .large])
        }
        .task {
            if let fresh = try? await PixivAPI.shared.detail(novel.id) { novel = fresh }
        }
    }

    private var readLabel: String {
        if let r = library.record(for: novel.id), r.percent > 0.01 {
            return String(format: "继续阅读 %.0f%%", r.percent * 100)
        }
        return "开始阅读"
    }

    private var statsGrid: some View {
        let rate = novel.views > 0 ? Double(novel.bookmarks) / Double(novel.views) * 100 : 0
        let days = max(novel.ageHours / 24, 0.5)
        return HStack {
            stat("收藏", NumberFmt.short(novel.bookmarks), "heart.fill", .pink)
            stat("阅读", NumberFmt.short(novel.views), "eye.fill", .blue)
            stat("收藏率", String(format: "%.1f%%", rate), "percent", .orange)
            stat("日均收藏", String(format: "%.1f", Double(novel.bookmarks) / days), "chart.line.uptrend.xyaxis", .green)
            stat("字数", NumberFmt.short(novel.length), "doc.text", .gray)
        }
    }

    private func stat(_ t: String, _ v: String, _ icon: String, _ c: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).foregroundStyle(c).font(.caption)
            Text(v).font(.subheadline.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(t).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func toggleBookmark() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            if novel.isBookmarked == true {
                try await PixivAPI.shared.deleteBookmark(novel.id)
                novel.isBookmarked = false
            } else {
                try await PixivAPI.shared.addBookmark(novel.id)
                novel.isBookmarked = true
                novel.totalBookmarks = (novel.totalBookmarks ?? 0) + 1
            }
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - 系列

struct SeriesView: View {
    let seriesId: Int
    @State private var detail: SeriesDetail?
    @State private var first: Novel?
    @StateObject private var model: NovelListModel

    init(seriesId: Int) {
        self.seriesId = seriesId
        _model = StateObject(wrappedValue: NovelListModel(contentFilter: false) { try await PixivAPI.shared.seriesAsList(seriesId) })
    }

    var body: some View {
        List {
            if let d = detail {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(d.title).font(.title3.bold())
                        if let u = d.user { Text(u.name).foregroundStyle(.secondary) }
                        HStack {
                            if let c = d.contentCount { Text("\(c) 话") }
                            if let t = d.totalCharacterCount { Text("· \(NumberFmt.short(t)) 字") }
                            if d.isConcluded == true { PillTag("已完结", .green) } else { PillTag("连载中", .orange) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        let cap = NovelContentParser.plainCaption(d.caption)
                        if !cap.isEmpty { Text(cap).font(.footnote).lineLimit(6) }
                        if let first {
                            NavigationLink(value: Route.reader(first)) {
                                Label("从第一话开始阅读", systemImage: "book.fill")
                            }
                            .buttonStyle(.borderedProminent).padding(.top, 4)
                        }
                    }
                }
            }
            Section("目录") {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { i, n in
                    NavigationLink(value: Route.novel(n)) {
                        HStack {
                            Text("#\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                            VStack(alignment: .leading) {
                                Text(n.title).lineLimit(2)
                                Text("\(NumberFmt.short(n.length))字 · ♥ \(NumberFmt.short(n.bookmarks))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onAppear { model.loadMoreIfNeeded(n) }
                }
                if model.isLoading { ProgressView().frame(maxWidth: .infinity) }
                if let e = model.error { Text(e).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("系列")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let r = try? await PixivAPI.shared.series(seriesId) {
                detail = r.novelSeriesDetail
                first = r.novelSeriesFirstNovel ?? r.novels.first
            }
            if model.items.isEmpty { await model.refresh() }
        }
    }
}

extension PixivAPI {
    func seriesAsList(_ id: Int) async throws -> NovelListResponse {
        let r = try await series(id)
        return NovelListResponse(novels: r.novels, nextUrl: r.nextUrl, rankingNovels: nil)
    }
}

// MARK: - 作者

struct UserView: View {
    let userId: Int
    @State private var detail: UserDetailResponse?
    @State private var followed = false
    @StateObject private var model: NovelListModel

    init(userId: Int) {
        self.userId = userId
        _model = StateObject(wrappedValue: NovelListModel(contentFilter: false) { try await PixivAPI.shared.userNovels(userId) })
    }

    var body: some View {
        NovelListContent(model: model)
            .safeAreaInset(edge: .top) {
                if let d = detail {
                    HStack(spacing: 12) {
                        PximgImage(url: d.user.profileImageUrls?.medium).frame(width: 48, height: 48).clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(d.user.name).font(.headline)
                            if let t = d.profile?.totalNovels { Text("\(t) 篇小说").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(followed ? "已关注" : "关注") {
                            Task {
                                do {
                                    if followed { try await PixivAPI.shared.unfollow(userId) } else { try await PixivAPI.shared.follow(userId) }
                                    followed.toggle()
                                } catch {}
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(followed ? .gray : .accentColor)
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .navigationTitle(detail?.user.name ?? "作者")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SortMenu(selection: $model.localSort, defaultTitle: "发布时间")
                }
            }
            .task {
                if detail == nil, let d = try? await PixivAPI.shared.user(userId) {
                    detail = d; followed = d.user.isFollowed ?? false
                }
                if model.items.isEmpty { await model.refresh() }
            }
    }
}
