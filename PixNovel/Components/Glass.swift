import SwiftUI

// iOS 26+ Liquid Glass，旧系统回退到毛玻璃材质。
// 使用 compiler 检查，保证旧版 Xcode 也能编译。

extension View {
    /// 玻璃背景
    @ViewBuilder
    func glassBackground<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        #endif
    }

    /// 玻璃按钮样式
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #endif
    }

    /// 滚动时缩小底栏（iOS 26+）
    @ViewBuilder
    func minimizeTabBarOnScroll() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else { self }
        #else
        self
        #endif
    }
}

/// 列表顶部悬浮的玻璃分段选择器容器
struct GlassHeader<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(6)
            .glassBackground(Capsule())
            .padding(.horizontal)
            .padding(.vertical, 6)
    }
}

/// 筛选菜单中的「仅中文 + R18」项
struct ContentFilterMenuItems: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        Section("内容") {
            Toggle(isOn: $settings.chineseOnly) { Label("仅中文", systemImage: "textformat") }
            Picker(selection: $settings.r18Mode) {
                ForEach(R18Mode.allCases) { Text($0.title).tag($0) }
            } label: { Label("R18", systemImage: "flame") }
        }
    }
}

/// 筛选状态的简短描述
extension AppSettings {
    var filterSummary: String {
        var parts: [String] = []
        if chineseOnly { parts.append("中文") }
        switch r18Mode {
        case .all: break
        case .exclude: parts.append("不含R18")
        case .only: parts.append("仅R18")
        }
        return parts.isEmpty ? "全部内容" : parts.joined(separator: " · ")
    }
    var filterActive: Bool { chineseOnly || r18Mode != .all }
}
