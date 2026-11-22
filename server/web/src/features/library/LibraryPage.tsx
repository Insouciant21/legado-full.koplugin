import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  Accordion,
  ActionIcon,
  Alert,
  Badge,
  Box,
  Button,
  Card,
  Center,
  Checkbox,
  Divider,
  Grid,
  Group,
  Loader,
  Modal,
  Paper,
  Progress,
  ScrollArea,
  Select,
  SimpleGrid,
  Stack,
  Text,
  TextInput,
  Title,
} from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { api, SourceGroupSummary, SourceSummary } from '../../api'
import { BookCover } from '../../BookCover'
import { CacheConcurrencyDialog } from '../../CacheConcurrencyDialog'
import { Icon } from '../../icons'
import { sourceLoginContext, type OpenBook } from '../../openBook'
import { isLocalBook } from '../../localBook'
import { cleanAuthor, cleanTitle, filterSearchGroups, isExactMatch, isPopularMatch, SearchFilters, SortMode } from '../../searchFilters'
import { groupSearchResults, searchStore, SourceChoice, useSearchStore } from '../../searchStore'
import { SearchBox } from '../../SearchBox'
import { removeGroupSourceOverrides, SearchScopeBar } from '../../SearchScopeBar'
import { SearchScopePickerModal } from '../../SearchScopePickerModal'
import { SourceLoginModal } from '../../SourceLoginModal'
import { clearStoredInspections, getInitialOrStoredInspections, inspectAllSourcesConcurrently, SourceHealthInspection } from '../../sourceInspector'
import { toast } from '../../Toast'

function SourceChoiceList({
  choices,
  inspections,
  active,
  onChoose,
  onRecheck,
  checking,
}: {
  choices: SourceChoice[]
  inspections: Map<string, SourceHealthInspection>
  active?: string
  onChoose: (choice: SourceChoice) => void
  onRecheck: () => void
  checking: boolean
}) {
  const { t } = useTranslation()

  const sortedChoices = useMemo(() => {
    return [...choices].sort((a, b) => {
      const keyA = `${a.result.sourceId}\u0000${a.result.bookUrl}`
      const keyB = `${b.result.sourceId}\u0000${b.result.bookUrl}`
      const inspA = inspections.get(keyA)
      const inspB = inspections.get(keyB)
      const scoreA = inspA ? inspA.score : (a.status === 'loaded' ? 5000 : 0)
      const scoreB = inspB ? inspB.score : (b.status === 'loaded' ? 5000 : 0)
      if (scoreB !== scoreA) return scoreB - scoreA
      return (inspB?.totalChapters ?? 0) - (inspA?.totalChapters ?? 0)
    })
  }, [choices, inspections])

  const completedCount = useMemo(() => {
    let count = 0
    for (const choice of choices) {
      const insp = inspections.get(`${choice.result.sourceId}\u0000${choice.result.bookUrl}`)
      if (insp && insp.status !== 'checking' && insp.status !== 'idle') {
        count++
      }
    }
    return count
  }, [choices, inspections])

  return (
    <Paper p="sm" withBorder radius="md" aria-label={t('source.sourceChoicesList', '可用书源切换列表')}>
      <Stack gap="sm">
        <Group justify="space-between" align="center" wrap="wrap" gap="xs">
          <Stack gap={2}>
            <Text size="sm" fw={600}>
              {t('source.availableSources', '可用书源 ({{count}})', { count: choices.length })}
            </Text>
            <Text size="xs" c="dimmed">
              {checking
                ? t('source.checkingHealthProgress', '正在并发校验书源健康度 ({{completed}}/{{total}})...', { completed: completedCount, total: choices.length })
                : t('source.checkedHealthSummary', '{{completed}}/{{total}} 个书源已完成质量检测', { completed: completedCount, total: choices.length })}
            </Text>
          </Stack>
          <Button
            size="xs"
            variant="default"
            leftSection={<Icon name="refresh" size={14} className={checking ? 'spin' : ''} />}
            onClick={onRecheck}
            disabled={checking}
            title={t('source.probeAllTitle', '探测所有书源的章节可用性与VIP限制')}
          >
            {checking ? t('source.probing', '探测中') : t('source.recheck', '重新校验')}
          </Button>
        </Group>

        <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="xs">
          {sortedChoices.map(choice => {
            const key = `${choice.result.sourceId}\u0000${choice.result.bookUrl}`
            const isSelected = active === choice.result.bookUrl
            const isLoading = choice.status === 'loading'
            const inspection = inspections.get(key)

            let badge = null
            let statusText = t('source.clickToSwitch', '点击切换为此书源')

            if (inspection) {
              if (inspection.status === 'checking') {
                badge = <Badge size="xs" variant="light" color="gray">{t('source.probingWithDots', '探测中...')}</Badge>
                statusText = t('source.samplingContentAndVip', '正在抽检章节正文与VIP限制...')
              } else if (inspection.status === 'valid') {
                badge = <Badge size="xs" variant="light" color="teal">{t('source.healthBadgeValid', '完整可读')}</Badge>
                statusText = t('source.inspectionValid', '共 {{total}} 章 · 全本可读 (后段字数充足 均{{avg}}字)', {
                  total: inspection.totalChapters ?? 0,
                  avg: inspection.avgLateChapterLength ?? 0,
                })
              } else if (inspection.status === 'vip_restricted') {
                badge = <Badge size="xs" variant="light" color="gold">{t('source.healthBadgeVip', 'VIP/付费拦截')}</Badge>
                statusText = t('source.inspectionVip', '共 {{total}} 章 · 后期章节较短/疑似VIP截断 (抽检均{{avg}}字)', {
                  total: inspection.totalChapters ?? 0,
                  avg: inspection.avgLateChapterLength ?? 0,
                })
              } else if (inspection.status === 'incomplete') {
                badge = <Badge size="xs" variant="light" color="orange">{t('source.healthBadgeIncomplete', '疑似残卷')}</Badge>
                statusText = t('source.inspectionIncomplete', '仅 {{total}} 章 · 章节严重缺失', {
                  total: inspection.totalChapters ?? 0,
                })
              } else if (inspection.status === 'error') {
                badge = <Badge size="xs" variant="light" color="red">{t('source.healthBadgeError', '无法读取')}</Badge>
                const errorDetail = inspection.error === '目录为空'
                  ? t('source.emptyToc', '目录为空')
                  : inspection.error === '书源连接失败'
                  ? t('source.connectFailed', '书源连接失败')
                  : (inspection.error || '')
                statusText = t('source.inspectionError', '书源异常: {{error}}', { error: errorDetail })
              }
            } else if (isLoading) {
              statusText = t('source.readingToc', '正在读取目录...')
            } else if (choice.status === 'error') {
              statusText = t('source.failedToLoadToc', '目录读取失败')
            } else if (choice.status === 'loaded' && choice.book) {
              statusText = t('source.loadedChapters', '已载入 · 共 {{count}} 章', { count: choice.book.chapters.length })
            }

            return (
              <Card
                key={key}
                component="button"
                type="button"
                p="xs"
                withBorder
                radius="sm"
                disabled={isLoading}
                onClick={() => onChoose(choice)}
                className="legado-interactive-card"
                style={{
                  textAlign: 'left',
                  cursor: isLoading ? 'wait' : 'pointer',
                  borderColor: isSelected ? 'var(--accent)' : undefined,
                  background: isSelected ? 'var(--accent-soft)' : undefined,
                }}
              >
                <Stack gap={4}>
                  <Group justify="space-between" wrap="nowrap" gap="xs">
                    <Text size="sm" fw={600} truncate>{choice.result.sourceId}</Text>
                    {badge}
                  </Group>
                  <Text size="xs" c="dimmed" lineClamp={2}>{statusText}</Text>
                </Stack>
              </Card>
            )
          })}
        </SimpleGrid>
      </Stack>
    </Paper>
  )
}

