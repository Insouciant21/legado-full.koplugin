# AGENTS.md — 自动化代理项目注意事项

给在本仓库工作的编码代理的实操备忘。项目结构见 README.md，导入边界见
docs/backup-format.md。

## gettext 的 `_` 绝不能被循环遮蔽

KOReader 插件模块普遍以 `local _ = require("gettext")` 引入翻译函数
（main.lua、legado/webdav.lua、legado/book_detail.lua 等）。在这些模块里
**永远不要把 `_` 用作循环变量名**：

```lua
-- 错误：循环变量把 `_` 遮蔽成索引（数字），循环体内的 _("Folder")
-- 变成"调用一个数字"，直接抛运行时错误。
for _, item in ipairs(items) do
    display_items[#display_items + 1] = {
        text = item.name,
        mandatory = _("Folder"),
    }
end

-- 正确：占位变量显式命名。
for item_index, item in ipairs(items) do
    ...
end
```

真实案例（2026-11-10）：main.lua 的 `showWebDAVDirectory` 里 `for _, item`
使循环体内的 `_("Folder")` 抛出
`attempt to call local '_' (a number value)`，WebDAV 目录列表无法打开。

注意 `luajit -b` 语法检查查不出这类错误（遮蔽是合法语法，只有运行路径触发）。
写完循环后要在宿主机上真正执行一次相关函数——纯函数模块可以模仿
tools/test-webdav-parse.lua 的 package.preload 桩模式做宿主机冒烟测试。

## 真机调试备忘（USBNet SSH 可达时）

- **部署后必须完全重启 KOReader** 才会加载新模块（Lua 模块缓存在运行中的
  进程里）。菜单里的「重启 KOReader」经合成触摸经常不可靠；直接
  `kill $(pgrep luajit)` 后重新拉起 koreader.sh 最稳妥。确认重启生效要用
  进程启动时间对照文件 mtime，不能凭截图猜。
- 设备上的 busybox `ps` 输出不可靠（截断/漏行）。判断进程一律用
  `for p in $(pgrep <name>); do tr '\0' ' ' </proc/$p/cmdline; done` 这类
  /proc 直读方式。
- **截图**：`dd if=/dev/fb0`，帧缓冲为 8bpp 灰度、stride 1088、可视区
  1072×1448（虚拟高度 6144，首缓冲即当前画面），本地按 stride 还原成 PNG
  即可查看。
- **触摸注入**：向 `/dev/input/event2`（goodix-ts）写多点协议 B 的
  input_event（struct：2×int32 timeval、u16 type、u16 code、s32 value，
  共 16 字节）即可模拟点击和滑动，与截图配合形成"操作→看结果"闭环。
- 设备空闲几分钟会挂起并断开 WiFi；长流程中途先 `ping` 确认在线再操作，
  掉线后需要人工唤醒。
