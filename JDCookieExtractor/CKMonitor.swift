import Foundation
import SwiftUI

/// 打开 App / 回到前台时，对全部已登录账号做一次「无感」CK 有效性自检：
/// 并发探测京东个人页，把结果写回每个窗口的 ckExpired，使「窗口列表」直接标红失效账号。
/// 不弹系统通知、不做定时轮询（iOS 无法在被杀后推送；24/7 兜底由服务器侧 PushPlus 负责）。
///
/// 设计要点（防资源浪费）：带「冷却时间」——两次自动扫描间隔若小于 cooldownMinutes，
/// 则直接跳过、不发起任何网络请求。京东 CK 过期是小时/天级别，分钟级重复探测既无意义、
/// 又浪费流量电量，还易触发京东风控。用户主动「一键检测全部账号」走另一条路径，不受冷却影响。
@MainActor
final class CKMonitor: NSObject, ObservableObject {
    static let shared = CKMonitor()

    /// 由 ContentView 注入：直接弱持有会话池，从中取会话列表与控制器（避免闭包捕获值类型的 View）
    weak var pool: SessionControllerPool?

    /// 两次自动无感检测之间的最小间隔（分钟）。短于此间隔的前台切换不再重复扫描。
    /// 默认 15 分钟：CK 过期远慢于此，足够安全；想更省流量可调大，想更灵敏可调小。
    @AppStorage("ck_scan_cooldown_min") private var cooldownMinutes: Int = 15

    /// 上次成功完成无感扫描的时间戳（持久化，跨冷启动生效）。
    @AppStorage("ck_last_scan_ts") private var lastScanTS: Double = 0

    private override init() { super.init() }

    /// 打开 App / 回到前台调用：先判冷却，未到冷却期直接返回（零资源消耗）；
    /// 否则并发检测所有已登录账号，**跳过用户当前正在看的窗口**（避免打断），
    /// 把每个账号的 CK 有效性写回列表用于标红。并发度受限（默认 4），账号再多也不卡 UI，全程无感。
    /// 全部账号检测完成后再写入 lastScanTS，确保只有「真正扫过一遍」才进入冷却。
    ///
    /// 重要：WKWebView 必须在主线程创建与操作。本函数整体处于 @MainActor，
    /// 检测任务用「@MainActor task」确保每个 WKWebView 的创建/加载都在主线程完成，
    /// 同时利用 checkValidity 内部 load 的异步特性实现多账号重叠检测（不阻塞 UI）。
    func scanNow() async {
        // 冷却判断：距上次扫描不足冷却期则不重复扫描
        let now = Date().timeIntervalSince1970
        guard now - lastScanTS >= Double(cooldownMinutes) * 60 else { return }

        guard let pool = pool else { return }
        // 跳过当前正在显示的窗口：用户自己看得到其登录态，且避免 _load 跳转打断他正在浏览的页面
        let targets = pool.sessions.filter { !$0.cookies.isEmpty && $0.id != pool.activeSessionId }
        guard !targets.isEmpty else { return }

        // 分批并发（每批 4 个），每批内多账号利用异步 load 重叠检测，既无感又不卡 UI。
        // （各窗口 WKWebView 的创建由 SessionControllerPool.controller(for:) 统一保证在主线程，
        //  故并发任务里访问也安全，不会触发后台创建崩溃。）
        let batchSize = 4
        var from = targets.startIndex
        while from < targets.endIndex {
            let end = min(from + batchSize, targets.endIndex)
            let slice = Array(targets[from..<end])
            await withThrowingTaskGroup(of: Void.self) { group in
                for s in slice {
                    // @MainActor：保证 WKWebView 创建/加载与 @Published 写入都在主线程
                    group.addTask { @MainActor in
                        let msg: String = await withCheckedContinuation { cont in
                            pool.controller(for: s).checkValidity(cookies: s.cookies) { _, m in
                                cont.resume(returning: m)
                            }
                        }
                        pool.setCkExpired(id: s.id, expired: !msg.hasPrefix("✅"))
                    }
                }
                _ = try? await group.waitForAll()
            }
            from = end
        }

        // 全部账号检测完毕，记录时间戳进入冷却期（下次前台切回若未超期则跳过）
        lastScanTS = Date().timeIntervalSince1970
    }
}
