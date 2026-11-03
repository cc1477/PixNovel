import Foundation
import CryptoKit
import Security

enum PixivConst {
    static let clientID = "MOBrBDS8blbauoSck0ZfDbtuzpyT"
    static let clientSecret = "lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj"
    static let hashSecret = "28c1fdd170a5204386cb1313c7077b34f83e4aaf4aa829ce78c231e05b0bae2c"
    static let appVersion = "7.19.1"
    static let osVersion = "17.5"
    static let userAgent = "PixivIOSApp/\(appVersion) (iOS \(osVersion); iPhone15,2)"
    static let apiHost = "https://app-api.pixiv.net"
    static let oauthURL = URL(string: "https://oauth.secure.pixiv.net/auth/token")!
    static let redirectURI = "https://app-api.pixiv.net/web/v1/users/auth/pixiv/callback"
    static let loginBase = "https://app-api.pixiv.net/web/v1/login"
    /// OAuth 换 token 使用 Android App 的 UA（与 client=pixiv-android 保持一致）
    static let oauthUserAgent = "PixivAndroidApp/5.0.234 (Android 11; Pixel 5)"
    /// 网页登录使用桌面浏览器 UA，避免被识别为其他客户端
    static let webLoginUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
}

// MARK: - PKCE

struct PKCE {
    let verifier: String
    let challenge: String

    init() {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = Data(bytes).base64URL
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }

    var loginURL: URL {
        var c = URLComponents(string: PixivConst.loginBase)!
        c.queryItems = [
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "client", value: "pixiv-android")
        ]
        return c.url!
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum Hashing {
    static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - OAuth

struct OAuthResponse: Decodable {
    struct User: Decodable {
        var id: String
        var name: String
        var account: String
        var isPremium: Bool?
        var profileImageUrls: [String: String]?
    }
    var accessToken: String
    var refreshToken: String
    var expiresIn: Int
    var user: User
}

enum PixivAuth {
    static func exchange(code: String, verifier: String) async throws -> Account {
        try await token([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": PixivConst.redirectURI,
            "include_policy": "true"
        ])
    }

    static func refresh(_ refreshToken: String) async throws -> Account {
        try await token([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "include_policy": "true"
        ])
    }

    private static func token(_ params: [String: String]) async throws -> Account {
        var form = params
        form["client_id"] = PixivConst.clientID
        form["client_secret"] = PixivConst.clientSecret
        var req = URLRequest(url: PixivConst.oauthURL)
        req.httpMethod = "POST"
        req.httpBody = FormEncoder.encode(form).data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(PixivConst.oauthUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw PixivError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let r = try dec.decode(OAuthResponse.self, from: data)
        let avatar = r.user.profileImageUrls?.sorted { $0.key > $1.key }.first?.value
        return Account(userId: r.user.id, name: r.user.name, account: r.user.account,
                       isPremium: r.user.isPremium ?? false, avatar: avatar,
                       refreshToken: r.refreshToken, accessToken: r.accessToken,
                       expiresAt: Date().addingTimeInterval(TimeInterval(r.expiresIn - 120)))
    }
}

enum PixivHeaders {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f
    }()

    static func apply(to req: inout URLRequest) {
        let time = timeFormatter.string(from: Date())
        req.setValue(PixivConst.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("ios", forHTTPHeaderField: "App-OS")
        req.setValue(PixivConst.osVersion, forHTTPHeaderField: "App-OS-Version")
        req.setValue(PixivConst.appVersion, forHTTPHeaderField: "App-Version")
        req.setValue("zh-hans", forHTTPHeaderField: "Accept-Language")
        req.setValue(time, forHTTPHeaderField: "X-Client-Time")
        req.setValue(Hashing.md5(time + PixivConst.hashSecret), forHTTPHeaderField: "X-Client-Hash")
    }
}

enum FormEncoder {
    static let allowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()
    static func encode(_ dict: [String: String]) -> String {
        dict.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.pixnovel.account"

    static func save(_ account: Account?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: "default"]
        SecItemDelete(base as CFDictionary)
        guard let account, let data = try? JSONEncoder().encode(account) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> Account? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: "default",
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }
}

// MARK: - Token 管理（串行刷新）

actor TokenManager {
    static let shared = TokenManager()

    private(set) var account: Account? = Keychain.load()
    private var refreshing: Task<Account, Error>?
    var onChange: (@Sendable (Account?) -> Void)?

    func setOnChange(_ f: @escaping @Sendable (Account?) -> Void) { onChange = f }

    func set(_ a: Account?) {
        account = a
        Keychain.save(a)
        onChange?(a)
    }

    func accessToken() async throws -> String {
        guard let a = account else { throw PixivError.notLoggedIn }
        if a.expiresAt > Date() { return a.accessToken }
        return try await refresh().accessToken
    }

    @discardableResult
    func refresh() async throws -> Account {
        if let refreshing { return try await refreshing.value }
        guard let a = account else { throw PixivError.notLoggedIn }
        let t = Task { try await PixivAuth.refresh(a.refreshToken) }
        refreshing = t
        defer { refreshing = nil }
        let new = try await t.value
        set(new)
        return new
    }
}
