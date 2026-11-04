import SwiftUI

struct FlatBlock: Identifiable, Hashable {
    let id: Int          // 全局序号
    let page: Int
    let index: Int       // 页内序号
    let block: ReaderBlock

    var title: String {
        if case .chapter(let t) = block { return t }
        return ""
    }
    var isChapter: Bool {
        if case .chapter = block { return true }
        return false
    }
}

/// 目录项（章节 / 分页统一表示）
struct TOCEntry: Identifiable, Hashable {
    let id: Int          // 跳转目标 FlatBlock.id
    let title: String
}

@MainActor
final class ReaderModel: ObservableObject {
    @Published var novel: Novel
    @Published private(set) var content: NovelContent?
    @Published private(set) var pages: [ReaderPage] = []
    @Published private(set) var flat: [FlatBlock] = []
    @Published private(set) var chapters: [TOCEntry] = []
    @Published private(set) var pageEntries: [TOCEntry] = []
    @Published private(set) var seriesNovels: [Novel] = []
    @Published private(set) var seriesTitle: String?
    @Published private(set) var loading = false
    @Published var error: String?
    @Published var currentFlat = 0
    @Published var currentPage = 0
    /// 每次加载成功 +1，用于触发恢复进度
    @Published private(set) var loadToken = 0

    private var loadedSeriesId: Int?

    init(novel: Novel) { self.novel = novel }

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let c = try await PixivAPI.shared.content(novel.id)
            content = c
            pages = NovelContentParser.pages(from: c)
            var f: [FlatBlock] = []
            var pe: [TOCEntry] = []
            for p in pages {
                if !p.blocks.isEmpty { pe.append(TOCEntry(id: f.count, title: "第 \(p.id + 1) 页")) }
                for (i, b) in p.blocks.enumerated() { f.append(FlatBlock(id: f.count, page: p.id, index: i, block: b)) }
            }
            flat = f
            pageEntries = pages.count > 1 ? pe : []
            chapters = f.filter(\.isChapter).map { TOCEntry(id: $0.id, title: $0.title) }
            if let r = LocalLibrary.shared.record(for: novel.id) {
                currentFlat = min(f.firstIndex { $0.page == r.page && $0.index == r.block } ?? 0, max(f.count - 1, 0))
                currentPage = pages.firstIndex { $0.id == r.page } ?? 0
            } else {
                currentFlat = 0; currentPage = 0
            }
            loadToken += 1
            saveProgress()
            if let sid = c.seriesId ?? novel.series?.id { await loadSeries(sid) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadSeries(_ id: Int) async {
        guard loadedSeriesId != id else { return }
        do {
            var r = try await PixivAPI.shared.series(id)
            var list = r.novels
            seriesTitle = r.novelSeriesDetail.title
            var pages = 1
            while let next = r.nextUrl, pages < 10 {
                r = try await PixivAPI.shared.get(next: next)
                list += r.novels
                pages += 1
            }
            seriesNovels = list
            loadedSeriesId = id
        } catch {}
    }

    func open(novelId: Int) async {
        guard novelId != novel.id else { return }
        saveProgress()
        loading = true
        do {
            if let cached = seriesNovels.first(where: { $0.id == novelId }) {
                novel = cached
            } else {
                novel = try await PixivAPI.shared.detail(novelId)
            }
            content = nil; pages = []; flat = []; chapters = []; pageEntries = []
            await load()
        } catch {
            loading = false
            self.error = error.localizedDescription
        }
    }

    var percent: Double {
        guard flat.count > 1 else { return flat.isEmpty ? 0 : 1 }
        return Double(currentFlat) / Double(flat.count - 1)
    }

    /// 当前所在章节（或分页）的索引
    func currentIndex(in entries: [TOCEntry]) -> Int? {
        entries.lastIndex { $0.id <= currentFlat }
    }

    /// 用于「上一章 / 下一章」的目录：有章节用章节，否则用分页
    var navEntries: [TOCEntry] { chapters.count > 1 ? chapters : pageEntries }

    var currentSectionTitle: String {
        let e = navEntries
        if let i = currentIndex(in: e) { return e[i].title }
        return novel.title
    }

    func saveProgress() {
        guard !flat.isEmpty else { return }
        let b = flat[min(currentFlat, flat.count - 1)]
        LocalLibrary.shared.save(novel: novel, page: b.page, block: b.index, percent: percent)
    }

    func pageIndexChanged(_ idx: Int) {
        currentPage = idx
        guard idx < pages.count else { return }
        let pid = pages[idx].id
        if let first = flat.first(where: { $0.page == pid }) { currentFlat = first.id }
    }
}

struct ReaderView: View {
    @StateObject private var model: ReaderModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var showControls = false
    @State private var showSettings = false
    @State private var showTOC = false
    @State private var showComments = false
    @State private var visible = Set<Int>()
    @State private var scrollTarget: Int?
    @State private var sliderValue = 0.0
    @State private var sliding = false
    @State private var lastSaved = 0

