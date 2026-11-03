import Foundation

/// 阅读器内容块
enum ReaderBlock: Hashable {
    case chapter(String)
    case paragraph(String)
    case image(String)      // url
    case missingImage(String)
}

struct ReaderPage: Identifiable, Hashable {
    var id: Int
    var blocks: [ReaderBlock]
}

enum NovelContentParser {

    // MARK: webview HTML -> NovelContent

    static func parseWebview(html: String, id: Int) throws -> NovelContent {
        guard let json = extractJSON(html) else { throw PixivError.parse("未找到正文数据") }
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PixivError.parse("正文 JSON")
        }
        func int(_ v: Any?) -> Int? {
            if let i = v as? Int { return i }
            if let s = v as? String { return Int(s) }
            return nil
        }
        func nav(_ key: String) -> (id: Int, title: String)? {
            guard let navObj = obj["seriesNavigation"] as? [String: Any],
                  let n = navObj[key] as? [String: Any], let nid = int(n["id"]) else { return nil }
            if let viewable = n["viewable"] as? Bool, !viewable { return nil }
            return (nid, n["title"] as? String ?? "")
        }
        var uploaded: [String: String] = [:]
        if let imgs = obj["images"] as? [String: Any] {
            for (k, v) in imgs {
                guard let d = v as? [String: Any], let urls = d["urls"] as? [String: Any] else { continue }
                let u = (urls["1200x1200"] ?? urls["original"] ?? urls["480mw"]) as? String
                if let u { uploaded[k] = u }
            }
        }
        var pixivImgs: [String: String] = [:]
        if let ills = obj["illusts"] as? [String: Any] {
            for (k, v) in ills {
                guard let d = v as? [String: Any],
                      let ill = d["illust"] as? [String: Any],
                      let images = ill["images"] as? [String: Any] else { continue }
                if let u = (images["medium"] ?? images["original"] ?? images["small"]) as? String {
                    pixivImgs[k] = u
                }
            }
        }
        return NovelContent(
            id: int(obj["id"]) ?? id,
            title: obj["title"] as? String ?? "",
            text: obj["text"] as? String ?? "",
            seriesId: int(obj["seriesId"]),
            seriesTitle: obj["seriesTitle"] as? String,
            prevNovel: nav("prevNovel"),
            nextNovel: nav("nextNovel"),
            uploadedImages: uploaded,
            pixivImages: pixivImgs
        )
    }

    private static func extractJSON(_ html: String) -> String? {
        let patterns = [#"novel:\s*(\{.+\}),\s*isOwnWork"#, #"novel:\s*(\{.+\})\s*,\s*authorDetails"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            if let m = re.firstMatch(in: html, range: range), let r = Range(m.range(at: 1), in: html) {
                return String(html[r])
            }
        }
        return nil
    }

    // MARK: pixiv 小说标记 -> 页面

    static func pages(from content: NovelContent) -> [ReaderPage] {
        let normalized = content.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawPages = normalized.components(separatedBy: "[newpage]")
        var result: [ReaderPage] = []
        for (i, page) in rawPages.enumerated() {
            let blocks = parseBlocks(page, content: content)
            if !blocks.isEmpty || rawPages.count == 1 {
                result.append(ReaderPage(id: i, blocks: blocks))
            }
        }
        return result.isEmpty ? [ReaderPage(id: 0, blocks: [])] : result
    }

    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"\[chapter:(.*?)\]|\[uploadedimage:(\d+)\]|\[pixivimage:([\d\-]+)\]"#)

    private static func parseBlocks(_ text: String, content: NovelContent) -> [ReaderBlock] {
        var blocks: [ReaderBlock] = []
        let ns = text as NSString
        var cursor = 0
        func flush(_ s: String) {
            let inline = inlineMarkup(s)
            // 按行拆段，保留空行营造段落间距
            var buffer: [String] = []
            for line in inline.components(separatedBy: "\n") {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !buffer.isEmpty { blocks.append(.paragraph(buffer.joined(separator: "\n"))); buffer.removeAll() }
                } else {
                    buffer.append(line)
                }
            }
            if !buffer.isEmpty { blocks.append(.paragraph(buffer.joined(separator: "\n"))) }
        }
        for m in tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                flush(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            if m.range(at: 1).location != NSNotFound {
                blocks.append(.chapter(inlineMarkup(ns.substring(with: m.range(at: 1)))))
            } else if m.range(at: 2).location != NSNotFound {
                let key = ns.substring(with: m.range(at: 2))
                blocks.append(content.uploadedImages[key].map { .image($0) } ?? .missingImage("图片 \(key)"))
            } else if m.range(at: 3).location != NSNotFound {
                let key = ns.substring(with: m.range(at: 3))
                let base = key.components(separatedBy: "-").first ?? key
                if let u = content.pixivImages[key] ?? content.pixivImages[base] {
                    blocks.append(.image(u))
                } else {
                    blocks.append(.missingImage("插画 #\(key)"))
                }
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { flush(ns.substring(from: cursor)) }
        return blocks
    }

    private static let rubyRegex = try! NSRegularExpression(pattern: #"\[\[rb:\s*(.+?)\s*>\s*(.+?)\s*\]\]"#)
    private static let jumpUriRegex = try! NSRegularExpression(pattern: #"\[\[jumpuri:\s*(.+?)\s*>\s*(.+?)\s*\]\]"#)
    private static let jumpRegex = try! NSRegularExpression(pattern: #"\[jump:(\d+)\]"#)

    /// 行内标记：注音、链接、页内跳转
    static func inlineMarkup(_ s: String) -> String {
        var out = s
        out = rubyRegex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1（$2）")
        out = jumpUriRegex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        out = jumpRegex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "→第$1页")
        return out
    }

    /// 简介中的 HTML 清理
    static func plainCaption(_ html: String?) -> String {
        guard var s = html, !s.isEmpty else { return "" }
        s = s.replacingOccurrences(of: "<br />", with: "\n").replacingOccurrences(of: "<br>", with: "\n")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }
}
