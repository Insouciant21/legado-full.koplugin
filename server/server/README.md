# Legado Server

独立的单用户 Web 服务。首次启动必须设置至少 12 位的 `ADMIN_PASSWORD`；密码只在初始化时写入 PBKDF2-HMAC-SHA256 哈希，之后可移除该环境变量。

## 运行

```bash
cp .env.example .env
docker compose --env-file .env -f compose.server.yml up -d --build
```

仓库根目录的 `compose.server.yml` 将 HTTP `28095/tcp` 和 LAN 发现
`47832/udp` 发布到宿主机，适用于 Linux Docker Engine 与 Docker Desktop。
电脑有不可信或公网接口时，用主机防火墙限制这两个端口仅允许私网访问。

## 重置密码

在停止服务或确保没有并发请求时执行：

```bash
docker compose --env-file .env -f compose.server.yml run --rm legado-server reset-password 'new-password-at-least-12-chars'
```

这会撤销全部浏览器会话。

## 当前实现边界

已提供安全登录、会话、CSRF、防爆破、SQLite 书源 CRUD、JSON 导入导出、版本冲突与结构校验。

**书源解析已可用**：书源规则（`ruleSearch`/`ruleBookInfo`/`ruleToc`/`ruleContent`/`ruleExplore`）在
JVM 沙箱（Rhino + Jsoup + JsonPath）中执行，搜索、详情、目录、正文、发现分类、漫画图片、
有声书音轨、登录流程与 `data:` 聚合源载荷均已打通；书源校验（Android「校验书源」的四段链路 +
失效分组/`respondTime`/`// Error:` 注释回写）由 `POST /api/sources/check` 提供。

## 与 Android 的已知差异（刻意保留）

- **页面内同步桥接**：Android 的 `webJs` 跑在 WebView 页面里，页面脚本可以**同步**调用
  `java.ajax(...)` 等（`@JavascriptInterface`）。服务端用无头浏览器执行同一段 JS，但 CDP 无法
  提供同步返回值，页面内只能拿到纯 DOM/`window` 能力；规则级 JS（`<js>...`、`ruleSearch` 等）
  不受影响，仍在服务端沙箱里完整执行。
- **界面交互**：`payAction`（购买）、`callBackJs` 的点击类事件（`clickCustomButton`/`clickAuthor`…）、
  `customButton`、`startRead`/`saveRead`/`endRead` 属于阅读界面/阅读端行为，服务端没有对应交互，
  因此不触发；书架动作事件（`addBookShelf`/`delBookShelf`）由服务端按 Android 语义触发。
- **主题与阅读配置**：`getThemeConfig*`/`getReadBookConfig*` 报告 Android 的出厂默认值
  （内置 `assets/defaultData` 同名资源），服务端没有可配置的阅读界面。
