# 开发文档

面向在本仓库中继续开发与排查问题的工程师：架构约定、Jenkins 对接踩坑、验证命令与扩展指南。

---

## 1. 架构与分层

| 层级 | 职责 | 典型位置 |
|------|------|----------|
| **Presentation** | Widget、Riverpod 监听、用户交互 | `lib/features/*/presentation/` |
| **Application** | 用例编排（如发版轮询） | `lib/features/release/application/` |
| **Data** | HTTP API、Repository、Provider | `lib/features/jenkins/data/`、`lib/core/http/` |
| **Domain** | 纯模型与领域逻辑（无 Flutter / IO） | `lib/features/jenkins/domain/` |

原则：**Domain 不依赖 Data**；跨功能能力放在 `lib/core/`（主题、断点、HTTP、存储）。

---

## 2. Jenkins HTTP 客户端（核心经验）

### 2.1 Dio 实例与 Cookie

Jenkins 开启 CSRF 时，**crumb 常与会话 Cookie 绑定**。仅发送 Basic Auth、不复用 `crumbIssuer` 返回的 `Set-Cookie`，容易导致 **POST 一直被 403**。

本项目在 `buildJenkinsDio` 中为 Jenkins 专用 Dio 挂载 **`CookieManager(CookieManager)`**（`dio_cookie_manager` + `cookie_jar`），使拉 crumb 与触发构建共用会话。

### 2.2 CSRF Crumb

- 获取：`GET /crumbIssuer/api/json`，读取 `crumbRequestField` 与 `crumb`。
- 提交：在请求 **Header** 中携带对应字段；部分反向代理会剥离自定义 Header，因此触发构建时还会在 **表单字段** 中附带同名 crumb（与文档常见 curl 写法一致）。

### 2.3 Referer

部分 Jenkins / 安全插件校验 **Referer 与站点同源**。触发构建时使用 **当前 Job 控制台 URL**（`{baseUrl}/job/.../`），而不是仅用站点根路径。

### 2.4 响应类型与错误页

全局 `BaseOptions.responseType` 常为 **JSON**。Jenkins 在 **403** 时经常返回 **HTML**，若仍按 JSON 解析会在 Dio 层抛错，上层看不到真实状态码与正文。

触发构建的请求单独指定 **`responseType: ResponseType.plain`**，便于区分权限问题与 crumb 问题。

### 2.5 触发构建的多策略（必读）

参数化 Job 常见两类接口：

1. **`POST .../buildWithParameters`**  
   - `application/x-www-form-urlencoded`，参数在 body 或 query；附 `delay=0sec` 与 crumb。
2. **`POST .../build`**（Pipeline / WorkflowJob 在不少实例上更可靠）  
   - 表单字段 **`json`**，值为 JSON 字符串：`{"parameter":[{"name":"KEY","value":"VAL"}, ...]}`  

线上常见现象：`buildWithParameters` **403** 或 **400**，改用 **`/build` + `json=`** 后成功。  
实现上按策略依次尝试；对 **401 / 403** 会清空缓存的 crumb 再试；对 **400** 也会切换到下一策略（避免 Pipeline 只接受 `/build` 时卡在单次失败）。

相关代码：`lib/features/jenkins/data/jenkins_api.dart`（`_triggerBuildWithRetries`、`_postParameterizedTrigger`）。

### 2.6 参数默认值与 UI 状态

界面展示默认值常用 `values[name] ?? defaultValue`，但若 **`values` 从未写入**，触发时 Map 可能为空，误走无参 **`POST .../build`**，参数化 Job 易被拒绝。

解决：触发前用 **`BuildParameter.mergeForTrigger(definitions, overrides)`** 合并 Jenkins 定义中的默认值；**Choice** 类型若 API 未带回默认值，回退为 **`choices.first`**。  
相关：`lib/features/jenkins/domain/build_parameter.dart`、`lib/features/jenkins/presentation/project_page.dart`。

### 2.7 参数定义所在 JSON 路径

不同 Jenkins / 插件版本里，参数可能在：

- `actions[].parameterDefinitions`
- `property[]` 中带 `ParametersDefinitionProperty` 的 `parameterDefinitions`

解析顺序与兜底递归见 `JenkinsApi.parseParameters`。多分支流水线须在 **选中子 Job** 上拉详情，参数才与分支一致。

---

## 3. 本地存储与安全

- **Token**：优先 `flutter_secure_storage`；Debug / 无签名环境下钥匙串可能失败（如 macOS `-34018`），`JenkinsConfigRepository` 会回落到 **`SharedPreferences`**（仅开发便利，发布包应保证签名与权限）。
- **macOS**：网络与会见钥匙串相关 entitlement 已在工程中配置；勿随意开启需签名团队的 entitlement，否则本地调试失败。

---

## 4. 国际化与生成代码

- 文案：**`lib/l10n/*.arb`** → `flutter gen-l10n` 生成 `app_localizations*.dart`（勿手改生成文件）。
- Freezed / json_serializable：修改模型后执行 `dart run build_runner build --delete-conflicting-outputs`（若项目启用）。

---

## 5. 测试与验收

```bash
# 一键：单元测试 + 静态分析（推荐提交前执行）
pnpm verify

# 分项
pnpm test      # flutter test
pnpm analyze   # flutter analyze
```

触发 Jenkins 相关逻辑的单测使用 **Mock Dio 拦截器**，覆盖：

- `buildWithParameters` 行为（Referer、表单中含 crumb、plain 响应）
- 403 重试与 crumb 刷新
- **BW 全 400 → 回落 `POST /build` + `json=`**

无法在无凭证环境中 CI 对接真实 Jenkins；若线上仍失败，请抓取 **最后一次请求的 URL、HTTP 状态码及响应正文片段**（HTML 里常有 “No valid crumb” / “Access denied” 等关键字）。

---

## 6. Web 与 CORS

- **`dart:io` `Platform`**：Web 不可用，入口需 **`kIsWeb` / `defaultTargetPlatform`** 分支。
- 浏览器直连 Jenkins 易受 **CORS** 限制；桌面客户端无此问题。Web 调试可改用桌面目标或浏览器禁用 CORS 的调试配置（仅本地）。

---

## 7. 扩展功能时的检查清单

- [ ] 新建 API：是否需 **plain** 响应、是否继承同一 Dio（含 Cookie）？
- [ ] 新建 POST：是否带 **crumb** 与合理 **Referer**？
- [ ] 参数化触发：是否已合并 **默认值**，多分支是否基于 **当前子 Job fullName**？
- [ ] UI 错误：是否通过 **`JenkinsException`** 露出 **`statusCode` / `body`** 便于用户复制排查？
- [ ] 提交前：`pnpm verify` 通过。

---

## 8. 关键文件索引

| 主题 | 路径 |
|------|------|
| Jenkins Dio + Cookie | `lib/core/http/jenkins_http_client.dart` |
| Crumb、树、详情、触发、队列、日志 | `lib/features/jenkins/data/jenkins_api.dart` |
| Repository / Provider | `lib/features/jenkins/data/jenkins_repository.dart` |
| 参数合并 | `lib/features/jenkins/domain/build_parameter.dart` |
| 项目页、触发前合并参数 | `lib/features/jenkins/presentation/project_page.dart` |
| 发版状态机 | `lib/features/release/application/release_controller.dart` |
| 触发构建单测 | `test/jenkins_api_trigger_test.dart` |

---

文档版本与仓库代码同步维护；若 Jenkins 大版本升级导致 API 行为变化，请优先更新上文「Jenkins HTTP 客户端」一节与单测场景。
