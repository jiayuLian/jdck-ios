import SwiftUI
import UIKit

struct ContentView: View {
    @AppStorage("ql_baseURL") private var baseURL: String = ""
    @AppStorage("ql_clientId") private var clientId: String = ""
    @AppStorage("ql_clientSecret") private var clientSecret: String = ""
    @AppStorage("jd_cookie") private var jdCookie: String = ""

    @State private var statusMessage: String = ""
    @State private var isPushing = false

    private let loginURL = URL(string: "https://home.m.jd.com/myJd/home.action")!

    var body: some View {
        TabView {
            extractTab
                .tabItem { Label("提取", systemImage: "key.fill") }
            settingsTab
                .tabItem { Label("青龙", systemImage: "server.rack") }
        }
    }

    private var extractTab: some View {
        NavigationView {
            VStack(spacing: 0) {
                LoginWebView(url: loginURL) { ck in
                    jdCookie = ck
                    statusMessage = "已自动提取 Cookie（长度 \(ck.count)）"
                }
                .ignoresSafeArea(.container, edges: .bottom)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("当前 Cookie").font(.headline)
                        Spacer()
                        Button("复制") {
                            UIPasteboard.general.string = jdCookie
                            statusMessage = "已复制到剪贴板"
                        }
                        .disabled(jdCookie.isEmpty)
                    }
                    ScrollView {
                        Text(jdCookie.isEmpty ? "（登录京东后自动提取 pt_key/pt_pin）" : jdCookie)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                    .padding(6)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)

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
            .navigationTitle("京东 CK 提取")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var settingsTab: some View {
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
            }
            Section("说明") {
                Text("在「提取」页用内置浏览器登录京东 H5，自动抓取 pt_key/pt_pin；点击「推送到青龙」会写入或更新 JD_COOKIE 环境变量并启用。配置保存在本机。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("青龙配置")
    }

    private var configValid: Bool {
        !baseURL.isEmpty && !clientId.isEmpty && !clientSecret.isEmpty
    }

    private func pushToQinglong() {
        guard configValid else {
            statusMessage = "请先在「青龙」页填写面板地址 / Client ID / Client Secret"
            return
        }
        isPushing = true
        let cookie = jdCookie
        Task {
            do {
                let msg = try await QinglongManager.shared.pushCookie(
                    baseURL: baseURL, clientId: clientId, clientSecret: clientSecret, cookie: cookie)
                await MainActor.run {
                    statusMessage = "✅ \(msg)"
                    isPushing = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = "❌ 失败：\(error.localizedDescription)"
                    isPushing = false
                }
            }
        }
    }

    private func testConnection() async {
        do {
            let token = try await QinglongManager.shared.getToken(
                baseURL: baseURL, clientId: clientId, clientSecret: clientSecret)
            await MainActor.run { statusMessage = "✅ 连接成功，token 长度 \(token.count)" }
        } catch {
            await MainActor.run { statusMessage = "❌ 连接失败：\(error.localizedDescription)" }
        }
    }
}
