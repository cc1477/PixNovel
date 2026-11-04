import Foundation

enum PixivError: LocalizedError {
    case notLoggedIn
    case http(Int, String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "尚未登录"
        case .http(let code, let body):
            if let msg = PixivError.message(from: body) { return "请求失败(\(code))：\(msg)" }
            return "请求失败(\(code))"
        case .parse(let s): return "解析失败：\(s)"
        }
    }

    static func message(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // OAuth: {"has_error":true,"errors":{"system":{"message":"...","code":918}},"error":"invalid_request"}
        if let errs = obj["errors"] as? [String: Any], let sys = errs["system"] as? [String: Any] {
            let msg = sys["message"] as? String ?? ""
            let code = sys["code"].map { "\($0)" } ?? ""
            let kind = obj["error"] as? String ?? ""
            return [msg, kind.isEmpty ? nil : kind, code.isEmpty ? nil : "code \(code)"]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if let e = obj["error"] as? [String: Any] {
            if let m = e["message"] as? String, !m.isEmpty { return m }
            if let m = e["user_message"] as? String, !m.isEmpty { return m }
            if let m = e["reason"] as? String, !m.isEmpty { return m }
        }
        if let m = obj["message"] as? String { return m }
        return nil
    }

    var isTokenProblem: Bool {
        if case .http(let code, let body) = self {
            return code == 401 || (code == 400 && body.contains("OAuth"))
        }
        return false
    }
}

/// 排行榜模式
enum RankingMode: String, CaseIterable, Identifiable {
    case day, week, male = "day_male", female = "day_female", rookie = "week_rookie"
    case dayR18 = "day_r18", weekR18 = "week_r18", maleR18 = "day_male_r18", femaleR18 = "day_female_r18"
    case dayAI = "day_ai", dayR18AI = "day_r18_ai"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "日榜"
        case .week: return "周榜"
        case .male: return "男性向"
        case .female: return "女性向"
        case .rookie: return "新人"
        case .dayAI: return "AI 日榜"
        case .dayR18AI: return "R18 AI 日榜"
        case .dayR18: return "R18 日榜"
        case .weekR18: return "R18 周榜"
        case .maleR18: return "R18 男性向"
        case .femaleR18: return "R18 女性向"
        }
    }
    var isR18: Bool { rawValue.contains("r18") }
}

enum SearchTarget: String, CaseIterable, Identifiable {
    case partialTag = "partial_match_for_tags"
    case exactTag = "exact_match_for_tags"
    case text = "text"
    case keyword = "keyword"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .partialTag: return "标签(部分一致)"
        case .exactTag: return "标签(完全一致)"
        case .text: return "正文"
        case .keyword: return "标题/简介"
        }
    }
}

enum ServerSort: String {
    case dateDesc = "date_desc", dateAsc = "date_asc", popularDesc = "popular_desc"
}

