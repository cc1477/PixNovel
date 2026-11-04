import SwiftUI

/// 顶部筛选条：仅中文 + R18 三选一（全局共享设置）
struct ContentFilterBar: View {
    @EnvironmentObject var settings: AppSettings
    var status: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button {
                settings.chineseOnly.toggle()
            } label: {
                Label("仅中文", systemImage: settings.chineseOnly ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(settings.chineseOnly ? .accentColor : .secondary)
            .controlSize(.small)

            Menu {
                Picker("R18", selection: $settings.r18Mode) {
                    ForEach(R18Mode.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label(settings.r18Mode == .all ? "R18：全部" : settings.r18Mode.title,
                      systemImage: settings.r18Mode == .exclude ? "eye.slash" : "flame")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(settings.r18Mode == .only ? .red : (settings.r18Mode == .exclude ? .green : .secondary))
            .controlSize(.small)

            Spacer(minLength: 4)
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }
}

struct ModelSortMenu: View {
    @ObservedObject var model: NovelListModel
    var defaultTitle = "默认顺序"
    var body: some View {
        SortMenu(selection: $model.localSort, defaultTitle: defaultTitle)
    }
}
