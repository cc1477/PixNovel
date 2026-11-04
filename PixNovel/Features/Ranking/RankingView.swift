import SwiftUI

/// 榜单周期
enum RankPeriod: String, CaseIterable, Identifiable {
    case day, week, month, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "日榜"
        case .week: return "周榜"
        case .month: return "月榜"
        case .year: return "年榜"
        }
    }
    /// Pixiv 小说没有官方月榜 / 年榜，由历史周榜合成
    var isSynthesized: Bool { self == .month || self == .year }
}

/// 榜单分类（二级菜单）
enum RankCategory: String, CaseIterable, Identifiable {
    case general, male, female, rookie, ai, long
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "综合"
        case .male: return "男性向"
        case .female: return "女性向"
        case .rookie: return "新人"
        case .ai: return "AI 作品"
        case .long: return "长篇（5万字以上）"
        }
    }
    var icon: String {
        switch self {
        case .general: return "square.grid.2x2"
        case .male: return "person"
        case .female: return "person.fill"
        case .rookie: return "leaf"
        case .ai: return "cpu"
        case .long: return "books.vertical"
        }
    }
    static func available(for p: RankPeriod) -> [RankCategory] {
        switch p {
        case .day: return [.general, .male, .female, .rookie, .ai]
        case .week: return [.general, .rookie]
        case .month, .year: return [.general, .long]
        }
    }

    /// (普通榜, R18 榜)
    func modes(_ p: RankPeriod) -> (RankingMode, RankingMode?) {
        switch (p, self) {
        case (.day, .male): return (.male, .maleR18)
        case (.day, .female): return (.female, .femaleR18)
        case (.day, .ai): return (.dayAI, .dayR18AI)
        case (_, .rookie): return (.rookie, nil)
        case (.day, _): return (.day, .dayR18)
        default: return (.week, .weekR18)
        }
    }
}

@MainActor
final class RankingModel: ObservableObject {
    @Published private(set) var items: [Novel] = []
    @Published private(set) var loading = false
    @Published private(set) var loadedCount = 0
    @Published private(set) var progress: Double = 0
    @Published var error: String?
    @Published var localSort: HotMetric? { didSet { apply() } }
    @Published private(set) var note: String?
    @Published private(set) var synthesized = false
    /// 月榜 / 年榜的数据来源说明
    @Published private(set) var source: String?
    private var category: RankCategory = .general

    /// 小说 id -> 官方名次（合成榜单为空）
    private(set) var ranks: [Int: Int] = [:]
    private var raw: [Int: Novel] = [:]
    private var order: [Int] = []
    private var task: Task<Void, Never>?

    private var loadedKey: String?

    /// 同一组参数已加载过则不重复请求（切换标签返回时）
    func loadIfNeeded(key: String, period: RankPeriod, category: RankCategory, date: Date?, r18: R18Mode) {
        guard key != loadedKey else { return }
        loadedKey = key
        load(period: period, category: category, date: date, r18: r18, force: false)
    }

    func load(period: RankPeriod, category: RankCategory, date: Date?, r18: R18Mode, force: Bool) {
        task?.cancel()
        raw = [:]; order = []; ranks = [:]; items = []; loadedCount = 0; progress = 0; error = nil; note = nil
        synthesized = period.isSynthesized
        source = nil
        self.category = category
        let (normal, r18Mode) = category.modes(period)
        var modes: [RankingMode] = []
        switch r18 {
        case .exclude: modes = [normal]
        case .only: if let m = r18Mode { modes = [m] }
        case .all: modes = [normal] + (r18Mode.map { [$0] } ?? [])
        }
        if modes.isEmpty { note = "「\(category.title)」没有 R18 榜单"; return }

        // 任务：(榜单, 日期, 最多页数)
        let cal = Calendar.current
        let anchor = date ?? cal.date(byAdding: .day, value: -1, to: Date())!
        var jobs: [(RankingMode, Date?, Int)] = []
        switch period {
        case .day, .week:
            jobs = modes.map { ($0, date, 15) }
        case .month:
            for m in modes { for w in 0..<4 { jobs.append((m, cal.date(byAdding: .day, value: -7 * w, to: anchor), 3)) } }
        case .year:
            for m in modes { for w in 0..<52 { jobs.append((m, cal.date(byAdding: .day, value: -7 * w, to: anchor), 1)) } }
        }
        loading = true
        let total = Double(jobs.count)
        task = Task { [self] in
            // 月榜 / 年榜：优先读取每日抓取积累的数据
            if period.isSynthesized, let remote = await RemoteRank.fetch(period: period, anchor: date ?? Date(), force: force) {
                for n in remote.novels where raw[n.id] == nil { order.append(n.id); raw[n.id] = n }
                loadedCount = raw.count
                source = remote.note
                apply()
                progress = 1
                loading = false
                return
            }
            // 逐个加载（全局限速器控制节奏），每页到达即刷新列表
            var done = 0.0
            for j in jobs {
                if Task.isCancelled { return }
                await self.loadMode(j.0, date: j.1, maxPages: j.2, force: force)
                done += 1
                self.progress = done / total
            }
            if !Task.isCancelled { self.loading = false }
        }
    }

