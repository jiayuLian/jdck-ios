import Foundation

/// 一个登录窗口的持久化描述。每个窗口使用独立的 WKWebsiteDataStore（storeId），
/// 因此各窗口的京东登录态彼此隔离、互不退出，且关闭 App 后依然保持登录。
struct SessionModel: Identifiable, Codable {
    let id: UUID
    let storeId: UUID
    var label: String
    var cookie: String
    var ptPin: String?
    var status: String

    init(label: String) {
        self.id = UUID()
        self.storeId = UUID()
        self.label = label
        self.cookie = ""
        self.ptPin = nil
        self.status = "未提取"
    }

    /// 是否已成功提取到可用的 CK
    var isValid: Bool { !cookie.isEmpty && ptPin != nil }
}
