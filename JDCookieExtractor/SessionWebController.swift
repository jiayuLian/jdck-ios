import SwiftUI
import WebKit

/// 京东 H5 登录页地址（手机版）
let jdLoginURL = URL(string: "https://home.m.jd.com/myJd/home.action")!

/// 单个登录窗口的 WebView 控制器：持有自己独立的（nonPersistent）WKWebsiteDataStore，
/// 与 App 内其它窗口彻底隔离。cookie 提取只读取本窗口的数据存储，不会串号。
/// 因 iOS 15 不支持 WKWebsiteDataStore(forIdentifier:) 持久化自定义存储，
/// 故登录态通过 SavedCookie 手动持久化，启动时再注入本窗口的存储。
final class SessionWebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let storeId: UUID

    private(set) lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        // 独立的、非持久化的 cookie 容器：每个窗口互不干扰
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.bounces = true
        // iPhone Safari UA，避免京东返回 PC 页或被拦截
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.4 Mobile/15E148 Safari/604.1"
        return wv
    }()

    var onCookieExtracted: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onQQLoginAttempted: (() -> Void)?

    private var loaded = false

    init(storeId: UUID) {
        self.storeId = storeId
        super.init()
    }

    /// 首次进入窗口时加载京东登录页（重复进入不重载，保留登录态）。
    /// restore 非空时，先把已保存的 cookie 注入本窗口存储，再加载（实现关 App 后仍登录）。
    func ensureLoaded(url: URL, restore: [SavedCookie] = []) {
        guard !loaded else { return }
        loaded = true
        if !restore.isEmpty {
            applyCookies(restore) { self._load(url) }
        } else {
            _load(url)
        }
    }

    /// 重新打开登录页（用于会话过期后重新登录，不会退出其它窗口）
    func reload(url: URL) {
        _load(url)
    }

    private func _load(_ url: URL) {
        var req = URLRequest(url: url)
        req.httpShouldHandleCookies = true
        webView.load(req)
    }

    /// 把保存的 cookie 注入本窗口的独立存储
    private func applyCookies(_ saved: [SavedCookie], completion: @escaping () -> Void) {
        guard !saved.isEmpty else { completion(); return }
        let group = DispatchGroup()
        for c in saved {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: c.name, .value: c.value, .domain: c.domain, .path: c.path,
                .version: 0,
                .secure: c.secure,
                .init(rawValue: "HttpOnly"): c.httpOnly ? "TRUE" : "FALSE"
            ]
            if let e = c.expires { props[.expires] = Date(timeIntervalSince1970: e) }
            if let cookie = HTTPCookie(properties: props) {
                group.enter()
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion() }
    }

    /// 读取本窗口存储里的全部 cookie（用于持久化登录态）
    func fetchCookies(completion: @escaping ([SavedCookie]) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let saved = cookies.map { c in
                SavedCookie(name: c.name, value: c.value, domain: c.domain, path: c.path,
                            secure: c.isSecure, httpOnly: c.isHTTPOnly,
                            expires: c.expiresDate?.timeIntervalSince1970,
                            sameSite: nil)
            }
            completion(saved)
        }
    }

    /// 从本窗口独立的 cookie 存储中提取 pt_key / pt_pin
    func extract(completion: ((String) -> Void)? = nil) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
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

    // MARK: - WKNavigationDelegate / WKUIDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        extract()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        extract()
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
            DispatchQueue.main.async { self.onQQLoginAttempted?() }
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
        onError?("页面加载失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isCancelledError(error) else { return }
        onError?("页面加载失败：\(error.localizedDescription)")
    }
}
