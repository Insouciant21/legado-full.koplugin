# Legado for KOReader on Kindle

这是一个面向越狱 Kindle Paperwhite 4 的 KOReader 插件项目，目标是：

- 在 Kindle 本地执行文本小说书源；
- 导入和导出 `legado-with-MD3` 的 Android 备份；
- 让 Kindle 生成的备份可以被 Android 版直接恢复；
- 使用 KOReader 负责最终阅读和排版。

当前里程碑是备份兼容核心和 Kindle 端本地导入导出。它不把用户的
WebDAV 备份放进仓库，也不会把 `.env` 中的凭据写入报告。

## 当前实现

```text
legado_kindle/       桌面端备份读取、结构校验和无损重打包
plugin/              KOReader 插件最小入口和本地状态存储
tests/               不包含个人数据的合成测试
```

## 使用备份工具

```bash
python -m unittest discover -v
python -m legado_kindle inspect /path/to/backup.zip
python -m legado_kindle roundtrip /path/to/backup.zip /path/to/output.zip
python -m legado_kindle source-report /path/to/backup.zip
```

`inspect` 只输出文件结构、数量、字段名、规则使用情况和哈希，不输出书名、作者、URL、正文或配置值。
`source-report` 只输出每条书源使用了哪些规则能力，不输出书源名称、地址或规则值，
便于在导入 Kindle 前发现使用 JavaScript/XPath 的书源；这些能力已有对应的
Kindle 运行时实现，但仍可用报告提前识别耗时或依赖 Android 专属对象的来源。

运行 `make plugin-zip` 可生成可直接复制的
`dist/legado.koplugin.zip`；解压后目录名应保持为 `legado.koplugin`。

导入备份时，Android ZIP 的每个成员会原样保存到 Kindle 状态目录；导出
时重新生成 Android 形状的 ZIP。因此 `servers.json`、`config.xml` 和暂未
支持的未来成员不会因为 Kindle 端暂时不理解而丢失。

## KOReader 插件

将 `plugin/legado.koplugin` 复制到 KOReader 的 `plugins/` 目录后重启
KOReader。书架现在位于 KOReader 主菜单页：打开菜单图标后选择 `Legado bookshelf`
即可进入；在 `Legado → Open bookshelf` 也保留了同一个入口。还可以在 KOReader
的手势/快捷键设置中绑定 `Legado: open bookshelf`。`Legado → Source settings →
Source list` 会列出备份中的全部书源；点选书源后可执行登录/Actions、搜索、完整
JSON 修改、启用/禁用和删除。`Source settings → Add source` 支持粘贴单个书源或
书源数组，也支持从 JSON 文件导入；相同 `bookSourceUrl` 会更新原书源。备份入口
已集中到 `Legado → Backup & restore`，诊断信息位于 `Diagnostics`。再次导入或
编辑书源时旧状态会被移动到 `.previous` 目录保留。

在 KPW4 上的最小使用流程：先安装能在该设备固件上运行的 KOReader，把
整个 `plugin/legado.koplugin/` 目录复制到
`/mnt/us/koreader/plugins/`，重启 KOReader；再通过 USB 把 Android 导出的
备份 ZIP 放到 Kindle，进入 `Legado → Backup & restore → Import Android backup`。搜索书源时
Kindle 需要自己的 Wi-Fi；HTTPS 会使用 KOReader 自带的 LuaSec（若该构建
没有 HTTPS 模块，插件会明确提示）。

