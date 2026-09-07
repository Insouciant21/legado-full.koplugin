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
        │   ├── font.lua
        │   ├── javascript.lua
        │   ├── network.lua
        │   ├── rules.lua
        │   ├── runtime.lua
        │   ├── session.lua
        │   ├── source.lua
        │   ├── storage.lua
        │   └── content.lua
        └── lib/
            ├── armel/liblegado_js.so
            └── armhf/liblegado_js.so
```

The plugin can now import an Android Legado backup ZIP and export the imported
state back to an Android-shaped ZIP. It preserves unknown and Android-specific
members byte-for-byte, including `servers.json` and `config.xml`; an existing
on-device state is moved to a `.previous` directory before a new import is
activated.

The source status screen also counts text sources and marks sources containing
JavaScript or XPath. The Kindle rule layer covers CSS, Legado's old
`class./tag./id.` selectors, numeric and bracket indexes, text, JSONPath, common
XPath, regex (including `:` AllInOne capture rules), `@put/@get` rule variables,
composition, templates, replacement rules, and the common
`nth-*`/`eq` selector filters used by legacy sources.

Search and page requests also understand Legado URL options for GET/POST,
form/JSON bodies, page-list placeholders such as `<1,2>`, and optional GBK
conversion when the KOReader base exposes its iconv library. JSON list rules
are returned as JSON records, so a source can use `@json:` paths for search
results as well.

The bookshelf is available directly from the KOReader main-menu page as
`Legado bookshelf`; it is also available as `Legado → Open bookshelf` for
hosts that group plugin entries. The dispatcher action `Legado: open bookshelf`
can also be assigned to a KOReader gesture or key. The search flow is
intentionally conservative: choose one imported text source, search it, choose
a book, then continue from the last selected chapter, jump to a chapter number,
or open one chapter.

Opening a chapter creates a lightweight reading session containing the book,
source and chapter list. At the end of a cached or newly downloaded chapter,
the plugin switches directly to the next chapter without returning to the
bookshelf. The reader menu exposes the chapter list, next chapter and previous
chapter actions while a Legado chapter is open. KOReader's normal Table of
contents action is redirected to this Legado chapter list for these standalone
TXT chapters, while non-Legado documents keep their native ToC. When a serial
reaches the last known chapter, the plugin refreshes the table of contents;
newly published chapters can then be opened automatically. Only the current
chapter is needed for normal reading, and cached chapters are reused after
restarting KOReader.

The reader prefetches the next five uncached chapters in the background after a
Legado chapter is ready. `Legado → Prefetch next N chapters` changes this to
any value from 5 through 10. Prefetch is sequential and is cancelled by normal
chapter navigation, so it does not put a progress dialog over the page and an
incomplete request can be retried in the foreground.

`Download entire book` downloads chapters one at a time with a visible,
cancellable chapter progress bar. Completed chapters are kept in the per-book
cache, so a later attempt skips them and resumes at the first missing chapter.
After all chapters are cached, the plugin writes both UTF-8 TXT and EPUB; the
EPUB is opened when the KOReader archive writer is available. The
restored-bookshelf entry can perform the same flow for books recorded in
`bookshelf.json` by matching their original source URL/name.
`ruleContent.replaceRegex` is applied to the merged chapter text for common
Java-regex replacement rules.

Legado content rules may return HTML fragments. After rule processing, the
plugin converts block tags such as `p`, `div`, and `br` to paragraph breaks,
decodes common HTML entities, and removes scripts, styles, images, SVG payloads,
and remaining tags. This is deliberately a text-novel policy: it keeps the
aggregate source's prose readable on KPW4 rather than exposing web markup in a
TXT document. The same normalized text is used when building EPUB paragraphs.

Emoji are kept in book names, chapter names, backup data and chapter text. On
KPW4, the bundled monochrome `Symbola_hint.ttf` is copied to KOReader's
`fonts/legado/` directory and registered as a CRe/UI fallback. This lets common
emoji render as grayscale outline glyphs suitable for an e-ink screen instead
of deleting them or leaving square placeholders. If the running KOReader build
cannot register a newly copied font, the plugin asks for one restart so its
normal font scan can load it.

JavaScript rules run in the bundled QuickJS bridge. The bridge maps the common
Legado host surface (`java.ajax`, URL options, Cookie, source/book variables,
memory/cache, Base64 and Hex) to Lua, including typed `data:` responses used by
aggregated sources. JSON-mapped remote `jsLib` helpers are downloaded and
cached per source. `ruleToc.preUpdateJs` and `formatJs` are also executed;
function-style `formatChapter(index, title)` hooks are supported. Source login is
available from `Legado → Log in to a text source`: the plugin reads the source's
`loginUi`, supports text/password/number/textarea controls, offers its declared
button actions, and runs `loginUrl` in the same QuickJS host. `source.getLoginInfo`,
`getLoginInfoMap`, `putLoginInfo`, source variables, and HTTP Cookie/Set-Cookie state
are persisted per source in
`<KOReader data dir>/legado/source-sessions.json`, then restored for later workers.
This is deliberately outside the Android ZIP because the Android backup does not
contain live authentication state; credentials must be entered once on Kindle.
WebView-only JavaScript (`@webjs`), Android Java/Jsoup objects, browser/captcha-only
login, and image/audio features remain explicit unsupported capabilities.
The session JSON is permission-restricted where the KOReader filesystem supports it,
but it is not end-to-end encrypted; treat it as private credential/token data.

Choose a backup by long-pressing the ZIP in the file chooser. Exporting creates
`legado-kindle-YYYYMMDD-HHMMSS.zip` in the selected folder. The book-source
members remain Android-shaped; WebDAV's separate `bookProgress/` sidecars are
not ZIP members. Network and HTML work run in a Trapper subprocess so a slow
source does not block the KOReader UI. The runtime is for text sources only
and keeps explicit errors for capabilities it cannot safely execute.
