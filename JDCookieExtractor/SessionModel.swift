import Foundation

/// 一个登录窗口的持久化描述。每个窗口使用独立的 WKWebsiteDataStore（iOS 15 下用 nonPersistent 隔离），
/// 登录态通过 cookis 字段手动持久化，因此各窗口互相隔离、且关闭 App 后依然可恢复登录。
struct SessionModel: Identifiable, Codable {
    let id: UUID
    let storeId: UUID
    var label: String
    var cookie: String
    var ptPin: String?
    var status: String
    /// 最近一次 CK 有效性自检结果：nil=未检测/未知，true=已失效，false=有效。
    /// 用于「窗口列表」直接标红失效账号，免去逐个点开窗口才发现过期。
    var ckExpired: Bool? = nil
    /// 本窗口的京东登录态（cookie），用于 App 重启后自动恢复，避免重新登录
    var cookies: [SavedCookie]

    init(label: String) {
        self.id = UUID()
        self.storeId = UUID()
        self.label = label
        self.cookie = ""
        self.ptPin = nil
        self.status = "未提取"
        self.cookies = []
    }

    /// 是否已成功提取到可用的 CK
    var isValid: Bool { !cookie.isEmpty && ptPin != nil }
}

/// 可序列化的 Cookie（iOS 15 兼容，用于本机持久化登录态）
struct SavedCookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let httpOnly: Bool
    let expires: Double?
    let sameSite: String?
}
