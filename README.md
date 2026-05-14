# Deployment · Jenkins 发版管理工具

跨平台（**桌面 + 移动**）Jenkins 快速发版工具，使用 Flutter / Dart 开发。

> 解决 Jenkins Web 页面发版繁琐的痛点：
>
> - 在多标签工作区里集中管理项目
> - 一次性配置好分支与构建参数
> - 一键触发构建，**实时**展示队列状态、阶段进度、控制台日志
> - 一套代码：macOS / Windows / Linux 桌面 + iOS / Android 移动端

UI 风格借鉴了 [DB-Browser](https://github.com/example/DB-Browser)（深色为主 + 浅色可选 + IDE 风格多标签）。

---

## 目录

- [核心特性](#核心特性)
- [界面布局](#界面布局)
- [技术栈](#技术栈)
- [项目结构](#项目结构)
- [开发文档（架构 / Jenkins 踩坑 / 测试）](docs/DEVELOPMENT.md)
- [开始开发](#开始开发)
- [Jenkins 凭证](#jenkins-凭证)
- [内置网络代理与 HTTPS 解密](#内置网络代理与-https-解密)
- [API 一览](#api-一览)
- [发布与打包](#发布与打包)
- [路线图 / TODO](#路线图--todo)

---

## 核心特性

| 模块 | 说明 |
|------|------|
| **Jenkins 配置** | URL + 用户名 + Token / 密码二选一；测试连接；本地凭证走系统钥匙串 |
| **多标签工作区** | Chrome 风格 tab；首页 / 设置 / 项目页可同时打开；自动持久化 |
| **项目树** | 递归展示 Folder / MultiBranch / Job；按颜色显示最近构建结果；支持搜索过滤 |
| **快速发版** | 多分支流水线 → 选择分支；参数化项目 → 动态生成表单；一键 Build Now |
| **实时进度** | 队列等待、构建进度条、Pipeline Stage View 阶段图标（成功/失败/进行中） |
| **实时日志** | progressiveText 增量拉取；自动滚动；error/warn 关键字着色 |
| **响应式布局** | ≥ 1100px 桌面侧边栏 + 标签栏；< 720px 移动 BottomNav |
| **主题** | 深色 / 浅色 / 跟随系统三档切换 |
| **国际化** | 简体中文 / English |
| **内置网络代理** | 支持加密代理、HTTPS 解密抓包、移动端证书信任探测与安装引导 |

---

## 界面布局

**桌面（≥ 1100px）**

```
┌─────────────────────────────────────────────────────────────┐
│ 应用标题栏 · 主题切换                                          │
├─────────────────────────────────────────────────────────────┤
│ [首页] [order-service] [+]                  ← chrome 标签栏    │
├──────────┬──────────────────────────────────────────────────┤
│  项目树   │  ┌──────────────┐ ┌─────────────────────────┐    │
│          │  │ 分支选择器     │ │  发版进度面板             │    │
│ ● 后端组  │  │ 参数表单       │ │  ▓▓▓▓░░  Build #128      │    │
│ ● 前端组  │  │ [立即构建]     │ │  ✓ Checkout              │    │
│          │  └──────────────┘ │  ◐ Test (running)        │    │
│          │                   │  ○ Deploy                │    │
│          │                   ├─────────────────────────┤    │
│          │                   │  实时日志（progressiveText）│    │
├──────────┴──────────────────────────────────────────────────┤
│ 状态栏：● 已连接 jenkins.example.com · 3 tabs                  │
└─────────────────────────────────────────────────────────────┘
```

**移动（< 720px）**

```
┌─────────────────┐
│ ← order-service │  ← AppBar
├─────────────────┤
│ 分支：[develop]   │
│ ENV：[prod ▼]    │
│ [立即构建]        │
│ ────────────    │
│ 进度：65%        │
│ ✓ Checkout      │
│ ◐ Test          │
├─────────────────┤
│ [构建][项目][设置] │  ← BottomNav
└─────────────────┘
```

---

## 技术栈

| | |
|---|---|
| 框架 | Flutter 3.41 / Dart 3.11 |
| 状态管理 | flutter_riverpod 3.x（Notifier / AsyncNotifier / family） |
| 路由 | 暂用 Tab 状态机管理（go_router 已加入依赖，未来可平滑接入） |
| 网络 | dio |
| 凭证存储 | flutter_secure_storage（系统钥匙串） |
| 偏好存储 | shared_preferences |
| 桌面窗口 | window_manager |
| 国际化 | flutter_localizations + intl + ARB |

---

## 项目结构

```text
lib/
├── main.dart                    # 入口（窗口初始化、ProviderScope）
├── app.dart                     # MaterialApp + 主题
├── core/                        # 跨功能基础设施
│   ├── theme/                   # AppPalette + AppTheme + ThemeController
│   ├── responsive/              # 桌面/移动断点
│   ├── http/                    # JenkinsHttpClient（Basic Auth + 拦截器）
│   ├── storage/                 # secureStorage / SharedPreferences
│   └── utils/                   # logger / 时长格式化
├── features/
│   ├── settings/                # JenkinsConfig 配置
│   ├── workspace/               # 多标签工作区（home / sidebar / tab bar / status bar）
│   ├── jenkins/                 # Jenkins API + 项目页 + 参数表单 + 项目树
│   └── release/                 # 发版流程（trigger / progress / log）
├── plug/
│   └── network_proxy/           # 内置 HTTP/HTTPS 代理、MITM 证书、代理状态探测
└── l10n/                        # 国际化（zh / en）
```

---

## 开始开发

### 1. 环境

```bash
flutter --version    # >= 3.41 stable
flutter doctor -v    # 至少满足 macOS desktop / Chrome 即可开始
```

桌面 / 移动各平台还需安装：

| 平台 | 额外要求 |
|------|----------|
| macOS 桌面 | Xcode + CocoaPods |
| iOS | Xcode + CocoaPods + Apple Developer 证书 |
| Android | Android Studio + 相应 SDK |
| Windows | Visual Studio + C++ workload |
| Linux | clang / cmake / ninja-build / pkg-config / GTK |

### 2. 安装依赖

```bash
flutter pub get
flutter gen-l10n
```

### 3. 跑起来

```bash
# Web（最快）
flutter run -d chrome

# macOS 桌面
flutter run -d macos

# iOS / Android（连接设备 / 模拟器后）
flutter run
```

### 4. 静态检查 / 测试

```bash
flutter analyze
flutter test
# 或一键验收（测试 + dart analyze）
pnpm verify
```

更多架构说明、Jenkins 对接经验（CSRF、Cookie、Pipeline `json=` 触发等）见 **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)**。

---

## Jenkins 凭证

应用支持两种鉴权方式（Basic Auth 形式发送）：

1. **API Token（推荐）**
   - 登录 Jenkins → 右上角点击用户名 → **Configure** → **API Token** → 添加新 Token
   - 复制返回的 Token 串到本应用「凭证」字段

2. **用户名 + 密码**
   - 直接使用 Jenkins 登录密码（如未启用二步验证）

> 凭证只保存在**本机系统钥匙串**（macOS / iOS Keychain / Android Keystore / Windows DPAPI），不会上传任何远程服务。

---

## 内置网络代理与 HTTPS 解密

应用内置转发代理用于移动端或远端设备访问 Jenkins，支持两种代理链路：

- **加密代理**：代理协议外层使用 TLS，适合经过内网穿透或公网入口时避免明文 CONNECT 被拦截。
- **HTTPS 解密抓包**：服务端动态生成 MITM 根证书和站点证书，用于调试 Jenkins HTTPS 请求。

证书与缓存默认保存在本机用户目录：

- macOS：`~/Library/Application Support/Deployment/mitm`
- 其他桌面环境：`~/.deployment/mitm`

这些文件包含私钥和本机根证书，不能提交到仓库。若重新生成根证书，旧的站点证书缓存会自动失效并重新生成。

### iOS 证书安装

开启 HTTPS 解密后，移动端会每 15 秒探测代理状态和 MITM 证书信任状态。如果需要证书且尚未信任，App 会在移动端弹框提示，并打开当前代理地址的安装页，例如：

```text
https://<proxy-host>:<proxy-port>/__proxy/cert
```

iOS 需要手动完成两步：

1. 在 Safari 中下载根证书描述文件，并到 `设置 → 通用 → VPN 与设备管理` 安装。
2. 到 `设置 → 通用 → 关于本机 → 证书信任设置` 打开完全信任。

iOS 不允许普通 App 或网页自动完成“完全信任根证书”，系统设置页深链也不稳定，因此安装页只提供明确步骤和当前根证书 SHA-256 指纹，便于确认手机信任的是当前代理正在使用的证书。

---

## API 一览

| 用途 | 端点 |
|------|------|
| 测试连接 | `GET /api/json` |
| 节点树 | `GET /api/json?tree=jobs[name,url,_class,...{deeper}]` |
| 项目详情 | `GET /job/{path}/api/json`（解析 `actions[].parameterDefinitions`） |
| 触发构建 | `POST .../buildWithParameters`（表单/query）；Pipeline 常见 fallback：`POST .../build` + 表单字段 `json=`（见开发文档） |
| 队列状态 | `GET /queue/item/{id}/api/json` |
| 构建详情 | `GET /job/{path}/{n}/api/json` |
| 控制台日志 | `GET /job/{path}/{n}/logText/progressiveText?start={N}` |
| Pipeline 阶段 | `GET /job/{path}/{n}/wfapi/describe` |

> `{path}` 自动按 `/job/<seg>` 编码以处理 Folder。多分支流水线下 `分支 = 子 job`，触发的实际路径是 `parent/branch`。

---

## 发布与打包

```bash
flutter build macos      # → build/macos/Build/Products/Release/Deployment.app
flutter build windows    # → build/windows/runner/Release/
flutter build linux      # → build/linux/x64/release/bundle/
flutter build apk        # → build/app/outputs/flutter-apk/app-release.apk
flutter build ipa        # → build/ios/ipa/*.ipa
flutter build web        # → build/web/
```

未来可加入 GitHub Actions Workflow 自动出 Release 包。

---

## 路线图 / TODO

- [ ] 标签拖拽排序持久化
- [ ] 项目页加入「构建历史」面板
- [ ] 取消运行中的构建（`POST /stop`）
- [ ] 多 Jenkins 实例（命名空间）
- [ ] 桌面端原生通知（构建完成 / 失败）
- [ ] 移动端推送（构建状态变化）
- [ ] 自定义状态栏快捷指标
- [ ] 主题色自定义
- [ ] 暗色 Pipeline 阶段流程图（横向卡片视图）

---

## License

待补充。

