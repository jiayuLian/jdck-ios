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
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for c in saved {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: c.name, .value: c.value, .domain: c.domain, .path: c.path,
                .version: 0,
                .secure: c.secure,
                .init(rawValue: "HttpOnly"): c.httpOnly ? "TRUE" : "FALSE"
            ]
            // 关键：恢复登录态时【不】设置 .expires。
            // 京东 pt_key 的 expires 是登录时抓到的绝对过期时间，App 重启后该时间可能已过期；
            // 若原样注入，WKWebView 会判定 cookie 过期而不再发送，页面显示"需重新登录"，
            // 即便京东服务端仍认该 pt_key（京东按值校验，与本地 expires 无关）。
            // 改为 session cookie 注入，由京东按 pt_key 值校验；服务端未真正失效即可正常恢复。
            // 优先用完整属性构造；若个别属性（如 HttpOnly）导致构造失败则降级重试，
            // 避免某条 cookie 注入失败而丢失登录态。
            func makeCookie(_ p: [HTTPCookiePropertyKey: Any]) -> HTTPCookie? {
                HTTPCookie(properties: p)
            }
            var cookie = makeCookie(props)
            if cookie == nil {
                var p2 = props
                p2.removeValue(forKey: .init(rawValue: "HttpOnly"))
                cookie = makeCookie(p2)
            }
            guard let ck = cookie else { continue }
            group.enter()
            store.setCookie(ck) { group.leave() }
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

    /// 单次导航内只提取一次 cookie，避免 didFinish 与 navigationResponse 重复触发 getAllCookies。
    /// 每个顶层导航开始时重置标记，从而取到最早可用的 cookie（登录重定向中途即可抓到）。
    private var extractedThisNavigation = false

    /// 自检 CK 有效性时的一次性回调；didFinish 触发评估登录态
    private var pendingCheck: ((Bool, String) -> Void)?
    private var checkTimer: DispatchWorkItem?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        extractedThisNavigation = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        extractOnce()
        if pendingCheck != nil {
            checkTimer?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.runLoginStateCheck() }
            checkTimer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        extractOnce()
        decisionHandler(.allow)
    }

    private func extractOnce() {
        guard !extractedThisNavigation else { return }
        extractedThisNavigation = true
        extract()
    }

    /// 自检本账号 CK 是否有效：注入本窗口 cookie 后加载京东个人页，依据最终落页判断。
    /// 有效（落在个人页）-> (true, "✅ CK 有效")；被重定向到登录页 -> (false, "❌ CK 已失效")
    func checkValidity(cookies saved: [SavedCookie], completion: @escaping (Bool, String) -> Void) {
        pendingCheck = completion
        if !saved.isEmpty {
            applyCookies(saved) { self._load(jdLoginURL) }
        } else {
            _load(jdLoginURL)
        }
    }

    private func runLoginStateCheck() {
        guard let check = pendingCheck else { return }
        pendingCheck = nil
        let url = webView.url?.absoluteString.lowercased() ?? ""
        if url.contains("passport") || url.contains("login.jd") || url.contains("/login") || url.contains("qrscan") {
            check(false, "❌ CK 已失效（已跳转登录页）")
            return
        }
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { text, _ in
            let t = ((text as? String) ?? "").lowercased()
            DispatchQueue.main.async {
                if t.contains("登录京东") || t.contains("账号登录") || t.contains("扫码登录") || (t.contains("登录") && t.contains("免费注册")) {
                    check(false, "❌ CK 已失效（显示为登录页）")
                } else if t.contains("我的京东") || t.contains("我的订单") || t.contains("退出登录") || t.contains("我的关注") || t.contains("我的资产") {
                    check(true, "✅ CK 有效")
                } else {
                    check(true, "✅ CK 有效（未跳转登录页）")
                }
            }
        }
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
        if let check = pendingCheck {
            pendingCheck = nil
            checkTimer?.cancel()
            check(false, "❌ 检测失败：\(error.localizedDescription)")
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isCancelledError(error) else { return }
        onError?("页面加载失败：\(error.localizedDescription)")
        if let check = pendingCheck {
            pendingCheck = nil
            checkTimer?.cancel()
            check(false, "❌ 检测失败：\(error.localizedDescription)")
        }
    }
}
