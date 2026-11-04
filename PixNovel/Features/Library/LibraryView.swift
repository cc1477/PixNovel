import SwiftUI

struct LibraryView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case history = "阅读历史", publicBM = "公开收藏", privateBM = "私密收藏"
        var id: String { rawValue }
    }

    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var library: LocalLibrary
    @State private var tab: Tab = .history
    // 收藏夹不按中文 / R18 筛选
    @StateObject private var publicModel = NovelListModel(contentFilter: false) { throw PixivError.notLoggedIn }
    @StateObject private var privateModel = NovelListModel(contentFilter: false) { throw PixivError.notLoggedIn }

    var body: some View {
        Group {
            switch tab {
            case .history: historyList
            case .publicBM: NovelListContent(model: publicModel)
            case .privateBM: NovelListContent(model: privateModel)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.bottom, 6)
            .background(.bar)
        }
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                switch tab {
                case .history:
                    Menu {
                        Button("清空历史", role: .destructive) { library.clear() }
                    } label: { Image(systemName: "ellipsis.circle") }
                case .publicBM:
                    SortMenu(selection: $publicModel.localSort, defaultTitle: "收藏时间")
                case .privateBM:
                    SortMenu(selection: $privateModel.localSort, defaultTitle: "收藏时间")
                }
            }
        }
        .task(id: tab) {
            guard let uid = session.account?.userId else { return }
            switch tab {
            case .history: break
            case .publicBM:
                if publicModel.items.isEmpty {
                    publicModel.setLoader { try await PixivAPI.shared.bookmarks(userId: uid, restrict: "public") }
                    await publicModel.refresh()
                }
            case .privateBM:
                if privateModel.items.isEmpty {
                    privateModel.setLoader { try await PixivAPI.shared.bookmarks(userId: uid, restrict: "private") }
                    await privateModel.refresh()
                }
            }
        }
        .pixivDestinations()
    }

    private var historyList: some View {
        List {
            if library.history.isEmpty {
                Text("还没有阅读记录").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            ForEach(library.history) { r in
                NavigationLink(value: Route.reader(r.novel)) {
                    VStack(alignment: .leading, spacing: 4) {
                        NovelRow(novel: r.novel)
                        HStack {
                            ProgressView(value: r.percent).frame(maxWidth: 160)
                            Text(String(format: "%.0f%%", r.percent * 100)).font(.caption2.monospacedDigit())
                            Spacer()
                            Text(r.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("删除", role: .destructive) { library.remove(r.id) }
                    NavigationLink(value: Route.novel(r.novel)) { Text("详情") }.tint(.blue)
                }
            }
        }
        .listStyle(.plain)
    }
}
