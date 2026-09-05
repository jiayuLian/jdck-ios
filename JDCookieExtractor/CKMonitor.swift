import Foundation
import SwiftUI
import UserNotifications

/// 前台轮询监控：App 处于前台时，每隔设定间隔对各账号的 CK 做一次有效性自检，
/// 发现「新失效」的账号就弹本地通知提醒用户更新。仅前台运行（App 退到后台 / 被杀掉不检测）。
@MainActor
final class CKMonitor: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = CKMonitor()

    /// 由 ContentView 注入：直接弱持有会话池，从中取会话列表与控制器（避免闭包捕获值类型的 View）
    weak var pool: SessionControllerPool?

    private var running = false
    private var nextWork: DispatchWorkItem?

    /// 记录上一次检测中「失效」的账号，仅当某账号从有效变失效（新出现）才弹通知，避免每个周期重复骚扰
    private var lastInvalid = Set<UUID>()

    private override init() { super.init() }

    // MARK: - 启停（配合 App 前后台）
    func start() {
        guard !running else { return }
        running = true
        scheduleNext()
    }

    func stop() {
        running = false
        nextWork?.cancel()
        nextWork = nil
    }

    private func intervalSeconds() -> TimeInterval {
        let m = UserDefaults.standard.integer(forKey: "ck_poll_minutes")
        return TimeInterval(max(1, (m <= 0 ? 30 : m))) * 60
    }

    /// 非重复定时器：每轮结束后按当前间隔排下一轮，天然支持间隔被用户修改后立即生效
    private func scheduleNext() {
        nextWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.runCycle() }
        nextWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + intervalSeconds(), execute: w)
    }

    private func runCycle() {
        guard running else { return }
        guard let pool = pool else { scheduleNext(); return }
        let targets = pool.sessions.filter { !$0.cookies.isEmpty }
        guard !targets.isEmpty else { scheduleNext(); return }

        Task { [weak self] in
            guard let self = self, let pool = self.pool else { return }
            var expiredNow = Set<UUID>()
            for s in targets {
                let c = pool.controller(for: s)
                let (_, msg) = await withCheckedContinuation { cont in
                    c.checkValidity(cookies: s.cookies) { _, m in
                        cont.resume(returning: (false, m))
                    }
                }
                if !msg.hasPrefix("✅") { expiredNow.insert(s.id) }
            }
            let newlyExpired = expiredNow.subtracting(self.lastInvalid)
            self.lastInvalid = expiredNow
            if !newlyExpired.isEmpty {
                let names = pool.sessions.filter { newlyExpired.contains($0.id) }
                                         .map { $0.label }
                                         .joined(separator: "、")
                self.notify(title: "京东 CK 已过期",
                            body: "以下账号 CK 失效，请打开 App 更新：\(names)")
            }
            self.scheduleNext()
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// 即便 App 在前台，也照常弹出横幅 + 声音
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
