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
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("推荐", systemImage: "sparkles") }
            NavigationStack { RankingView() }
                .tabItem { Label("排行", systemImage: "crown") }
            NavigationStack { SearchView() }
                .tabItem { Label("热度搜索", systemImage: "flame") }
            NavigationStack { LibraryView() }
                .tabItem { Label("书架", systemImage: "books.vertical") }
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
