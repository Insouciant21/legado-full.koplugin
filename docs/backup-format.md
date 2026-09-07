# Android backup compatibility baseline

This document records the structure observed in the WebDAV backup baseline used
for development. It contains no book names, authors, URLs, credentials, or
chapter text.

## Container

The backup is a ZIP containing 17 top-level files:

```text
bookshelf.json
bookGroup.json
bookSource.json
rssSources.json
readRecord.json
readRecordDetail.json
readRecordSession.json
searchHistory.json
txtTocRule.json
httpTTS.json
keyboardAssists.json
dictRule.json
servers.json
readConfig.json
shareReadConfig.json
themeConfig.json
config.xml
```

The writer keeps this file order for known members. Unknown future members are
preserved after the known members.

## Baseline counts

The latest sampled archive contains:

| Data | Count |
| --- | ---: |
| Text book sources | 167 |
| Bookshelf entries | 60 |
| Book groups | 14 |
| Read records | 101 |
| Read record details | 141 |
| Read record sessions | 8488 |

All sampled `bookSourceType` values are `0`, so text novels are the current
runtime scope.

## Source features observed

The sample uses discovery, pagination, cookies, login configuration, source
headers, replacement rules, and JS helper libraries. It has no non-empty
`mainJs` or content `webJs` fields, but this does not remove the need for a
sandboxed JS capability: 7 source JS libraries are present and many rule
strings use template/Java helper expressions. Several legacy sources also use
`@put:{...}`/`@get:{...}` to carry IDs from one rule stage to the next; the
Kindle runtime keeps those variables per book/chapter instead of sharing them
between unrelated search results.

The current reference capability scan reports 167 text sources. It sees 26
explicit CSS markers, 110 JSON-path-like rules, 366 template strings, and 148
JavaScript/helper-bearing strings across 48 sources. 46 sources also carry a
non-empty whole-content replacement rule. These are diagnostics, not a claim
that every source without a marker is fully compatible; the Kindle runtime
supports the common rule forms and runs ordinary Legado JavaScript through the
bundled QuickJS bridge, while it reports the first Android/WebView-only
capability it actually reaches.

The sampled aggregate source uses JavaScript URL rules which return typed
`data:` URIs and source-defined URL options.
The Kindle network adapter decodes those URIs and converts typed HTTP bodies to
hex before the JS rule, matching the source's `java.hexDecodeToString` flow.
Its search, detail, catalog, and content stages have been exercised with a
sanitized end-to-end fixture.

The sampled aggregate source also contains a `loginUi` with text/password fields
and button actions such as `login(true)` and `checkStatus()`. The Kindle plugin
executes those actions through `loginUrl`; its resulting login JSON, source
variables, and HTTP cookies are stored in the separate Kindle-side
`legado/source-sessions.json` file. Live authentication is not part of the
Android ZIP baseline, so the first Kindle login is an intentional post-restore
step rather than a change to the Android archive format.

`ruleContent.replaceRegex` is a whole-content AnalyzeRule expression. The
Kindle runtime supports its common `##match##replacement` form, including
ordinary Java-regex constructs that can be translated to Lua patterns and
`$1`-style captures. Java-regex constructs such as lookarounds, Unicode regex
classes, and other non-equivalent expressions remain explicit incompatibilities
for the Lua replacement path; they can still be handled inside a JavaScript
rule when the source itself provides that logic. List rules beginning with `:`
also expose their capture groups as `$1`, `$2`, and so on for legacy
AllInOne sources.

## Opaque members

`servers.json` is not valid JSON in the sampled backup and is retained as raw
bytes. `config.xml` is parsed only for well-formedness and shape; its values are
not normalized yet. This prevents Android-only settings from being lost during
a Kindle → Android round trip.

## Kindle state layout

The migration core materializes a backup as:

```text
<state>/
├── manifest.json
└── android/
    ├── bookSource.json
    ├── bookshelf.json
    ├── ...
    └── config.xml
```

`manifest.json` contains only schema metadata, member hashes, counts, and field
names. The raw Android-shaped members remain the source of truth until the
Kindle runtime model is implemented.

The sampled WebDAV service also exposes a separate `bookProgress/` collection
of per-book JSON sidecars. It is not part of the Android backup ZIP and is not
silently folded into the 17-member archive. The current Kindle path preserves
the Android read-record members and lets KOReader own progress for downloaded
TXT documents.

On the device, the plugin uses the same shape under its KOReader data directory:

```text
<KOReader data dir>/legado/state/
├── manifest.json
└── android/
    ├── bookSource.json
    ├── bookshelf.json
    └── ...
```

An import is staged first. If a previous state exists, it is renamed to a
timestamp-independent `.previous` sibling before the new state is activated,
so a failed activation does not discard the previous state.
