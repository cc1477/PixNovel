import SwiftUI
import WebKit

struct LoginView: View {
    @EnvironmentObject var session: SessionStore
    @State private var showWeb = false
    @State private var pkce = PKCE()
    @State private var refreshToken = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "book.pages.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                        .padding(.top, 48)
                    Text("PixNovel").font(.largeTitle.bold())
                    Text("Pixiv 第三方小说阅读客户端").foregroundStyle(.secondary)

                    Button {
                        pkce = PKCE()
                        showWeb = true
                    } label: {
                        Label("使用 Pixiv 账号登录", systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("或使用 Refresh Token 登录").font(.headline)
                        TextField("粘贴 refresh_token", text: $refreshToken, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(1...3)
                        Button {
                            Task { await loginWithToken() }
                        } label: {
                            Text("登录").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(refreshToken.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }

                    if busy { ProgressView() }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }

                    Text("登录信息仅保存在本机钥匙串中，直接与 Pixiv 官方服务器通信。\n中国大陆地区需自备可访问 Pixiv 的网络环境。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .sheet(isPresented: $showWeb) {
                NavigationStack {
                    PixivLoginWebView(url: pkce.loginURL) { code in
                        showWeb = false
                        Task { await exchange(code) }
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("登录 Pixiv")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { showWeb = false } }
                    }
                }
            }
        }
    }

    private func exchange(_ code: String) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let acc = try await PixivAuth.exchange(code: code, verifier: pkce.verifier)
            await session.login(acc)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loginWithToken() async {
        busy = true; error = nil
        defer { busy = false }
        do { try await session.loginWithRefreshToken(refreshToken) }
        catch { self.error = error.localizedDescription }
    }
}

/// 拦截 pixiv://account/login?code=... 回调
struct PixivLoginWebView: UIViewRepresentable {
    let url: URL
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        private func code(in url: URL) -> String? {
            guard url.scheme == "pixiv" || url.absoluteString.hasPrefix(PixivConst.redirectURI) else { return nil }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "code" }?.value
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, let c = code(in: url) {
                decisionHandler(.cancel)
                if !done { done = true; onCode(c) }
                return
            }
            if let url = navigationAction.request.url, url.scheme == "pixiv" {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // 自定义 scheme 跳转失败时，从失败的 URL 中提取 code
            let nsError = error as NSError
            if let s = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
               let url = URL(string: s), let c = code(in: url), !done {
                done = true; onCode(c)
            }
        }
    }
}
