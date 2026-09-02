import SwiftUI
import WebKit

/// 承载某个登录窗口的持久化 WKWebView。
/// makeUIView 直接返回 SessionWebController 持有的那个 WebView（只创建一次），
/// 因此 SwiftUI 视图重建/切走再回来都不会丢失登录态。
struct SessionWebView: UIViewRepresentable {
    let controller: SessionWebController

    func makeUIView(context: Context) -> WKWebView {
        return controller.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
