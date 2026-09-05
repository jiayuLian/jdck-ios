import SwiftUI
import UIKit
import UserNotifications

struct ContentView: View {
    @StateObject private var pool = SessionControllerPool()
    @AppStorage("ql_baseURL") private var baseURL: String = ""
    @AppStorage("ql_clientId") private var clientId: String = ""
    @AppStorage("ql_clientSecret") private var clientSecret: String = ""
    /// CK 过期自动检测：是否开启（仅前台轮询）
    @AppStorage("ck_poll_enabled") private var pollEnabled: Bool = true
    /// CK 过期自动检测：轮询间隔（分钟，5–120，步进 5）
    @AppStorage("ck_poll_minutes") private var pollMinutes: Int = 30
    @State private var settingsStatus: String = ""

    private var configValid: Bool {
        !baseURL.isEmpty && !clientId.isEmpty && !clientSecret.isEmpty
    }

    var body: some View {
        TabView {
            sessionsTab
                .tabItem { Label("窗口", systemImage: "rectangle.stack") }
            settingsTab
                .tabItem { Label("青龙", systemImage: "server.rack") }
        }
        .alert(item: $pool.alertInfo) { info in
            Alert(title: Text(info.title),
                  message: Text(info.message),
                  dismissButton: .default(Text("好")))
        }
        .environmentObject(pool)
        .onAppear {
            // 申请本地通知权限，并把通知代理指向监控器（前台也弹横幅）
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            UNUserNotificationCenter.current().delegate = CKMonitor.shared
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // 进入前台时把会话池交给监控器，并按开关启停轮询
            CKMonitor.shared.pool = pool
            if pollEnabled { CKMonitor.shared.start() } else { CKMonitor.shared.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // 退到后台即停止轮询（用户选了"仅前台"）
            CKMonitor.shared.stop()
        }
        .onChange(of: pollEnabled) { _ in
            if pollEnabled { CKMonitor.shared.start() } else { CKMonitor.shared.stop() }
        }
    }

    // MARK: - 登录窗口列表
    private var sessionsTab: some View {
        NavigationView {
            List {
                if pool.sessions.isEmpty {
                    Text("还没有登录窗口。点右上角「＋」新增一个，登录京东账号后提取 CK。每个窗口互相隔离，不要在同一窗口退出登录。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(pool.sessions) { session in
                    NavigationLink {
                        SessionDetail(sessionId: session.id,
                                      baseURL: baseURL, clientId: clientId, clientSecret: clientSecret)
                            .environmentObject(pool)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.label).font(.headline)
                            if let pin = session.ptPin, !pin.isEmpty {
                                Text("pt_pin: \(pin)").font(.caption).foregroundColor(.green)
                            } else {
                                Text("尚未提取 CK").font(.caption).foregroundColor(.secondary)
                            }
                            if !session.status.isEmpty {
                                Text(session.status).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .onDelete { idx in
                    idx.map { pool.sessions[$0].id }.forEach { pool.remove($0) }
                }
            }
            .navigationTitle("登录窗口")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { _ = pool.add() }) {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    // MARK: - 青龙配置
    private var settingsTab: some View {
        NavigationView {
            Form {
                Section("青龙面板") {
                    TextField("面板地址（含 http/https）", text: $baseURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Client ID", text: $clientId)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("Client Secret", text: $clientSecret)
                }

                Section {
                    Button("测试连接") { Task { await testConnection() } }
                        .disabled(!configValid)
                    if !settingsStatus.isEmpty {
                        Text(settingsStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Button("一键推送全部账号") { Task { await pushAll() } }
                        .disabled(!configValid || pool.sessions.isEmpty)
                    Text("依次把每个已提取 CK 的窗口推送到青龙，按 pt_pin 归位到对应 JD_COOKIE，互不串号。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button("一键检测全部账号") { Task { await checkAll() } }
                        .disabled(pool.sessions.isEmpty)
                    Text("依次在每个已登录窗口加载京东个人页，依据落页判断 CK 是否有效，结果以弹窗汇总（类似「一键推送全部账号」）。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("CK 过期自动检测（仅前台）") {
                    Toggle("开启自动检测", isOn: $pollEnabled)
                    Stepper(value: $pollMinutes, in: 5...120, step: 5) {
                        Text("轮询间隔：\(pollMinutes) 分钟")
                    }
                    Text("App 处于前台时，每隔设定时间自动检测各账号 CK 是否失效；发现失效会弹出本机通知提醒你更新。后台及被杀掉后不检测（你已有 PushPlus 兜底）。检测时会短暂重载对应窗口的页面，间隔调大可减少打扰。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("说明") {
                    Text("每个「窗口」是一个独立隔离的京东登录态，互不干扰、互不退出。登录后提取 CK 推送到青龙即可。多账号请各自开一个窗口；切勿在同一窗口退出登录（退出会导致该 CK 失效）。同一京东账号不要同时在手机京东 App 与本窗口登录，否则可能互顶掉线。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("青龙配置")
        }
    }

    // MARK: - 动作
    private func testConnection() async {
        do {
            let token = try await QinglongManager.shared.getToken(
                baseURL: baseURL, clientId: clientId, clientSecret: clientSecret)
            await MainActor.run {
                settingsStatus = "✅ 连接成功，token 长度 \(token.count)"
                pool.alertInfo = AlertInfo(title: "连接成功",
                                           message: "已成功获取 token（长度 \(token.count)），面板可正常通信。")
            }
        } catch {
            await MainActor.run {
                settingsStatus = "❌ 连接失败：\(error.localizedDescription)"
                pool.alertInfo = AlertInfo(title: "连接失败", message: error.localizedDescription)
            }
        }
    }

    private func pushAll() async {
        let targets = pool.sessions.filter { $0.isValid }
        guard !targets.isEmpty else {
            pool.alertInfo = AlertInfo(title: "无可用账号",
                                       message: "没有已提取 CK 的窗口。请先到各窗口提取 CK。")
            return
        }
        var ok = 0, fail = 0
        var lines: [String] = []
        for s in targets {
            do {
                let msg = try await QinglongManager.shared.pushCookie(
                    baseURL: baseURL, clientId: clientId, clientSecret: clientSecret, cookie: s.cookie)
                ok += 1
                lines.append("✅ \(s.label): \(msg)")
            } catch {
                fail += 1
                lines.append("❌ \(s.label): \(error.localizedDescription)")
            }
        }
        await MainActor.run {
            pool.alertInfo = AlertInfo(title: "推送完成（成功 \(ok) / 失败 \(fail)）",
                                       message: lines.joined(separator: "\n"))
        }
    }

    private func checkAll() async {
        let targets = pool.sessions.filter { !$0.cookies.isEmpty }
        guard !targets.isEmpty else {
            pool.alertInfo = AlertInfo(title: "无可用账号",
                                       message: "没有已提取 CK 的窗口。请先到各窗口登录并提取 CK。")
            return
        }
        var lines: [String] = []
        for s in targets {
            let (label, msg) = await withCheckedContinuation { cont in
                pool.controller(for: s).checkValidity(cookies: s.cookies) { _, msg in
                    cont.resume(returning: (s.label, msg))
                }
            }
            lines.append("\(msg)  \(label)")
        }
        await MainActor.run {
            pool.alertInfo = AlertInfo(title: "检测完成（\(lines.count) 个）",
                                       message: lines.joined(separator: "\n"))
        }
    }
}

// MARK: - 单窗口详情（独立 WebView + 提取/推送）
struct SessionDetail: View {
    @EnvironmentObject private var pool: SessionControllerPool
    let sessionId: UUID
    let baseURL: String, clientId: String, clientSecret: String

    @State private var isPushing = false
    @AppStorage("show_ck") private var showCK: Bool = false

    private var session: SessionModel? { pool.sessions.first(where: { $0.id == sessionId }) }
    private var configValid: Bool { !baseURL.isEmpty && !clientId.isEmpty && !clientSecret.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if let s = session {
                SessionWebView(controller: pool.controller(for: s))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("窗口已删除").foregroundColor(.secondary)
            }
            Divider()
            actionSection
        }
        .navigationTitle(session?.label ?? "窗口")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let s = session { pool.controller(for: s).ensureLoaded(url: jdLoginURL, restore: s.cookies) }
            bindCallbacks()
        }
    }

    private func bindCallbacks() {
        guard let s = session else { return }
        let c = pool.controller(for: s)
        c.onCookieExtracted = { [weak pool] ck in
            guard !ck.isEmpty else { return }
            guard let pool else { return }
            guard let base = pool.sessions.first(where: { $0.id == sessionId }) else { return }
            var m = base
            m.cookie = ck
            m.ptPin = QinglongManager.extractPtPin(ck)
            m.status = "✅ 已提取 Cookie"
            pool.update(m)
            // 同时持久化本窗口登录态，下次启动自动恢复（避免重新登录）
            // getAllCookies 回调在后台线程，pool.update 改 @Published 需回到主线程
            pool.controller(for: m).fetchCookies { saved in
                DispatchQueue.main.async {
                    if var m2 = pool.sessions.first(where: { $0.id == sessionId }) {
                        m2.cookies = saved
                        pool.update(m2)
                    }
                }
            }
        }
        c.onError = { msg in
            if var m = pool.sessions.first(where: { $0.id == sessionId }) {
                m.status = "❌ \(msg)"
                pool.update(m)
            }
        }
        c.onQQLoginAttempted = {
            if var m = pool.sessions.first(where: { $0.id == sessionId }) {
                m.status = "❌ 不支持 QQ 快速登录，请用短信/密码登录"
                pool.update(m)
            }
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = session {
                HStack {
                    Text("当前 CK").font(.headline)
                    Spacer()
                    Button("复制") {
                        UIPasteboard.general.string = s.cookie
                        if var m = pool.sessions.first(where: { $0.id == sessionId }) {
                            m.status = "已复制到剪贴板"
                            pool.update(m)
                        }
                    }
                    .disabled(s.cookie.isEmpty)
                }

                // 是否显示 CK 明文：默认关闭，避免旁人窥屏看到 cookie；开关状态持久化到 UserDefaults
                Toggle("显示 CK 明文", isOn: $showCK)
                    .font(.caption)

                // 仅在开关打开时展示 CK 明文（可滚动查看 / 长按选择复制），默认不显示
                if showCK && !s.cookie.isEmpty {
                    ScrollView {
                        Text(s.cookie)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 96)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(8)
                }

                if !s.status.isEmpty {
                    Text(s.status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("提取CK") { pool.controller(for: s).extract() }
                    Button("重新登录") { pool.controller(for: s).reload(url: jdLoginURL) }
                    Button("检测CK") {
                        pool.controller(for: s).checkValidity(cookies: s.cookies) { ok, msg in
                            DispatchQueue.main.async {
                                if var m = pool.sessions.first(where: { $0.id == sessionId }) {
                                    m.status = msg
                                    pool.update(m)
                                }
                            }
                        }
                    }
                    .disabled(s.cookies.isEmpty)
                }

                Button(action: push) {
                    if isPushing {
                        ProgressView()
                    } else {
                        Text("推送到青龙").bold()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .disabled(s.cookie.isEmpty || isPushing || !configValid)
            }
        }
        .padding(10)
    }

    private func push() {
        guard let s = session, !s.cookie.isEmpty else { return }
        isPushing = true
        let cookie = s.cookie
        Task {
            do {
                let msg = try await QinglongManager.shared.pushCookie(
                    baseURL: baseURL, clientId: clientId, clientSecret: clientSecret, cookie: cookie)
                await MainActor.run {
                    if var m = pool.sessions.first(where: { $0.id == sessionId }) {
                        m.status = "✅ \(msg)"
                        pool.update(m)
                    }
                    isPushing = false
                    pool.alertInfo = AlertInfo(title: "推送成功", message: msg)
                }
            } catch {
                await MainActor.run {
                    if var m = pool.sessions.first(where: { $0.id == sessionId }) {
                        m.status = "❌ 失败：\(error.localizedDescription)"
                        pool.update(m)
                    }
                    isPushing = false
                    pool.alertInfo = AlertInfo(title: "推送失败", message: error.localizedDescription)
                }
            }
        }
    }
}
