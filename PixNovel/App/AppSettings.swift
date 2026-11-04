import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable, Codable {
    case light, sepia, green, gray, dark, black
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: return "白"
        case .sepia: return "羊皮纸"
        case .green: return "护眼"
        case .gray: return "灰"
        case .dark: return "夜间"
        case .black: return "纯黑"
        }
    }
    var background: Color {
        switch self {
        case .light: return Color(red: 1, green: 1, blue: 1)
        case .sepia: return Color(red: 0.96, green: 0.92, blue: 0.83)
        case .green: return Color(red: 0.80, green: 0.91, blue: 0.81)
        case .gray: return Color(red: 0.88, green: 0.88, blue: 0.88)
        case .dark: return Color(red: 0.12, green: 0.12, blue: 0.14)
        case .black: return Color.black
        }
    }
    var foreground: Color {
        switch self {
        case .dark: return Color(white: 0.78)
        case .black: return Color(white: 0.65)
        case .sepia: return Color(red: 0.33, green: 0.25, blue: 0.16)
        default: return Color(white: 0.12)
        }
    }
    var isDark: Bool { self == .dark || self == .black }
}

enum ReaderFont: String, CaseIterable, Identifiable, Codable {
    case system, serif, rounded, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "系统"
        case .serif: return "宋体/衬线"
        case .rounded: return "圆体"
        case .mono: return "等宽"
        }
    }
    var design: Font.Design {
        switch self {
        case .system: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        case .mono: return .monospaced
        }
    }
}

enum ReaderLayout: String, CaseIterable, Identifiable, Codable {
    case scroll, paged
    var id: String { rawValue }
    var title: String { self == .scroll ? "连续滚动" : "按原文分页" }
}

/// 全局设置（UserDefaults 持久化）
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var chineseOnly: Bool { didSet { d.set(chineseOnly, forKey: "chineseOnly") } }
    @Published var r18Mode: R18Mode { didSet { d.set(r18Mode.rawValue, forKey: "r18Mode") } }
    @Published var imageProxy: String { didSet { d.set(imageProxy, forKey: "imageProxy") } }
    @Published var defaultMetric: HotMetric { didSet { d.set(defaultMetric.rawValue, forKey: "defaultMetric") } }
    @Published var scanDepth: Int { didSet { d.set(scanDepth, forKey: "scanDepth") } }
    @Published var hotGravity: Double { didSet { d.set(hotGravity, forKey: "hotGravity") } }
    @Published var preferServerPopular: Bool { didSet { d.set(preferServerPopular, forKey: "preferServerPopular") } }
    @Published var mutedTags: [String] { didSet { d.set(mutedTags, forKey: "mutedTags") } }

    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "r.fontSize") } }
    @Published var lineSpacing: Double { didSet { d.set(lineSpacing, forKey: "r.lineSpacing") } }
    @Published var paragraphSpacing: Double { didSet { d.set(paragraphSpacing, forKey: "r.paragraphSpacing") } }
    @Published var horizontalPadding: Double { didSet { d.set(horizontalPadding, forKey: "r.padding") } }
    @Published var readerTheme: ReaderTheme { didSet { d.set(readerTheme.rawValue, forKey: "r.theme") } }
    @Published var readerFont: ReaderFont { didSet { d.set(readerFont.rawValue, forKey: "r.font") } }
    @Published var readerLayout: ReaderLayout { didSet { d.set(readerLayout.rawValue, forKey: "r.layout") } }
    @Published var keepAwake: Bool { didSet { d.set(keepAwake, forKey: "r.keepAwake") } }
    @Published var firstLineIndent: Bool { didSet { d.set(firstLineIndent, forKey: "r.indent") } }
    @Published var collapseBlankLines: Bool { didSet { d.set(collapseBlankLines, forKey: "r.collapseBlank") } }

    private init() {
        d.register(defaults: [
            "chineseOnly": true, "r18Mode": R18Mode.all.rawValue, "imageProxy": "", "defaultMetric": HotMetric.bookmarks.rawValue,
            "scanDepth": 10, "hotGravity": 0.6, "preferServerPopular": true, "mutedTags": [String](),
            "r.fontSize": 18.0, "r.lineSpacing": 8.0, "r.paragraphSpacing": 14.0, "r.padding": 20.0,
            "r.theme": ReaderTheme.light.rawValue, "r.font": ReaderFont.system.rawValue,
            "r.layout": ReaderLayout.scroll.rawValue, "r.keepAwake": true, "r.indent": true, "r.collapseBlank": true
        ])
        chineseOnly = d.bool(forKey: "chineseOnly")
        r18Mode = R18Mode(rawValue: d.string(forKey: "r18Mode") ?? "") ?? .all
        imageProxy = d.string(forKey: "imageProxy") ?? ""
        defaultMetric = HotMetric(rawValue: d.string(forKey: "defaultMetric") ?? "") ?? .bookmarks
        scanDepth = d.integer(forKey: "scanDepth")
        hotGravity = d.double(forKey: "hotGravity")
        preferServerPopular = d.bool(forKey: "preferServerPopular")
        mutedTags = d.stringArray(forKey: "mutedTags") ?? []
        fontSize = d.double(forKey: "r.fontSize")
        lineSpacing = d.double(forKey: "r.lineSpacing")
        paragraphSpacing = d.double(forKey: "r.paragraphSpacing")
        horizontalPadding = d.double(forKey: "r.padding")
        readerTheme = ReaderTheme(rawValue: d.string(forKey: "r.theme") ?? "") ?? .light
        readerFont = ReaderFont(rawValue: d.string(forKey: "r.font") ?? "") ?? .system
        readerLayout = ReaderLayout(rawValue: d.string(forKey: "r.layout") ?? "") ?? .scroll
        keepAwake = d.bool(forKey: "r.keepAwake")
        firstLineIndent = d.bool(forKey: "r.indent")
        collapseBlankLines = d.bool(forKey: "r.collapseBlank")
    }

    var contentFilter: ContentFilter {
        ContentFilter(chineseOnly: chineseOnly, r18: r18Mode, mutedTags: mutedTags)
    }

    /// 图片地址：可选替换为反代域名（如 i.pixiv.re）
    func imageURL(_ s: String?) -> URL? {
        guard var s, !s.isEmpty else { return nil }
        let proxy = imageProxy.trimmingCharacters(in: .whitespaces)
        if !proxy.isEmpty { s = s.replacingOccurrences(of: "i.pximg.net", with: proxy) }
        return URL(string: s)
    }
}

// MARK: - 本地书架：阅读历史 & 进度

struct ReadingRecord: Codable, Identifiable, Hashable {
    var id: Int
    var novel: Novel
    var page: Int
    var block: Int
    var percent: Double
    var updatedAt: Date
}

final class LocalLibrary: ObservableObject {
    static let shared = LocalLibrary()
    @Published private(set) var history: [ReadingRecord] = []
    private let url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("history.json")

    private init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([ReadingRecord].self, from: data) {
            history = list
        }
    }

    func record(for id: Int) -> ReadingRecord? { history.first { $0.id == id } }

    func save(novel: Novel, page: Int, block: Int, percent: Double) {
        var list = history.filter { $0.id != novel.id }
        list.insert(ReadingRecord(id: novel.id, novel: novel, page: page, block: block,
                                  percent: percent, updatedAt: Date()), at: 0)
        history = Array(list.prefix(500))
        persist()
    }

    func remove(_ id: Int) { history.removeAll { $0.id == id }; persist() }
    func clear() { history = []; persist() }

    private func persist() {
        let snapshot = history
        DispatchQueue.global(qos: .utility).async { [url] in
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
}
