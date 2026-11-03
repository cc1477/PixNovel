import SwiftUI

struct HomeView: View {
    enum Feed: String, CaseIterable, Identifiable {
        case recommended = "推荐", follow = "关注新作", newest = "最新"
        var id: String { rawValue }
    }

    @State private var feed: Feed = .recommended
    @StateObject private var recommended = NovelListModel { try await PixivAPI.shared.recommended() }
    @StateObject private var follow = NovelListModel { try await PixivAPI.shared.followNew() }
    @StateObject private var newest = NovelListModel { try await PixivAPI.shared.newest() }

    private var model: NovelListModel {
        switch feed {
        case .recommended: return recommended
        case .follow: return follow
        case .newest: return newest
        }
    }

    var body: some View {
        NovelListContent(model: model)
            .safeAreaInset(edge: .top) {
                Picker("", selection: $feed) {
                    ForEach(Feed.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.bottom, 6)
                .background(.bar)
            }
            .navigationTitle("推荐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ModelSortMenu(model: model)
                }
            }
            .task(id: feed) {
                if model.items.isEmpty { await model.refresh() }
            }
            .pixivDestinations()
    }
}

struct ModelSortMenu: View {
    @ObservedObject var model: NovelListModel
    var defaultTitle = "默认顺序"
    var body: some View {
        SortMenu(selection: $model.localSort, defaultTitle: defaultTitle)
    }
}
