import SwiftUI
import UIKit

/// i.pximg.net 需要 Referer，AsyncImage 不支持自定义头，故自行实现
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 300 << 20)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
        cache.totalCostLimit = 80 << 20
    }

    func clear() {
        cache.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async throws -> UIImage {
        if let img = cached(url) { return img }
        var req = URLRequest(url: url)
        req.setValue("https://app-api.pixiv.net/", forHTTPHeaderField: "Referer")
        req.setValue(PixivConst.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        guard let img = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        cache.setObject(img, forKey: url as NSURL, cost: data.count)
        return img
    }
}

struct PximgImage: View {
    let url: String?
    var contentMode: ContentMode = .fill

    @EnvironmentObject private var settings: AppSettings
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        let resolved = settings.imageURL(url)
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.12))
                    .overlay {
                        Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: resolved) {
            guard let resolved else { return }
            if let c = ImageLoader.shared.cached(resolved) { image = c; return }
            do { image = try await ImageLoader.shared.load(resolved) } catch { failed = true }
        }
    }
}

/// 阅读器中的插图：按原始比例显示
struct ReaderImage: View {
    let url: String
    @State private var image: UIImage?
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task {
            guard let u = settings.imageURL(url) else { return }
            image = try? await ImageLoader.shared.load(u)
        }
    }
}
