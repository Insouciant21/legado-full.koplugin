# Android backup import boundary

This document describes the subset of a Legado Android backup that the Kindle
plugin imports. It is deliberately an import-only format: the Kindle plugin no
longer exports or round-trips Android configuration.

## Supported members

The Android ZIP must contain these six top-level JSON members:

```text
bookSource.json
bookshelf.json
bookGroup.json
readRecord.json
readRecordDetail.json
readRecordSession.json
```

`bookSource.json` is kept as a complete source definition. No source name,
aggregate endpoint, private field, login form or rule is hard-coded by the
Kindle port. This is the compatibility boundary needed by ordinary and
aggregate Legado sources.

`bookshelf.json` is kept as book metadata and progress metadata, except for
the optional `readConfig` object on each book. That object belongs to the
Android reader UI and is removed before the bytes are written to Kindle.

`bookGroup.json` is retained so the Kindle bookshelf can show imported custom
groups and Legado's built-in dynamic groups. Positive group IDs use Legado's
power-of-two bit flags and are matched against a book's stored `group` value;
negative built-in IDs are evaluated from generic book type, source, progress
and update fields.

The three `readRecord*.json` members are retained as raw JSON data. They are
read by a separate import step, not by every bookshelf or chapter-list load.
The current Android format stores reading statistics rather than a chapter
index. The plugin therefore uses `durChapterIndex`, `durChapterTitle` and
`durChapterTime` from the bookshelf to create its one-based KOReader chapter
progress, and stores the record statistics in its local reading history.

## Ignored members

Any other flat ZIP member is ignored and is not extracted or parsed. Examples
include:

```text
readConfig.json
shareReadConfig.json
themeConfig.json
config.xml
servers.json
rssSources.json
searchHistory.json
```

Malformed ignored members do not prevent the six supported members from being
imported. ZIP path traversal and duplicate supported members are still rejected.

## Kindle state layout

The active state is version 2 and contains only the six supported members plus
the manifest:

```text
<KOReader data dir>/legado/state/
├── manifest.json
├── bookSource.json
├── bookshelf.json
├── bookGroup.json
├── readRecord.json
├── readRecordDetail.json
└── readRecordSession.json
```

The desktop materializer also records member hashes and value-redacted source
capability information; the on-device manifest records schema metadata, member
sizes and counts. Neither manifest contains source values, book names, URLs or
chapter text.

Kindle-native runtime data is separate:

```text
<KOReader data dir>/legado/
├── reading-progress.lua   # chapter index/title/time, including imported progress
├── reading-history.lua    # imported Android reading statistics
├── reading-session.lua    # static local source/TOC session
├── reading-position.lua   # tiny hot current-chapter record
├── settings.lua           # plugin-owned prefetch setting only
└── library/               # downloaded chapter text/EPUB cache
```

The static reader session is schema version 2. Common rule variables are kept
once on the book and chapter entries retain only their differing variables.
Changing chapters updates `reading-position.lua` rather than rewriting the
whole TOC. Older schema version 1 sessions are compacted automatically on
first access.

KOReader's own document sidecars remain the authority for font, font size,
layout, CSS, embedded-font handling, position, bookmarks and other reader UI
state. The plugin does not copy Android reader settings into these sidecars.

## Migration from the temporary v1 layout

Earlier development builds used:

```text
<state>/manifest.json
<state>/android/<all Android backup members>
```

On the next plugin start, a v1 state is read only for the six supported
members, normalized, and atomically replaced by the version-2 layout. The old
`android/` directory is removed after activation so stale Android font/theme/
reader settings cannot be reused. A failed activation restores the old
directory before reporting the error.