    private func loadMode(_ mode: RankingMode, date: Date?, maxPages: Int, force: Bool) async {
        do {
            var r = try await PixivAPI.shared.ranking(mode: mode, date: date, force: force)
            var rank = 0, pages = 0
            while !Task.isCancelled {
                for n in r.novels {
                    rank += 1
                    if raw[n.id] == nil { order.append(n.id) }
                    raw[n.id] = n
                    if !synthesized && ranks[n.id] == nil { ranks[n.id] = rank }
                }
                loadedCount = raw.count
                apply()
                pages += 1
                guard let next = r.nextUrl, pages < maxPages else { break }
                r = try await PixivAPI.shared.rankingNext(next, force: force)
            }
        } catch {
            // 合成榜单中个别周期失败不影响整体
            if !Task.isCancelled && (!synthesized || raw.isEmpty) { self.error = error.localizedDescription }
        }
    }

    func apply() {
        let s = AppSettings.shared
        let f = s.contentFilter
        var visible = order.compactMap { raw[$0] }.filter(f.accept)
        if category == .long { visible = visible.filter { $0.length >= 50000 } }
        if let m = localSort {
            items = HotRanker.sort(visible, by: m, gravity: s.hotGravity)
        } else if synthesized {
            items = HotRanker.sort(visible, by: .bookmarks, gravity: s.hotGravity)
        } else {
            items = visible.sorted { (ranks[$0.id] ?? .max, $0.isR18 ? 1 : 0) < (ranks[$1.id] ?? .max, $1.isR18 ? 1 : 0) }
        }
    }

    func updateBookmark(_ id: Int, _ v: Bool) {
        raw[id]?.isBookmarked = v
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].isBookmarked = v }
    }
}

