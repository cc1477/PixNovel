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
    case general, male, female, rookie, ai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "综合"
        case .male: return "男性向"
        case .female: return "女性向"
        case .rookie: return "新人"
        case .ai: return "AI 作品"
        }
    }
    var icon: String {
        switch self {
        case .general: return "square.grid.2x2"
        case .male: return "person"
        case .female: return "person.fill"
        case .rookie: return "leaf"
        case .ai: return "cpu"
        }
    }
    static func available(for p: RankPeriod) -> [RankCategory] {
        switch p {
        case .day: return [.general, .male, .female, .rookie, .ai]
        case .week: return [.general, .rookie]
        case .month, .year: return [.general]
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

    /// 小说 id -> 官方名次（合成榜单为空）
    private(set) var ranks: [Int: Int] = [:]
    private var raw: [Int: Novel] = [:]
    private var order: [Int] = []
    private var task: Task<Void, Never>?

    func load(period: RankPeriod, category: RankCategory, date: Date?, r18: R18Mode) {
        task?.cancel()
        raw = [:]; order = []; ranks = [:]; items = []; loadedCount = 0; progress = 0; error = nil; note = nil
        synthesized = period.isSynthesized
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
            jobs = modes.map { ($0, date, 20) }
        case .month:
            for m in modes { for w in 0..<4 { jobs.append((m, cal.date(byAdding: .day, value: -7 * w, to: anchor), 5)) } }
        case .year:
            for m in modes { for w in 0..<52 { jobs.append((m, cal.date(byAdding: .day, value: -7 * w, to: anchor), 2)) } }
        }
        loading = true
        let total = Double(jobs.count)
        task = Task {
            var done = 0.0
            var idx = 0
            let batch = 6
            while idx < jobs.count && !Task.isCancelled {
                let slice = Array(jobs[idx..<min(idx + batch, jobs.count)])
                await withTaskGroup(of: Void.self) { group in
                    for j in slice {
                        group.addTask { await self.loadMode(j.0, date: j.1, maxPages: j.2) }
                    }
                    for await _ in group { done += 1; self.progress = done / total }
                }
                idx += batch
            }
            if !Task.isCancelled { self.loading = false }
        }
    }

    private func loadMode(_ mode: RankingMode, date: Date?, maxPages: Int) async {
        do {
            var r = try await PixivAPI.shared.ranking(mode: mode, date: date)
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
                r = try await PixivAPI.shared.get(next: next)
            }
        } catch {
            // 合成榜单中个别周期失败不影响整体
            if !Task.isCancelled && (!synthesized || raw.isEmpty) { self.error = error.localizedDescription }
        }
    }

    func apply() {
        let s = AppSettings.shared
        let f = s.contentFilter
        let visible = order.compactMap { raw[$0] }.filter(f.accept)
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
        .refreshable { reload() }
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
        .task(id: loadKey) { reload() }
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
                Button("重试") { reload() }.glassButton()
            }.frame(maxWidth: .infinity)
        } else if model.items.isEmpty {
            Text(settings.chineseOnly ? "榜单中没有识别到中文作品\n可在右上角筛选中关闭「仅中文」" : "暂无内容")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if model.synthesized {
            Text(period == .month ? "月榜由最近 4 期周榜合并，按收藏数排序" : "年榜由最近 52 期周榜前 60 名合并，按收藏数排序")
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

    private func reload() {
        model.load(period: period, category: category, date: useDate ? date : nil, r18: settings.r18Mode)
    }
}
