# 京东 CK 提取（iOS · 巨魔 TrollStore 版）

功能与 Android 版「京东提取ck对接青龙」完全一致：

1. 内置浏览器登录京东 H5（`home.m.jd.com`），自动抓取 `pt_key` / `pt_pin` cookie；
2. 把 cookie 推送到你的青龙面板 OpenAPI：写入/更新 `JD_COOKIE` 环境变量并启用。

> 反编译原 APK 确认其逻辑来自开源项目 `xanderye/android-jdck`，青龙接口为
> `/open/auth/token`、`/open/envs?searchValue=JD_COOKIE`、`/open/envs`、`/open/envs/enable`，
> 鉴权头 `Authorization: Bearer <token>`，环境变量名 `JD_COOKIE`。本工程用原生 SwiftUI 1:1 重建。

## 最低要求

- iOS 15.0+（巨魔 TrollStore 2 支持的版本）
- 不需要 Apple 开发者账号，巨魔负责安装/签名

---

## 方式一：GitHub Actions 直接出 IPA（无需 Mac）

1. 把这个 `JDCookieExtractor` 目录推到你自己的 GitHub 仓库（含 `.github/workflows/build.yml`）。
2. 仓库 → **Actions** → 选择 `Build IPA (TrollStore)` → **Run workflow**。
3. 跑完后在 **Artifacts** 里下载 `JDCookieExtractor-ipa`（即 `JDCookieExtractor.ipa`）。
4. 把 IPA 传到 iPhone（AirDrop / 文件 App），用**巨魔 TrollStore** 打开安装即可。

---

## 方式二：用 Mac + Xcode 自己编

1. 把整个 `JDCookieExtractor` 文件夹拷到 Mac。
2. 双击 `JDCookieExtractor.xcodeproj` 用 Xcode 打开。
3. 选设备 `Any iOS Device (arm64)`，`Product → Build`（工程已设为 `CODE_SIGNING_ALLOWED=NO`，无需签名）。
4. 找到产物 `.app`（默认在 `~/Library/Developer/Xcode/DerivedData/.../Release-iphoneos/JDCookieExtractor.app`），
   手动打包成 IPA：
   ```bash
   mkdir -p Payload
   cp -R JDCookieExtractor.app Payload/
   zip -r JDCookieExtractor.ipa Payload
   ```
5. 把 `JDCookieExtractor.ipa` 用 AirDrop 传到 iPhone，巨魔打开安装。

---

## 使用

1. 打开 App，切到「青龙」页，填：
   - **面板地址**：`http://你的IP:5700`（注意带 http/https）
   - **Client ID / Client Secret**：青龙「系统设置 → 应用设置 → 创建应用」里拿
2. 点「测试连接」确认能拿到 token。
3. 切到「提取」页，用内置浏览器登录京东（账号密码或扫码）。登录成功后页面自动抓取
   `pt_key;pt_pin` 并显示在下方。
4. 点「推送到青龙」→ 会在青龙里新建/更新 `JD_COOKIE` 并启用。

## 常见问题

- **连不上青龙**：面板若是 `http://` 自建地址，Info.plist 里已加 `NSAllowsArbitraryLoads` 放行；
  但请确认手机和青龙在同一网络/能互通。
- **抓不到 cookie**：确认是登录 `m.jd.com` 成功状态（首页已显示账号），`pt_key` 才会出现；
  可点页面右上角刷新重新触发抓取。Cookie 已用 `@AppStorage` 存本机，重开 App 仍在。
- **巨魔安装提示失败**：确认系统版本在 TrollStore 支持范围，且 IPA 是未损坏的 Release 构建。
