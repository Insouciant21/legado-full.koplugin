<div align="center">

<img src="./web/public/logo.svg" width="88" height="88" alt="Legado Server Logo" />

# Legado Server

**Legado 书源处理、内容缓存与 Kindle 同步服务**

<p align="center">
  <b>简体中文</b> | <a href="./README_EN.md">English</a>
</p>

</div>

---

## 项目简介

**Legado Server** 是基于 Kotlin JVM、Ktor 和 SQLite 的独立后端。精简后的 React WebUI 保留书源管理、搜书、目录与正文查看、书架管理、TXT/EPUB 导出和 Android 配置导入。Kindle 阅读仍由 KOReader 插件承担；其他后端管理能力通过 API 保留。

## 核心能力

| 模块 | 说明 |
| --- | --- |
| **书源处理** | 保留 Legado 书源导入导出、分组、检索、调试、登录凭据、详情、目录和正文解析 API；Rhino、Jsoup 和 JsonPath 运行在 JVM 沙箱中。书源校验（Android「校验书源」的同一条链路：源地址/搜索/发现/详情/目录/正文 + 失效分组、`respondTime`、`// Error:` 注释回写）走 `POST /api/sources/check`。 |
| **React 精简 WebUI** | 保留书源管理、搜索、目录/正文查看、书架、导出、Kindle 配对/推送状态与自动上架状态，以及本地 ZIP / 外部 WebDAV 配置导入；不展示替换规则、漫画和有声前台入口。 |
| **Kindle 同步与推送** | 保留 `/api/v1` Kindle Sync Protocol v1：配对授权、逐本上架、增量同步、整本 EPUB 校验、双向阅读进度和冲突解决。自动上架会等待全书缓存完成后生成不可变 EPUB；设备联网时主动领取，支持 Range 续传、SHA-256 校验、原子安装和逐设备确认。 |
| **书架导出** | `POST /api/bookshelf/export` 为书架中的文字书创建 TXT 或 EPUB 2.0 导出任务；缺失正文沿用 Android `WebBook.getContent` 链路抓取并最多尝试 3 次，单章失败仍保留目录结构并以 `null` 占位。默认逐章、单书排队；`parallel=true` 时单书最多 9 章并发，多书任务始终按提交顺序串行。EPUB 支持 NCX 卷层级、`epubScope` 选择章节以及 `epubSize` 拆分文件。`/export-epub` 保留为 EPUB 快捷别名。 |
| **漫画** | 后端 API 保留漫画书籍入库、章节解析、图片代理、内容寻址缓存、预取、配额统计与清除能力；精简 WebUI 不提供漫画阅读器。 |
| **有声书** | 后端 API 保留有声书籍入库、音频规则解析、音频代理、缓存与预取能力；精简 WebUI 不提供音频播放器。 |
| **WebDAV 与备份** | `/webdav` 文件端点继续提供服务器存储区；配置导入弹窗可直接上传 Android 备份 ZIP，也可用 HTTP Basic 连接任意外部 WebDAV，列出 `backup*.zip` 后下载并交给同一个 `BackupImporter`。导入覆盖书源、替换规则、在线书架、阅读进度、书架分组和书签，手机本机文件会跳过。 |

书源 JSON 中的 `exploreUrl` 与 `ruleExplore` 字段和规则解析能力保留；发现页 UI 与 `/api/explore` 功能路由已移除。

## Kindle EPUB 推送

`POST /api/bookshelf/export` 可附带 `pushToKindle=true` 与可选的 `kindleDeviceIds`。服务端在 EPUB 导出成功后把全部输出文件复制到独立、内容寻址的持久目录，再为指定设备创建投递；空的设备列表表示全部未撤销设备。存在失败章节时不会自动推送。

Kindle 使用现有设备 Bearer 令牌调用：

- `GET /api/v1/inbox?cursor=<decimal>`：领取尚未确认的投递。
- `GET /api/v1/inbox/files/{file_id}`：下载 EPUB，支持单段 Range、`If-Range`、ETag。
- `POST /api/v1/inbox/ack`：按本次游标范围返回 `applied` 或 `failed` 并推进收件箱游标。

设备端先写 `.part` 临时文件，校验大小和 SHA-256 后原子改名；确认响应丢失时使用旧游标重试。失败投递保持 pending，不会因为游标推进而丢失。普通导出缓存仍保留 24 小时，推送文件不受该期限影响。

撤销 Kindle 会立即阻止该设备令牌继续访问，并把尚未领取的投递标为已取消；已经领取的书籍不受影响。KOReader 只在设备已经联网时自动检查收件箱，不会主动唤醒 Wi-Fi。

## Kindle 双向书架与阅读进度

已上架书架使用服务端权威的增量协议：

- `GET /api/v1/sync?cursor=...`：拉取书籍、目录、canonical 阅读进度和整本 EPUB 描述符；新书籍不再发送逐章内容包。
- `GET /api/v1/books/{book_id}/epub`：使用设备 Bearer 令牌下载不可变 EPUB，支持单段 Range、`If-Range` 和 ETag。
- `POST /api/v1/sync/ack`：确认内容包已原子安装，再推进设备游标。
- `POST /api/v1/progress`：Kindle 以持久事件上传章节和章内比例；`base_progress_version` 使用精确 CAS 防止静默覆盖。
- `GET /api/v1/progress/conflicts`：读取未解决冲突。WebUI 管理员可读取全部，设备 Bearer 只能读取自己产生的冲突。
- `POST /api/v1/progress/conflicts/{id}/resolve`：以 `server` 或 `kindle` 二选一解决。重复提交同一选择幂等，陈旧版本返回 `conflict_stale`。