struct RankingView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var model = RankingModel()
    @State private var period: RankPeriod = .day
    @State private var category: RankCategory = .general
    @State private var date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var useDate = false
    @State private var showDate = false

    private var loadKey: String {
        "\(period.rawValue)|\(category.rawValue)|\(useDate ? PixivDate.ymd.string(from: date) : "latest")|\(settings.r18Mode.rawValue)"
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, n in
                    NavigationLink(value: Route.novel(n)) {
                        NovelRow(novel: n, rank: model.synthesized ? idx + 1 : model.ranks[n.id],
                                 badge: model.localSort.flatMap { HotRanker.badge(n, metric: $0, gravity: settings.hotGravity) })
                    }
                    .swipeActions(edge: .trailing) {
                        BookmarkSwipe(novel: n) { model.updateBookmark(n.id, $0) }
                    }
                }
                footer
            } header: {
                header
            }
        }
        .listStyle(.plain)
        .refreshable { reload(force: true) }
        .safeAreaInset(edge: .top, spacing: 0) {
            GlassHeader {
                Picker("榜单", selection: $period) {
                    ForEach(RankPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("热榜")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { showDate = true } label: {
                    Image(systemName: useDate ? "calendar.badge.clock" : "calendar")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) { filterMenu }
        }
        .sheet(isPresented: $showDate) { dateSheet }
        .task(id: loadKey) { reload(force: false) }
        .onChange(of: period) { p in
            if !RankCategory.available(for: p).contains(category) { category = .general }
        }
        .onChange(of: settings.chineseOnly) { _ in model.apply() }
        .pixivDestinations()
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: category.icon)
            Text(category.title)
            Text("·")
            Text(settings.filterSummary)
            Spacer()
            Text("\(model.items.count) / \(model.loadedCount) 篇").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textCase(nil)
    }

    @ViewBuilder
    private var footer: some View {
        if model.loading {
            VStack(spacing: 6) {
                ProgressView(value: model.progress)
                Text(model.synthesized ? "正在合成\(period.title)（合并历史周榜）…" : "正在加载完整榜单…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
        } else if let note = model.note {
            Text(note).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else if let e = model.error, model.items.isEmpty {
            VStack(spacing: 8) {
                Text(e).font(.footnote).foregroundStyle(.red)
                Button("重试") { reload(force: true) }.glassButton()
            }.frame(maxWidth: .infinity)
        } else if model.items.isEmpty {
            Text(settings.chineseOnly ? "榜单中没有识别到中文作品\n可在右上角筛选中关闭「仅中文」" : "暂无内容")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if let src = model.source {
            Text(src)
                .font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .listRowSeparator(.hidden)
        } else if model.synthesized {
            Text(period == .month ? "月榜由最近 4 期周榜合并，按收藏数排序" : "年榜由最近 52 期周榜前 30 名合并，按收藏数排序（已缓存，再次打开无需等待）")
                .font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        }
    }

    private var filterMenu: some View {
        Menu {
            Section("分类") {
                Picker(selection: $category) {
                    ForEach(RankCategory.available(for: period)) { c in
                        Label(c.title, systemImage: c.icon).tag(c)
                    }
                } label: { Label("分类：\(category.title)", systemImage: category.icon) }
            }
            ContentFilterMenuItems()
            Section("排序") {
                Picker(selection: $model.localSort) {
                    Text(model.synthesized ? "收藏数" : "榜单名次").tag(HotMetric?.none)
                    ForEach(HotMetric.allCases) { m in Label(m.title, systemImage: m.icon).tag(HotMetric?.some(m)) }
                } label: { Label("排序：\(model.localSort?.title ?? "默认")", systemImage: "arrow.up.arrow.down") }
            }
        } label: {
            Image(systemName: settings.filterActive || category != .general || model.localSort != nil
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    private var dateSheet: some View {
        NavigationStack {
            Form {
                Toggle("查看历史榜单", isOn: $useDate)
                if useDate {
                    DatePicker("日期", selection: $date, in: ...Date().addingTimeInterval(-86400), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
            }
            .navigationTitle("选择日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showDate = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func reload(force: Bool) {
        if force {
            model.load(period: period, category: category, date: useDate ? date : nil, r18: settings.r18Mode, force: true)
        } else {
            model.loadIfNeeded(key: loadKey, period: period, category: category, date: useDate ? date : nil, r18: settings.r18Mode)
        }
    }
}


/// 读取 GitHub Actions 每日抓取生成的榜单（发布在 GitHub Pages /rank/ 下）
enum RemoteRank {
    struct Result { let novels: [Novel]; let note: String }

    private struct File: Decodable {
        var novels: [Novel]
        var days: Int?
    }

    static func fetch(period: RankPeriod, anchor: Date, force: Bool) async -> Result? {
        let base = AppSettings.shared.rankDataBase.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        let cal = Calendar.current
        let y = cal.component(.year, from: anchor), m = cal.component(.month, from: anchor)
        let path = period == .month ? String(format: "month/%04d-%02d.json", y, m) : String(format: "year/%04d.json", y)
        guard let url = URL(string: base.hasSuffix("/") ? base + path : base + "/" + path) else { return nil }
        let now = Date()
        let isPast = period == .month
            ? (cal.component(.year, from: now) * 12 + cal.component(.month, from: now)) > (y * 12 + m)
            : cal.component(.year, from: now) > y
        do {
            let data = try await ResponseCache.shared.data(for: url, permanent: isPast, force: force) {
                let (d, r) = try await URLSession.shared.data(from: url)
                guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
                return d
            }
            let dec = JSONDecoder()
            dec.keyDecodingStrategy = .convertFromSnakeCase
            let f = try dec.decode(File.self, from: data)
            guard !f.novels.isEmpty else { return nil }
            let label = period == .month ? String(format: "%04d 年 %d 月", y, m) : "\(y) 年"
            let days = f.days.map { "，已积累 \($0) 天榜单" } ?? ""
            return Result(novels: f.novels, note: "\(label)：每日抓取的全部上榜作品\(days)，按收藏数排序")
        } catch {
            return nil
        }
    }
}
