import SwiftUI

@main
struct PixNovelApp: App {
    @StateObject private var session = SessionStore()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var library = LocalLibrary.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if session.account == nil {
                    LoginView()
                } else {
                    RootTabView()
                }
            }
            .environmentObject(session)
            .environmentObject(settings)
            .environmentObject(library)
        }
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var account: Account?

    init() {
        account = Keychain.load()
        Task {
            await TokenManager.shared.setOnChange { acc in
                Task { @MainActor in self.account = acc }
            }
        }
    }

    var isPremium: Bool { account?.isPremium ?? false }

    func login(_ acc: Account) async {
        await TokenManager.shared.set(acc)
        account = acc
    }

    func loginWithRefreshToken(_ token: String) async throws {
        let acc = try await PixivAuth.refresh(token.trimmingCharacters(in: .whitespacesAndNewlines))
        await login(acc)
    }

    func logout() async {
        await TokenManager.shared.set(nil)
        account = nil
    }
}

struct RootTabView: View {
    var body: some View {
        if #available(iOS 18.0, *) {
            // iOS 26+：悬浮玻璃底栏，搜索为独立的玻璃按钮
            TabView {
                Tab("热榜", systemImage: "flame") { NavigationStack { RankingView() } }
                Tab("关注", systemImage: "person.2") { NavigationStack { FollowingView() } }
                Tab("我的", systemImage: "person.crop.circle") { NavigationStack { LibraryView() } }
                Tab("搜索", systemImage: "magnifyingglass", role: .search) { NavigationStack { SearchView() } }
            }
            .minimizeTabBarOnScroll()
        } else {
            TabView {
                NavigationStack { RankingView() }.tabItem { Label("热榜", systemImage: "flame") }
                NavigationStack { FollowingView() }.tabItem { Label("关注", systemImage: "person.2") }
                NavigationStack { SearchView() }.tabItem { Label("搜索", systemImage: "magnifyingglass") }
                NavigationStack { LibraryView() }.tabItem { Label("我的", systemImage: "person.crop.circle") }
            }
        }
    }
}
