import Foundation

/// 热度聚合搜索引擎
///
/// Pixiv 的 `popular_desc` 仅对会员开放。非会员时采用三路聚合：
/// 1. `popular-preview` 接口：官方给出的热门预览（非会员可用）
/// 2. 并发扫描 `date_desc` 多页（offset 分页），在所选时间范围内尽量覆盖全部作品
/// 3. 可选的「users入り」标签补充（例如 `xxx 1000users入り`），快速捞出高收藏作品
/// 然后在本地去重、过滤，按所选指标排序。时间范围越小，扫描越完整，排序越准确。
@MainActor
final class HotSearchModel: ObservableObject {
    @Published var word = ""
    @Published var target: SearchTarget = .partialTag
    @Published var metric: HotMetric = AppSettings.shared.defaultMetric
    @Published var range: HotDateRange = .all
    @Published var depth: Int = AppSettings.shared.scanDepth
    @Published var useUsersTags = true
    @Published var filter = HotFilter()

    @Published private(set) var results: [Novel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var scanned = 0
    @Published private(set) var totalJobs = 0
    @Published private(set) var doneJobs = 0
    @Published private(set) var reachedEnd = false
    @Published private(set) var mode: String = ""
    @Published var error: String?

    private var pool: [Int: Novel] = [:]
    private var task: Task<Void, Never>?
    private var serverNextURL: String?

    var progress: Double { totalJobs == 0 ? 0 : Double(doneJobs) / Double(totalJobs) }
    var hasSearched: Bool { !pool.isEmpty || isLoading }
    var poolCount: Int { pool.count }

    func cancel() { task?.cancel(); isLoading = false }

    func run(isPremium: Bool) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        task?.cancel()
        pool = [:]; results = []; scanned = 0; doneJobs = 0; reachedEnd = false; error = nil
        isLoading = true
        SearchHistory.add(w)
        let target = self.target, start = range.start, end = range.end, depth = self.depth, users = useUsersTags
        task = Task { [weak self] in
            guard let self else { return }
            if isPremium && AppSettings.shared.preferServerPopular {
                await self.runPremium(w, target: target, start: start, end: end, pages: depth)
            } else {
                await self.runAggregate(w, target: target, start: start, end: end, pages: depth, usersTags: users)
            }
            if !Task.isCancelled { self.isLoading = false }
        }
    }

    /// 会员：直接使用服务端热门排序，多页拉取
    private func runPremium(_ w: String, target: SearchTarget, start: Date?, end: Date?, pages: Int) async {
        mode = "会员热门排序 · 服务端 popular_desc"
        totalJobs = pages
        do {
            var r = try await PixivAPI.shared.search(word: w, target: target, sort: .popularDesc, start: start, end: end)
            merge(r.novels); doneJobs += 1
            var next = r.nextUrl
            while let n = next, doneJobs < pages, !Task.isCancelled {
                r = try await PixivAPI.shared.get(next: n)
                merge(r.novels); doneJobs += 1
                next = r.nextUrl
            }
            serverNextURL = next
            reachedEnd = next == nil
            doneJobs = totalJobs
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    /// 非会员：多路聚合 + 本地排序
    private func runAggregate(_ w: String, target: SearchTarget, start: Date?, end: Date?, pages: Int, usersTags: Bool) async {
        mode = "热度聚合 · 本地排序"
        let thresholds = [10000, 5000, 1000, 500, 100]
        let tagMode = target == .partialTag || target == .exactTag
        let extra = 1 + ((usersTags && tagMode) ? thresholds.count : 0)
        totalJobs = pages + extra

        // 1 & 3：热门预览 + users入り
        await withTaskGroup(of: [Novel].self) { group in
            group.addTask {
                (try? await PixivAPI.shared.popularPreview(word: w, target: target, start: start, end: end))?.novels ?? []
            }
            if usersTags && tagMode {
                for t in thresholds {
                    group.addTask {
                        (try? await PixivAPI.shared.search(word: "\(w) \(t)users入り", target: .partialTag,
                                                            sort: .dateDesc, start: start, end: end))?.novels ?? []
                    }
                }
            }
            for await list in group {
                merge(list); doneJobs += 1
            }
        }
        if Task.isCancelled { return }

        // 2：并发扫描 date_desc，每批 4 页
        let pageSize = 30, maxOffset = 4980, batch = 4
        var page = 0
        var firstError: Error?
        scan: while page < pages && !Task.isCancelled {
            let offsets = (page..<min(page + batch, pages)).map { $0 * pageSize }.filter { $0 <= maxOffset }
            if offsets.isEmpty { reachedEnd = true; break }
            var gotShort = false
            await withTaskGroup(of: (Int, Result<NovelListResponse, Error>).self) { group in
                for off in offsets {
                    group.addTask {
                        do {
                            let r = try await PixivAPI.shared.search(word: w, target: target, sort: .dateDesc,
                                                                     start: start, end: end, offset: off == 0 ? nil : off)
                            return (off, .success(r))
                        } catch { return (off, .failure(error)) }
                    }
                }
                for await (_, res) in group {
                    switch res {
                    case .success(let r):
                        merge(r.novels)
                        if r.novels.count < pageSize || r.nextUrl == nil { gotShort = true }
                    case .failure(let e):
                        if firstError == nil { firstError = e }
                    }
                    doneJobs += 1
                }
            }
            page += offsets.count
            if gotShort { reachedEnd = true; break scan }
            if firstError != nil { break scan }
        }
        doneJobs = totalJobs
        if let firstError, pool.isEmpty { error = firstError.localizedDescription }
        else if let firstError { error = "部分页面加载失败：\(firstError.localizedDescription)" }
    }

    private func merge(_ list: [Novel]) {
        guard !list.isEmpty else { return }
        for n in list { pool[n.id] = n }
        scanned = pool.count
        resort()
    }

    /// 重新排序（指标或过滤变化时调用，不重新请求）
    func resort() {
        let s = AppSettings.shared
        let content = s.contentFilter
        let filtered = pool.values.filter { filter.accept($0, content: content) }
        results = HotRanker.sort(filtered, by: metric, gravity: s.hotGravity)
    }

    /// 会员模式下继续加载
    var canLoadMoreServer: Bool { serverNextURL != nil && !isLoading }

    func loadMoreServer() {
        guard let next = serverNextURL, !isLoading else { return }
        isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let r: NovelListResponse = try await PixivAPI.shared.get(next: next)
                self.merge(r.novels)
                self.serverNextURL = r.nextUrl
                self.reachedEnd = r.nextUrl == nil
            } catch { self.error = error.localizedDescription }
            self.isLoading = false
        }
    }

    func updateBookmark(_ id: Int, _ value: Bool) {
        pool[id]?.isBookmarked = value
        if let i = results.firstIndex(where: { $0.id == id }) { results[i].isBookmarked = value }
    }
}

enum SearchHistory {
    private static let key = "search.history"
    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func add(_ w: String) {
        var list = all.filter { $0 != w }
        list.insert(w, at: 0)
        UserDefaults.standard.set(Array(list.prefix(30)), forKey: key)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
