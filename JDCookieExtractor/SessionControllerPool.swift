import SwiftUI
import WebKit
import Combine

/// 全局弹窗模型：推送 / 测试 成功或失败都走它
struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 管理所有登录窗口（会话）及其对应的 WebView 控制器。
/// 会话列表持久化到 UserDefaults，因此窗口与登录态在 App 重启后依然存在。
final class SessionControllerPool: ObservableObject {
    @Published var sessions: [SessionModel] = []
    @Published var alertInfo: AlertInfo?

    private var controllers: [UUID: SessionWebController] = [:]
    private let key = "jd_sessions_v1"

    init() { load() }

    func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([SessionModel].self, from: data) {
            sessions = arr
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 新增一个隔离登录窗口
    func add() -> SessionModel {
        let n = sessions.count + 1
        let s = SessionModel(label: "账号 \(n)")
        sessions.append(s)
        save()
        return s
    }

    /// 删除窗口，并清空其独立的 cookie 存储
    func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if let c = controllers.removeValue(forKey: id) {
            c.webView.removeFromSuperview()
            c.webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                               modifiedSince: Date.distantPast) {}
        }
        save()
    }

    /// 取（或创建）某窗口的 WebView 控制器，保证每个 storeId 只对应一个实例
    func controller(for session: SessionModel) -> SessionWebController {
        if let c = controllers[session.id] { return c }
        let c = SessionWebController(storeId: session.storeId)
        controllers[session.id] = c
        return c
    }

    /// 更新并持久化某个窗口的数据
    func update(_ session: SessionModel) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
            save()
        }
    }
}