final class PixivAPI {
    static let shared = PixivAPI()

    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg)
    }

    // MARK: 基础请求

    private func makeURL(_ path: String, _ query: [String: String?]) -> URL {
        var c = URLComponents(string: PixivConst.apiHost + path)!
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        if !items.isEmpty { c.queryItems = items.sorted { $0.name < $1.name } }
        // Pixiv 要求 + 号等需要编码
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    func raw(_ url: URL, method: String = "GET", form: [String: String]? = nil, retry: Bool = true) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        PixivHeaders.apply(to: &req)
        let token = try await TokenManager.shared.accessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let form {
            req.httpBody = FormEncoder.encode(form).data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        // 全局限速 + 429 退避重试
        var attempt = 0
        var data = Data(), code = 0
        while true {
            await RateLimiter.shared.acquire()
            do {
                let (d, resp) = try await session.data(for: req)
                await RateLimiter.shared.release()
                data = d
                code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                await RateLimiter.shared.release()
                throw error
            }
            guard code == 429, attempt < 3 else { break }
            attempt += 1
            await RateLimiter.shared.penalize(seconds: Double(1 << attempt))   // 2s / 4s / 8s
        }
        if (200..<300).contains(code) { return data }
        let err = PixivError.http(code, String(data: data, encoding: .utf8) ?? "")
        if retry && err.isTokenProblem {
            try await TokenManager.shared.refresh()
            return try await raw(url, method: method, form: form, retry: false)
        }
        throw err
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String?] = [:]) async throws -> T {
        try await decode(raw(makeURL(path, query)))
    }

    func get<T: Decodable>(next url: String) async throws -> T {
        guard let u = URL(string: url) else { throw PixivError.parse("next_url") }
        return try await decode(raw(u))
    }

    func post(_ path: String, _ form: [String: String]) async throws {
        _ = try await raw(makeURL(path, [:]), method: "POST", form: form)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) }
        catch { throw PixivError.parse(String(describing: error).prefix(300).description) }
    }

    // MARK: 小说列表

    func recommended() async throws -> NovelListResponse {
        try await get("/v1/novel/recommended", ["include_ranking_novels": "true", "filter": "for_ios", "include_privacy_policy": "true"])
    }

    func ranking(mode: RankingMode, date: Date?, force: Bool = false) async throws -> NovelListResponse {
        let url = makeURL("/v1/novel/ranking", ["mode": mode.rawValue, "filter": "for_ios",
                                                "date": date.map { PixivDate.ymd.string(from: $0) }])
        return try await decode(ResponseCache.shared.data(for: url, permanent: date != nil, force: force) { try await self.raw(url) })
    }

    /// 榜单翻页（带缓存）
    func rankingNext(_ next: String, force: Bool = false) async throws -> NovelListResponse {
        guard let url = URL(string: next) else { throw PixivError.parse("next_url") }
        let permanent = next.contains("date=")
        return try await decode(ResponseCache.shared.data(for: url, permanent: permanent, force: force) { try await self.raw(url) })
    }

    func followNew(restrict: String = "all") async throws -> NovelListResponse {
        try await get("/v1/novel/follow", ["restrict": restrict])
    }

    func newest() async throws -> NovelListResponse {
        try await get("/v1/novels", ["filter": "for_ios"])
    }

    func search(word: String, target: SearchTarget, sort: ServerSort,
                start: Date? = nil, end: Date? = nil, offset: Int? = nil) async throws -> NovelListResponse {
        try await get("/v1/search/novel", [
            "word": word,
            "search_target": target.rawValue,
            "sort": sort.rawValue,
            "merge_plain_keyword_results": "true",
            "include_translated_tag_results": "true",
            "filter": "for_ios",
            "start_date": start.map { PixivDate.ymd.string(from: $0) },
            "end_date": end.map { PixivDate.ymd.string(from: $0) },
            "offset": offset.map(String.init)
        ])
    }

    /// 非会员也可用的「热门预览」，返回按热度排序的前若干篇
    func popularPreview(word: String, target: SearchTarget, start: Date? = nil, end: Date? = nil) async throws -> NovelListResponse {
        try await get("/v1/search/popular-preview/novel", [
            "word": word,
            "search_target": target.rawValue,
            "merge_plain_keyword_results": "true",
            "include_translated_tag_results": "true",
            "filter": "for_ios",
            "start_date": start.map { PixivDate.ymd.string(from: $0) },
            "end_date": end.map { PixivDate.ymd.string(from: $0) }
        ])
    }

    func trendingTags() async throws -> TrendTagsResponse {
        try await get("/v1/trending-tags/novel", ["filter": "for_ios"])
    }

    func autocomplete(_ word: String) async throws -> AutocompleteResponse {
        try await get("/v2/search/autocomplete", ["word": word, "merge_plain_keyword_results": "true"])
    }

    // MARK: 详情 / 系列 / 用户

    func detail(_ id: Int) async throws -> Novel {
        let r: NovelDetailResponse = try await get("/v2/novel/detail", ["novel_id": String(id)])
        return r.novel
    }

    func series(_ id: Int) async throws -> SeriesResponse {
        try await get("/v2/novel/series", ["series_id": String(id)])
    }

    func user(_ id: Int) async throws -> UserDetailResponse {
        try await get("/v1/user/detail", ["user_id": String(id), "filter": "for_ios"])
    }

    func userNovels(_ id: Int) async throws -> NovelListResponse {
        try await get("/v1/user/novels", ["user_id": String(id)])
    }

    func bookmarks(userId: String, restrict: String = "public") async throws -> NovelListResponse {
        try await get("/v1/user/bookmarks/novel", ["user_id": userId, "restrict": restrict])
    }

    func following(userId: String) async throws -> UserPreviewsResponse {
        try await get("/v1/user/following", ["user_id": userId, "restrict": "public"])
    }

    // MARK: 操作

    func addBookmark(_ id: Int, restrict: String = "public") async throws {
        try await post("/v2/novel/bookmark/add", ["novel_id": String(id), "restrict": restrict])
    }

    func deleteBookmark(_ id: Int) async throws {
        try await post("/v1/novel/bookmark/delete", ["novel_id": String(id)])
    }

    func follow(_ userId: Int) async throws {
        try await post("/v1/user/follow/add", ["user_id": String(userId), "restrict": "public"])
    }

    func unfollow(_ userId: Int) async throws {
        try await post("/v1/user/follow/delete", ["user_id": String(userId)])
    }

    func addSeriesWatchlist(_ seriesId: Int) async throws {
        try await post("/v1/watchlist/novel/add", ["series_id": String(seriesId)])
    }

    // MARK: 评论

    func comments(novelId: Int) async throws -> CommentsResponse {
        do { return try await get("/v3/novel/comments", ["novel_id": String(novelId)]) }
        catch PixivError.http(404, _) { return try await get("/v1/novel/comments", ["novel_id": String(novelId)]) }
    }

    func commentReplies(_ commentId: Int) async throws -> CommentsResponse {
        try await get("/v2/novel/comment/replies", ["comment_id": String(commentId)])
    }

    func addComment(novelId: Int, text: String, parent: Int?) async throws -> PixivComment {
        var form = ["novel_id": String(novelId), "comment": text]
        if let parent { form["parent_comment_id"] = String(parent) }
        let data = try await raw(makeURL("/v1/novel/comment/add", [:]), method: "POST", form: form)
        let r: CommentAddResponse = try decode(data)
        return r.comment
    }

    // MARK: 正文

    func content(_ id: Int) async throws -> NovelContent {
        let data = try await raw(makeURL("/webview/v2/novel", ["id": String(id), "viewer_version": "20221031_ai"]))
        guard let html = String(data: data, encoding: .utf8) else { throw PixivError.parse("正文编码") }
        return try NovelContentParser.parseWebview(html: html, id: id)
    }
}