function BookDetailModal({
  book,
  choices,
  source,
  loading,
  error,
  onChooseSource,
  onRead,
  onOpenShelf,
  onClose,
}: {
  book: OpenBook
  choices: SourceChoice[]
  source?: SourceSummary
  loading: boolean
  error: string
  onChooseSource: (choice: SourceChoice) => void
  onRead: (book: OpenBook) => void
  onOpenShelf: () => void
  onClose: () => void
}) {
  const { t } = useTranslation()
  const [introExpanded, setIntroExpanded] = useState(false)
  const [inspections, setInspections] = useState<Map<string, SourceHealthInspection>>(() =>
    getInitialOrStoredInspections(choices.map(c => c.result))
  )
  const [checking, setChecking] = useState(false)
  const [inShelf, setInShelf] = useState<boolean | null>(null)
  const [shelfBusy, setShelfBusy] = useState(false)
  const [cacheBusy, setCacheBusy] = useState(false)
  const [cacheConcurrencyOpen, setCacheConcurrencyOpen] = useState(false)
  const [loginOpen, setLoginOpen] = useState(false)
  const abortControllerRef = useRef<AbortController | null>(null)
  const cancelInspectRef = useRef(false)

  const latestChapter = book.chapters.at(-1)
  const availableSources = choices.length
  const canLogin = !isLocalBook({ sourceId: book.details.sourceId, bookUrl: book.bookUrl }) && source?.hasLogin !== false
  const childDialogOpen = loginOpen || cacheConcurrencyOpen

  const runInspection = useCallback((forceRefresh = false) => {
    abortControllerRef.current?.abort()
    const controller = new AbortController()
    abortControllerRef.current = controller
    cancelInspectRef.current = false
    const rawSources = choices.map(c => c.result)
    if (forceRefresh) {
      clearStoredInspections(rawSources)
      setInspections(getInitialOrStoredInspections(rawSources))
    }
    setChecking(true)
    void inspectAllSourcesConcurrently(
      rawSources,
      3,
      updated => {
        if (!cancelInspectRef.current && !controller.signal.aborted) {
          setInspections(updated)
        }
      },
      () => cancelInspectRef.current || controller.signal.aborted,
      undefined,
      controller.signal
    ).finally(() => {
      if (!cancelInspectRef.current && !controller.signal.aborted) {
        setChecking(false)
      }
    })
  }, [choices])

  useEffect(() => {
    if (loading || error) return
    runInspection()
    return () => {
      cancelInspectRef.current = true
      abortControllerRef.current?.abort()
    }
  }, [runInspection, loading, error])

  const handleClose = useCallback(() => {
    cancelInspectRef.current = true
    abortControllerRef.current?.abort()
    onClose()
  }, [onClose])

  useEffect(() => {
    if (loading || error) return
    let active = true
    void api.bookshelf().then(items => {
      if (!active) return
      const found = items.some(
        item => (item.sourceId === book.details.sourceId && item.bookUrl === book.bookUrl) ||
                (cleanTitle(item.name).toLowerCase() === cleanTitle(book.details.name).toLowerCase() &&
                 (cleanAuthor(item.author) || '').toLowerCase() === (cleanAuthor(book.details.author) || '').toLowerCase())
      )
      setInShelf(found)
    }).catch(() => {
      if (active) setInShelf(false)
    })
    return () => {
      active = false
    }
  }, [book.details.sourceId, book.bookUrl, book.details.name, book.details.author, loading, error])

  const toggleShelf = async () => {
    if (shelfBusy) return
    setShelfBusy(true)
    try {
      if (inShelf) {
        await api.removeFromBookshelf(book.details.sourceId, book.bookUrl)
        setInShelf(false)
        toast.info(t('shelf.removedFromShelfToast', { name: book.details.name, defaultValue: `《${book.details.name}》已移出书架` }))
      } else {
        const fallbackCover = book.details.coverUrl || choices.find(c => c.result.coverUrl?.trim())?.result.coverUrl?.trim()
        await api.addToBookshelf({
          sourceId: book.details.sourceId,
          bookUrl: book.bookUrl,
          name: book.details.name,
          author: book.details.author,
          tocUrl: book.details.tocUrl,
          coverUrl: fallbackCover || undefined,
          alternateSources: choices.map(c => c.result).filter(s => s.sourceId !== book.details.sourceId || s.bookUrl !== book.bookUrl),
          catalogChapters: book.chapters.length,
        })
        setInShelf(true)
        toast.success(t('shelf.addedToShelfToast', { name: book.details.name, defaultValue: `《${book.details.name}》已加入书架` }))
      }
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.toggleShelfFailed', { defaultValue: '操作书架失败' }))
    } finally {
      setShelfBusy(false)
    }
  }

  const cacheBook = async (chapterConcurrency?: number) => {
    if (cacheBusy || shelfBusy) return
    setCacheBusy(true)
    try {
      if (inShelf !== true) {
        const fallbackCover = book.details.coverUrl || choices.find(choice => choice.result.coverUrl?.trim())?.result.coverUrl?.trim()
        await api.addToBookshelf({
          sourceId: book.details.sourceId,
          bookUrl: book.bookUrl,
          name: book.details.name,
          author: book.details.author,
          tocUrl: book.details.tocUrl,
          coverUrl: fallbackCover || undefined,
          alternateSources: choices.map(choice => choice.result).filter(source => source.sourceId !== book.details.sourceId || source.bookUrl !== book.bookUrl),
          catalogChapters: book.chapters.length,
        })
        setInShelf(true)
      }
      await api.cacheBookshelfBook(book.details.sourceId, book.bookUrl, chapterConcurrency)
      setCacheConcurrencyOpen(false)
      toast.success(chapterConcurrency == null
        ? t('shelf.cacheStartedToast', { name: book.details.name, defaultValue: `《${book.details.name}》已加入全本缓存队列` })
        : t('shelf.cacheStartedWithConcurrency', {
            name: book.details.name,
            count: chapterConcurrency,
            defaultValue: `《${book.details.name}》已按 ${chapterConcurrency} 章并发加入缓存队列`,
          }))
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.cacheStartFailed', '启动缓存失败'))
    } finally {
      setCacheBusy(false)
    }
  }

  const handleSelectChoice = (choice: SourceChoice) => {
    const key = `${choice.result.sourceId}\u0000${choice.result.bookUrl}`
    const insp = inspections.get(key)
    const fallbackCover = book.details.coverUrl || choices.find(c => c.result.coverUrl?.trim())?.result.coverUrl?.trim()
    const fallbackIntro = book.details.intro || choices.find(c => c.result.intro?.trim())?.result.intro?.trim()

    if (insp?.book) {
      const mergedBook: OpenBook = {
        ...insp.book,
        details: {
          ...insp.book.details,
          name: (cleanTitle(insp.book.details.name) && cleanTitle(insp.book.details.name) !== '未命名书籍' && cleanTitle(insp.book.details.name) !== '未知书名')
            ? cleanTitle(insp.book.details.name)
            : book.details.name,
          author: cleanAuthor(insp.book.details.author) || book.details.author,
          coverUrl: insp.book.details.coverUrl || fallbackCover || undefined,
          intro: insp.book.details.intro || fallbackIntro || undefined,
          alternateSources: choices.map(c => c.result).filter(s => s.sourceId !== choice.result.sourceId || s.bookUrl !== choice.result.bookUrl),
        }
      }
      onChooseSource({ ...choice, book: mergedBook, status: 'loaded' })
    } else {
      onChooseSource(choice)
    }
  }

  return (
    <>
      <Modal
        opened
        onClose={handleClose}
        size="xl"
        withCloseButton={false}
        closeOnEscape={!childDialogOpen}
        closeOnClickOutside={!childDialogOpen}
        trapFocus={!childDialogOpen}
        padding="lg"
        aria-label={t('shelf.bookDetailWithTitle', { name: book.details.name, defaultValue: `书籍详情: ${book.details.name}` })}
      >
        <Stack gap="md">
          <Group justify="space-between" align="center" pb="xs" style={{ borderBottom: '1px solid var(--line)' }}>
            <Text size="xs" fw={700} c="brand" tt="uppercase" lts={0.6}>
              {t('shelf.bookDetail', '书籍详情')}
            </Text>
            <Group gap="xs">
              {canLogin && (
                <Button size="compact-xs" variant="subtle" disabled={loading} leftSection={<Icon name="key" size={14} />} onClick={() => setLoginOpen(true)}>
                  {t('source.loginButton', '登录')}
                </Button>
              )}
              <ActionIcon variant="subtle" color="gray" onClick={handleClose} aria-label={t('common.close', '关闭')}>
                <Icon name="close" size={16} />
              </ActionIcon>
            </Group>
          </Group>

          <Group align="flex-start" wrap="nowrap" gap="md">
            <Box w={92} className="legado-cover-frame">
              <BookCover coverUrl={book.details.coverUrl} name={book.details.name} />
            </Box>
            <Stack gap="xs" style={{ flex: 1, minWidth: 0 }}>
              <Title order={3} lh={1.3}>{book.details.name}</Title>
              <Text size="sm" c="dimmed">
                {book.details.author || t('common.unknownAuthor', '未知作者')}
              </Text>
              <Group gap={6} wrap="wrap">
                {book.details.kind && <Badge variant="light" color="gray" size="sm">{book.details.kind}</Badge>}
                {book.details.wordCount && <Badge variant="light" color="gray" size="sm">{book.details.wordCount}</Badge>}
                <Badge variant="light" color="brand" size="sm">
                  {t('reader.totalChapters', { count: book.chapters.length, defaultValue: `${book.chapters.length} 章` })}
                </Badge>
                <Badge variant="light" color="gold" size="sm">
                  {t('library.availableSourcesCount', { count: availableSources || 1, defaultValue: `${availableSources || 1} 个可用书源` })}
                </Badge>
              </Group>
              {(book.details.lastChapter || latestChapter) && (
                <Text size="xs" c="dimmed" truncate>
                  {t('library.latestChapterWithTitle', { title: book.details.lastChapter || latestChapter!.title, defaultValue: `最新：${book.details.lastChapter || latestChapter!.title}` })}
                </Text>
              )}
              <Group gap="xs" wrap="wrap" pt={4}>
                <Button
                  size="xs"
                  variant={inShelf ? 'light' : 'filled'}
                  color="brand"
                  leftSection={<Icon name={inShelf ? 'check' : 'plus'} size={14} />}
                  onClick={inShelf ? onOpenShelf : toggleShelf}
                  disabled={shelfBusy || inShelf === null || loading || Boolean(error)}
                  title={inShelf ? t('shelf.inShelf', '已在书架') : t('shelf.addToShelf', '加入书架')}
                >
                  {inShelf ? '已在书架 · 去阅读' : '1. 加入书架'}
                </Button>
                <Button
                  size="xs"
                  variant="default"
                  loading={cacheBusy}
                  leftSection={<Icon name="cloudDownload" size={14} />}
                  disabled={loading || Boolean(error) || cacheBusy || shelfBusy}
                  onClick={() => {
                    if ((book.details.bookKind ?? 'novel') === 'novel') setCacheConcurrencyOpen(true)
                    else void cacheBook()
                  }}
                >
                  {cacheBusy ? t('shelf.startingCache', '启动缓存...') : '2. 缓存全本'}
                </Button>
                <Button
                  size="xs"
                  variant="subtle"
                  leftSection={<Icon name="bookOpen" size={14} />}
                  disabled={loading || Boolean(error) || book.chapters.length === 0}
                  onClick={() => onRead(book)}
                >
                  先读一章
                </Button>
              </Group>
            </Stack>
          </Group>

          {loading ? (
            <Center py="xl" role="status">
              <Group gap="sm">
                <Loader size="sm" />
                <Text size="sm" c="dimmed">{t('library.loadingBookDetail', '正在获取最新书籍详情与目录...')}</Text>
              </Group>
            </Center>
          ) : error ? (
            <Alert color="red" variant="light" icon={<Icon name="alert" size={16} />} role="alert">
              <Text size="sm">{error}</Text>
            </Alert>
          ) : (
            <ScrollArea.Autosize mah="52vh" offsetScrollbars>
              <Stack gap="md" pr={4}>
                {choices.length > 1 && (
                  <SourceChoiceList
                    choices={choices}
                    inspections={inspections}
                    active={book.bookUrl}
                    onChoose={handleSelectChoice}
                    onRecheck={() => runInspection(true)}
                    checking={checking}
                  />
                )}

                {book.details.intro && (
                  <Paper p="sm" withBorder radius="md" style={{ background: 'var(--canvas)' }}>
                    <Stack gap={6}>
                      <Text size="xs" fw={600} c="dimmed">{t('shelf.bookIntro', '书籍简介')}</Text>
                      <Text size="sm" lineClamp={introExpanded ? undefined : 4} style={{ whiteSpace: 'pre-line' }}>
                        {book.details.intro}
                      </Text>
                      {book.details.intro.length > 120 && (
                        <Button
                          size="compact-xs"
                          variant="subtle"
                          w="fit-content"
                          onClick={() => setIntroExpanded(value => !value)}
                        >
                          {introExpanded ? t('shelf.collapseIntro', '收起简介') : t('shelf.expandIntro', '展开简介')}
                        </Button>
                      )}
                    </Stack>
                  </Paper>
                )}

                <Stack gap="xs">
                  <Group justify="space-between">
                    <Text size="sm" fw={600}>{t('reader.previewToc', '目录预览')}</Text>
                    <Text size="xs" c="dimmed">
                      {t('reader.totalChapters', { count: book.chapters.length, defaultValue: `共 ${book.chapters.length} 章` })}
                    </Text>
                  </Group>
                  <SimpleGrid cols={{ base: 1, sm: 2 }} spacing={6}>
                    {book.chapters.slice(0, 16).map(item => (
                      <Paper
                        key={item.url}
                        px="xs"
                        py={6}
                        withBorder
                        radius="sm"
                        style={{ background: item.isVolume ? 'var(--surface-muted)' : 'var(--canvas)' }}
                      >
                        <Group justify="space-between" wrap="nowrap" gap="xs">
                          <Text size="xs" fw={item.isVolume ? 700 : 400} truncate>{item.title}</Text>
                          {(item.isVip || item.isPay || item.tag || item.wordCount) && (
                            <Text size="xs" c="dimmed" style={{ flexShrink: 0 }}>
                              {[
                                item.isVip ? t('reader.vip', 'VIP') : '',
                                item.isPay ? t('reader.purchased', '已购') : '',
                                item.tag || '',
                                item.wordCount || '',
                              ].filter(Boolean).join(' · ')}
                            </Text>
                          )}
                        </Group>
                      </Paper>
                    ))}
                  </SimpleGrid>
                  {book.chapters.length > 16 && (
                    <Text size="xs" c="dimmed">
                      共 {book.chapters.length} 章，点击“先读一章”可打开完整目录。
                    </Text>
                  )}
                </Stack>
              </Stack>
            </ScrollArea.Autosize>
          )}
        </Stack>
      </Modal>
      {loginOpen && (
        <SourceLoginModal
          sourceId={book.details.sourceId}
          sourceName={source?.name}
          context={sourceLoginContext(book)}
          onBookRefresh={searchStore.applyLoginBookRefresh}
          onClose={() => setLoginOpen(false)}
          onToast={toast.show}
        />
      )}
      {cacheConcurrencyOpen && (
        <CacheConcurrencyDialog
          bookName={book.details.name}
          busy={cacheBusy}
          onCancel={() => setCacheConcurrencyOpen(false)}
          onConfirm={chapterConcurrency => void cacheBook(chapterConcurrency)}
        />
      )}
    </>
  )
}

