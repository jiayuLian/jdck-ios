# 京东 CK 提取（iOS · 巨魔 TrollStore 版）

功能与 Android 版「京东提取ck对接青龙」完全一致，并用原生 SwiftUI 1:1 重建。

> 反编译原 APK 确认其逻辑来自开源项目 `xanderye/android-jdck`，青龙接口为
> `/open/auth/token`、`/open/envs?searchValue=JD_COOKIE`、`/open/envs`、`/open/envs/enable`，
> 鉴权头 `Authorization: Bearer <token>`，环境变量名 `JD_COOKIE`。

## 最低要求

- iOS 15.0+（巨魔 TrollStore 2 支持 15.0–16.6.1）
- 不需要 Apple 开发者账号，巨魔负责安装/签名

---

## 核心特性

1. 内置浏览器登录京东 H5（`home.m.jd.com`），自动抓取 `pt_key` / `pt_pin` cookie；
2. 推送到你的青龙面板 OpenAPI：按 `pt_pin` 精确匹配、写入/更新 `JD_COOKIE` 并启用，**多账号不串号、不覆盖备注**；
3. **多开隔离登录窗口**：每个账号一个独立 WebView（独立 `WKWebsiteDataStore`），A/B/C 各登各的、**互不退出、互不干扰**；
4. **登录态持久化**：窗口的登录 cookie 存本机，关 App 再进自动恢复，**只要 CK 未过期就无需重新登录**；
5. 「一键推送全部账号」：一次把每个已提取的窗口全推到青龙。

### 关于「退出登录」的重要提示
京东的 `pt_key` 与本次登录会话绑定：**一旦退出登录，该 `pt_key` 立即被吊销，推到青龙的 CK 随之失效**。
因此本工具刻意不做「退出」按钮，多开隔离窗口让你为每个账号单独保持登录，谁都不用退。
若某账号 `pt_key` 自然过期，回到该窗口重新登录即可，其他窗口不受影响。

---

## 方式一：直接装 Release 里的 IPA（最简单）

1. 到 [Releases](https://github.com/jiayuLian/jdck-ios/releases) 下载 `JDCookie.ipa`；
2. 用 **巨魔 TrollStore** 打开安装（iOS 15.0+ 免签名永久可用）；
3. 没有巨魔？ 用 AltStore / 爱思助手以免费 Apple ID 自签安装，每 7 天需重签。

## 方式二：GitHub Actions 自己出 IPA（无需 Mac）

1. Fork / 把这个 `JDCookieExtractor` 目录推到你自己的 GitHub 仓库（含 `.github/workflows/build.yml`）。
2. 仓库 → **Actions** → 选择 `Build IPA (TrollStore)` → **Run workflow**。
3. 跑完后在 **Artifacts** 里下载 `JDCookieExtractor-ipa`（即 `JDCookieExtractor.ipa`）。

## 方式三：Mac + Xcode 自己编

1. 把整个 `JDCookieExtractor` 文件夹拷到 Mac，双击 `JDCookieExtractor.xcodeproj` 用 Xcode 打开；
2. 选 `Any iOS Device (arm64)`，`Product → Build`（工程已设 `CODE_SIGNING_ALLOWED=NO`，无需签名）；
3. 产物 `.app` 打包成 IPA：`mkdir -p Payload && cp -R xxx.app Payload/ && zip -r JDCookie.ipa Payload`；
4. AirDrop 到 iPhone，巨魔打开安装。

---

## 使用

1. 打开 App，切到「青龙」页，填：
   - **面板地址**：`https://你的面板域名`（注意带 http/https）
   - **Client ID / Client Secret**：青龙「系统设置 → 应用设置 → 创建应用」里拿
   - 点「测试连接」确认能拿到 token。
2. 切到「窗口」页，点右上角「＋」新增一个隔离登录窗口；
3. 进入窗口，用内置浏览器登录京东（账号密码或短信），登录成功后自动抓取 `pt_key;pt_pin` 并显示在下方；
4. 点「推送到青龙」→ 按 `pt_pin` 新建/更新 `JD_COOKIE` 并启用；
5. 多账号：再开一个窗口登另一个号，重复提取推送，**互不干扰**；
6. 回到「青龙」页点「一键推送全部账号」可批量推送。
7. 关 App 再进，各窗口登录态自动恢复，无需重登（CK 未过期前提下）。

## 常见问题

- **连不上青龙**：面板若是 `http://` 自建地址，Info.plist 已加 `NSAllowsArbitraryLoads` 放行；请确认手机与面板网络互通。
- **抓不到 cookie**：确认是登录 `m.jd.com` 成功状态（首页已显示账号），`pt_key` 才会出现；可点刷新重新触发抓取。
- **重开 App 要重登？** 不应发生——登录态已持久化。若仍要重登，通常是该账号 `pt_key` 被京东服务端过期或风控踢掉（同账号在手机京东 App 与本窗口同时登录会互顶），回该窗口重登一次即可。
- **巨魔安装失败**：确认系统版本在 TrollStore 支持范围，且 IPA 完整未损坏。

## 免责声明

仅供学习交流与技术研究，请遵守京东用户协议与当地法律法规，勿用于任何违规用途。

## License

[MIT](LICENSE)