当前已经接入文本书源的搜索、书籍信息、目录分页、正文分页和阅读闭环；单章会
生成干净的 UTF-8 TXT，整本书会同时生成带原生目录的 EPUB 和 TXT。选择章节后会
建立 Legado 阅读会话：翻到章节末尾会直接切换到下一章，不必退回书架；阅读器菜单
中也提供目录、上一章、下一章。阅读相关操作位于 `Legado → Reading`。连载读到已知目录末尾时会刷新目录，若源已发布新章
则继续打开新章。正常阅读只按需下载当前章，不要求先下载全本。目录页支持
继续阅读、按章节号跳转，并会自动刷新旧版本留下的 HTML TXT 缓存。整本下载改为
逐章执行，显示可取消的章节进度；已经缓存的章节会跳过，取消后再次下载可以续传。
阅读会话会把 KOReader 的标准“目录”入口重定向到 Legado 章节列表（仅对当前
Legado 章节生效，普通书籍仍使用 KOReader 原生目录），并在打开章节后后台预载
后续未缓存的章节。默认预载 5 章，可在阅读器的 `Legado → Reading → Prefetch next N chapters`
中调整为 5–10 章；预载请求按章顺序执行，不会用进度弹窗遮挡当前阅读。
阅读中的目录直接使用已保存的本地章节列表，不再为打开目录重复请求网络书源；
目录菜单中的“Refresh chapter list”才会联网检查连载更新。
规则层覆盖普通 CSS/Legado 旧式选择器、JSONPath、
常见 XPath、正则（含 `:` 开头的 AllInOne 捕获规则）、`@put/@get` 变量、模板、
分页、替换规则和 Legado JavaScript。插件内置 QuickJS
桥接，并把 `java.ajax`、Cookie、变量、缓存、Base64/Hex 等主机能力映射到
Kindle；因此使用 JavaScript、`data:` 中间载荷或带 JSON URL options 的聚合书源，
只要其行为属于 Legado 的通用 `java.*`/HTTP 协议，就可以直接走搜索 → 详情 →
目录 → 正文链路。实现不识别聚合源名称、接口地址或私有字段，聚合源只作为协议
覆盖测试的参考。

书源登录也已经接入：插件解析备份中的 `loginUi` 文本/密码/数字/多行输入框，
显示书源定义的按钮动作，并执行书源的 `loginUrl` JavaScript。登录信息、服务端返回的
Cookie 以及 `source.setVariable` 写入的源变量，会按书源保存到
`<KOReader data dir>/legado/source-sessions.json`，后续每个独立的搜索、详情、
目录和正文 worker 都会恢复它们。因此书源所需的登录会话可以跨操作和
KOReader 重启复用。这个文件不属于 Android ZIP，避免把密码和活动会话伪装成
Android 备份成员；从 Android 备份首次迁移到 Kindle 时需要在 Kindle 上输入一次
登录信息。只依赖 Android WebView/浏览器交互、验证码页面或 Android Java 加密类
的登录动作会明确报不兼容，普通 HTTP/JavaScript 登录流程可以运行。
该会话文件按 KOReader 数据目录权限保存，但当前不是端到端加密格式；请勿把它
公开分享，若迁移设备应把它视为包含账号凭据和会话令牌的私密文件。

`@webjs`、真实 Android Java/Jsoup 类、需要浏览器登录或图片/音频/漫画的专属
能力没有等价的 Kindle 实现，会被明确报错。无法等价转换的复杂 Java 正则也会在运行时返回错误，避免静默抓取错误
内容。目录 `preUpdateJs` 和 `formatJs` 已接入，后者兼容备份中常见的
`formatChapter(index, title)` 形式。

Emoji 不会被删除。插件随包提供适合 KPW4 墨水屏的单色 `Symbola_hint.ttf`，首次
运行会安装到 KOReader 的 `fonts/legado/` 并注册为正文/UI 回退字体；因此书名、
章节名和正文中的常见 emoji 会以灰度轮廓字形显示。若当前 KOReader 构建不能在
运行中注册新字体，插件会提示重启一次以完成字体扫描。

QuickJS 原生库随插件同时放在 `lib/armel/` 和 `lib/armhf/`，`make plugin-zip`
会构建并打包两种 ARM ABI。KOReader 会根据设备加载器选择可用的库；KPW4 使用
的是 `armhf`。

导入/导出不依赖手机、电脑或 WebDAV，ZIP 可以通过 USB 直接放到 Kindle 上。

注意：Android 备份 ZIP 不包含正文缓存；WebDAV 中的 `bookProgress/` 是独立
的阅读进度同步目录，不属于这 17 个 ZIP 成员。插件对已下载到 Kindle 的 TXT
使用 KOReader 自己的阅读进度，Android 的 `readRecord*.json` 则作为备份成员
原样保留并可随 ZIP 恢复。