/// 全局请求限速：最多 2 个并发，相邻请求间隔 ≥ 0.3 秒；被 429 时整体暂停
actor RateLimiter {
    static let shared = RateLimiter()
    private let maxConcurrent = 2
    private let spacing: TimeInterval = 0.3
    private var running = 0
    private var nextAllowed = Date.distantPast
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        while running >= maxConcurrent {
            await withCheckedContinuation { waiters.append($0) }
        }
        running += 1
        let now = Date()
        let start = max(now, nextAllowed)
        nextAllowed = start.addingTimeInterval(spacing)
        let wait = start.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    func release() {
        running = max(0, running - 1)
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    func penalize(seconds: TimeInterval) async {
        nextAllowed = max(nextAllowed, Date().addingTimeInterval(seconds))
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// 响应缓存：内存 30 分钟；历史榜单（不会再变）写入磁盘永久缓存
actor ResponseCache {
    static let shared = ResponseCache()
    private var memory: [String: (Date, Data)] = [:]
    private let ttl: TimeInterval = 30 * 60
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("api-cache")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func data(for url: URL, permanent: Bool, force: Bool, fetch: () async throws -> Data) async throws -> Data {
        let key = url.absoluteString
        let file = dir.appendingPathComponent(Hashing.md5(key) + ".json")
        if !force {
            if let e = memory[key], Date().timeIntervalSince(e.0) < ttl { return e.1 }
            if permanent, let d = try? Data(contentsOf: file) { memory[key] = (Date(), d); return d }
        }
        let d = try await fetch()
        memory[key] = (Date(), d)
        if permanent { try? d.write(to: file, options: .atomic) }
        return d
    }

    func clear() {
        memory = [:]
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
