import Foundation
import SwiftUI

/// 打开 App / 回到前台时，对全部已登录账号做一次「无感」CK 有效性自检：
/// 并发探测京东个人页，把结果写回每个窗口的 ckExpired，使「窗口列表」直接标红失效账号。
/// 不弹系统通知、不做定时轮询（iOS 无法在被杀后推送；24/7 兜底由服务器侧 PushPlus 负责）。
@MainActor
final class CKMonitor: NSObject, ObservableObject {
    static let shared = CKMonitor()

    /// 由 ContentView 注入：直接弱持有会话池，从中取会话列表与控制器（避免闭包捕获值类型的 View）
    weak var pool: SessionControllerPool?

    private override init() { super.init() }

    /// 打开 App / 回到前台时调用：并发检测所有已登录账号，**跳过用户当前正在看的窗口**（避免打断），
    /// 把每个账号的 CK 有效性写回列表用于标红。并发度受限（默认 4），账号再多也不会卡 UI，全程无感。
    func scanNow() async {
        guard let pool = pool else { return }
        // 跳过当前正在显示的窗口：用户自己看得到其登录态，且避免 _load 跳转打断他正在浏览的页面
        let targets = pool.sessions.filter { !$0.cookies.isEmpty && $0.id != pool.activeSessionId }
        guard !targets.isEmpty else { return }

        let maxConcurrent = 4
        await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = targets.makeIterator()
            func spawnNext() {
                guard let s = iterator.next() else { return }
                group.addTask {
                    let (_, msg) = await withCheckedContinuation { cont in
                        pool.controller(for: s).checkValidity(cookies: s.cookies) { _, m in
                            cont.resume(returning: (false, m))
                        }
                    }
                    pool.setCkExpired(id: s.id, expired: !msg.hasPrefix("✅"))
                }
            }
            // 初始填满并发槽
            for _ in 0..<min(maxConcurrent, targets.count) { spawnNext() }
            // 每完成一个就补一个，直到全部跑完（限流 + 全程并发，账号多也不卡）
            var completed = 0
            while completed < targets.count {
                _ = try? await group.next()
                completed += 1
                spawnNext()
            }
        }
    }
}