function HighlightText({ text, keyword }: { text: string; keyword: string }) {
  const cleanK = cleanTitle(keyword).trim()
  if (!cleanK || !text) return <>{text}</>

  const escaped = cleanK.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const parts = text.split(new RegExp(`(${escaped})`, 'gi'))

  return (
    <>
      {parts.map((part, i) =>
        part.toLowerCase() === cleanK.toLowerCase() ? (
          <mark key={i} className="legado-highlight">{part}</mark>
        ) : (
          part
        )
      )}
    </>
  )
}

export default function LibraryPage({ sources, onRead, onOpenShelf }: { sources: SourceSummary[]; onRead: (book: OpenBook) => void; onOpenShelf: () => void }) {
  const { t } = useTranslation()
  const search = useSearchStore()
  const [sourceGroups, setSourceGroups] = useState<SourceGroupSummary[]>([])
  const [showScopePicker, setShowScopePicker] = useState(false)
  /**
   * 书源分组列表从服务端单独取。
   *
   * 不从 `sources` 里现算：`sources` 会被书源页的筛选框改写（书源页 `load()` 用的是带 `q` 的结果），
   * 直接推导会得到一份「随书源页搜索词变化」的分组列表。这里要的是权威聚合结果。
   */
  useEffect(() => {
    void api.sourceGroups().then(setSourceGroups).catch(() => undefined)
  }, [sources])
  /**
   * 搜索范围 = 「全部书源」+ 每个书源分组 + 未分组，作为搜索栏**下面**的一排选项卡
   * （结构与「全部书源」默认项由 [SearchScopeBar] 负责，分组的新建/改名/删除在「书源」页面做）。
   */
  const groups = useMemo(() => groupSearchResults(search.results), [search.results])
  const visibleGroups = useMemo(() => filterSearchGroups(groups, search.filters, search.keyword), [groups, search.filters, search.keyword])
  const hasFilters = search.filters.query || search.filters.minimumSources > 1 || search.filters.withIntro || search.filters.withCover || search.filters.sortMode !== 'smart'
  const completed = search.progress?.completedSources ?? 0
  const total = search.progress?.totalSources ?? 0
  const failures = search.progress?.failedSources ?? 0
  const empty = search.progress?.emptySources ?? 0
  const searchFinished = !search.loading && (search.progress?.type === 'done' || Boolean(search.message))
  const enabledSources = sources.filter(source => source.enabled).length
  const searchableGroups = sourceGroups.filter(group => group.enabledCount > 0).length
  const failureCategoryLabels = {
    verification: t('library.searchFailure.verification', '待验证'),
    network: t('library.searchFailure.network', '网络失败'),
    rule: t('library.searchFailure.rule', '规则失败'),
    unknown: t('library.searchFailure.unknown', '未知失败'),
  }

  return (
    <Stack gap="lg" component="main">
      <Paper p={{ base: 'md', md: 'lg' }} withBorder radius="lg">
        <Stack gap="md">
          <Grid align="center" gutter="md">
            <Grid.Col span={{ base: 12, md: 7 }}>
              <Stack gap={4}>
                <Text size="xs" fw={700} c="brand" tt="uppercase" lts={0.8}>
                  {t('library.heroKicker', '在线书库')}
                </Text>
                <Title order={2}>{t('library.heroTitle', '找一本书，安静地读下去。')}</Title>
                <Text size="sm" c="dimmed">
                  跨书源搜索书名与作者，确认目录后直接加入书架、缓存或上架 Kindle。
                </Text>
              </Stack>
            </Grid.Col>
            <Grid.Col span={{ base: 12, md: 5 }} aria-label="书库概览">
              <SimpleGrid cols={3} spacing="xs">
                <Paper p="xs" withBorder radius="md" style={{ background: 'var(--canvas)' }}>
                  <Text size="xs" c="dimmed">可用书源</Text>
                  <Text size="xl" fw={700} c="brand">{enabledSources}</Text>
                  <Text size="xs" c="dimmed" truncate>
                    {sources.length - enabledSources > 0 ? `${sources.length - enabledSources} 个已停用` : '全部已启用'}
                  </Text>
                </Paper>
                <Paper p="xs" withBorder radius="md" style={{ background: 'var(--canvas)' }}>
                  <Text size="xs" c="dimmed">搜索分组</Text>
                  <Text size="xl" fw={700}>{searchableGroups}</Text>
                  <Text size="xs" c="dimmed">个可用分组</Text>
                </Paper>
                <Paper p="xs" withBorder radius="md" style={{ background: 'var(--canvas)' }}>
                  <Text size="xs" c="dimmed">本次结果</Text>
                  <Text size="xl" fw={700}>{groups.length || '—'}</Text>
                  <Text size="xs" c="dimmed">聚合书目</Text>
                </Paper>
              </SimpleGrid>
            </Grid.Col>
          </Grid>

          <Divider />

          <Stack gap="sm">
            <SearchBox
              keyword={search.keyword}
              loading={search.loading}
              onChange={search.setKeyword}
              onSubmit={() => search.startSearch()}
              onStop={search.stopSearch}
            />
            <SearchScopeBar
              groups={sourceGroups}
              selectedGroups={search.selectedGroups}
              selectedSourceIds={search.selectedSourceIds}
              onSelectAll={() => {
                search.setSearchScope([], [])
              }}
              onToggleGroup={group => {
                const selected = search.selectedGroups.includes(group)
                const next = selected
                  ? search.selectedGroups.filter(item => item !== group)
                  : [...search.selectedGroups, group]
                search.setSelectedGroups(next)
                if (!selected && search.selectedSourceIds.length > 0) {
                  void api.sourcePicker('', [group]).then(result => {
                    const sourceIds = removeGroupSourceOverrides(
                      searchStore.getSnapshot().selectedSourceIds,
                      result.items.map(item => item.id),
                    )
                    searchStore.setSelectedSourceIds(sourceIds)
                  }).catch(() => undefined)
                }
              }}
              onOpenPicker={() => setShowScopePicker(true)}
            />
          </Stack>

          {showScopePicker && (
            <SearchScopePickerModal
              selectedGroups={search.selectedGroups}
              selectedSourceIds={search.selectedSourceIds}
              onApply={(groups, sourceIds) => search.setSearchScope(groups, sourceIds)}
              onClose={() => setShowScopePicker(false)}
            />
          )}

          {(search.loading || search.stopped) && (
            <Paper p="xs" withBorder radius="md" style={{ background: 'var(--canvas)' }}>
              <Stack gap={6}>
                <Text size="xs" c="dimmed">
                  {search.stopped
                    ? t('library.searchStatusStopped', { count: groups.length, defaultValue: `已停止，已获得 ${groups.length} 本书。` })
                    : t('library.searchStatusRunning', { count: groups.length, completed, total, defaultValue: `已获得 ${groups.length} 本书，已检查 ${completed} / ${total} 个书源` }) +
                      (failures || empty ? t('library.searchStatusFailures', { failed: failures, empty, defaultValue: `，失败 ${failures} 个、无结果 ${empty} 个` }) : '') + '。'}
                </Text>
                {search.loading && total > 0 && (
                  <Progress value={Math.max(4, Math.round((completed / total) * 100))} animated size="xs" radius="xl" />
                )}
              </Stack>
            </Paper>
          )}

          {searchFinished && groups.length === 0 && (
            <Alert color="gray" variant="light" role="status">
              <Text size="sm">{t('library.noMatches', '没有匹配结果。')}</Text>
            </Alert>
          )}

          {search.sourceFailures.length > 0 && (
            <Accordion variant="contained" radius="md">
              <Accordion.Item value="failures">
                <Accordion.Control>
                  <Text size="xs" fw={600}>
                    {t('library.searchFailureDetails', { count: search.sourceFailures.length, defaultValue: `失败详情（${search.sourceFailures.length}）` })}
                  </Text>
                </Accordion.Control>
                <Accordion.Panel>
                  <ScrollArea.Autosize mah={220}>
                    <Stack gap={6}>
                      {search.sourceFailures.map(failure => (
                        <Group key={failure.sourceId} justify="space-between" wrap="wrap" gap="xs">
                          <Group gap="xs">
                            <Text size="xs" fw={600}>{failure.sourceId}</Text>
                            <Badge size="xs" variant="light" color="red">
                              {failureCategoryLabels[failure.category]}
                            </Badge>
                          </Group>
                          {failure.reason && <Text size="xs" c="dimmed">{failure.reason}</Text>}
                        </Group>
                      ))}
                    </Stack>
                  </ScrollArea.Autosize>
                </Accordion.Panel>
              </Accordion.Item>
            </Accordion>
          )}
        </Stack>
      </Paper>

      {search.message && (
        <Alert color="red" variant="light" icon={<Icon name="alert" size={16} />}>
          <Text size="sm">{search.message}</Text>
        </Alert>
      )}

      {groups.length > 0 && (
        <Stack gap="md">
          <Paper p="sm" withBorder radius="md" aria-label={t('library.filterResults', '筛选搜索结果')}>
            <Group gap="sm" align="center" wrap="wrap">
              <TextInput
                size="xs"
                leftSection={<Icon name="search" size={14} />}
                value={search.filters.query}
                onChange={event => search.setFilters(current => ({ ...current, query: event.target.value }))}
                placeholder={t('library.filterPlaceholder', '筛选书名或作者')}
                style={{ flex: 1, minWidth: 180 }}
              />
              <Select
                size="xs"
                aria-label={t('library.sortLabel', '排序')}
                value={search.filters.sortMode}
                onChange={value => search.setFilters(current => ({ ...current, sortMode: (value as SortMode) ?? 'smart' }))}
                data={[
                  { value: 'smart', label: t('library.sortSmart', '智能推荐') },
                  { value: 'sources', label: t('library.sortSources', '书源最多') },
                  { value: 'exact', label: t('library.sortExact', '精准优先') },
                  { value: 'name', label: t('library.sortName', '书名 A-Z') },
                ]}
                w={130}
              />
              <Select
                size="xs"
                aria-label={t('header.sources', '书源')}
                value={String(search.filters.minimumSources)}
                onChange={value => search.setFilters(current => ({
                  ...current,
                  minimumSources: Number(value ?? 1) as SearchFilters['minimumSources'],
                }))}
                data={[
                  { value: '1', label: t('common.all', '全部') },
                  { value: '2', label: t('library.minSources2', '2 个及以上') },
                  { value: '3', label: t('library.minSources3', '3 个及以上') },
                ]}
                w={130}
              />
              <Checkbox
                size="xs"
                label={t('library.withIntro', '有简介')}
                checked={search.filters.withIntro}
                onChange={event => search.setFilters(current => ({ ...current, withIntro: event.target.checked }))}
              />
              <Checkbox
                size="xs"
                label={t('library.withCover', '有封面')}
                checked={search.filters.withCover}
                onChange={event => search.setFilters(current => ({ ...current, withCover: event.target.checked }))}
              />
            </Group>
          </Paper>

          <Stack gap="sm">
            <Group justify="space-between" align="baseline">
              <Title order={4}>{t('library.searchResults', '搜索结果')}</Title>
              <Text size="xs" c="dimmed">
                {t('shelf.booksInGroup', '{{count}} 本书', { count: visibleGroups.length })}
                {hasFilters && ` / ${groups.length}`}
              </Text>
            </Group>

            <SimpleGrid cols={{ base: 1, sm: 2, lg: 3 }} spacing="md">
              {visibleGroups.map(group => {
                const isExact = isExactMatch(group, search.keyword)
                const isPopular = isPopularMatch(group)
                const coverUrl = group.sources.find(source => source.coverUrl?.trim())?.coverUrl
                const metaLine = [
                  group.sources.find(source => source.kind?.trim())?.kind,
                  group.sources.find(source => source.wordCount?.trim())?.wordCount,
                  group.sources.find(source => source.lastChapter?.trim())?.lastChapter && t('library.latestChapterShort', { title: group.sources.find(source => source.lastChapter?.trim())!.lastChapter!, defaultValue: `最新 ${group.sources.find(source => source.lastChapter?.trim())!.lastChapter!}` }),
                ].filter(Boolean).join(' · ')

                return (
                  <Card
                    key={group.key}
                    component="button"
                    type="button"
                    p="sm"
                    withBorder
                    radius="md"
                    className="legado-interactive-card"
                    data-source-ids={JSON.stringify(group.sources.map(source => source.sourceId))}
                    data-book-urls={JSON.stringify(group.sources.map(source => source.bookUrl))}
                    onClick={() => void search.openGroup(group)}
                    disabled={search.detailLoading}
                    style={{
                      textAlign: 'left',
                      cursor: 'pointer',
                      borderColor: isExact ? 'var(--accent)' : undefined,
                    }}
                  >
                    <Group align="flex-start" wrap="nowrap" gap="sm">
                      <Box w={68} className="legado-cover-frame">
                        <BookCover coverUrl={coverUrl} name={group.name} />
                      </Box>
                      <Stack gap={4} style={{ flex: 1, minWidth: 0 }}>
                        <Group gap={6} wrap="wrap" align="center">
                          <Text size="sm" fw={700} lineClamp={1} style={{ flex: 1, minWidth: 0 }}>
                            <HighlightText text={group.name} keyword={search.keyword} />
                          </Text>
                          {isExact && (
                            <Badge size="xs" variant="light" color="brand">
                              {t('library.exactMatch', '精准匹配')}
                            </Badge>
                          )}
                          {isPopular && (
                            <Badge size="xs" variant="light" color="gold">
                              {t('library.sourcesBadge', '{{count}} 源', { count: group.sources.length })}
                            </Badge>
                          )}
                        </Group>
                        <Text size="xs" c="dimmed" truncate>
                          <HighlightText text={group.author || t('common.unknownAuthor', '未知作者')} keyword={search.keyword} />
                          {!isPopular && ` · ${t('library.sourcesCount', '{{count}} 个书源', { count: group.sources.length })}`}
                        </Text>
                        {metaLine && (
                          <Text size="xs" c="dimmed" lineClamp={1}>
                            {metaLine}
                          </Text>
                        )}
                      </Stack>
                      <Box c="dimmed" pt={4}>
                        <Icon name="arrowRight" size={14} />
                      </Box>
                    </Group>
                  </Card>
                )
              })}
            </SimpleGrid>

            {visibleGroups.length === 0 && (
              <Paper p="lg" withBorder radius="md">
                <Text size="sm" c="dimmed" ta="center">
                  {t('library.filterEmpty', '没有符合当前筛选条件的书籍。')}
                </Text>
              </Paper>
            )}

            <Center pt="xs">
              <Button
                variant="default"
                loading={search.nextPageLoading}
                disabled={search.loading}
                onClick={search.loadMore}
              >
                {search.nextPageLoading
                  ? t('library.loadingNextPage', '正在加载下一页...')
                  : t('library.nextSearchPage', { page: search.page + 1, defaultValue: `加载第 ${search.page + 1} 页` })}
              </Button>
            </Center>
          </Stack>
        </Stack>
      )}
      {search.openBook && (
        <BookDetailModal
          book={search.openBook}
          choices={search.choices}
          source={sources.find(source => source.id === search.openBook?.details.sourceId)}
          loading={search.detailLoading}
          error={search.detailError}
          onChooseSource={choice => { if (!search.detailLoading) void search.chooseSource(choice) }}
          onRead={selectedBook => {
            search.setOpenBook(null)
            onRead(selectedBook)
          }}
          onOpenShelf={() => {
            search.setOpenBook(null)
            onOpenShelf()
          }}
          onClose={() => search.setOpenBook(null)}
        />
      )}
    </Stack>
  )
}

/**
 * 从书籍变量（Legado `Book.variable`，一个 JSON 对象字符串）里取出 `custom` 键的值。
 *
 * 对齐开源阅读：`custom` 在 Legado 里是一等公民（`getCustomVariable()`/`putCustomVariable()`），
 * 编辑弹窗**只编辑它**，而底层存的始终是整张表的 JSON。实测用途就是听书音色/朗读者
 * （`🍅大灰狼聚合` 源：`book.getVariable('custom')` 取音色编号）。
 *
 * 解析失败一律当空值：脏数据（手改过的库、旧版本写坏的 JSON）绝不能让编辑弹窗打崩。
 */
