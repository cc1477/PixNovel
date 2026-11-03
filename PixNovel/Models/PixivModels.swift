import Foundation

// MARK: - 通用

struct ImageUrls: Codable, Hashable {
    var squareMedium: String?
    var medium: String?
    var large: String?

    var best: String? { large ?? medium ?? squareMedium }
}

struct ProfileImageUrls: Codable, Hashable {
    var medium: String?
}

struct PixivUser: Codable, Hashable, Identifiable {
    var id: Int
    var name: String
    var account: String?
    var profileImageUrls: ProfileImageUrls?
    var isFollowed: Bool?
    var comment: String?
}

struct PixivTag: Codable, Hashable {
    var name: String
    var translatedName: String?
    var addedByUploadedUser: Bool?
}

struct SeriesRef: Codable, Hashable {
    var id: Int?
    var title: String?
}

// MARK: - 小说

struct Novel: Codable, Identifiable, Hashable {
    var id: Int
    var title: String
    var caption: String?
    var restrict: Int?
    var xRestrict: Int?
    var isOriginal: Bool?
    var imageUrls: ImageUrls?
    var createDate: String?
    var tags: [PixivTag]?
    var pageCount: Int?
    var textLength: Int?
    var user: PixivUser
    var series: SeriesRef?
    var isBookmarked: Bool?
    var totalBookmarks: Int?
    var totalView: Int?
    var visible: Bool?
    var totalComments: Int?
    var isMuted: Bool?
    var isMypixivOnly: Bool?
    var isXRestricted: Bool?
    var novelAiType: Int?

    static func == (lhs: Novel, rhs: Novel) -> Bool { lhs.id == rhs.id && lhs.isBookmarked == rhs.isBookmarked }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var bookmarks: Int { totalBookmarks ?? 0 }
    var views: Int { totalView ?? 0 }
    var length: Int { textLength ?? 0 }
    var isR18: Bool { (xRestrict ?? 0) > 0 }
    var isAI: Bool { (novelAiType ?? 0) == 2 }
    var tagNames: [String] { (tags ?? []).map(\.name) }

    var created: Date? { PixivDate.parse(createDate) }

    /// 小时级作品年龄
    var ageHours: Double {
        guard let created else { return 24 * 365 }
        return max(0, Date().timeIntervalSince(created) / 3600)
    }
}

enum PixivDate {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s)
    }
    static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

struct NovelListResponse: Decodable {
    var novels: [Novel]
    var nextUrl: String?
    var rankingNovels: [Novel]?
}

struct NovelDetailResponse: Decodable {
    var novel: Novel
}

struct SeriesDetail: Decodable, Hashable {
    var id: Int
    var title: String
    var caption: String?
    var isOriginal: Bool?
    var isConcluded: Bool?
    var contentCount: Int?
    var totalCharacterCount: Int?
    var user: PixivUser?
    var displayText: String?
    var watchlistAdded: Bool?
}

struct SeriesResponse: Decodable {
    var novelSeriesDetail: SeriesDetail
    var novelSeriesFirstNovel: Novel?
    var novelSeriesLatestNovel: Novel?
    var novels: [Novel]
    var nextUrl: String?
}

struct UserDetailResponse: Decodable {
    struct Profile: Decodable { var totalNovels: Int?; var totalFollowUsers: Int?; var webpage: String? }
    var user: PixivUser
    var profile: Profile?
}

struct UserPreview: Decodable, Identifiable {
    var user: PixivUser
    var novels: [Novel]?
    var id: Int { user.id }
}

struct UserPreviewsResponse: Decodable {
    var userPreviews: [UserPreview]
    var nextUrl: String?
}

struct TrendTag: Decodable, Hashable {
    var tag: String
    var translatedName: String?
}

struct TrendTagsResponse: Decodable {
    var trendTags: [TrendTag]
}

struct AutocompleteResponse: Decodable {
    var tags: [PixivTag]
}

struct EmptyResponse: Decodable {}

// MARK: - 正文 (webview/v2/novel 内嵌 JSON)

struct NovelContent {
    var id: Int
    var title: String
    var text: String
    var seriesId: Int?
    var seriesTitle: String?
    var prevNovel: (id: Int, title: String)?
    var nextNovel: (id: Int, title: String)?
    /// [uploadedimage:id] -> url
    var uploadedImages: [String: String]
    /// [pixivimage:illustId(-page)] -> url
    var pixivImages: [String: String]
}

// MARK: - 账号

struct Account: Codable, Equatable {
    var userId: String
    var name: String
    var account: String
    var isPremium: Bool
    var avatar: String?
    var refreshToken: String
    var accessToken: String
    var expiresAt: Date
}
