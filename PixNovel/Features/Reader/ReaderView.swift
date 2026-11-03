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

@MainActor
final class ReaderModel: ObservableObject {
    @Published var novel: Novel
    @Published private(set) var content: NovelContent?
    @Published private(set) var pages: [ReaderPage] = []
    @Published private(set) var flat: [FlatBlock] = []
    @Published private(set) var chapters: [FlatBlock] = []
    @Published private(set) var loading = false
    @Published var error: String?
    @Published var currentFlat = 0
    @Published var currentPage = 0
    /// 每次加载成功 +1，用于触发恢复进度
    @Published private(set) var loadToken = 0

    init(novel: Novel) { self.novel = novel }

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let c = try await PixivAPI.shared.content(novel.id)
            content = c
            pages = NovelContentParser.pages(from: c)
            var f: [FlatBlock] = []
            for p in pages {
                for (i, b) in p.blocks.enumerated() { f.append(FlatBlock(id: f.count, page: p.id, index: i, block: b)) }
            }
            flat = f
            chapters = f.filter(\.isChapter)
            if let r = LocalLibrary.shared.record(for: novel.id) {
                currentFlat = min(f.firstIndex { $0.page == r.page && $0.index == r.block } ?? 0, max(f.count - 1, 0))
                currentPage = pages.firstIndex { $0.id == r.page } ?? 0
            } else {
                currentFlat = 0; currentPage = 0
            }
            loadToken += 1
            saveProgress()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func open(novelId: Int) async {
        saveProgress()
        loading = true
        do {
            novel = try await PixivAPI.shared.detail(novelId)
            content = nil; pages = []; flat = []
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
                    Button("重试") { Task { await model.load() } }.buttonStyle(.bordered)
                }.padding()
            } else {
                switch settings.readerLayout {
                case .scroll: scrollReader
                case .paged: pagedReader
                }
            }
        }
        .preferredColorScheme(theme.isDark ? .dark : nil)
        .navigationTitle(model.novel.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showControls ? .visible : .hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showControls)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { showTOC = true } label: { Image(systemName: "list.bullet") }
                    .disabled(model.chapters.isEmpty && model.pages.count <= 1)
                Button { showSettings = true } label: { Image(systemName: "textformat.size") }
            }
        }
        .overlay(alignment: .bottom) { if showControls { bottomBar } }
        .sheet(isPresented: $showSettings) { ReaderSettingsSheet().presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showTOC) { tocSheet }
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

    // MARK: 连续滚动

    private var scrollReader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: settings.paragraphSpacing) {
                    header
                    ForEach(model.flat) { fb in
                        if fb.index == 0 && fb.page > 0 {
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
                .padding(.vertical, 24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } }
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
                    .padding(.vertical, 24)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } }
    }

    // MARK: 内容块

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.novel.title)
                .font(.system(size: settings.fontSize + 6, weight: .bold, design: settings.readerFont.design))
            Text(model.novel.user.name).font(.subheadline)
            if let st = model.content?.seriesTitle, !st.isEmpty {
                Text("《\(st)》").font(.caption)
            }
        }
        .foregroundStyle(theme.foreground)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func blockView(_ b: ReaderBlock) -> some View {
        switch b {
        case .chapter(let t):
            Text(t)
                .font(.system(size: settings.fontSize + 3, weight: .semibold, design: settings.readerFont.design))
                .foregroundStyle(theme.foreground)
                .padding(.top, 12)
        case .paragraph(let s):
            Text(settings.firstLineIndent ? indent(s) : s)
                .font(.system(size: settings.fontSize, design: settings.readerFont.design))
                .lineSpacing(settings.lineSpacing)
                .foregroundStyle(theme.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .image(let u):
            ReaderImage(url: u).frame(maxWidth: .infinity)
        case .missingImage(let t):
            Label(t, systemImage: "photo").font(.caption).foregroundStyle(theme.foreground.opacity(0.5))
        }
    }

    private func indent(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line in
            line.hasPrefix("　") || line.hasPrefix("「") || line.hasPrefix("『") ? line : "　　" + line
        }.joined(separator: "\n")
    }

    private func pageDivider(_ page: Int) -> some View {
        HStack {
            Rectangle().frame(height: 0.5)
            Text("第 \(page + 1) 页").font(.caption2)
            Rectangle().frame(height: 0.5)
        }
        .foregroundStyle(theme.foreground.opacity(0.35))
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Text("— 完 —").font(.footnote).foregroundStyle(theme.foreground.opacity(0.5))
            HStack(spacing: 12) {
                if let p = model.content?.prevNovel {
                    Button { Task { await model.open(novelId: p.id) } } label: {
                        Label("上一话", systemImage: "chevron.left").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                }
                if let n = model.content?.nextNovel {
                    Button { Task { await model.open(novelId: n.id) } } label: {
                        Label("下一话：\(n.title)", systemImage: "chevron.right").lineLimit(1).frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent)
                }
            }
            BookmarkButton(novel: $model.novel)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: 控制栏

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if settings.readerLayout == .scroll && model.flat.count > 1 {
                HStack {
                    Text(String(format: "%.0f%%", model.percent * 100)).font(.caption.monospacedDigit()).frame(width: 44)
                    Slider(value: $sliderValue, in: 0...Double(max(model.flat.count - 1, 1)), step: 1, onEditingChanged: { editing in
                        sliding = editing
                        if !editing { scrollTarget = Int(sliderValue) }
                    })
                }
            } else if model.pages.count > 1 {
                Text("第 \(model.currentPage + 1) / \(model.pages.count) 页").font(.caption)
            }
            HStack {
                Button { if let p = model.content?.prevNovel { Task { await model.open(novelId: p.id) } } } label: {
                    Label("上一话", systemImage: "backward.end")
                }.disabled(model.content?.prevNovel == nil)
                Spacer()
                Picker("", selection: $settings.readerTheme) {
                    ForEach(ReaderTheme.allCases) { t in Text(t.title).tag(t) }
                }
                .pickerStyle(.menu)
                Spacer()
                Button { if let n = model.content?.nextNovel { Task { await model.open(novelId: n.id) } } } label: {
                    Label("下一话", systemImage: "forward.end")
                }.disabled(model.content?.nextNovel == nil)
            }
            .font(.subheadline)
        }
        .padding()
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom))
    }

    private var tocSheet: some View {
        NavigationStack {
            List {
                if !model.chapters.isEmpty {
                    Section("章节") {
                        ForEach(model.chapters) { c in
                            Button {
                                showTOC = false
                                jump(to: c)
                            } label: {
                                Text(c.title)
                            }
                        }
                    }
                }
                if model.pages.count > 1 {
                    Section("页") {
                        ForEach(Array(model.pages.enumerated()), id: \.offset) { i, p in
                            Button("第 \(i + 1) 页") {
                                showTOC = false
                                if let f = model.flat.first(where: { $0.page == p.id }) { jump(to: f) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func jump(to f: FlatBlock) {
        if settings.readerLayout == .paged {
            if let idx = model.pages.firstIndex(where: { $0.id == f.page }) { model.pageIndexChanged(idx) }
        } else {
            scrollTarget = f.id
        }
    }
}

struct BookmarkButton: View {
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
            Label(marked ? "已收藏" : "收藏本作", systemImage: marked ? "heart.fill" : "heart")
        }
        .tint(.pink)
        .buttonStyle(.bordered)
        .disabled(busy)
    }
}

struct ReaderSettingsSheet: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        NavigationStack {
            Form {
                Section("排版") {
                    Picker("阅读方式", selection: $settings.readerLayout) {
                        ForEach(ReaderLayout.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    VStack(alignment: .leading) {
                        Text("字号 \(Int(settings.fontSize))")
                        Slider(value: $settings.fontSize, in: 12...32, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("行距 \(Int(settings.lineSpacing))")
                        Slider(value: $settings.lineSpacing, in: 0...24, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("段距 \(Int(settings.paragraphSpacing))")
                        Slider(value: $settings.paragraphSpacing, in: 0...40, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("页边距 \(Int(settings.horizontalPadding))")
                        Slider(value: $settings.horizontalPadding, in: 8...60, step: 2)
                    }
                    Toggle("段首缩进", isOn: $settings.firstLineIndent)
                }
                Section("外观") {
                    Picker("字体", selection: $settings.readerFont) {
                        ForEach(ReaderFont.allCases) { Text($0.title).tag($0) }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(ReaderTheme.allCases) { t in
                                Button { settings.readerTheme = t } label: {
                                    Text(t.title).font(.caption)
                                        .foregroundStyle(t.foreground)
                                        .frame(width: 56, height: 40)
                                        .background(t.background, in: RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8)
                                            .stroke(settings.readerTheme == t ? Color.accentColor : Color.gray.opacity(0.3),
                                                    lineWidth: settings.readerTheme == t ? 2 : 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Toggle("阅读时保持屏幕常亮", isOn: $settings.keepAwake)
                }
                Section("预览") {
                    Text("　　春はあけぼの。やうやう白くなりゆく山ぎは、少し明かりて、紫だちたる雲の細くたなびきたる。")
                        .font(.system(size: settings.fontSize, design: settings.readerFont.design))
                        .lineSpacing(settings.lineSpacing)
                        .foregroundStyle(settings.readerTheme.foreground)
                        .padding()
                        .listRowBackground(settings.readerTheme.background)
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
