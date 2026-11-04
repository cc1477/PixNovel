import SwiftUI

enum Route: Hashable {
    case novel(Novel)
    case user(Int)
    case series(Int)
    case tag(String)
    case reader(Novel)
}

extension View {
    func pixivDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .novel(let n): NovelDetailView(novel: n)
            case .user(let id): UserView(userId: id)
            case .series(let id): SeriesView(seriesId: id)
            case .tag(let t): SearchView(initialWord: t)
            case .reader(let n): ReaderView(novel: n)
            }
        }
    }
}

enum NumberFmt {
    static func short(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1f万", Double(n) / 10000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

struct NovelRow: View {
    let novel: Novel
    var rank: Int? = nil
    var badge: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topLeading) {
                PximgImage(url: novel.imageUrls?.medium ?? novel.imageUrls?.squareMedium)
                    .frame(width: 72, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if let rank {
                    Text("\(rank)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(rankColor(rank), in: RoundedRectangle(cornerRadius: 4))
                        .padding(3)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if novel.isR18 { PillTag("R18", .red) }
                    if novel.isAI { PillTag("AI", .purple) }
                    if novel.isOriginal == true { PillTag("原创", .blue) }
                    Text(novel.title).font(.headline).lineLimit(2)
                }
                Text(novel.user.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let s = novel.series, let t = s.title, s.id != nil {
                    Label(t, systemImage: "books.vertical").font(.caption).foregroundStyle(.teal).lineLimit(1)
                }
                Text(novel.tagNames.prefix(6).map { "#\($0)" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.tint).lineLimit(1)
                HStack(spacing: 10) {
                    Label(NumberFmt.short(novel.bookmarks), systemImage: novel.isBookmarked == true ? "heart.fill" : "heart")
                        .foregroundStyle(novel.isBookmarked == true ? .pink : .secondary)
                    Label(NumberFmt.short(novel.views), systemImage: "eye")
                    Label(NumberFmt.short(novel.length) + "字", systemImage: "doc.text")
                    if let badge { Text(badge).foregroundStyle(.orange) }
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func rankColor(_ r: Int) -> Color {
        switch r {
        case 1: return Color(red: 0.95, green: 0.65, blue: 0.1)
        case 2: return Color(red: 0.6, green: 0.6, blue: 0.65)
        case 3: return Color(red: 0.75, green: 0.45, blue: 0.2)
        default: return Color.black.opacity(0.55)
        }
    }
}

struct PillTag: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(.caption2.bold()).foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 3))
    }
}

/// 通用分页列表模型，支持本地二次排序
@MainActor
final class NovelListModel: ObservableObject {
    typealias Loader = () async throws -> NovelListResponse

    @Published private(set) var items: [Novel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var nextURL: String?
    @Published var error: String?
    /// nil = 保持服务端顺序
    @Published var localSort: HotMetric? { didSet { applySort() } }

    private var raw: [Novel] = []
    private var loader: Loader
    private var seen = Set<Int>()

    init(localSort: HotMetric? = nil, contentFilter: Bool = true, loader: @escaping Loader) {
        self.loader = loader
        self.localSort = localSort
        self.useContentFilter = contentFilter
    }

    func setLoader(_ l: @escaping Loader) { loader = l }

    func refresh() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let r = try await loader()
            raw = []; seen = []
            append(r.novels)
            nextURL = r.nextUrl
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(_ n: Novel) {
        guard let last = items.last, last.id == n.id else { return }
        Task { await loadMore() }
    }

    func loadMore() async {
        guard let next = nextURL, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let r: NovelListResponse = try await PixivAPI.shared.get(next: next)
            append(r.novels)
            nextURL = r.nextUrl
        } catch { self.error = error.localizedDescription }
    }

    /// 连续加载多页（用于排行榜整体热度重排）
    func loadPages(_ count: Int) async {
        for _ in 0..<count {
            guard nextURL != nil else { break }
            await loadMore()
        }
    }

    private func append(_ list: [Novel]) {
        for n in list where !seen.contains(n.id) {
            seen.insert(n.id); raw.append(n)
        }
        applySort()
    }

    /// 是否应用「仅中文 / R18」内容筛选（收藏夹等列表可关闭）
    var useContentFilter = true

    var rawCount: Int { raw.count }

    func reapply() { applySort() }

    private func applySort() {
        let s = AppSettings.shared
        let f = useContentFilter ? s.contentFilter : ContentFilter(chineseOnly: false, r18: .all, mutedTags: s.mutedTags)
        let visible = raw.filter(f.accept)
        if let m = localSort { items = HotRanker.sort(visible, by: m, gravity: s.hotGravity) }
        else { items = visible }
    }

    /// 筛选后结果太少时自动继续翻页
    func fillUntil(_ minimum: Int, maxPages: Int) async {
        var pages = 0
        while items.count < minimum && nextURL != nil && pages < maxPages && !Task.isCancelled {
            await loadMore()
            pages += 1
        }
    }

    func updateBookmark(_ id: Int, _ v: Bool) {
        if let i = raw.firstIndex(where: { $0.id == id }) { raw[i].isBookmarked = v }
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].isBookmarked = v }
    }
}

/// 通用列表视图
struct NovelListContent: View {
    @ObservedObject var model: NovelListModel
    var showRank = false

    var body: some View {
        List {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, n in
                NavigationLink(value: Route.novel(n)) {
                    NovelRow(novel: n, rank: showRank ? idx + 1 : nil,
                             badge: model.localSort.flatMap { HotRanker.badge(n, metric: $0, gravity: AppSettings.shared.hotGravity) })
                }
                .onAppear { model.loadMoreIfNeeded(n) }
                .swipeActions(edge: .trailing) {
                    BookmarkSwipe(novel: n) { model.updateBookmark(n.id, $0) }
                }
            }
            if model.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            } else if let e = model.error {
                VStack(spacing: 8) {
                    Text(e).font(.footnote).foregroundStyle(.red)
                    Button("重试") {
                        Task {
                            if model.items.isEmpty { await model.refresh() } else { await model.loadMore() }
                        }
                    }
                }.frame(maxWidth: .infinity)
            } else if model.items.isEmpty {
                Text("暂无内容").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
    }
}

struct BookmarkSwipe: View {
    let novel: Novel
    let onChange: (Bool) -> Void
    var body: some View {
        let marked = novel.isBookmarked == true
        Button {
            Task {
                do {
                    if marked { try await PixivAPI.shared.deleteBookmark(novel.id) }
                    else { try await PixivAPI.shared.addBookmark(novel.id) }
                    await MainActor.run { onChange(!marked) }
                } catch {}
            }
        } label: {
            Label(marked ? "取消收藏" : "收藏", systemImage: marked ? "heart.slash" : "heart")
        }
        .tint(marked ? .gray : .pink)
    }
}

/// 本地排序菜单
struct SortMenu: View {
    @Binding var selection: HotMetric?
    var allowDefault = true
    var defaultTitle = "默认顺序"

    var body: some View {
        Menu {
            if allowDefault {
                Button { selection = nil } label: {
                    if selection == nil { Label(defaultTitle, systemImage: "checkmark") } else { Text(defaultTitle) }
                }
            }
            ForEach(HotMetric.allCases) { m in
                Button { selection = m } label: {
                    if selection == m { Label(m.title, systemImage: "checkmark") } else { Label(m.title, systemImage: m.icon) }
                }
            }
        } label: {
            Label(selection?.title ?? defaultTitle, systemImage: "arrow.up.arrow.down")
        }
    }
}
