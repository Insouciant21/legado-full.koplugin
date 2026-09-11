# Legado for KOReader

将 [Legado](https://github.com/HapeLee/legado-with-MD3) 的书源、书架和阅读记录带到已越狱的 Kindle 上，并使用 KOReader 负责最终阅读。

项目主要面向 Kindle Paperwhite 4，当前以文本小说为主。

## 功能特性

- 从 Android Legado 备份包导入书源、书架和阅读记录。
- 兼容普通书源和聚合书源，支持搜索、目录、登录、书源 Actions 和换源。
- 书架提供全部、在读、未读、已读动态分类。
- 支持上一章、下一章连续阅读，章节预加载和连载目录刷新。
- 按需下载章节，也支持带进度的整本下载。
- 清理章节 HTML 后交给 KOReader 排版。
- 字体、字号、间距和其他阅读设置由 KOReader 管理。
- 支持 emoji 回退字体。

Android 备份中的主题、字体、阅读界面设置和书架分组不会导入 Kindle。插件只提供 Android → Kindle 的导入，不提供 Kindle 端导出。

## 安装

### 从源码构建

在 Linux/macOS 环境准备 Python 3、`zip`、`msgfmt`、QuickJS 构建所需工具，以及 Kindle 使用的 ARM 交叉编译器，然后执行：

```bash
make plugin-zip
```

构建完成后会生成：

```text
dist/legado.koplugin.zip
```

### 安装到 Kindle

将生成的 ZIP 复制到 Kindle 的 `/mnt/us/`，解压到 KOReader 的插件目录，并保持目录名为 `legado.koplugin`：

```bash
mkdir -p /mnt/us/koreader/plugins
unzip -o /mnt/us/legado.koplugin.zip -d /mnt/us/koreader/plugins
```

也可以直接将完整的 `legado.koplugin` 目录复制到：

```text
/mnt/us/koreader/plugins/legado.koplugin/
```

重启 KOReader 后，在 `Legado` 菜单中使用插件。

## 导入备份并开始阅读

1. 将 Android Legado 导出的备份 ZIP 复制到 Kindle。
2. 打开 `Legado → Backup & restore → Import Android backup`。
3. 导入完成后，从 `Legado bookshelf` 打开书籍。
4. 选择书籍和章节即可阅读；阅读到章节末尾会自动进入下一章。

需要登录或依赖浏览器验证的书源，功能取决于 Kindle 上可用的浏览器环境；文本内容会由 KOReader 打开和排版。
