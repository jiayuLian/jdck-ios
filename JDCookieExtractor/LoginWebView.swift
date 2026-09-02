import SwiftUI
import WebKit

/// 持有 WKWebView 引用，支持手动触发提取
final class WebViewController: ObservableObject {
    weak var webView: WKWebView?
    var onCookieExtracted: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onQQLoginAttempted: (() -> Void)?

    /// 从默认 Cookie 存储中提取京东 pt_key/pt_pin
    func extract(completion: ((String) -> Void)? = nil) {
        guard let _ = webView else {
            completion?("")
            return
        }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let jd = cookies.filter {
                $0.domain.contains("jd.com") &&
                ($0.name == "pt_key" || $0.name == "pt_pin")
            }
            guard let pk = jd.first(where: { $0.name == "pt_key" }),
                  let pp = jd.first(where: { $0.name == "pt_pin" }) else {
                DispatchQueue.main.async { completion?("") }
                return
            }
            let cookie = "pt_key=\(pk.value);pt_pin=\(pp.value);"
            DispatchQueue.main.async {
                self.onCookieExtracted?(cookie)
                completion?(cookie)
            }
        }
    }
}

/// 用 WKWebView 加载京东 H5 登录页，登录完成后从共享 Cookie 存储里抓取 pt_key / pt_pin。
struct LoginWebView: UIViewRepresentable {
    @ObservedObject var controller: WebViewController
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.bounces = true
        // 用 iPhone Safari UA，避免京东返回 PC 页或被拦截
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Mobile/15E148 Safari/604.1"
        controller.webView = wv

        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = true
        wv.load(req)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: LoginWebView
        init(_ parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.controller.extract()
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            parent.controller.extract()
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            let host = url.host?.lowercased() ?? ""

            // 京东 H5 里的 QQ 快速登录会尝试调起 QQ App，WKWebView 做不到；
            // 拦截相关 scheme，让上层提示用户改用短信/密码登录。
            let qqSchemes = ["wtloginmqq", "mqq", "mqqopensdkapi", "mqqapi", "mqqwpa", "mqqbrowser"]
            let qqHosts = ["ptlogin2.qq.com", "openmobile.qq.com", "xui.ptlogin2.qq.com"]
            let isQQ = qqSchemes.contains { scheme.hasPrefix($0) }
                      || qqHosts.contains { host.hasSuffix($0) }
            if isQQ {
                DispatchQueue.main.async { self.parent.controller.onQQLoginAttempted?() }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        private func isCancelledError(_ error: Error) -> Bool {
            let ns = error as NSError
            return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !isCancelledError(error) else { return }
            parent.controller.onError?("页面加载失败：\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !isCancelledError(error) else { return }
            parent.controller.onError?("页面加载失败：\(error.localizedDescription)")
        }
    }
}
