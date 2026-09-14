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
an archive. Only `bookSource.json`, `bookshelf.json`, `readRecord.json`,
`readRecordDetail.json` and `readRecordSession.json` are stored. Android
themes, reader settings, servers, RSS data, search history, `bookGroup.json`
and other members are ignored. The `readConfig` object and Android bookshelf
group fields nested in a bookshelf book are also removed.

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
The first screen contains only `All books`, `Reading`, `Unread` and `Read`.
These are plugin-owned dynamic categories. `Reading` means that a book has
started progress but has not reached its last known chapter; `Read` means its
current chapter is the last known chapter; `Unread` has no start evidence.
The Kindle-native progress and imported Android reading history are combined.
Android bookshelf groups and the book `group` bitmask are not imported or
consulted.

Selecting a book opens its source chapter list. The current reading session
contains the book, source and chapter list. Its static TOC is stored separately
from a tiny current-position file, and common rule variables are stored once
on the book instead of being repeated in every chapter. At the end of a cached
or newly downloaded chapter, the plugin opens the next chapter directly. The
reader menu exposes the local chapter list, previous chapter and next chapter;
the normal KOReader Table of contents action is redirected only for a Legado
chapter document. The chapter list has an explicit refresh action for serial
updates. Existing schema version 1 sessions are compacted automatically.

For source-independent performance, a pure JavaScript `chapterUrl` rule is
evaluated for all items on a TOC page in one QuickJS bridge call. Rules that
contain stateful operations, a trailing selector, or JavaScript chapter-name/
VIP rules retain the original per-chapter evaluation order.

Only the current chapter is needed for normal reading. Whole-book download is
sequential, cancellable and resumable because cached chapters are skipped.
After a chapter is ready, the plugin prefetches the next five uncached
chapters in the background; `Legado → Legado settings` can change this from 5
to 10.

The source search page follows the Android workflow: choose all enabled text
sources or an explicit subset, enter a keyword with the KOReader keyboard,
search sources concurrently, merge the same title/author from multiple
origins, and act on each candidate without waiting for every source. Results
can be added to the bookshelf, opened directly, or loaded again page by page.
The search concurrency is configurable from 1 to 4 in `Legado settings`.

`Manage bookshelf` and the book-detail page can remove a shelf entry. Removal
also clears its plugin-owned chapter cache, cover cache, reading position and
imported reading-history record; KOReader's own document settings are not
modified.

KOReader owns font, size, spacing, CSS, embedded-font handling, position,
bookmarks and all other reading presentation. The plugin no longer reads or
writes its old per-book `reading-settings.lua` profiles. Use KOReader's own
font and reading menus. Since each Legado chapter is a separate document, the
plugin copies only KOReader's native presentation fields to the next chapter's
`.sdr` before switching; position, bookmarks, annotations and Android settings
remain document-specific. Emoji remain in source/book/chapter text; the bundled
monochrome `Symbola_hint.ttf` is installed as an optional fallback for common
emoji on KPW4.

Chapter content passes through a plugin-side ContentProcessor before it is
cached: the source's `ruleContent.replaceRegex` is applied first, then HTML is
parsed structurally, `head`/script/style/SVG/media containers are discarded,
block tags become paragraph boundaries, entities are decoded, duplicate
chapter titles and empty paragraphs are removed, and the result is written as
plain XHTML paragraphs. No fixed font, line-height or paragraph-indent CSS is
embedded, so the final presentation remains KOReader's responsibility. This
is shared by foreground downloads, background prefetch, old-cache migration
and whole-book downloads.

## Sources and login

`Legado → Source settings → Source list` lists all imported source types.
Selecting a source provides login/Actions, search, full JSON editing,
enable/disable and delete. `Add source` accepts a source object or array from
pasted JSON or a JSON file.

Book details provide `Change source`, modeled after Legado Android's
`ChangeBookSourceDialog`: opening it searches all enabled searchable text sources
with the book title, optionally checking the author, and presents the candidates
in one result list. Results arrive incrementally while the worker reports
`source/total` progress. On KPW4 the source rules run in one sequential worker
to keep the 32-bit memory footprint bounded. The list can be filtered by source
name/title and by one or more source groups; selected groups also limit the
search pool, the current source is marked, and the menu opens at that result
when it is available. Long-pressing a result opens the generic source actions
(login, edit, enable/disable, reorder and delete).

The result options can also load book information or probe chapter counts before
selection. A TOC probe deliberately returns only the count and is capped at 24
candidates on Kindle; the full TOC is fetched only for the selected source. This
keeps the Android-style workflow usable on KPW4 without retaining multiple large
chapter lists. Tapping a candidate fetches and validates its TOC before the
replacement is committed, maps the old reading position by chapter title (then
index), removes old source chapter/cover/session caches, and refreshes the detail
and chapter-list parent. A broken candidate source therefore cannot replace a
working shelf entry.

The rule layer covers common CSS/legacy selectors, JSONPath, XPath, regex,
`@put/@get` variables, templates, pagination, replacements and Legado
JavaScript. QuickJS maps generic `java.ajax`, response objects, Cookie/login
state, source variables, `infoMap`, cache, browser/WebView, Base64/Hex,
cryptography and common Java/Jsoup objects to Kindle, so aggregate sources are
handled by their imported definitions rather than a source-specific adapter.
Discovery sources may return newline/`&&`/JSON/script-defined categories and
their select/toggle/button actions; each source's filter state is persisted
independently.

Source-defined login controls and actions use `loginUi` plus `loginUrl` or
JavaScript. Cookies, login information and source variables are stored per
source in `<KOReader data dir>/legado/source-sessions.json`; this file is not
an Android backup member and must be treated as private credential data.

`@webjs` and `java.webView` use the Kindle Chromium/browser bridge as a
background DOM renderer: the resulting HTML is returned to KOReader, which
does the actual reading layout. `startBrowser*` and browser-based
login/discovery actions are the interactive exception and may require the
browser page to be brought to the foreground for verification. Android-only
UI, RSS/image/audio/manga features and `qread` are outside the text-reader
scope and remain explicit limited/unsupported
capabilities.

Cloudflare-like interstitials are detected asynchronously, and the bridge
does not attempt to bypass or solve them on the older KPW4 Chromium engine. If
a challenge is detected, the request ends immediately with an explicit
unsupported message; source-side catches cannot turn it into a successful
action. After an ordinary interactive browser completion, cookies are merged
before an optional HTTP refetch. A challenge that rejects the Kindle engine
requires a source-side alternative, a newer browser, or an external cookie
handoff.
