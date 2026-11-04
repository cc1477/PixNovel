import Foundation

/// R18 筛选
enum R18Mode: String, CaseIterable, Identifiable, Codable {
    case all, exclude, only
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .exclude: return "不含R18"
        case .only: return "仅R18"
        }
    }
    func accept(_ n: Novel) -> Bool {
        switch self {
        case .all: return true
        case .exclude: return !n.isR18
        case .only: return n.isR18
        }
    }
}

/// 中文作品识别
///
/// App API 不返回作品语言，这里根据标题 / 简介 / 标签 / 系列名的文字特征判断：
/// - 带「中文」「中国語」「简中」「繁中」等标签 → 中文
/// - 平假名 / 片假名占比高 → 日文
/// - 出现中文常用而日文不用的字（们、这、说、吗……） → 中文
/// - 没有假名、汉字较多 → 中文
enum LanguageDetector {
    private static let chineseTags: [String] = [
        "中文", "中国語", "中國語", "简中", "簡中", "繁中", "简体", "簡體", "繁體", "繁体中文", "简体中文",
        "中文小说", "中文小說", "华语", "華語", "Chinese", "chinese", "中文创作", "中文創作"
    ]
    private static let chineseOnlyChars: Set<Character> = Set(
        "们們这這说說么麼还還没沒过過对让讓吗嗎呢吧哪啊你您她该谁样樣怎几听聽觉覺见给給从從为现发發话进边邊"
    )
    private static let japaneseOnlyChars: Set<Character> = Set("々〆ヶ")

    private static var cache: [Int: Bool] = [:]
    private static let lock = NSLock()

    static func isChinese(_ n: Novel) -> Bool {
        lock.lock(); if let v = cache[n.id] { lock.unlock(); return v }; lock.unlock()
        let v = detect(n)
        lock.lock(); cache[n.id] = v; lock.unlock()
        return v
    }

    private static func detect(_ n: Novel) -> Bool {
        let tags = n.tagNames
        if tags.contains(where: { t in chineseTags.contains { t.localizedCaseInsensitiveContains($0) } }) { return true }

        let caption = NovelContentParser.plainCaption(n.caption)
        let text = [n.title, n.series?.title ?? "", caption, tags.joined(separator: " ")].joined(separator: " ")

        var kana = 0, han = 0, cnOnly = 0, jpOnly = 0, hangul = 0
        for ch in text {
            if chineseOnlyChars.contains(ch) { cnOnly += 1 }
            if japaneseOnlyChars.contains(ch) { jpOnly += 1 }
            for u in ch.unicodeScalars {
                switch u.value {
                case 0x3041...0x309F, 0x30A1...0x30FA, 0x31F0...0x31FF: kana += 1   // 平假名 / 片假名（不含长音符）
                case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
                case 0xAC00...0xD7AF: hangul += 1
                default: break
                }
            }
        }
        if hangul > 3 && hangul > han { return false }
        let ratio = Double(kana) / Double(max(kana + han, 1))
        // 日文：假名较多
        if kana >= 3 && ratio > 0.12 { return cnOnly >= 4 && ratio < 0.25 }
        if jpOnly > 0 && cnOnly == 0 { return false }
        if cnOnly >= 1 && ratio < 0.12 { return true }
        // 无假名、汉字为主（日文标题偶尔全是汉字，因此要求有一定数量）
        return kana == 0 && han >= 6
    }
}

/// 列表通用内容筛选（在热榜 / 关注 / 搜索之间共享）
struct ContentFilter: Equatable {
    var chineseOnly: Bool
    var r18: R18Mode
    var mutedTags: [String]

    func accept(_ n: Novel) -> Bool {
        if n.isMuted == true { return false }
        if !r18.accept(n) { return false }
        if chineseOnly && !LanguageDetector.isChinese(n) { return false }
        if !mutedTags.isEmpty {
            let tags = n.tagNames
            if mutedTags.contains(where: { m in !m.isEmpty && tags.contains { $0.localizedCaseInsensitiveContains(m) } }) {
                return false
            }
        }
        return true
    }
}
