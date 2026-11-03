import SwiftUI

struct RankingView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var mode: RankingMode = .day
    @State private var date: Date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var useDate = false
    @State private var showDate = false
    @State private var expanding = false
    @StateObject private var model = NovelListModel { try await PixivAPI.shared.ranking(mode: .day, date: nil) }

    private var modes: [RankingMode] {
        RankingMode.allCases.filter { settings.showR18 || !$0.isR18 }
    }

    var body: some View {
        NovelListContent(model: model, showRank: true)
            .safeAreaInset(edge: .top) {
                VStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(modes) { m in
                                Button(m.title) { mode = m }
                                    .buttonStyle(.bordered)
                                    .tint(mode == m ? .accentColor : .secondary)
                                    .controlSize(.small)
                            }
                        }.padding(.horizontal)
                    }
                    if model.localSort != nil {
                        HStack {
                            Image(systemName: "info.circle")
                            Text("已按「\(model.localSort!.title)」重排当前已加载的 \(model.items.count) 篇")
                            Spacer()
                            Button(expanding ? "加载中…" : "扩展到前 300") {
                                Task { expanding = true; await model.loadPages(10); expanding = false }
                            }
                            .disabled(expanding || model.nextURL == nil)
                        }
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    }
                }
                .padding(.bottom, 6)
                .background(.bar)
            }
            .navigationTitle(useDate ? "排行 · \(PixivDate.ymd.string(from: date))" : "排行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showDate = true } label: { Image(systemName: "calendar") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    SortMenu(selection: $model.localSort, defaultTitle: "榜单顺序")
                }
            }
            .sheet(isPresented: $showDate) {
                NavigationStack {
                    Form {
                        Toggle("查看历史榜单", isOn: $useDate)
                        if useDate {
                            DatePicker("日期", selection: $date, in: ...Date().addingTimeInterval(-86400), displayedComponents: .date)
                                .datePickerStyle(.graphical)
                        }
                    }
                    .navigationTitle("选择日期")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showDate = false } } }
                }
                .presentationDetents([.medium, .large])
            }
            .task(id: "\(mode.rawValue)|\(useDate)|\(PixivDate.ymd.string(from: date))") {
                let m = mode, d = useDate ? date : nil
                model.setLoader { try await PixivAPI.shared.ranking(mode: m, date: d) }
                await model.refresh()
            }
            .pixivDestinations()
    }
}
