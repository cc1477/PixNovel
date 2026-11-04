import SwiftUI

@MainActor
final class CommentsModel: ObservableObject {
    let novelId: Int
    @Published private(set) var comments: [PixivComment] = []
    @Published private(set) var replies: [Int: [PixivComment]] = [:]
    @Published private(set) var loadingReplies = Set<Int>()
    @Published private(set) var loading = false
    @Published private(set) var total: Int?
    @Published var error: String?
    private var next: String?

    init(novelId: Int) { self.novelId = novelId }

    var canLoadMore: Bool { next != nil && !loading }

    func refresh() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let r = try await PixivAPI.shared.comments(novelId: novelId)
            comments = r.comments
            next = r.nextUrl
            total = r.totalComments
            replies = [:]
        } catch { self.error = error.localizedDescription }
    }

    func loadMore() async {
        guard let n = next, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let r: CommentsResponse = try await PixivAPI.shared.get(next: n)
            let seen = Set(comments.map(\.id))
            comments += r.comments.filter { !seen.contains($0.id) }
            next = r.nextUrl
        } catch { self.error = error.localizedDescription }
    }

    func toggleReplies(_ c: PixivComment) async {
        if replies[c.id] != nil { replies[c.id] = nil; return }
        loadingReplies.insert(c.id)
        defer { loadingReplies.remove(c.id) }
        do {
            var r = try await PixivAPI.shared.commentReplies(c.id)
            var all = r.comments
            while let n = r.nextUrl, all.count < 200 {
                r = try await PixivAPI.shared.get(next: n)
                all += r.comments
            }
            replies[c.id] = all
        } catch { self.error = error.localizedDescription }
    }

    func send(_ text: String, replyTo parent: PixivComment?) async -> Bool {
        do {
            let c = try await PixivAPI.shared.addComment(novelId: novelId, text: text, parent: parent?.id)
            if let parent {
                replies[parent.id, default: []].append(c)
                if let i = comments.firstIndex(where: { $0.id == parent.id }) { comments[i].hasReplies = true }
            } else {
                comments.insert(c, at: 0)
                total = (total ?? 0) + 1
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

/// 评论区（作品详情与阅读器共用，以 sheet 形式展示）
struct CommentsView: View {
    @StateObject private var model: CommentsModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var replyTo: PixivComment?
    @State private var sending = false
    @FocusState private var focused: Bool
    let title: String

    init(novelId: Int, title: String) {
        _model = StateObject(wrappedValue: CommentsModel(novelId: novelId))
        self.title = title
    }

    var body: some View {
        NavigationStack {
            List {
                if model.comments.isEmpty && !model.loading {
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.secondary)
                        Text(model.error ?? "还没有评论，来写第一条吧").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowSeparator(.hidden)
                }
                ForEach(model.comments) { c in
                    CommentRow(comment: c, onReply: { startReply(c) })
                        .onAppear { if c.id == model.comments.last?.id { Task { await model.loadMore() } } }
                    if c.hasReplies == true || model.replies[c.id] != nil {
                        Button {
                            Task { await model.toggleReplies(c) }
                        } label: {
                            HStack(spacing: 6) {
                                Rectangle().frame(width: 20, height: 1)
                                if model.loadingReplies.contains(c.id) { ProgressView().controlSize(.mini) }
                                Text(model.replies[c.id] == nil ? "查看回复" : "收起回复（\(model.replies[c.id]?.count ?? 0)）")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .padding(.leading, 46)
                        .listRowSeparator(.hidden)
                    }
                    ForEach(model.replies[c.id] ?? []) { r in
                        CommentRow(comment: r, small: true, onReply: { startReply(c) })
                            .padding(.leading, 46)
                            .listRowSeparator(.hidden)
                    }
                }
                if model.loading { ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden) }
            }
            .listStyle(.plain)
            .refreshable { await model.refresh() }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle(model.total.map { "评论 \($0)" } ?? "评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .task { if model.comments.isEmpty { await model.refresh() } }
            .pixivDestinations()
        }
    }

    private func startReply(_ c: PixivComment) {
        replyTo = c
        focused = true
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let r = replyTo {
                HStack {
                    Text("回复 @\(r.user.name)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { replyTo = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                TextField(replyTo == nil ? "写评论…" : "写回复…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .glassBackground(RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    sending = true
                    Task {
                        if await model.send(text, replyTo: replyTo) { draft = ""; replyTo = nil; focused = false }
                        sending = false
                    }
                } label: {
                    if sending { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title) }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
            if let e = model.error, !model.comments.isEmpty {
                Text(e).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}

/// pixiv 评论表情 (xxx) -> emoji
enum PixivEmoji {
    static let map: [String: String] = [
        "normal": "🙂", "surprise": "😮", "serious": "😐", "heaven": "😇", "happy": "😄", "excited": "🤩",
        "sing": "🎵", "cry": "😢", "normal2": "😊", "shame2": "😳", "love2": "😍", "interesting2": "😆",
        "blush2": "☺️", "fire2": "🔥", "angry2": "😠", "shine2": "✨", "panic2": "😱", "normal3": "😌",
        "satisfaction3": "😋", "surprise3": "😲", "smile4": "😁", "shock4": "😨", "gaze4": "👀",
        "wink5": "😉", "happy5": "😃", "excited5": "🥳", "love5": "🥰", "mischievous": "😏",
        "dog": "🐶", "cat": "🐱", "kiss": "😘", "deny": "🙅", "rich": "🤑", "embarrassed": "😅",
        "shy": "🙈", "good": "👍", "beer": "🍺", "luck": "🍀", "heart": "❤️", "cool": "😎", "pout": "😤",
        "yawn": "🥱", "sleepy": "😪", "laugh": "🤣", "awkward": "😬", "sweat": "😓", "sad": "😞"
    ]
    private static let re = try! NSRegularExpression(pattern: #"\(([a-z]+[0-9]?)\)"#)
    static func replace(_ s: String) -> String {
        let ns = s as NSString
        var out = s
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let key = ns.substring(with: m.range(at: 1))
            if let e = map[key], let r = Range(m.range, in: out) { out.replaceSubrange(r, with: e) }
        }
        return out
    }
}

struct CommentRow: View {
    let comment: PixivComment
    var small = false
    let onReply: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PximgImage(url: comment.user.profileImageUrls?.medium)
                .frame(width: small ? 26 : 36, height: small ? 26 : 36)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(comment.user.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(RelativeTime.string(PixivDate.parse(comment.date))).font(.caption2).foregroundStyle(.secondary)
                }
                if let s = comment.stamp?.stampUrl {
                    PximgImage(url: s, contentMode: .fit).frame(width: 72, height: 72)
                } else {
                    Text(PixivEmoji.replace(comment.comment ?? "")).font(small ? .footnote : .callout).textSelection(.enabled)
                }
                Button("回复", action: onReply).font(.caption).foregroundStyle(.secondary).buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}
