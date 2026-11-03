import SwiftUI
import WebKit
import AuthenticationServices

/// 登录流程状态（引用类型，确保生成 challenge 的 verifier 与换 token 时用的是同一个）
@MainActor
final class LoginFlow: NSObject, ObservableObject {
    @Published var busy = false
    @Published var error: String?
    @Published var showWeb = false

    private(set) var pkce = PKCE()
    private(set) var loginURL: URL = PKCE().loginURL
    private var authSession: ASWebAuthenticationSession?
    /// WebView 实际加载的首个 URL 中的 challenge（诊断用）
    var loadedChallenge: String?
    var visitedHosts: [String] = []

    var onAccount: ((Account) async -> Void)?

    private func newPKCE() {
        pkce = PKCE()
        loginURL = pkce.loginURL
        loadedChallenge = nil
        visitedHosts = []
        error = nil
    }

    // MARK: 方式一：系统 Safari 登录（ASWebAuthenticationSession）

    func startSafari() {
        newPKCE()
        let s = ASWebAuthenticationSession(url: loginURL, callbackURLScheme: "pixiv") { [weak self] url, err in
            Task { @MainActor in
                guard let self else { return }
                self.authSession = nil
                if let err {
                    if (err as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
                    self.error = "Safari 登录失败：\(err.localizedDescription)"
                    return
                }
                guard let url, let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value else {
                    self.error = "未从回调中获取到 code：\(url?.absoluteString ?? "-")"
                    return
                }
                self.loadedChallenge = self.pkce.challenge
                await self.exchange(code, source: "Safari")
            }
        }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIWindow()
        let provider = AnchorProvider(window)
        anchorProvider = provider
        s.presentationContextProvider = provider
        s.prefersEphemeralWebBrowserSession = false
        authSession = s
        if !s.start() { error = "无法启动 Safari 登录" }
    }

    private var anchorProvider: AnchorProvider?

    // MARK: 方式二：内置 WebView 登录

    func startWebView() {
        newPKCE()
        showWeb = true
    }

    func webViewGotCode(_ code: String, source: String) {
        showWeb = false
        Task { await exchange(code, source: source) }
    }

    // MARK: 换 token

    func exchange(_ code: String, source: String) async {
        busy = true; error = nil
        defer { busy = false }
        let verifier = pkce.verifier
        do {
            let acc = try await PixivAuth.exchange(code: code, verifier: verifier)
            await onAccount?(acc)
        } catch {
            let expected = pkce.challenge
            let match: String
            if let lc = loadedChallenge { match = lc == expected ? "一致" : "不一致(\(lc.prefix(6))… vs \(expected.prefix(6))…)" }
            else { match = "未记录" }
            self.error = error.localizedDescription
                + "\n[诊断] 来源 \(source) · code 长度 \(code.count) · verifier \(verifier.count) · challenge \(match)"
                + (visitedHosts.isEmpty ? "" : "\n跳转：" + visitedHosts.joined(separator: " → "))
        }
    }
}

final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor
    init(_ anchor: ASPresentationAnchor) { self.anchor = anchor }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
}

struct LoginView: View {
    @EnvironmentObject var session: SessionStore
    @StateObject private var flow = LoginFlow()
    @State private var refreshToken = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "book.pages.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                        .padding(.top, 40)
                    Text("PixNovel").font(.largeTitle.bold())
                    Text("Pixiv 第三方小说阅读客户端").foregroundStyle(.secondary)

                    Button { flow.startSafari() } label: {
                        Label("使用 Safari 登录 Pixiv（推荐）", systemImage: "safari")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(flow.busy)

                    Button { flow.startWebView() } label: {
                        Label("使用内置网页登录", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(flow.busy)

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
                        .disabled(refreshToken.trimmingCharacters(in: .whitespaces).isEmpty || flow.busy)
                    }
                    .padding(.top, 8)

                    if flow.busy { ProgressView() }
                    if let error = flow.error {
                        Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }

                    Text("登录信息仅保存在本机钥匙串中，直接与 Pixiv 官方服务器通信。\n中国大陆地区需自备可访问 Pixiv 的网络环境。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .sheet(isPresented: $flow.showWeb) {
                NavigationStack {
                    PixivLoginWebView(flow: flow)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle("登录 Pixiv")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { flow.showWeb = false } }
                        }
                }
            }
            .onAppear {
                flow.onAccount = { acc in await session.login(acc) }
            }
        }
    }

    private func loginWithToken() async {
        flow.busy = true; flow.error = nil
        defer { flow.busy = false }
        do { try await session.loginWithRefreshToken(refreshToken) }
        catch { flow.error = error.localizedDescription }
    }
}

/// 拦截 pixiv://account/login?code=... 回调
struct PixivLoginWebView: UIViewRepresentable {
    let flow: LoginFlow

    func makeCoordinator() -> Coordinator {
        let f = flow
        return Coordinator(onCode: { code, source in f.webViewGotCode(code, source: source) },
                           onVisit: { url in
                               if f.loadedChallenge == nil,
                                  let c = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                                    .queryItems?.first(where: { $0.name == "code_challenge" })?.value {
                                   f.loadedChallenge = c
                               }
                               if let h = url.host, f.visitedHosts.last != h { f.visitedHosts.append(h) }
                               if url.scheme == "pixiv" { f.visitedHosts.append("pixiv://") }
                           })
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: flow.loginURL))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCode: @MainActor (String, String) -> Void
        let onVisit: @MainActor (URL) -> Void
        private var done = false
        /// callback 页面上的 code，仅作兜底：正常情况下 callback 会再跳转到 pixiv://account/login?code=...
        private var callbackCode: String?

        init(onCode: @escaping @MainActor (String, String) -> Void, onVisit: @escaping @MainActor (URL) -> Void) {
            self.onCode = onCode; self.onVisit = onVisit
        }

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
            if navigationAction.targetFrame?.isMainFrame != false { onVisit(url) }
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
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.finish(c, "callback")
            }
        }
    }
}
