import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var settings: AppSettings
    @State private var mutedText = ""
    @State private var showToken = false
    @State private var confirmLogout = false

    var body: some View {
        Form {
            if let a = session.account {
                Section("账号") {
                    HStack(spacing: 12) {
                        PximgImage(url: a.avatar).frame(width: 44, height: 44).clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(a.name).font(.headline)
                            Text("@\(a.account)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if a.isPremium { PillTag("Premium", .orange) }
                    }
                    Button(showToken ? "隐藏 Refresh Token" : "显示 Refresh Token") { showToken.toggle() }
                    if showToken {
                        Text(a.refreshToken).font(.caption.monospaced()).textSelection(.enabled)
                        Button("复制") { UIPasteboard.general.string = a.refreshToken }
                    }
                    Button("退出登录", role: .destructive) { confirmLogout = true }
                }
            }

            Section {
                Picker("默认排序指标", selection: $settings.defaultMetric) {
                    ForEach(HotMetric.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                Stepper("默认扫描深度：\(settings.scanDepth) 页", value: $settings.scanDepth, in: 1...166)
                VStack(alignment: .leading) {
                    Text(String(format: "综合热度时间衰减：%.2f", settings.hotGravity))
                    Slider(value: $settings.hotGravity, in: 0...2, step: 0.05)
                    Text("0 = 不考虑发布时间；越大越偏向新作品").font(.caption).foregroundStyle(.secondary)
                }
                if session.isPremium {
                    Toggle("会员优先使用服务端热门排序", isOn: $settings.preferServerPopular)
                }
            } header: { Text("热度排序") }

            Section {
                Toggle("显示 R-18 内容", isOn: $settings.showR18)
                TextField("屏蔽标签（空格分隔）", text: $mutedText)
                    .onSubmit { saveMuted() }
                Button("保存屏蔽标签") { saveMuted() }
            } header: { Text("内容") } footer: {
                Text("R-18 内容还需在 Pixiv 网页版「浏览限制」中开启。")
            }

            Section {
                Picker("图片代理", selection: $settings.imageProxy) {
                    Text("直连 i.pximg.net").tag("")
                    Text("i.pixiv.re").tag("i.pixiv.re")
                    Text("i.pixiv.cat").tag("i.pixiv.cat")
                }
                Button("清除图片缓存") { ImageLoader.shared.clear() }
            } header: { Text("网络") }

            Section("阅读") {
                NavigationLink("阅读器设置") { ReaderSettingsSheet() }
            }

            Section("关于") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                Text("PixNovel 是开源的 Pixiv 第三方小说客户端，与 pixiv Inc. 无关。作品版权归原作者所有。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .onAppear { mutedText = settings.mutedTags.joined(separator: " ") }
        .confirmationDialog("确定退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await session.logout() } }
        }
    }

    private func saveMuted() {
        settings.mutedTags = mutedText.split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
    }
}
