# Legado KOReader plugin

Copy this directory as a whole into KOReader's `plugins/` directory:

```text
koreader/
└── plugins/
    └── legado.koplugin/
        ├── _meta.lua
        ├── main.lua
        ├── assets/
        │   ├── Symbola_hint.ttf
        │   └── Symbola-LICENSE.txt
        ├── legado/
        │   ├── backup.lua
        │   ├── browser_input.lua
        │   ├── content.lua
        │   ├── font.lua
        │   ├── javascript.lua
        │   ├── network.lua
        │   ├── rules.lua
        │   ├── runtime.lua
        │   ├── session.lua
        │   ├── source.lua
        │   └── storage.lua
        └── lib/
            ├── armel/liblegado_js.so
            └── armhf/liblegado_js.so
```

## Import boundary

`Legado → Backup & restore` imports an Android backup ZIP. It does not export
an archive. Only `bookSource.json`, `bookshelf.json`, `bookGroup.json`,
`readRecord.json`, `readRecordDetail.json` and `readRecordSession.json` are
stored. Android themes, reader settings, servers, RSS data, search history and
other members are ignored. The `readConfig` object nested in a bookshelf book
is also removed.

Source definitions are kept complete, including aggregate-source rules,
pagination, variables, JavaScript, login UI and login actions. No source name,
endpoint or private aggregate protocol is embedded in the plugin.

The record tables are processed once after import. Android stores the current
chapter in the bookshelf (`durChapterIndex`, `durChapterTitle` and
`durChapterTime`), while `readRecord*.json` stores reading statistics. The
plugin converts the chapter index to its own one-based continuation record and
stores statistics separately in `reading-history.lua`.

## Bookshelf and reading

The bookshelf is available directly from the KOReader main-menu page as
`Legado bookshelf`; it is also available as `Legado → Open bookshelf`. The
dispatcher action `Legado: open bookshelf` can be assigned to a gesture or key.
The first screen contains `All books` and imported Legado groups. Positive
custom group IDs are matched as Legado's power-of-two flags against a book's
stored group; negative built-in groups are derived from generic type, source,
progress and update fields.

Selecting a book opens its source chapter list. The current reading session
contains the book, source and chapter list. At the end of a cached or newly
downloaded chapter, the plugin opens the next chapter directly. The reader
menu exposes the local chapter list, previous chapter and next chapter; the
normal KOReader Table of contents action is redirected only for a Legado
chapter document. The chapter list has an explicit refresh action for serial
updates.

Only the current chapter is needed for normal reading. Whole-book download is
sequential, cancellable and resumable because cached chapters are skipped.
After a chapter is ready, the plugin prefetches the next five uncached
chapters in the background; `Legado → Reading` can change this from 5 to 10.

KOReader owns font, size, spacing, CSS, embedded-font handling, position,
bookmarks and all other reading presentation. The plugin no longer reads or
writes its old per-book `reading-settings.lua` profiles. Use KOReader's own
font and reading menus. Emoji remain in source/book/chapter text; the bundled
monochrome `Symbola_hint.ttf` is installed as an optional fallback for common
emoji on KPW4.

## Sources and login

`Legado → Source settings → Source list` lists all imported source types.
Selecting a source provides login/Actions, search, full JSON editing,
enable/disable and delete. `Add source` accepts a source object or array from
pasted JSON or a JSON file.

The rule layer covers common CSS/legacy selectors, JSONPath, XPath, regex,
`@put/@get` variables, templates, pagination, replacements and Legado
JavaScript. QuickJS maps generic `java.ajax`, Cookie, variables, cache,
Base64 and Hex host functions to Kindle, so aggregate sources are handled by
their imported definitions rather than a source-specific adapter.

Source-defined login controls and actions use `loginUi` plus `loginUrl` or
JavaScript. Cookies, login information and source variables are stored per
source in `<KOReader data dir>/legado/source-sessions.json`; this file is not
an Android backup member and must be treated as private credential data.

WebView-only JavaScript, Android Java/Jsoup objects, image/audio/manga-only
features and `java.webView` remain explicit unsupported capabilities.
