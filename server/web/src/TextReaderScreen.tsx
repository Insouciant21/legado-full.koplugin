import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { api, BookRequestContext } from './api'
import { Icon } from './icons'
import type { OpenBook } from './openBook'
import { sanitizeImageUrl } from './sourceImport'

type Props = {
  openBook: OpenBook
  startIndex: number
  onClose: () => void
  theme: string
}

type ContentLine =
  | { type: 'text'; value: string }
  | { type: 'image'; src: string; alt: string }

const BLOCK_TAGS = 'address|article|aside|blockquote|dd|div|dl|dt|figcaption|figure|footer|h[1-6]|header|hr|li|main|nav|ol|p|pre|section|table|tbody|td|tfoot|th|thead|tr|ul'

function decodeHtmlText(value: string): string {
  const textarea = document.createElement('textarea')
  textarea.innerHTML = value
  return textarea.value
}

function imageAttribute(tag: string, name: string): string {
  const match = new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, 'i').exec(tag)
  return decodeHtmlText(match?.[1] ?? match?.[2] ?? match?.[3] ?? '')
}

function illustrationProxyUrl(
  upstreamUrl: string,
  sourceId: string,
  chapterUrl: string,
  bookUrl: string,
  chapterIndex: number,
): string {
  const params = new URLSearchParams({
    sourceId,
    chapterUrl,
    bookUrl,
    chapterIndex: String(chapterIndex),
    url: upstreamUrl,
  })
  return `/api/books/images/illustration?${params.toString()}`
}

