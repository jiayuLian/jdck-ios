import SwiftUI
import WebKit

/// 用 WKWebView 加载京东 H5 登录页，登录完成后从共享 Cookie 存储里抓取 pt_key / pt_pin。
struct LoginWebView: UIViewRepresentable {
    let url: URL
    var onCookieExtracted: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 使用默认 WKWebsiteDataStore，这样 getAllCookies 才能读到登录后写入的 cookie
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.bounces = true
        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = true
        wv.load(req)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: LoginWebView
        init(_ parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            extractCookies()
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            extractCookies()
            decisionHandler(.allow)
        }

        private func extractCookies() {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let jd = cookies.filter {
                    $0.domain.contains("jd.com") &&
                    ($0.name == "pt_key" || $0.name == "pt_pin")
                }
                guard let pk = jd.first(where: { $0.name == "pt_key" }),
                      let pp = jd.first(where: { $0.name == "pt_pin" }) else { return }
                let cookie = "pt_key=\(pk.value);pt_pin=\(pp.value);"
                DispatchQueue.main.async { self.parent.onCookieExtracted(cookie) }
            }
        }
    }
}
