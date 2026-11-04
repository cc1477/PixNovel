import SwiftUI

/// 榜单类型（R18 由筛选条决定使用哪个榜）
enum RankBase: String, CaseIterable, Identifiable {
    case day, week, male, female, rookie
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "日榜"
        case .week: return "周榜"
        case .male: return "男性向"
        case .female: return "女性向"
        case .rookie: return "新人"
        }
    }
    var normal: RankingMode {
        switch self {
        case .day: return .day
        case .week: return .week
        case .male: return .male
        case .female: return .female
        case .rookie: return .rookie
        }
    }
    var r18: RankingMode? {
        switch self {
        case .day: return .dayR18
        case .week: return .weekR18
        case .male: return .maleR18
        case .female: return .femaleR18
        case .rookie: return nil
        }
    }
}

/// 加载整个榜单（多页）后在本地筛选中文 / R18，并可按热度重排
@MainActor
final class RankingModel: ObservableObject {
    @Published private(set) var items: [Novel] = []
    @Published private(set) var loading = false
    @Published private(set) var loadedCount = 0
    @Published var error: String?
    @Published var localSort: HotMetric? { didSet { apply() } }
    @Published private(set) var note: String?

    /// 小说 id -> 官方名次
    private(set) var ranks: [Int: Int] = [:]
    private var raw: [Novel] = []
    private var task: Task<Void, Never>?

    func load(base: RankBase, date: Date?, r18: R18Mode) {
        task?.cancel()
        raw = []; ranks = [:]; items = []; loadedCount = 0; error = nil; note = nil
        var modes: [RankingMode] = []
        switch r18 {
        case .exclude: modes = [base.normal]
        case .only: if let m = base.r18 { modes = [m] }
        case .all: modes = [base.normal] + (base.r18.map { [$0] } ?? [])
        }
        if modes.isEmpty { note = "「\(base.title)」没有 R18 榜单"; return }
        loading = true
        task = Task {
            await withTaskGroup(of: Void.self) { group in
                for m in modes {
                    group.addTask { await self.loadAll(mode: m, date: date) }
                }
            }
            if !Task.isCancelled { self.loading = false }
        }
    }

    private func loadAll(mode: RankingMode, date: Date?) async {
        do {
            var r = try await PixivAPI.shared.ranking(mode: mode, date: date)
            var rank = 0
            var pages = 0
            while !Task.isCancelled {
                for n in r.novels {
                    rank += 1
                    if ranks[n.id] == nil { ranks[n.id] = rank; raw.append(n) }
                }
                loadedCount = raw.count
                apply()
                pages += 1
                guard let next = r.nextUrl, pages < 20 else { break }
                r = try await PixivAPI.shared.get(next: next)
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func apply() {
        let s = AppSettings.shared
        let f = s.contentFilter
        let visible = raw.filter(f.accept)
        if let m = localSort {
            items = HotRanker.sort(visible, by: m, gravity: s.hotGravity)
        } else {
            items = visible.sorted { (ranks[$0.id] ?? .max, $0.isR18 ? 1 : 0) < (ranks[$1.id] ?? .max, $1.isR18 ? 1 : 0) }
        }
    }

    func updateBookmark(_ id: Int, _ v: Bool) {
        if let i = raw.firstIndex(where: { $0.id == id }) { raw[i].isBookmarked = v }
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].isBookmarked = v }
    }
}

struct RankingView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var model = RankingModel()
    @State private var base: RankBase = .day
    @State private var date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var useDate = false
    @State private var showDate = false

    private var loadKey: String {
        "\(base.rawValue)|\(useDate ? PixivDate.ymd.string(from: date) : "latest")|\(settings.r18Mode.rawValue)"
    }

    var body: some View {
        List {
            ForEach(model.items) { n in
                NavigationLink(value: Route.novel(n)) {
                    NovelRow(novel: n, rank: model.ranks[n.id],
                             badge: model.localSort.flatMap { HotRanker.badge(n, metric: $0, gravity: settings.hotGravity) })
                }
                .swipeActions(edge: .trailing) {
                    BookmarkSwipe(novel: n) { model.updateBookmark(n.id, $0) }
                }
            }
            if model.loading {
                HStack { Spacer(); ProgressView("正在加载完整榜单…"); Spacer() }.listRowSeparator(.hidden)
            } else if let note = model.note {
                Text(note).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            } else if let e = model.error {
                VStack(spacing: 8) {
                    Text(e).font(.footnote).foregroundStyle(.red)
                    Button("重试") { reload() }
                }.frame(maxWidth: .infinity)
            } else if model.items.isEmpty {
                Text(settings.chineseOnly ? "榜单中没有识别到中文作品\n可以关闭「仅中文」或切换到周榜看看" : "暂无内容")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .refreshable { reload() }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                Picker("", selection: $base) {
                    ForEach(RankBase.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                ContentFilterBar(status: "\(model.items.count)/\(model.loadedCount) 篇")
            }
            .padding(.horizontal).padding(.bottom, 8)
            .background(.bar)
        }
        .navigationTitle(useDate ? "热榜 · \(PixivDate.ymd.string(from: date))" : "每日热榜")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { showDate = true } label: { Image(systemName: useDate ? "calendar.badge.clock" : "calendar") }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                SortMenu(selection: $model.localSort, defaultTitle: "榜单名次")
            }
        }
        .sheet(isPresented: $showDate) {
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
        .task(id: loadKey) { reload() }
        .onChange(of: settings.chineseOnly) { _ in model.apply() }
        .pixivDestinations()
    }

    private func reload() {
        model.load(base: base, date: useDate ? date : nil, r18: settings.r18Mode)
    }
}
