import SwiftUI
import UIKit

/// 统一的弹窗模型：推送/测试 成功或失败都走它
struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ContentView: View {
    @AppStorage("ql_baseURL") private var baseURL: String = ""
    @AppStorage("ql_clientId") private var clientId: String = ""
    @AppStorage("ql_clientSecret") private var clientSecret: String = ""
    @AppStorage("jd_cookie") private var jdCookie: String = ""

    @State private var extractStatus: String = ""
    @State private var settingsStatus: String = ""
    @State private var isPushing = false
    @State private var showWebView = false
    @State private var alertInfo: AlertInfo?
    @StateObject private var webController = WebViewController()

    private let loginURL = URL(string: "https://home.m.jd.com/myJd/home.action")!

    var body: some View {
        TabView {
            extractTab
                .tabItem { Label("提取", systemImage: "key.fill") }
            settingsTab
                .tabItem { Label("青龙", systemImage: "server.rack") }
        }
        // 全局弹窗：无论停留在哪个 Tab，推送/测试结果都会居中弹出
        .alert(item: $alertInfo) { info in
            Alert(
                title: Text(info.title),
                message: Text(info.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    // MARK: - 提取页
    private var extractTab: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 上半部分：WebView 或引导页
                Group {
                    if showWebView {
                        LoginWebView(controller: webController, url: loginURL)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        introView
                    }
                }

                Divider()

                // 下半部分：Cookie 与操作
                cookieSection
            }
            .navigationTitle("京东 CK 提取")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { webToolbarContent }
            .onAppear {
                // 接上 WebView 的自动提取与错误回调（之前是空接，导致自动抓取无效）
                webController.onCookieExtracted = { ck in
                    guard !ck.isEmpty else { return }
                    jdCookie = ck
                    extractStatus = "✅ 已自动提取 Cookie（长度 \(ck.count)）"
                }
                webController.onError = { msg in
                    extractStatus = "❌ \(msg)"
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var webToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if showWebView {
                Button("关闭") {
                    showWebView = false
                    extractStatus = "已关闭登录页"
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if showWebView {
                Button("提取CK") {
                    manualExtract()
                }
            }
        }
    }

    private var introView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text("点击开始登录京东")
                .font(.headline)
            Text("登录成功后，点击右上角「提取CK」即可获取 pt_key/pt_pin；也可等待自动提取")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("开始提取") {
                showWebView = true
                extractStatus = "正在打开京东登录页…"
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cookieSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前 Cookie").font(.headline)
                Spacer()
                Button("复制") {
                    UIPasteboard.general.string = jdCookie
                    extractStatus = "已复制到剪贴板"
                }
                .disabled(jdCookie.isEmpty)
            }

            ScrollView {
                Text(jdCookie.isEmpty ? "（登录京东后点击「提取CK」获取 pt_key/pt_pin）" : jdCookie)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
            .padding(6)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)

            if !extractStatus.isEmpty {
                Text(extractStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: pushToQinglong) {
                if isPushing {
                    ProgressView()
                } else {
                    Text("推送到青龙").bold()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .disabled(jdCookie.isEmpty || isPushing || !configValid)
        }
        .padding(10)
    }

    // MARK: - 青龙配置页
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
                    Button("测试连接") {
                        Task { await testConnection() }
                    }
                    .disabled(!configValid)

                    if !settingsStatus.isEmpty {
                        Text(settingsStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("说明") {
                    Text("在「提取」页点击「开始提取」打开京东 H5 登录页，登录成功后点击右上角「提取CK」手动抓取 pt_key/pt_pin；点击「推送到青龙」会写入或更新 JD_COOKIE 环境变量并启用。配置保存在本机。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("青龙配置")
        }
    }

    private var configValid: Bool {
        !baseURL.isEmpty && !clientId.isEmpty && !clientSecret.isEmpty
    }

    // MARK: - 动作
    private func manualExtract() {
        extractStatus = "正在提取 Cookie…"
        webController.extract { ck in
            if ck.isEmpty {
                extractStatus = "❌ 未找到 pt_key/pt_pin，请确认已在京东页面登录成功"
            } else {
                jdCookie = ck
                extractStatus = "✅ 已提取 Cookie（长度 \(ck.count)）"
            }
        }
    }

    private func pushToQinglong() {
        guard configValid else {
            extractStatus = "请先在「青龙」页填写面板地址 / Client ID / Client Secret"
            return
        }
        isPushing = true
        let cookie = jdCookie
        Task {
            do {
                let msg = try await QinglongManager.shared.pushCookie(
                    baseURL: baseURL, clientId: clientId, clientSecret: clientSecret, cookie: cookie)
                await MainActor.run {
                    extractStatus = "✅ \(msg)"
                    isPushing = false
                    alertInfo = AlertInfo(title: "推送成功", message: msg)
                }
            } catch {
                await MainActor.run {
                    extractStatus = "❌ 失败：\(error.localizedDescription)"
                    isPushing = false
                    alertInfo = AlertInfo(title: "推送失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func testConnection() async {
        do {
            let token = try await QinglongManager.shared.getToken(
                baseURL: baseURL, clientId: clientId, clientSecret: clientSecret)
            await MainActor.run {
                settingsStatus = "✅ 连接成功，token 长度 \(token.count)"
                alertInfo = AlertInfo(title: "连接成功", message: "已成功获取 token（长度 \(token.count)），面板可正常通信。")
            }
        } catch {
            await MainActor.run {
                settingsStatus = "❌ 连接失败：\(error.localizedDescription)"
                alertInfo = AlertInfo(title: "连接失败", message: error.localizedDescription)
            }
        }
    }
}
