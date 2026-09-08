# Legado for KOReader on Kindle

这是一个面向已越狱 Kindle Paperwhite 4 的 KOReader 插件项目，目标是：

- 在 Kindle 本地执行文本小说书源；
- 从 `legado-with-MD3` / Legado Android 备份导入书源、书架、书架分组和阅读记录；
- 使用 KOReader 负责最终阅读、字体、字号、排版和阅读界面；
- 以插件能力补充连续章节、预载和连载目录刷新。

当前备份功能是“Android → Kindle”的单向导入，不提供 Kindle 端导出。项目不把
用户的 WebDAV 备份或 `.env` 凭据放入仓库。

## 当前实现

```text
legado_kindle/       桌面端备份读取、结构校验和导入布局
plugin/              KOReader 插件、书源运行时和本地状态
tests/               不包含个人数据的合成测试
```

## 使用备份工具

```bash
python3 -m unittest discover -v
python3 -m legado_kindle inspect /path/to/backup.zip
python3 -m legado_kindle materialize /path/to/backup.zip /path/to/state
python3 -m legado_kindle source-report /path/to/backup.zip
```

`inspect` 只输出文件结构、数量、字段名、规则使用情况和哈希，不输出书名、作者、URL、正文或配置值。
`source-report` 只输出每条书源使用了哪些规则能力，不输出书源名称、地址或规则值，
便于在导入 Kindle 前发现使用 JavaScript/XPath 的书源。

Android 备份中仅有以下 6 个成员会进入 Kindle 状态：

```text
bookSource.json
bookshelf.json
bookGroup.json
readRecord.json
readRecordDetail.json
readRecordSession.json
```

`readConfig.json`、书架条目中的 `readConfig`、主题、界面设置、服务端、RSS、搜索历史
和其他未来成员都会被忽略；其中书架条目的 `readConfig` 会被剥离。书源 JSON 本身
完整保留，因此聚合源需要的规则、分页、变量、登录和 JavaScript 字段不会因为导入
边界而被硬编码替换。阅读记录会转换为 Kindle 端的阅读历史和续读章节；Android
记录表本身没有章节索引，章节位置使用 `bookshelf.json` 的
`durChapterIndex/durChapterTitle/durChapterTime`。

运行 `make plugin-zip` 可生成可直接复制的 `dist/legado.koplugin.zip`；解压后目录名
应保持为 `legado.koplugin`。

## KOReader 插件

将 `plugin/legado.koplugin` 复制到 KOReader 的 `plugins/` 目录后重启 KOReader。
书架位于 KOReader 主菜单页的 `Legado bookshelf`，也可以从
`Legado → Open bookshelf` 进入；还可以为 `Legado: open bookshelf` 绑定手势或快捷键。

`Legado → Source settings → Source list` 列出导入的全部书源。点选书源后可以执行
登录/Actions、搜索、完整 JSON 修改、启用/禁用和删除；`Add source` 支持粘贴单个
书源/数组或导入 JSON 文件。`Legado → Backup & restore` 只有 Android 备份导入入口，
`Diagnostics` 提供状态和兼容性报告。

打开书架后会先显示从 Android 备份导入的分组，包括“全部书籍”和 Legado 的内置动态
分组；自定义正数分组按 Legado 的幂次二进制标记与书籍 `group` 字段匹配。选择分组后进入书籍列表，
每本书会显示来源和已导入的续读章节。分组、书源和阅读历史都保存在插件自己的
状态目录中，不依赖 Android UI 配置。

选择章节后会建立轻量阅读会话：翻到章节末尾会直接打开下一章，不必退回书架；阅读器
菜单提供目录、上一章和下一章。当前 Legado 章节文档的 KOReader“目录”入口会显示源目录，
普通书籍仍使用 KOReader 原生目录。连载读到已知目录末尾时可以刷新目录以获取新章。
正常阅读只按需下载当前章，不要求先下载全本；整本下载逐章显示可取消进度，已缓存
章节会跳过，取消后可以续传。打开章节后默认后台预载后续 5 章，可调整为 5–10 章。

KOReader 完全负责字体、字号、间距、CSS、嵌入字体开关和其他阅读界面设置。插件不再
读取或写入按书保存的 `reading-settings.lua`，也不把 Android 的阅读设置复制到书架；
切换字体应直接使用 KOReader 的字体菜单。由于每个 Legado 章节是独立文档，章节切换
前插件只会把当前 KOReader 文档的原生阅读字段同步到目标章节的 `.sdr`，不复制位置、
书签、批注或 Android 设置。Emoji 数据不会被删除，插件提供单色
`Symbola_hint.ttf` 作为回退字体，首次安装后必要时重启 KOReader 完成字体扫描。

规则层覆盖普通 CSS/Legado 旧式选择器、JSONPath、常见 XPath、正则（含 `:` 开头的
AllInOne 捕获规则）、`@put/@get` 变量、模板、分页、替换规则和 Legado JavaScript。
QuickJS 桥接把 `java.ajax`、Cookie、变量、缓存、Base64/Hex 等通用主机能力映射到
Kindle。实现不识别任何聚合源名称、接口地址或私有字段；聚合源只作为通用协议覆盖
测试的参考。

书源登录读取源定义中的 `loginUi`、按钮和 `loginUrl`/JavaScript，结果 Cookie、登录
信息和源变量按书源保存到 `<KOReader data dir>/legado/source-sessions.json`，这个
会话文件不属于 Android 备份，首次迁移到 Kindle 后需要在 Kindle 上登录一次。

`@webjs`、真实 Android Java/Jsoup 对象、图片/音频/漫画专属能力和 `java.webView` 会
明确报错，不会静默抓取错误内容。网络和 HTML 处理在 Trapper 子进程执行，以避免慢源
阻塞 KOReader 界面；正文 HTML 会先转换为干净文本再交给 KOReader 排版。

QuickJS 原生库随插件放在 `lib/armel/` 和 `lib/armhf/`；`make plugin-zip` 会构建两种
ARM ABI，KPW4 使用 `armhf`。

Android 备份 ZIP 不包含正文缓存；插件只导入数据和阅读进度，不会把 Android 的
主题、字体或其他界面状态带到 Kindle。
