import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import {
  ActionIcon,
  Alert,
  Badge,
  Box,
  Button,
  Drawer,
  Group,
  Loader,
  Paper,
  ScrollArea,
  Stack,
  Text,
  Tooltip,
} from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { api, BookRequestContext, SourceLoginBookRefresh, SourceLoginContext, SourceSummary } from './api'
import { Icon } from './icons'
import { isLocalBook } from './localBook'
import { applySourceLoginBookRefresh, sourceLoginContext, type OpenBook } from './openBook'
import { sanitizeImageUrl } from './sourceImport'
import { SourceLoginModal } from './SourceLoginModal'
import { toast } from './Toast'

type Props = {
  openBook: OpenBook
  startIndex: number
  onClose: () => void
  onBookChange: (book: OpenBook, index: number) => void
  source?: SourceSummary
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

export function TextReaderScreen({ openBook, startIndex, onClose, onBookChange, source, theme }: Props) {
  const { t } = useTranslation()
  const initial = Math.min(Math.max(startIndex, 0), Math.max(openBook.chapters.length - 1, 0))
  const [index, setIndex] = useState(initial)
  const [content, setContent] = useState('')
  const [title, setTitle] = useState(openBook.chapters[initial]?.title || openBook.details.name)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const [tocOpen, setTocOpen] = useState(false)
  const [loginOpen, setLoginOpen] = useState(false)
  const scrollRef = useRef<HTMLElement>(null)
  const refreshedChapter = useRef<{ url: string; content: NonNullable<SourceLoginBookRefresh['content']> } | null>(null)
  const scrollSaveTimer = useRef<number | null>(null)
  const restorePosition = useRef<number | null>(
    openBook.progress?.chapterIndex === initial
      ? Math.min(Math.max(openBook.progress.scrollPosition, 0), 1)
      : 0,
  )
  const chapter = openBook.chapters[index]
  const canLogin = !isLocalBook({ sourceId: openBook.details.sourceId, bookUrl: openBook.bookUrl }) && source?.hasLogin !== false
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
    const fresh = refreshedChapter.current
    refreshedChapter.current = null
    if (fresh?.url === chapter.url) {
      setContent(fresh.content.content)
      setTitle(fresh.content.title || chapter.title)
      setError('')
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

  const scrollPosition = () => {
    const element = scrollRef.current
    const maxScroll = element ? Math.max(0, element.scrollHeight - element.clientHeight) : 0
    return maxScroll > 0 ? Math.min(1, Math.max(0, (element?.scrollTop ?? 0) / maxScroll)) : 0
  }

  const persistPosition = (targetIndex = index, targetChapter = chapter, targetTitle = title) => {
    if (!targetChapter || targetChapter.isVolume) return
    void api.saveProgress(
      openBook.details.sourceId,
      openBook.bookUrl,
      targetChapter.url,
      targetIndex,
      scrollPosition(),
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
      if (event.key !== 'Escape' || loginOpen || tocOpen || event.defaultPrevented) return
      if (event.target instanceof Element && event.target.closest('[role="dialog"]')) return
      closeReader()
    }
    // 在弹窗处理 Escape 前读取其打开状态，避免同一个按键继续关闭阅读页。
    window.addEventListener('keydown', handleKeyDown, true)
    return () => window.removeEventListener('keydown', handleKeyDown, true)
  }, [onClose, tocOpen, loginOpen, index, title, chapter])

  const applyLoginRefresh = (refresh: SourceLoginBookRefresh, request: SourceLoginContext) => {
    if (!refresh.content && !refresh.details && !refresh.chapters && !refresh.variables) return
    const book = applySourceLoginBookRefresh(openBook, refresh)
    const matchingIndex = book.chapters.findIndex(item => item.url === chapter?.url)
    const nextIndex = matchingIndex >= 0 ? matchingIndex : Math.min(index, Math.max(0, book.chapters.length - 1))
    const nextChapter = book.chapters[nextIndex]
    const position = matchingIndex >= 0 ? (restorePosition.current ?? scrollPosition()) : 0
    restorePosition.current = position
    if (nextChapter) {
      const fresh = request.chapter?.url === nextChapter.url ? refresh.content : undefined
      const retained = matchingIndex >= 0 && content ? { title, content } : undefined
      const chapterContent = fresh ?? retained
      if (chapterContent) refreshedChapter.current = { url: nextChapter.url, content: chapterContent }
    }
    if (scrollSaveTimer.current !== null) {
      window.clearTimeout(scrollSaveTimer.current)
      scrollSaveTimer.current = null
    }
    setIndex(nextIndex)
    onBookChange(nextChapter ? {
      ...book,
      progress: {
        ...book.progress,
        sourceId: book.details.sourceId,
        bookUrl: book.bookUrl,
        chapterUrl: nextChapter.url,
        chapterIndex: nextIndex,
        scrollPosition: position,
        updatedAt: Date.now(),
      },
    } : book, nextIndex)
  }

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
    <Box
      component="main"
      className={`legado-reader-shell theme-${theme}`}
      ref={scrollRef}
      onScroll={handleScroll}
      style={{ height: '100dvh', overflowY: 'auto' }}
    >
      <Box component="header" className="legado-reader-header" px={{ base: 'sm', sm: 'lg' }} py="xs">
        <Group justify="space-between" wrap="nowrap" maw={960} mx="auto" gap="sm">
          <Button
            size="xs"
            variant="default"
            leftSection={<Icon name="arrowLeft" size={14} />}
            onClick={closeReader}
          >
            返回
          </Button>
          <Stack gap={0} align="center" style={{ minWidth: 0, flex: 1 }}>
            <Text size="sm" fw={700} truncate maw="100%">{openBook.details.name}</Text>
            <Text size="xs" c="dimmed" truncate maw="100%">{title}</Text>
          </Stack>
          <Group gap="xs" wrap="nowrap">
            {canLogin && (
              <Tooltip label={t('source.loginButton', '登录')}>
                <ActionIcon variant="default" size="lg" aria-label={t('source.loginButton', '登录')} onClick={() => setLoginOpen(true)}>
                  <Icon name="key" size={16} />
                </ActionIcon>
              </Tooltip>
            )}
            <Button
              size="xs"
              variant="default"
              leftSection={<Icon name="list" size={14} />}
              onClick={() => setTocOpen(true)}
            >
              目录
            </Button>
          </Group>
        </Group>
      </Box>

      <Drawer
        opened={tocOpen}
        onClose={() => setTocOpen(false)}
        position="right"
        size="sm"
        title={
          <Group gap="xs">
            <Text fw={700}>章节目录</Text>
            <Badge size="sm" variant="light">{openBook.chapters.length} 章</Badge>
          </Group>
        }
      >
        <ScrollArea h="calc(100dvh - 80px)">
          <Stack gap={4}>
            {openBook.chapters.map((item, itemIndex) => (
              <Button
                key={`${item.index}:${item.url}`}
                variant={itemIndex === index ? 'light' : 'subtle'}
                color={itemIndex === index ? 'brand' : 'gray'}
                justify="space-between"
                fullWidth
                size="sm"
                styles={{
                  label: {
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    fontWeight: item.isVolume ? 700 : itemIndex === index ? 600 : 400,
                  },
                }}
                rightSection={item.isVolume ? <Badge size="xs" variant="outline">卷</Badge> : undefined}
                onClick={() => {
                  selectChapter(itemIndex)
                  setTocOpen(false)
                }}
              >
                {item.title}
              </Button>
            ))}
          </Stack>
        </ScrollArea>
      </Drawer>

      {loginOpen && (
        <SourceLoginModal
          sourceId={openBook.details.sourceId}
          sourceName={source?.name}
          context={sourceLoginContext(openBook, chapter)}
          onBookRefresh={applyLoginRefresh}
          onClose={() => setLoginOpen(false)}
          onToast={toast.show}
        />
      )}

      <article className="legado-reader-article">
        <h1>{title}</h1>
        {loading && (
          <Group justify="center" py="xl">
            <Loader size="sm" />
            <Text size="sm" c="dimmed">正在获取正文…</Text>
          </Group>
        )}
        {error && (
          <Alert color="red" variant="light" icon={<Icon name="alert" size={16} />}>
            {error}
          </Alert>
        )}
        {!loading && !error && chapter?.isVolume && (
          <Text size="sm" c="dimmed" py="xl" ta="center">这是卷标题。</Text>
        )}
        {!loading && !error && lines.map((line, lineIndex) =>
          line.type === 'image'
            ? <img key={lineIndex} className="text-reader-image" src={line.src} alt={line.alt} referrerPolicy="no-referrer" loading="lazy" />
            : <p key={lineIndex}>{line.value}</p>
        )}
      </article>

      <Paper radius={0} p="md" style={{ borderLeft: 0, borderRight: 0, borderBottom: 0 }}>
        <Group justify="space-between" maw={740} mx="auto">
          <Button
            variant="default"
            leftSection={<Icon name="arrowLeft" size={15} />}
            onClick={() => move(-1)}
            disabled={index <= 0}
          >
            上一章
          </Button>
          <Text size="sm" c="dimmed" fw={500}>{index + 1} / {openBook.chapters.length}</Text>
          <Button
            rightSection={<Icon name="arrowRight" size={15} />}
            onClick={() => move(1)}
            disabled={index >= openBook.chapters.length - 1}
          >
            下一章
          </Button>
        </Group>
      </Paper>
    </Box>
  )
}
