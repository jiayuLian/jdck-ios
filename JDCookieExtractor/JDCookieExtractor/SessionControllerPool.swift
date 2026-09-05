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

    /// 当前可见（已打开）的窗口 id，供 App 回到前台时对该窗口做 cookie 自愈（#2）
    var activeSessionId: UUID?

    /// App 回到前台时调用：对当前可见窗口重新比对并注入 cookie，
    /// 修复「窗口停在前台、但后台期间 nonPersistent 存储被系统回收」导致回到登录页的问题。
    func refreshActiveIfNeeded() {
        guard let id = activeSessionId,
              let s = sessions.first(where: { $0.id == id }) else { return }
        controller(for: s).ensureLoaded(url: jdLoginURL, restore: s.cookies)
    }

    /// 取（或创建）某窗口的 WebView 控制器，保证每个 storeId 只对应一个实例
    func controller(for session: SessionModel) -> SessionWebController {
        if let c = controllers[session.id] { return c }
        let c = SessionWebController(storeId: session.storeId)
        controllers[session.id] = c
        // 关键：WKWebView 严禁在后台线程创建。本方法可能被 scanNow 的并发任务（后台线程）
        // 或 checkAll 等路径调用，因此在此统一保证 WebView 完成首次实例化落在主线程，
        // 避免后台线程创建触发系统断言崩溃（这是此前「打开 App 即闪退」的根因来源）。
        if !Thread.isMainThread {
            DispatchQueue.main.sync { _ = c.webView }
        } else {
            _ = c.webView
        }
        return c
    }

    /// 更新并持久化某个窗口的数据
    func update(_ session: SessionModel) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
            save()
        }
    }

    /// 写入某窗口最近一次 CK 自检结果（用于列表标红），主线程调用
    func setCkExpired(id: UUID, expired: Bool) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].ckExpired = expired
        save()
    }
}