    init(novel: Novel) {
        _model = StateObject(wrappedValue: ReaderModel(novel: novel))
    }

    private var theme: ReaderTheme { settings.readerTheme }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            if model.loading && model.flat.isEmpty {
                ProgressView("正在加载正文…").tint(theme.foreground).foregroundStyle(theme.foreground)
            } else if let e = model.error, model.flat.isEmpty {
                VStack(spacing: 12) {
                    Text(e).foregroundStyle(theme.foreground).multilineTextAlignment(.center)
                    Button("重试") { Task { await model.load() } }.glassButton()
                }.padding()
            } else {
                switch settings.readerLayout {
                case .scroll: scrollReader
                case .paged: pagedReader
                }
            }
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .navigationTitle(showControls ? model.currentSectionTitle : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showControls ? .visible : .hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showControls)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { showComments = true } label: { Image(systemName: "text.bubble") }
                BookmarkToolbarButton(novel: $model.novel)
            }
        }
        .overlay(alignment: .bottom) {
            if showControls {
                bottomBar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if !showControls && !model.flat.isEmpty { progressBadge }
        }
        .sheet(isPresented: $showComments) {
            CommentsView(novelId: model.novel.id, title: model.novel.title)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet().presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showTOC) {
            ReaderTOCSheet(model: model) { target in
                showTOC = false
                jump(toFlat: target)
            } openNovel: { id in
                showTOC = false
                Task { await model.open(novelId: id) }
            }
            .presentationDetents([.medium, .large])
        }
        .task { if model.flat.isEmpty { await model.load() } }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = settings.keepAwake }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.saveProgress()
        }
        .onChange(of: scenePhase) { p in if p != .active { model.saveProgress() } }
        .onChange(of: model.currentFlat) { v in
            if !sliding { sliderValue = Double(v) }
            if abs(v - lastSaved) >= 8 { lastSaved = v; model.saveProgress() }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.25)) { showControls.toggle() }
    }

    // MARK: 连续滚动

    private var scrollReader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: settings.paragraphSpacing) {
                    header
                    ForEach(model.flat) { fb in
                        if fb.index == 0 && fb.page > 0 && model.chapters.count <= 1 {
                            pageDivider(fb.page)
                        }
                        blockView(fb.block)
                            .id(fb.id)
                            .onAppear { visible.insert(fb.id); updateCurrent() }
                            .onDisappear { visible.remove(fb.id); updateCurrent() }
                    }
                    footer
                }
                .padding(.horizontal, settings.horizontalPadding)
                .padding(.top, 28)
                .padding(.bottom, 120)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleControls() }
            .onChange(of: model.loadToken) { _ in
                let target = model.currentFlat
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(target, anchor: .top) }
            }
            .onChange(of: scrollTarget) { t in
                guard let t else { return }
                proxy.scrollTo(t, anchor: .top)
                scrollTarget = nil
            }
        }
    }

    private func updateCurrent() {
        if let m = visible.min(), m != model.currentFlat { model.currentFlat = m }
    }

    // MARK: 按原文分页

    private var pagedReader: some View {
        TabView(selection: Binding(get: { model.currentPage }, set: { model.pageIndexChanged($0) })) {
            ForEach(Array(model.pages.enumerated()), id: \.element.id) { idx, page in
                ScrollView {
                    VStack(alignment: .leading, spacing: settings.paragraphSpacing) {
                        if idx == 0 { header }
                        ForEach(Array(page.blocks.enumerated()), id: \.offset) { _, b in blockView(b) }
                        if idx == model.pages.count - 1 { footer }
                        Text("\(idx + 1) / \(model.pages.count)")
                            .font(.caption).foregroundStyle(theme.foreground.opacity(0.5))
                            .frame(maxWidth: .infinity).padding(.top, 20)
                    }
                    .padding(.horizontal, settings.horizontalPadding)
                    .padding(.top, 28)
                    .padding(.bottom, 120)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
    }

    // MARK: 内容块

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let st = model.seriesTitle ?? model.content?.seriesTitle, !st.isEmpty {
                Text(st).font(.caption).foregroundStyle(theme.foreground.opacity(0.6))
            }
            Text(model.novel.title)
                .font(.system(size: settings.fontSize + 8, weight: .bold, design: settings.readerFont.design))
            HStack(spacing: 8) {
                Text(model.novel.user.name)
                Text("·")
                Text("\(NumberFmt.short(model.novel.length)) 字")
            }
            .font(.subheadline)
            .foregroundStyle(theme.foreground.opacity(0.65))
            Rectangle().fill(theme.foreground.opacity(0.12)).frame(height: 0.5).padding(.top, 8)
        }
        .foregroundStyle(theme.foreground)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func blockView(_ b: ReaderBlock) -> some View {
        switch b {
        case .chapter(let t):
            VStack(alignment: .leading, spacing: 6) {
                Text(t)
                    .font(.system(size: settings.fontSize + 4, weight: .semibold, design: settings.readerFont.design))
                Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: 28, height: 2)
            }
            .foregroundStyle(theme.foreground)
            .padding(.top, 28).padding(.bottom, 8)
        case .paragraph(let s):
            Text(indented(s))
                .font(.system(size: settings.fontSize, design: settings.readerFont.design))
                .lineSpacing(settings.lineSpacing)
                .foregroundStyle(theme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .blank(let n):
            if settings.collapseBlankLines {
                // 压缩：单个空行由段距体现，连续空行视为场景切换
                if n >= 2 { Color.clear.frame(height: settings.fontSize) }
            } else {
                Color.clear.frame(height: CGFloat(n) * (settings.fontSize + settings.lineSpacing))
            }
        case .divider(let t):
            Text(t)
                .font(.system(size: settings.fontSize - 2, design: settings.readerFont.design))
                .foregroundStyle(theme.foreground.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, settings.fontSize * 0.6)
        case .image(let u):
            ReaderImage(url: u)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity)
        case .missingImage(let t):
            Label(t, systemImage: "photo").font(.caption).foregroundStyle(theme.foreground.opacity(0.5))
        }
    }

    /// 首行缩进：日式对白（「」『』）与括号开头的行保持顶格
    private func indented(_ s: String) -> String {
        guard settings.firstLineIndent else { return s }
        if let c = s.first, "「『（(【〈《〔".contains(c) { return s }
        return "\u{3000}\u{3000}" + s
    }

    private func pageDivider(_ page: Int) -> some View {
        HStack {
            Rectangle().frame(height: 0.5)
            Text("第 \(page + 1) 页").font(.caption2)
            Rectangle().frame(height: 0.5)
        }
        .foregroundStyle(theme.foreground.opacity(0.3))
        .padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Text("— 完 —").font(.footnote).foregroundStyle(theme.foreground.opacity(0.5))
            Button { showComments = true } label: {
                Label("查看评论（\(model.novel.totalComments ?? 0)）", systemImage: "text.bubble")
            }
            .glassButton()
            if let n = model.content?.nextNovel {
                Button { Task { await model.open(novelId: n.id) } } label: {
                    VStack(spacing: 2) {
                        Text("下一话").font(.caption)
                        Text(n.title).font(.headline).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .glassButton(prominent: true)
            }
            if let p = model.content?.prevNovel {
                Button { Task { await model.open(novelId: p.id) } } label: {
                    Label("上一话：\(p.title)", systemImage: "chevron.left").lineLimit(1)
                }
                .glassButton()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var progressBadge: some View {
        Text(String(format: "%.0f%%", model.percent * 100))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(theme.foreground.opacity(0.45))
            .padding(.horizontal, 10).padding(.top, 4)
            .allowsHitTesting(false)
    }

    // MARK: 悬浮控制栏

    private var bottomBar: some View {
        let entries = model.navEntries
        let cur = model.currentIndex(in: entries)
        let prevChapter: TOCEntry? = cur.flatMap { $0 > 0 ? entries[$0 - 1] : nil }
        let nextChapter: TOCEntry? = {
            if let c = cur { return c + 1 < entries.count ? entries[c + 1] : nil }
            return entries.first
        }()

        return VStack(spacing: 12) {
            // 进度
            if model.flat.count > 1 {
                HStack(spacing: 10) {
                    Text(model.currentSectionTitle).lineLimit(1).font(.caption)
                    Spacer()
                    Text(String(format: "%.0f%%", model.percent * 100)).font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
                if settings.readerLayout == .scroll {
                    Slider(value: $sliderValue, in: 0...Double(max(model.flat.count - 1, 1)), step: 1,
                           onEditingChanged: { editing in
                               sliding = editing
                               if !editing { scrollTarget = Int(sliderValue) }
                           })
                }
            }
            // 章节切换
            HStack(spacing: 0) {
                barButton("上一章", "chevron.left", enabled: prevChapter != nil || model.content?.prevNovel != nil) {
                    if let p = prevChapter { jump(toFlat: p.id) }
                    else if let p = model.content?.prevNovel { Task { await model.open(novelId: p.id) } }
                }
                barButton("目录", "list.bullet", enabled: true) { showTOC = true }
                barButton("排版", "textformat.size", enabled: true) { showSettings = true }
                Menu {
                    Picker("主题", selection: $settings.readerTheme) {
                        ForEach(ReaderTheme.allCases) { t in Text(t.title).tag(t) }
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: theme.isDark ? "moon.fill" : "sun.max.fill").font(.system(size: 18))
                        Text("主题").font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
                barButton("下一章", "chevron.right", enabled: nextChapter != nil || model.content?.nextNovel != nil) {
                    if let n = nextChapter { jump(toFlat: n.id) }
                    else if let n = model.content?.nextNovel { Task { await model.open(novelId: n.id) } }
                }
            }
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassBackground(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func barButton(_ title: String, _ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func jump(toFlat id: Int) {
        if settings.readerLayout == .paged {
            if let f = model.flat.first(where: { $0.id == id }),
               let idx = model.pages.firstIndex(where: { $0.id == f.page }) {
                model.pageIndexChanged(idx)
            }
        } else {
            scrollTarget = id
            model.currentFlat = id
        }
    }
}

// MARK: - 目录

struct ReaderTOCSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case chapters = "章节", pages = "分页", series = "系列"
        var id: String { rawValue }
    }

    @ObservedObject var model: ReaderModel
    let jump: (Int) -> Void
    let openNovel: (Int) -> Void
    @State private var tab: Tab = .chapters

    private var tabs: [Tab] {
        var t: [Tab] = []
        if !model.chapters.isEmpty { t.append(.chapters) }
        if !model.pageEntries.isEmpty { t.append(.pages) }
        if !model.seriesNovels.isEmpty { t.append(.series) }
        return t
    }

    var body: some View {
        NavigationStack {
            Group {
                if tabs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                        Text("本篇没有章节或分页").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        List {
                            switch tab {
                            case .chapters: entryList(model.chapters)
                            case .pages: entryList(model.pageEntries)
                            case .series: seriesList
                            }
                        }
                        .listStyle(.plain)
                        .onAppear { scrollToCurrent(proxy) }
                        .onChange(of: tab) { _ in scrollToCurrent(proxy) }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if tabs.count > 1 {
                    GlassHeader {
                        Picker("", selection: $tab) {
                            ForEach(tabs) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .navigationTitle(model.seriesTitle ?? model.novel.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if let f = tabs.first, !tabs.contains(tab) { tab = f } }
        }
    }

    private func entryList(_ entries: [TOCEntry]) -> some View {
        let cur = model.currentIndex(in: entries)
        return ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
            Button { jump(e.id) } label: {
                HStack {
                    Text(e.title).lineLimit(2)
                        .fontWeight(i == cur ? .semibold : .regular)
                    Spacer()
                    if i == cur { Image(systemName: "bookmark.fill").foregroundStyle(.tint) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(i == cur ? Color.accentColor : Color.primary)
            .id("e\(e.id)")
        }
    }

    private var seriesList: some View {
        ForEach(Array(model.seriesNovels.enumerated()), id: \.element.id) { i, n in
            let current = n.id == model.novel.id
            let read = LocalLibrary.shared.record(for: n.id)
            Button { openNovel(n.id) } label: {
                HStack(spacing: 10) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.title).lineLimit(2).fontWeight(current ? .semibold : .regular)
                        Text("\(NumberFmt.short(n.length)) 字" + (read.map { String(format: " · 已读 %.0f%%", $0.percent * 100) } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if current { Image(systemName: "book.fill").foregroundStyle(.tint) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(current ? Color.accentColor : Color.primary)
            .id("s\(n.id)")
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            switch tab {
            case .chapters:
                if let i = model.currentIndex(in: model.chapters) { proxy.scrollTo("e\(model.chapters[i].id)", anchor: .center) }
            case .pages:
                if let i = model.currentIndex(in: model.pageEntries) { proxy.scrollTo("e\(model.pageEntries[i].id)", anchor: .center) }
            case .series:
                proxy.scrollTo("s\(model.novel.id)", anchor: .center)
            }
        }
    }
}

struct BookmarkToolbarButton: View {
    @Binding var novel: Novel
    @State private var busy = false
    var body: some View {
        let marked = novel.isBookmarked == true
        Button {
            Task {
                busy = true
                defer { busy = false }
                do {
                    if marked { try await PixivAPI.shared.deleteBookmark(novel.id) }
                    else { try await PixivAPI.shared.addBookmark(novel.id) }
                    novel.isBookmarked = !marked
                } catch {}
            }
        } label: {
            Image(systemName: marked ? "heart.fill" : "heart").foregroundStyle(marked ? .pink : .primary)
        }
        .disabled(busy)
    }
}

// MARK: - 排版设置

struct ReaderSettingsSheet: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        NavigationStack {
            Form {
                Section("段落") {
                    Toggle("首行缩进", isOn: $settings.firstLineIndent)
                    Toggle("压缩多余空行", isOn: $settings.collapseBlankLines)
                    stepper("段距", value: $settings.paragraphSpacing, range: 0...40, step: 2)
                    stepper("行距", value: $settings.lineSpacing, range: 0...24, step: 1)
                }
                Section("文字") {
                    stepper("字号", value: $settings.fontSize, range: 12...34, step: 1)
                    Picker("字体", selection: $settings.readerFont) {
                        ForEach(ReaderFont.allCases) { Text($0.title).tag($0) }
                    }
                    stepper("页边距", value: $settings.horizontalPadding, range: 8...60, step: 2)
                }
                Section("外观") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(ReaderTheme.allCases) { t in
                                Button { settings.readerTheme = t } label: {
                                    Text(t.title).font(.caption)
                                        .foregroundStyle(t.foreground)
                                        .frame(width: 58, height: 42)
                                        .background(t.background, in: RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10)
                                            .stroke(settings.readerTheme == t ? Color.accentColor : Color.gray.opacity(0.3),
                                                    lineWidth: settings.readerTheme == t ? 2 : 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Picker("翻页方式", selection: $settings.readerLayout) {
                        ForEach(ReaderLayout.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("阅读时保持屏幕常亮", isOn: $settings.keepAwake)
                }
                Section("预览") {
                    VStack(alignment: .leading, spacing: settings.paragraphSpacing) {
                        ForEach(["夜色渐深，街灯一盏一盏亮了起来。", "「还没睡吗？」她轻声问道。", "他摇了摇头，把视线移回窗外。"], id: \.self) { line in
                            Text(settings.firstLineIndent && !line.hasPrefix("「") ? "\u{3000}\u{3000}" + line : line)
                                .font(.system(size: settings.fontSize, design: settings.readerFont.design))
                                .lineSpacing(settings.lineSpacing)
                        }
                    }
                    .foregroundStyle(settings.readerTheme.foreground)
                    .padding(.vertical, 8)
                    .listRowBackground(settings.readerTheme.background)
                }
            }
            .navigationTitle("排版")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func stepper(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue))").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