整本 EPUB 书的同步记录只保留章节稳定 ID、序号、标题和 `ready` 状态；章节内容哈希、路径及大小仍保存在服务端用于 bundle 与 EPUB 生成，但不会在大书架 reset 中重复发送。完整书架响应因此可在 Kindle 的内存范围内解码；设备端在首次安装时校验文件，并通过本地验证记录避免每次打开或游标重置都重新散列整本 EPUB。

同一设备、同一本书连续离线产生的冲突会合并为一项，候选位置更新为最新事件。解决 Kindle 方案后，服务端会生成新的 canonical progress、同步写入 WebUI 的 `reading_progress` 和 `last_read_at`，之后新设备或增量同步会收到相同位置。

### 自动缓存与自动上架

服务端默认自动补齐网络小说的全本正文缓存。目录刷新成功后，缺少正文的章节进入后台缓存队列，已缓存章节直接复用。同一书源一次抓取一章，不同书源可并行。用户手动创建缓存任务时可选择 1–9 章并发。失败或暂停的缓存任务需手动恢复。启动时会按当前目录重新校正已缓存数与异常归零的目录总数。

部分站会把“本卷结束”等提示页作为 0 字章节放进目录，而书源又没有 `isVolume` 规则。缓存详情会为“正文规则未提取到内容”的失败提供“将失败空章标记为空卷”；管理员确认站点页面确实没有正文后，服务端会持久化该决定，不再抓取该节点正文，EPUB 中保留为卷标题/导航，Kindle 上架中则从可读章节列表移除，再自动重新校验全书。普通抽取失败不会被自动忽略。

书架草稿使用逐本上架。每本网络小说各自通过 15 秒防抖后，只有“全本缓存完成且无失败章节”才会一次性生成整本 EPUB 并提交新书架版本，不再等待书架里的其他书。章节更新同样先在内存中完成全部新增正文，再生成 EPUB 后原子替换；Kindle 在提交前始终看到上一份完整版本，不会看到半本书或逐章中间态。缓存失败时只阻塞该书，其他已就绪书籍继续上架。本地书和删除操作不需要网络缓存。

- `GET /api/v1/publish/auto-status`：查看逐本自动上架阶段、当前待上架书籍、缓存阻塞项和最近上架时间。
- `POST /api/v1/publish/auto-retry`：跳过当前防抖等待；不会绕过缓存完成条件。
- `POST /api/v1/publish`：保留为管理员排障用的手动整架入口。协议路径沿用 `publish` 以兼容已部署的 Kindle 插件，WebUI 统一称为“上架”。

## 部署

### Docker Compose

Compose 将 `legado-server` 的 HTTP 服务发布到宿主机 `28095/tcp`，并把
UDP `47832` 发布给 Kindle/KOReader 的局域网发现。该方式同时适用于 Linux
Docker Engine 和 Docker Desktop；后者会在虚拟机中运行容器，无法从物理局域网
直接访问 host 网络。容器使用独立外部卷 `legado-server-data`，HTTP 会话配置为
`LEGADO_SECURE_COOKIES=false`。管理员凭据存放在仓库外的私有环境文件，已有数据库
沿用原密码。

端口默认发布到所有网卡。电脑还有不可信或公网接口时，可用系统防火墙只允许私网
访问 `28095/tcp` 和 `47832/udp`。

构建和启动使用 `compose.server.yml`；管理员凭据存放在仓库外的私有环境文件。

### 独立 JAR

```bash
LEGADO_PORT=8080 LEGADO_DATA_DIR=./ls_data LEGADO_SECURE_COOKIES=false \
ADMIN_PASSWORD='your_password_at_least_12_chars' \
java -jar legado-server.jar
```

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `LEGADO_HOST` | `0.0.0.0` | HTTP / WebSocket / WebDAV 监听地址；可绑定单一局域网地址 |
| `LEGADO_PORT` | `8080` | HTTP / WebSocket / WebDAV 监听端口 |
| `LEGADO_DATA_DIR` | `/data` | SQLite、缓存、WebDAV 和本地书籍根目录 |
| `ADMIN_PASSWORD` | 无 | 首次启动必需，至少 12 位 |
| `LEGADO_SECURE_COOKIES` | `true` | HTTPS 生产环境保持 `true`；本地 HTTP 设为 `false` |
| `LEGADO_LAN_DISCOVERY` | `true` | 开启局域网 UDP 发现；仅供私有网段中的 KOReader/Kindle 使用 |
| `LEGADO_LAN_DISCOVERY_PORT` | `47832` | LAN 发现 UDP 端口 |
| `LEGADO_LAN_DISCOVERY_GROUP` | `239.255.42.99` | LAN 发现兼容多播地址 |
| `LEGADO_SERVER_NAME` | 主机名 | Kindle 配对列表中显示的服务器名称 |
| `LEGADO_AUTO_CACHE` | `true` | 自动补齐网络小说的正文缓存，同一书源一次抓取一章 |
| `LEGADO_KINDLE_AUTO_PUBLISH` | `true` | 每本书缓存完成后独立自动上架到 Kindle 书架；变量名保留用于兼容 |
| `LEGADO_KINDLE_AUTO_PUBLISH_DELAY_SECONDS` | `15` | 每本书自动上架前的防抖秒数，范围 1–300 |

Compose 已发布 `28095/tcp` 和 `47832/udp`。部分 Docker Desktop、主机防火墙或
Wi-Fi 隔离配置仍可能拦截广播/多播探测；此时在 Kindle 端使用 **Pair manually**
输入一次 `http://局域网地址:28095` 即可。

