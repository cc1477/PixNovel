import SwiftUI

struct SearchView: View {
    var initialWord: String? = nil

    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var settings: AppSettings
    @StateObject private var model = HotSearchModel()
    @State private var query = ""
    @State private var suggestions: [PixivTag] = []
    @State private var trending: [TrendTag] = []
    @State private var history: [String] = SearchHistory.all
    @State private var showFilter = false
    @State private var showExplain = false
    @State private var didInit = false

    var body: some View {
        content
            .navigationTitle(initialWord ?? "热度搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "标签 / 关键词")
            .searchSuggestions {
                ForEach(suggestions, id: \.name) { t in
                    Text(t.translatedName.map { "\(t.name)  ·  \($0)" } ?? t.name)
                        .searchCompletion(t.name)
                }
            }
            .onSubmit(of: .search) { start(query) }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard q.count >= 1, q != model.word else { suggestions = []; return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                suggestions = (try? await PixivAPI.shared.autocomplete(q))?.tags ?? []
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showFilter = true } label: {
                        Image(systemName: model.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showFilter) {
                HotFilterSheet(model: model, isPremium: session.isPremium) { rerun in
                    if rerun { model.run(isPremium: session.isPremium) } else { model.resort() }
                }
            }
            .onChange(of: model.metric) { _ in model.resort() }
            .onAppear {
                guard !didInit else { return }
                didInit = true
                if let w = initialWord { model.target = .exactTag; start(w) }
            }
            .task { if trending.isEmpty { trending = (try? await PixivAPI.shared.trendingTags())?.trendTags ?? [] } }
            .modifier(RootDestinations(enabled: initialWord == nil))
    }

    private func start(_ w: String) {
        let word = w.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        query = word
        suggestions = []
        model.word = word
        model.run(isPremium: session.isPremium)
        history = SearchHistory.all
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasSearched {
            discover
        } else {
            results
        }
    }

    // MARK: 发现页：热门标签 + 历史

    private var discover: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("热度排序说明", systemImage: "flame.fill").font(.headline).foregroundStyle(.orange)
                    Text(session.isPremium
                         ? "你是 Pixiv 会员：将直接使用服务端「热门度排序」，并支持本地按收藏率、日均收藏等指标二次排序。"
                         : "非会员无法使用官方热门排序。本应用会聚合「热门预览」+「users入り 标签」+ 多页时间序扫描，在本地按收藏数等指标排序。缩小时间范围、加大扫描深度可让结果更准确。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !history.isEmpty {
                Section {
                    FlowLayout(spacing: 8) {
                        ForEach(history, id: \.self) { h in
                            Button(h) { start(h) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                } header: {
                    HStack {
                        Text("搜索历史")
                        Spacer()
                        Button("清除") { SearchHistory.clear(); history = [] }.font(.caption)
                    }
                }
            }
            if !trending.isEmpty {
                Section("热门标签") {
                    FlowLayout(spacing: 8) {
                        ForEach(trending, id: \.tag) { t in
                            Button { start(t.tag) } label: {
                                VStack(spacing: 0) {
                                    Text("#\(t.tag)").font(.subheadline)
                                    if let tr = t.translatedName { Text(tr).font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    // MARK: 结果页

    private var results: some View {
        List {
            Section {
                controls
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            Section {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { idx, n in
                    NavigationLink(value: Route.novel(n)) {
                        NovelRow(novel: n, rank: idx + 1,
                                 badge: HotRanker.badge(n, metric: model.metric, gravity: settings.hotGravity))
                    }
                    .swipeActions(edge: .trailing) {
                        BookmarkSwipe(novel: n) { model.updateBookmark(n.id, $0) }
                    }
                    .onAppear {
                        if n.id == model.results.last?.id && model.canLoadMoreServer { model.loadMoreServer() }
                    }
                }
                if !model.isLoading && model.results.isEmpty && model.error == nil {
                    Text(model.filter.isActive ? "没有符合过滤条件的结果" : "没有结果")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                if let e = model.error {
                    Text(e).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                if !model.results.isEmpty {
                    Text("共 \(model.results.count) 篇 · 按\(model.metric.title)")
                }
            }
        }
        .listStyle(.plain)
        .refreshable { model.run(isPremium: session.isPremium) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HotMetric.allCases) { m in
                        Button { model.metric = m } label: {
                            Label(m.title, systemImage: m.icon).font(.subheadline)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(model.metric == m ? Color.orange : Color(.systemGray5))
                        .foregroundStyle(model.metric == m ? Color.white : Color.primary)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal)
            }

            HStack(spacing: 8) {
                Menu {
                    Picker("时间范围", selection: $model.range) {
                        ForEach(HotDateRange.allCases) { Text($0.title).tag($0) }
                    }
                } label: { Label(model.range.title, systemImage: "calendar").font(.subheadline) }
                    .onChange(of: model.range) { _ in model.run(isPremium: session.isPremium) }

                Menu {
                    Picker("搜索范围", selection: $model.target) {
                        ForEach(SearchTarget.allCases) { Text($0.title).tag($0) }
                    }
                } label: { Label(model.target.title, systemImage: "tag").font(.subheadline) }
                    .onChange(of: model.target) { _ in model.run(isPremium: session.isPremium) }

                Spacer()
                Button { showExplain.toggle() } label: { Image(systemName: "questionmark.circle") }
            }
            .padding(.horizontal)

            if showExplain {
                Text(model.metric.explain).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }

            VStack(alignment: .leading, spacing: 4) {
                if model.isLoading {
                    ProgressView(value: model.progress)
                }
                HStack {
                    Text(model.mode).foregroundStyle(.orange)
                    Spacer()
                    Text(statusText).foregroundStyle(.secondary)
                    if model.isLoading {
                        Button("停止") { model.cancel() }.font(.caption)
                    }
                }
                .font(.caption)
                if !model.isLoading && !session.isPremium && !model.reachedEnd && model.scanned > 0 {
                    Text("提示：已扫描最新的 \(model.scanned) 篇，更早的作品可能未纳入排序。可缩小时间范围或在过滤中加大扫描深度。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
        }
    }

    private var statusText: String {
        if model.isLoading { return "已收集 \(model.scanned) 篇 · \(model.doneJobs)/\(model.totalJobs)" }
        return model.reachedEnd ? "已覆盖全部 \(model.scanned) 篇" : "已收集 \(model.scanned) 篇"
    }
}

private struct RootDestinations: ViewModifier {
    let enabled: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled { content.pixivDestinations() } else { content }
    }
}

// MARK: - 过滤面板

struct HotFilterSheet: View {
    @ObservedObject var model: HotSearchModel
    let isPremium: Bool
    let onDone: (_ rerun: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = HotFilter()
    @State private var depth = 10
    @State private var usersTags = true
    @State private var excludeText = ""

    private let depths = [3, 5, 10, 20, 40, 80, 166]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("扫描深度", selection: $depth) {
                        ForEach(depths, id: \.self) { Text("\($0) 页 · 约 \($0 * 30) 篇").tag($0) }
                    }
                    if !isPremium {
                        Toggle("使用 users入り 标签补充高收藏作品", isOn: $usersTags)
                    }
                } header: { Text("热度聚合") } footer: {
                    Text(isPremium ? "会员模式下按服务端热门顺序加载的页数。"
                                   : "页数越多越准确但越慢。Pixiv 最多允许翻到约 5000 篇（166 页）。")
                }

                Section("作品过滤") {
                    Stepper("最低收藏：\(draft.minBookmarks)", value: $draft.minBookmarks, in: 0...100000, step: draft.minBookmarks < 100 ? 10 : (draft.minBookmarks < 1000 ? 100 : 1000))
                    Stepper("最少字数：\(draft.minLength)", value: $draft.minLength, in: 0...1_000_000, step: draft.minLength < 10000 ? 1000 : 10000)
                    Stepper("最多字数：\(draft.maxLength == 0 ? "不限" : "\(draft.maxLength)")", value: $draft.maxLength, in: 0...1_000_000, step: draft.maxLength < 10000 ? 1000 : 10000)
                    Toggle("隐藏 AI 生成作品", isOn: $draft.hideAI)
                    Toggle("仅原创作品", isOn: $draft.originalOnly)
                    Toggle("仅系列作品", isOn: $draft.seriesOnly)
                }

                Section {
                    TextField("用空格分隔，如：BL 腐向", text: $excludeText)
                } header: { Text("排除标签") }
            }
            .navigationTitle("过滤与扫描")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        draft.excludeTags = excludeText.split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
                        let rerun = depth != model.depth || usersTags != model.useUsersTags
                        model.filter = draft
                        model.depth = depth
                        model.useUsersTags = usersTags
                        AppSettings.shared.scanDepth = depth
                        dismiss()
                        onDone(rerun && !model.word.isEmpty)
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("重置过滤") { draft = HotFilter(); excludeText = "" }
                }
            }
            .onAppear {
                draft = model.filter
                depth = model.depth
                usersTags = model.useUsersTags
                excludeText = model.filter.excludeTags.joined(separator: " ")
            }
        }
    }
}
