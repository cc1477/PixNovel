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
                    PixivLoginWebView(url: pkce.loginURL) { code, source in
                        showWeb = false
                        Task { await exchange(code, source: source) }
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

    private func exchange(_ code: String, source: String) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let acc = try await PixivAuth.exchange(code: code, verifier: pkce.verifier)
            await session.login(acc)
        } catch {
            self.error = error.localizedDescription
                + "\n[诊断] code 来源：\(source)，长度 \(code.count)，verifier 长度 \(pkce.verifier.count)"
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
    let onCode: (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: (String, String) -> Void
        private var done = false
        /// callback 页面上的 code，仅作兜底：正常情况下 callback 会再跳转到 pixiv://account/login?code=...
        private var callbackCode: String?

        init(onCode: @escaping (String, String) -> Void) { self.onCode = onCode }

        private func codeParam(_ url: URL) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "code" }?.value
        }

        private func finish(_ code: String, _ source: String) {
            guard !done else { return }
            done = true
            onCode(code, source)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
            if url.scheme == "pixiv" {
                decisionHandler(.cancel)
                if let c = codeParam(url) { finish(c, "pixiv://") }
                return
            }
            if url.absoluteString.hasPrefix(PixivConst.redirectURI), let c = codeParam(url) {
                callbackCode = c
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // 跳转到自定义 scheme 失败时，从失败的 URL 中取 code
            let nsError = error as NSError
            if let s = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
               let url = URL(string: s), url.scheme == "pixiv", let c = codeParam(url) {
                finish(c, "pixiv://(失败回调)")
                return
            }
            fallbackToCallback(after: 1.5)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let u = webView.url, u.absoluteString.hasPrefix(PixivConst.redirectURI) {
                fallbackToCallback(after: 2.0)
            }
        }

        private func fallbackToCallback(after delay: Double) {
            guard let c = callbackCode else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.finish(c, "callback")
            }
        }
    }
}
