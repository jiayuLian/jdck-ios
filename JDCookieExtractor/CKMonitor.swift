import Foundation
import SwiftUI

/// 打开 App / 回到前台时，对全部已登录账号做一次「无感」CK 有效性自检：
/// 串行探测京东个人页，把结果写回每个窗口的 ckExpired，使「窗口列表」直接标红失效账号。
/// 不弹系统通知、不做定时轮询（iOS 无法在被杀后推送；24/7 兜底由服务器侧 PushPlus 负责）。
///
/// 设计要点（防资源浪费）：带「冷却时间」——两次自动扫描间隔若小于 cooldownMinutes，
/// 则直接跳过、不发起任何网络请求。京东 CK 过期是小时/天级别，分钟级重复探测既无意义、
/// 又浪费流量电量，还易触发京东风控。用户主动「一键检测全部账号」走另一条路径，不受冷却影响。
///
/// 并发说明：本函数对账号**串行**逐个检测（沿用已知稳定的实现，不使用并发 TaskGroup）。
/// 串行可彻底避免「后台线程创建 WKWebView」等并发相关的崩溃，账号再多也只是逐一轮流检测，
/// 不会卡 UI（checkValidity 内部为异步加载，循环 await 时不阻塞主线程交互）。
@MainActor
final class CKMonitor: NSObject, ObservableObject {
    static let shared = CKMonitor()

    /// 由 ContentView 注入：直接弱持有会话池，从中取会话列表与控制器（避免闭包捕获值类型的 View）
    weak var pool: SessionControllerPool?

    /// 两次自动无感检测之间的最小间隔（分钟）。短于此间隔的前台切换不再重复扫描。
    /// 默认 15 分钟：CK 过期远慢于此，足够安全；想更省流量可调大，想更灵敏可调小。
    @AppStorage("ck_scan_cooldown_min") private var cooldownMinutes: Int = 15

    /// 上次成功触发无感扫描的时间戳（持久化，跨冷启动生效）
    @AppStorage("ck_last_scan_ts") private var lastScanTS: Double = 0

    private override init() { super.init() }

    /// 打开 App / 回到前台调用：先判冷却，未到冷却期直接返回（零资源消耗）；
    /// 否则串行检测所有已登录账号，**跳过用户当前正在看的窗口**（避免打断），
    /// 把每个账号的 CK 有效性写回列表用于标红。串行执行、不并发，避免并发崩溃。
    /// 全部账号检测完成（或冷却期内直接跳过）才会更新 lastScanTS 进入冷却。
    func scanNow() {
        // 冷却判断：距上次扫描不足冷却期则不重复扫描（立即返回，零消耗）
        let now = Date().timeIntervalSince1970
        guard now - lastScanTS >= Double(cooldownMinutes) * 60 else { return }

        guard let pool = pool else { return }
        // 跳过当前正在显示的窗口：用户自己看得到其登录态，且避免打断他正在浏览的页面
        let targets = pool.sessions.filter { !$0.cookies.isEmpty && $0.id != pool.activeSessionId }
        guard !targets.isEmpty else { return }

        Task { [weak self] in
            guard let self = self, let pool = self.pool else { return }
            for s in targets {
                let c = pool.controller(for: s)
                let (_, msg) = await withCheckedContinuation { cont in
                    c.checkValidity(cookies: s.cookies) { _, m in
                        cont.resume(returning: (false, m))
                    }
                }
                pool.setCkExpired(id: s.id, expired: !msg.hasPrefix("✅"))
            }
            // 全部账号检测完毕，记录时间戳进入冷却期（下次前台切回若未超期则跳过）
            self.lastScanTS = Date().timeIntervalSince1970
        }
    }
}