function contentLines(
  raw: string,
  sourceId: string,
  chapterUrl: string,
  bookUrl: string,
  chapterIndex: number,
): ContentLine[] {
  const result: ContentLine[] = []
  const addText = (value: string) => {
    const text = decodeHtmlText(value.replace(/<[^>]+>/g, '')).replace(/\u00a0/g, ' ').trim()
    if (text) result.push({ type: 'text', value: text })
  }
  const chapterBase = /^https?:\/\//i.test(chapterUrl)
    ? chapterUrl
    : (typeof location === 'undefined' ? '' : location.href)
  const normalized = raw
    .replace(/\r\n?/g, '\n')
    .replace(/<script\b[\s\S]*?<\/script>/gi, '')
    .replace(/<style\b[\s\S]*?<\/style>/gi, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(new RegExp(`</?(?:${BLOCK_TAGS})(?:\\s[^>]*)?>`, 'gi'), '\n')
  for (const line of normalized.split('\n')) {
    const trimmed = line.trim()
    if (!trimmed) continue
    let cursor = 0
    for (const match of trimmed.matchAll(/<img\b[^>]*>/gi)) {
      const start = match.index ?? 0
      addText(trimmed.slice(cursor, start))
      const tag = match[0]
      const source = imageAttribute(tag, 'src')
      const alt = imageAttribute(tag, 'alt') || '插图'
      let upstream: string | null = null
      try {
        upstream = sanitizeImageUrl(chapterBase ? new URL(source, chapterBase).href : source)
      } catch {
        upstream = null
      }
      if (upstream) {
        result.push({
          type: 'image',
          src: illustrationProxyUrl(upstream, sourceId, chapterUrl, bookUrl, chapterIndex),
          alt,
        })
      }
      else addText(alt)
      cursor = start + tag.length
    }
    addText(trimmed.slice(cursor))
  }
  return result
}

export function TextReaderScreen({ openBook, startIndex, onClose, theme }: Props) {
  const initial = Math.min(Math.max(startIndex, 0), Math.max(openBook.chapters.length - 1, 0))
  const [index, setIndex] = useState(initial)
  const [content, setContent] = useState('')
  const [title, setTitle] = useState(openBook.chapters[initial]?.title || openBook.details.name)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [tocOpen, setTocOpen] = useState(false)
  const scrollRef = useRef<HTMLElement>(null)
  const scrollSaveTimer = useRef<number | null>(null)
  const restorePosition = useRef<number | null>(
    openBook.progress?.chapterIndex === initial
      ? Math.min(Math.max(openBook.progress.scrollPosition, 0), 1)
      : 0,
  )
  const chapter = openBook.chapters[index]
  const context = useMemo<BookRequestContext>(() => ({
    name: openBook.details.name,
    author: openBook.details.author,
    tocUrl: openBook.details.tocUrl,
    bookKind: openBook.bookKind || openBook.details.bookKind,
    variables: openBook.details.variables,
  }), [openBook])

  useEffect(() => {
    if (!chapter) return
    if (chapter.isVolume) {
      setContent('')
      setTitle(chapter.title)
      setError('')
      setLoading(false)
      return
    }
    const kind = openBook.bookKind || openBook.details.bookKind
    if (kind === 'comic' || kind === 'audio') {
      setContent('')
      setTitle(chapter.title)
      setError('当前精简前端只保留文字书正文；漫画与有声内容仍由后端 API 保留。')
      setLoading(false)
      return
    }
    const controller = new AbortController()
    setLoading(true)
    setError('')
    setContent('')
    setTitle(chapter.title)
    scrollRef.current?.scrollTo({ top: 0 })
    void api.content(openBook.details.sourceId, chapter.url, openBook.bookUrl, controller.signal, context)
      .then(result => {
        if (controller.signal.aborted) return
        setContent(result.content)
        if (result.title) setTitle(result.title)
      })
      .catch(err => {
        if (!controller.signal.aborted) setError(err instanceof Error ? err.message : '正文加载失败')
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoading(false)
      })
    return () => controller.abort()
  }, [chapter, context, openBook.bookUrl, openBook.bookKind, openBook.details.sourceId])

  const persistPosition = (targetIndex = index, targetChapter = chapter, targetTitle = title) => {
    if (!targetChapter || targetChapter.isVolume) return
    const element = scrollRef.current
    const maxScroll = element ? Math.max(0, element.scrollHeight - element.clientHeight) : 0
    const ratio = maxScroll > 0 ? Math.min(1, Math.max(0, (element?.scrollTop ?? 0) / maxScroll)) : 0
    void api.saveProgress(
      openBook.details.sourceId,
      openBook.bookUrl,
      targetChapter.url,
      targetIndex,
      ratio,
      targetTitle || targetChapter.title,
      undefined,
      openBook.bookKind || openBook.details.bookKind,
    )
  }

  useLayoutEffect(() => {
    if (loading || !content || !scrollRef.current) return
    const element = scrollRef.current
    const ratio = restorePosition.current ?? 0
    restorePosition.current = null
    element.scrollTo({ top: Math.max(0, element.scrollHeight - element.clientHeight) * ratio })
  }, [content, index, loading])

  useEffect(() => {
    return () => {
      if (scrollSaveTimer.current !== null) window.clearTimeout(scrollSaveTimer.current)
    }
  }, [])

  const closeReader = () => {
    persistPosition()
    onClose()
  }

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        if (tocOpen) setTocOpen(false)
        else closeReader()
      }
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [onClose, tocOpen, index, title, chapter])

  const selectChapter = (next: number) => {
    if (next === index) {
      setTocOpen(false)
      return
    }
    persistPosition()
    restorePosition.current = openBook.progress?.chapterIndex === next
      ? Math.min(Math.max(openBook.progress.scrollPosition, 0), 1)
      : 0
    setContent('')
    setError('')
    setLoading(true)
    setIndex(next)
  }

  const move = (delta: number) => {
    let next = index + delta
    while (next >= 0 && next < openBook.chapters.length && openBook.chapters[next].isVolume) next += delta
    if (next >= 0 && next < openBook.chapters.length) selectChapter(next)
  }

  const handleScroll = () => {
    if (scrollSaveTimer.current !== null) return
    scrollSaveTimer.current = window.setTimeout(() => {
      scrollSaveTimer.current = null
      persistPosition()
    }, 700)
  }

  useEffect(() => {
    if (loading || !content || !chapter || chapter.isVolume) return
    persistPosition(index, chapter, title)
  }, [content, index, loading, title])

  const lines = contentLines(
    content,
    openBook.details.sourceId,
    chapter?.url || '',
    openBook.bookUrl,
    index,
  )

  return (
    <main className={`text-reader-page theme-${theme}`} ref={scrollRef} onScroll={handleScroll}>
      <header className="text-reader-header">
        <button type="button" className="subtle-button" onClick={closeReader}>
          <Icon name="arrowLeft" />
          <span>返回</span>
        </button>
        <div className="text-reader-heading">
          <strong>{openBook.details.name}</strong>
          <small>{title}</small>
        </div>
        <button type="button" className="subtle-button" onClick={() => setTocOpen(value => !value)}>
          <Icon name="list" />
          <span>目录</span>
        </button>
      </header>

      {tocOpen && (
        <aside className="text-reader-toc" aria-label="章节目录">
          <header>
            <strong>目录</strong>
            <span>{openBook.chapters.length} 章</span>
            <button type="button" className="subtle-button" onClick={() => setTocOpen(false)}><Icon name="close" /></button>
          </header>
          <div>
            {openBook.chapters.map((item, itemIndex) => (
              <button
                type="button"
                key={`${item.index}:${item.url}`}
                className={`${item.isVolume ? 'volume' : ''} ${itemIndex === index ? 'active' : ''}`}
                onClick={() => {
                  selectChapter(itemIndex)
                  setTocOpen(false)
                }}
              >
                <span>{item.title}</span>
                {item.isVolume && <small>卷</small>}
              </button>
            ))}
          </div>
        </aside>
      )}

      <article className="text-reader-content">
        <h1>{title}</h1>
        {loading && <p className="text-reader-message">正在获取正文…</p>}
        {error && <p className="form-error">{error}</p>}
        {!loading && !error && chapter?.isVolume && <p className="text-reader-message">这是卷标题。</p>}
        {!loading && !error && lines.map((line, lineIndex) =>
          line.type === 'image'
            ? <img key={lineIndex} className="text-reader-image" src={line.src} alt={line.alt} referrerPolicy="no-referrer" loading="lazy" />
            : <p key={lineIndex}>{line.value}</p>
        )}
      </article>

      <footer className="text-reader-footer">
        <button type="button" className="subtle-button" onClick={() => move(-1)} disabled={index <= 0}>上一章</button>
        <span>{index + 1} / {openBook.chapters.length}</span>
        <button type="button" className="primary-button" onClick={() => move(1)} disabled={index >= openBook.chapters.length - 1}>下一章</button>
      </footer>
    </main>
  )
}
