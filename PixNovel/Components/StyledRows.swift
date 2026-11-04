import SwiftUI

enum RelativeTime {
    private static let f: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()
    static func string(_ d: Date?) -> String {
        guard let d else { return "" }
        if Date().timeIntervalSince(d) < 60 { return "刚刚" }
        return f.localizedString(for: d, relativeTo: Date())
    }
}

enum Medal {
    static func color(_ rank: Int) -> Color {
        switch rank {
        case 1: return Color(red: 0.96, green: 0.68, blue: 0.10)
        case 2: return Color(red: 0.62, green: 0.65, blue: 0.70)
        case 3: return Color(red: 0.80, green: 0.50, blue: 0.25)
        default: return .secondary
        }
    }
}

// MARK: - 热榜：前三名大卡片

struct PodiumCard: View {
    let novel: Novel
    let rank: Int

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PximgImage(url: novel.imageUrls?.best)
                .frame(width: 150, height: 210)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(novel.title).font(.subheadline.bold()).lineLimit(2)
                HStack(spacing: 6) {
                    Label(NumberFmt.short(novel.bookmarks), systemImage: "heart.fill")
                    Text("\(NumberFmt.short(novel.length))字")
                }
                .font(.caption2)
                .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(10)
        }
        .frame(width: 150, height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topLeading) {
            ZStack {
                Image(systemName: "seal.fill").font(.system(size: 34)).foregroundStyle(Medal.color(rank))
                Text("\(rank)").font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            }
            .shadow(radius: 3)
            .padding(8)
        }
        .overlay(alignment: .topTrailing) {
            if novel.isR18 { PillTag("R18", .red).padding(10) }
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - 热榜：第 4 名起的紧凑行

struct RankedRow: View {
    let novel: Novel
    let rank: Int?
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(rank.map(String.init) ?? "–")
                .font(.system(size: (rank ?? 99) < 100 ? 22 : 17, weight: .heavy, design: .rounded))
                .foregroundStyle((rank ?? 99) <= 3 ? Medal.color(rank ?? 99) : Color.secondary.opacity(0.6))
                .frame(width: 40)
                .monospacedDigit()
            PximgImage(url: novel.imageUrls?.medium)
                .frame(width: 52, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if novel.isR18 { PillTag("R18", .red) }
                    Text(novel.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                Text(novel.user.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 10) {
                    Label(NumberFmt.short(novel.bookmarks), systemImage: novel.isBookmarked == true ? "heart.fill" : "heart")
                        .foregroundStyle(novel.isBookmarked == true ? .pink : .orange)
                    Text("\(NumberFmt.short(novel.length))字")
                    if let badge { Text(badge) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 关注：时间线条目

struct TimelineRow: View {
    let novel: Novel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PximgImage(url: novel.user.profileImageUrls?.medium)
                    .frame(width: 32, height: 32).clipShape(Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(novel.user.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("发布了新小说 · \(RelativeTime.string(novel.created))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if novel.isR18 { PillTag("R18", .red) }
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(novel.title).font(.headline).lineLimit(2)
                    if let s = novel.series, let t = s.title, s.id != nil {
                        Label(t, systemImage: "books.vertical").font(.caption).foregroundStyle(.teal).lineLimit(1)
                    }
                    let cap = NovelContentParser.plainCaption(novel.caption)
                    if !cap.isEmpty {
                        Text(cap).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
                PximgImage(url: novel.imageUrls?.medium)
                    .frame(width: 64, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 14) {
                Label(NumberFmt.short(novel.bookmarks), systemImage: novel.isBookmarked == true ? "heart.fill" : "heart")
                    .foregroundStyle(novel.isBookmarked == true ? .pink : .secondary)
                Label(NumberFmt.short(novel.views), systemImage: "eye")
                Label("\(NumberFmt.short(novel.length))字", systemImage: "doc.text")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
