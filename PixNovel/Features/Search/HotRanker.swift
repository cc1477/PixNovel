import Foundation

/// 热度排序指标
enum HotMetric: String, CaseIterable, Identifiable, Codable {
    case hotScore, bookmarks, views, bookmarkRate, velocity, comments, newest, length

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hotScore: return "综合热度"
        case .bookmarks: return "收藏数"
        case .views: return "阅读数"
        case .bookmarkRate: return "收藏率"
        case .velocity: return "日均收藏"
        case .comments: return "评论数"
        case .newest: return "最新发布"
        case .length: return "字数"
        }
    }

    var icon: String {
        switch self {
        case .hotScore: return "flame.fill"
        case .bookmarks: return "heart.fill"
        case .views: return "eye.fill"
        case .bookmarkRate: return "percent"
        case .velocity: return "chart.line.uptrend.xyaxis"
        case .comments: return "text.bubble.fill"
        case .newest: return "clock.fill"
        case .length: return "textformat.size"
        }
    }

    var explain: String {
        switch self {
        case .hotScore: return "收藏、阅读、评论加权后按发布时间衰减，兼顾热度与新鲜度（衰减强度可在设置中调整）"
        case .bookmarks: return "按总收藏数排序，最接近 Pixiv 会员的「热门度排序」"
        case .views: return "按总阅读数排序"
        case .bookmarkRate: return "收藏数 ÷ 阅读数，经贝叶斯平滑，避免阅读量极少的作品排到最前"
        case .velocity: return "收藏数 ÷ 发布天数，发现正在上升的新作"
        case .comments: return "按评论数排序"
        case .newest: return "按发布时间倒序"
        case .length: return "按字数从多到少"
        }
    }
}

enum HotRanker {
    /// 贝叶斯平滑参数：先验收藏率与先验阅读量
    static let priorRate = 0.06
    static let priorViews = 300.0

    static func score(_ n: Novel, metric: HotMetric, gravity: Double) -> Double {
        let b = Double(n.bookmarks), v = Double(n.views), c = Double(n.totalComments ?? 0)
        let days = n.ageHours / 24
        switch metric {
        case .bookmarks: return b + v * 1e-6
        case .views: return v + b * 1e-6
        case .comments: return c + b * 1e-6
        case .bookmarkRate: return (b + priorRate * priorViews) / (v + priorViews)
        case .velocity: return b / max(days, 0.5)
        case .newest: return -n.ageHours
        case .length: return Double(n.length)
        case .hotScore:
            let weighted = b + 0.02 * v + 3 * c
            let rate = (b + priorRate * priorViews) / (v + priorViews)
            let quality = 0.6 + min(rate / 0.12, 1.4)      // 0.6 ~ 2.0
            return weighted * quality / pow(days + 2, gravity)
        }
    }

    static func sort(_ novels: [Novel], by metric: HotMetric, gravity: Double = AppSettings.shared.hotGravity) -> [Novel] {
        novels
            .map { ($0, score($0, metric: metric, gravity: gravity)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func badge(_ n: Novel, metric: HotMetric, gravity: Double) -> String? {
        switch metric {
        case .bookmarkRate:
            let v = max(n.views, 1)
            return String(format: "收藏率 %.1f%%", Double(n.bookmarks) / Double(v) * 100)
        case .velocity:
            return String(format: "%.1f 收藏/天", score(n, metric: .velocity, gravity: gravity))
        case .hotScore:
            return String(format: "热度 %.0f", score(n, metric: .hotScore, gravity: gravity))
        default:
            return nil
        }
    }
}

/// 结果过滤
struct HotFilter: Equatable, Codable {
    var minBookmarks = 0
    var minLength = 0
    var maxLength = 0          // 0 = 不限
    var hideAI = false
    var originalOnly = false
    var seriesOnly = false
    var excludeTags: [String] = []

    func accept(_ n: Novel, content: ContentFilter) -> Bool {
        if !content.accept(n) { return false }
        if hideAI && n.isAI { return false }
        if originalOnly && n.isOriginal != true { return false }
        if seriesOnly && n.series?.id == nil { return false }
        if n.bookmarks < minBookmarks { return false }
        if n.length < minLength { return false }
        if maxLength > 0 && n.length > maxLength { return false }
        let block = excludeTags
        if !block.isEmpty {
            let tags = n.tagNames
            for t in block where !t.isEmpty {
                if tags.contains(where: { $0.localizedCaseInsensitiveContains(t) }) { return false }
            }
        }
        return true
    }

    var isActive: Bool {
        minBookmarks > 0 || minLength > 0 || maxLength > 0 || hideAI || originalOnly || seriesOnly || !excludeTags.isEmpty
    }
}

/// 时间范围
enum HotDateRange: String, CaseIterable, Identifiable {
    case all, day, week, month, halfYear, year

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部时间"
        case .day: return "24 小时"
        case .week: return "一周内"
        case .month: return "一个月内"
        case .halfYear: return "半年内"
        case .year: return "一年内"
        }
    }

    var start: Date? {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .all: return nil
        case .day: return cal.date(byAdding: .day, value: -1, to: now)
        case .week: return cal.date(byAdding: .day, value: -7, to: now)
        case .month: return cal.date(byAdding: .month, value: -1, to: now)
        case .halfYear: return cal.date(byAdding: .month, value: -6, to: now)
        case .year: return cal.date(byAdding: .year, value: -1, to: now)
        }
    }
    var end: Date? { self == .all ? nil : Date() }
}
