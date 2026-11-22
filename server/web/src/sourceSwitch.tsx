import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  ActionIcon,
  Badge,
  Button,
  Card,
  Checkbox,
  Group,
  Modal,
  Paper,
  Progress,
  ScrollArea,
  Stack,
  Text,
  Tooltip,
} from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { api, BookDetails, Chapter, SearchResult, SearchStreamEvent, streamSearch } from './api'
import { Icon } from './icons'
import { cleanAuthor, cleanTitle, isSourceSwitchBookMatch } from './searchFilters'
import { matchBestChapter, normalizeChapterTitle, remapChapterAfterSourceSwitch } from './sourceSwitchRemap'
import { toast } from './Toast'

/**
 * 换源（书源切换）的**单一实现**：弹窗 + 候选源编排 + 换源后的书籍落库。
 *
 * ## 为什么要有这个模块
 * 小说阅读器原先自带一份换源实现，漫画 / 有声阅读器也要"像小说的那个一样"。
 * 若各自再写一份，就会出现三份**候选源排序**与**重映射规则**——它们在"看起来没问题"时
 * 完全一致，只在边界（同名书、序号错位、目录更短）上分叉，属于最难查的一类缺陷。
 * 因此这里收口成一处，三端只是**接线方式**不同（换源后重新拉什么清单、清什么缓存）。
 *
 * ## 分层
 * - `sourceSwitchRemap.ts` —— 纯函数（重映射规则），无副作用；
 * - 本文件 —— 弹窗 UI + 编排（搜索 / 拉目录 / 落库 / 提示）；
 * - 各阅读器 —— 只负责"换源之后我这边要做什么"（正文 / 图片清单 / 音频清单）。
 */

export type SourceCandidate = {
  result: SearchResult
  isKnownAlternate?: boolean
  isCurrent?: boolean
  status: 'idle' | 'loading' | 'loaded' | 'error'
  /** 搜索流中的到达顺序；Android 默认按书源顺序展示。 */
  arrivalIndex: number
  /** 已成功加载的详情；点击换源时可直接复用。 */
  details?: BookDetails
  detailsLoaded?: boolean
  latestChapter?: string
  totalChapters?: number
  matchedChapterIndex?: number
  matchedChapterTitle?: string
  chapters?: Chapter[]
  /** 当前进度章（书架未开始时取末章）正文字数，等价于 Android `chapterWordCount`。 */
  wordCount?: number
  wordCountText?: string
  wordCountChapterIndex?: number
  respondTimeMs?: number
  /** 已按哪一组加载选项完成候选增强，避免 React 重渲染后重复抓取。 */
  enrichmentKey?: string
  error?: string
}

export type SourceSwitchOptions = {
  checkAuthor: boolean
  loadInfo: boolean
  loadToc: boolean
  loadWordCount: boolean
}

const SOURCE_SWITCH_OPTIONS_STORAGE_KEY = 'legado-source-switch-options-v1'
/** 与服务端书源搜索、正文缓存一致，按 Android MAX_THREAD 的 9 个槽位加载候选。 */
const SOURCE_SWITCH_HYDRATION_CONCURRENCY = 9

const defaultSourceSwitchOptions: SourceSwitchOptions = {
  checkAuthor: false,
  loadInfo: false,
  loadToc: false,
  loadWordCount: false,
}

function readSourceSwitchOptions(): SourceSwitchOptions {
  if (typeof localStorage === 'undefined') return { ...defaultSourceSwitchOptions }
  try {
    const stored = JSON.parse(localStorage.getItem(SOURCE_SWITCH_OPTIONS_STORAGE_KEY) || '{}') as Partial<SourceSwitchOptions>
    return {
      checkAuthor: stored.checkAuthor === true,
      loadInfo: stored.loadInfo === true,
      loadToc: stored.loadToc === true,
      loadWordCount: stored.loadWordCount === true,
    }
  } catch {
    return { ...defaultSourceSwitchOptions }
  }
}

function sourceSwitchEnrichmentKey(options: SourceSwitchOptions): string {
  const effectiveLoadToc = options.loadToc || options.loadWordCount
  return `info:${options.loadInfo || effectiveLoadToc ? 1 : 0};toc:${effectiveLoadToc ? 1 : 0};words:${options.loadWordCount ? 1 : 0}`
}

export type SourceSwitchModalProps = {
  bookName: string
  author?: string
  currentSourceId: string
  currentBookUrl: string
  currentChapterTitle?: string
  currentChapterIndex?: number
  knownAlternateSources?: SearchResult[]
  onSwitch: (chosen: { result: SearchResult; chapters: Chapter[]; targetChapterIndex: number }) => Promise<void>
  onClose: () => void
}

export function SourceSwitchModal({
  bookName,
  author,
  currentSourceId,
  currentBookUrl,
  currentChapterTitle,
  currentChapterIndex,
  knownAlternateSources = [],
  onSwitch,
  onClose,
}: SourceSwitchModalProps) {
  const { t } = useTranslation()
  const [candidates, setCandidates] = useState<SourceCandidate[]>([])
  const [searchProgress, setSearchProgress] = useState<SearchStreamEvent | null>(null)
  const [searching, setSearching] = useState(true)
  const [switchingSourceId, setSwitchingSourceId] = useState<string | null>(null)
  const [options, setOptions] = useState<SourceSwitchOptions>(readSourceSwitchOptions)

  const socketRef = useRef<WebSocket | null>(null)
  const hydratingRef = useRef<Set<string>>(new Set())
  const activeHydrationsRef = useRef(0)

  useEffect(() => {
    try {
      localStorage.setItem(SOURCE_SWITCH_OPTIONS_STORAGE_KEY, JSON.stringify(options))
    } catch {
      // 私密模式或浏览器禁用 storage 时，选项仍对本次弹窗有效。
    }
  }, [options])

  const consumeOptionChange = (key: keyof SourceSwitchOptions, checked: boolean) => {
    setOptions(previous => ({ ...previous, [key]: checked }))
  }

  const hydrateCandidate = useCallback(async (
    candidate: SourceCandidate,
    requestedOptions: SourceSwitchOptions,
  ) => {
    const effectiveLoadToc = requestedOptions.loadToc || requestedOptions.loadWordCount
    const needDetails = requestedOptions.loadInfo || effectiveLoadToc
    if (!needDetails) return

    const key = `${candidate.result.sourceId}\u0000${candidate.result.bookUrl}`
    const enrichmentKey = sourceSwitchEnrichmentKey(requestedOptions)
    if (candidate.enrichmentKey === enrichmentKey || hydratingRef.current.has(key)) return
    hydratingRef.current.add(key)

    setCandidates(prev =>
      prev.map(c =>
        c.result.sourceId === candidate.result.sourceId && c.result.bookUrl === candidate.result.bookUrl
          ? {
              ...c,
              status: effectiveLoadToc ? 'loading' : c.status,
              enrichmentKey,
              error: undefined,
            }
          : c
      )
    )

    try {
      const details = candidate.details || await api.details(candidate.result.sourceId, candidate.result.bookUrl, {
        name: candidate.result.name,
        author: candidate.result.author,
        tocUrl: candidate.result.tocUrl,
        bookKind: candidate.result.bookKind,
        variables: candidate.result.variables,
      })
      let chapters = candidate.chapters
      if (effectiveLoadToc && !chapters) {
        chapters = await api.chapters(candidate.result.sourceId, candidate.result.bookUrl, details.tocUrl, {
          name: details.name,
          author: details.author,
          tocUrl: details.tocUrl,
          bookKind: details.bookKind || candidate.result.bookKind,
          variables: details.variables,
        })
      }

      const best = chapters
        ? matchBestChapter(chapters, currentChapterTitle, currentChapterIndex)
        : undefined
      let wordCount: number | undefined
      let wordCountText: string | undefined
      let wordCountChapterIndex: number | undefined
      let respondTimeMs: number | undefined

      if (requestedOptions.loadWordCount && chapters && chapters.length > 0) {
        wordCountChapterIndex = currentChapterIndex === undefined
          ? chapters.length - 1
          : best?.index ?? 0
        const wordChapter = chapters[wordCountChapterIndex]
        const startedAt = performance.now()
        let wordTitle = wordChapter.title.trim()
        if (wordTitle.length > 20) wordTitle = `${wordTitle.slice(0, 20)}…`
        try {
          if (!wordChapter.url) throw new Error(t('source.chapterUrlMissing', '章节地址为空'))
          const preview = await api.contentPreview(
            candidate.result.sourceId,
            wordChapter.url,
            candidate.result.bookUrl,
            {
              name: details.name,
              author: details.author,
              tocUrl: details.tocUrl,
              bookKind: details.bookKind || candidate.result.bookKind,
              variables: details.variables,
            },
          )
          wordCount = preview.content.length
          wordCountText = `[${wordCountChapterIndex + 1}] ${wordTitle}\n${t('source.wordCountLabel', '字数')}：${wordCount}`
        } catch (err) {
          wordCount = -1
          const reason = err instanceof Error ? err.message : t('common.unknownReason', '未知原因')
          wordCountText = `[${wordCountChapterIndex + 1}] ${wordTitle}\n${t('source.wordCountFailed', '获取字数失败')}：${reason}`
        }
        respondTimeMs = Math.max(0, Math.round(performance.now() - startedAt))
      }

      setCandidates(prev =>
        prev.map(c =>
          c.result.sourceId === candidate.result.sourceId && c.result.bookUrl === candidate.result.bookUrl
            ? {
                ...c,
                status: effectiveLoadToc ? 'loaded' : 'idle',
                chapters,
                details,
                detailsLoaded: true,
                totalChapters: chapters?.length,
                latestChapter: chapters?.at(-1)?.title || details.lastChapter || candidate.result.lastChapter,
                matchedChapterIndex: best?.index,
                matchedChapterTitle: best?.title,
                wordCount,
                wordCountText,
                wordCountChapterIndex,
                respondTimeMs,
                enrichmentKey,
              }
            : c
        )
      )
    } catch (err) {
      const errorMsg = err instanceof Error
        ? err.message
        : requestedOptions.loadInfo
          ? t('source.unableToLoadDetails', '无法加载详情')
          : t('source.unableToGetToc', '无法获取目录')
      setCandidates(prev =>
        prev.map(c =>
          c.result.sourceId === candidate.result.sourceId && c.result.bookUrl === candidate.result.bookUrl
            ? { ...c, status: 'error', enrichmentKey, error: errorMsg }
            : c
        )
      )
    } finally {
      hydratingRef.current.delete(key)
    }
  }, [currentChapterIndex, currentChapterTitle, t])

  // Initialize known alternates
  useEffect(() => {
    const initialList: SourceCandidate[] = []

    // 1. Current source (if available)
    initialList.push({
      result: {
        sourceId: currentSourceId,
        bookUrl: currentBookUrl,
        name: bookName,
        author,
      },
      isCurrent: true,
      status: 'idle',
      arrivalIndex: 0,
    })

    // 2. Known alternate sources
    for (const alt of knownAlternateSources) {
      if (alt.sourceId === currentSourceId && alt.bookUrl === currentBookUrl) continue
      initialList.push({
        result: alt,
        isKnownAlternate: true,
        status: 'idle',
        arrivalIndex: initialList.length,
      })
    }

    setCandidates(initialList)
  }, [author, bookName, currentBookUrl, currentSourceId, knownAlternateSources])

  // Start streaming search for other sources
  useEffect(() => {
    let cancelled = false
    setSearching(true)

    const socket = streamSearch(
      bookName,
      undefined,
      event => {
        if (cancelled) return
        if (event.type === 'start' || event.type === 'progress' || event.type === 'done') {
          setSearchProgress(event)
        }
        if (event.type === 'results' && event.results.length > 0) {
          setCandidates(prev => {
            const existingKeys = new Set(prev.map(c => `${c.result.sourceId}\u0000${c.result.bookUrl}`))
            const newCandidates: SourceCandidate[] = []
            const firstArrivalIndex = prev.length

            for (const r of event.results) {
              const key = `${r.sourceId}\u0000${r.bookUrl}`
              if (
                !existingKeys.has(key) &&
                isSourceSwitchBookMatch(r.name, bookName, r.author, author, false)
              ) {
                existingKeys.add(key)
                const candidate: SourceCandidate = {
                  result: r,
                  status: 'idle',
                  arrivalIndex: firstArrivalIndex + newCandidates.length,
                }
                newCandidates.push(candidate)
              }
            }

            return newCandidates.length > 0 ? [...prev, ...newCandidates] : prev
          })
        }
        if (event.type === 'done' || event.type === 'error') {
          setSearching(false)
        }
      },
      () => {
        if (!cancelled) setSearching(false)
      },
      () => {
        if (!cancelled) setSearching(false)
      }
    )

    socketRef.current = socket

    return () => {
      cancelled = true
      socketRef.current?.close()
      socketRef.current = null
    }
  }, [author, bookName])

  // Android 的四个菜单选项会决定搜索命中后继续加载哪些数据；加载字数隐含加载目录，
  // 加载目录/字数又隐含加载详情。候选逐个到达或选项变化时补齐缺失数据，已经加载过的字段直接复用。
  useEffect(() => {
    const requestedOptions = options
    const needsHydration = requestedOptions.loadInfo || requestedOptions.loadToc || requestedOptions.loadWordCount
    if (!needsHydration) return
    const enrichmentKey = sourceSwitchEnrichmentKey(requestedOptions)
    let availableSlots = Math.max(0, SOURCE_SWITCH_HYDRATION_CONCURRENCY - activeHydrationsRef.current)
    for (const candidate of candidates) {
      if (availableSlots <= 0) break
      if (candidate.isCurrent || candidate.enrichmentKey === enrichmentKey) continue
      if (!isSourceSwitchBookMatch(
        candidate.result.name,
        bookName,
        candidate.result.author,
        author,
        requestedOptions.checkAuthor,
      )) continue
      activeHydrationsRef.current += 1
      availableSlots -= 1
      void hydrateCandidate(candidate, requestedOptions).finally(() => {
        activeHydrationsRef.current = Math.max(0, activeHydrationsRef.current - 1)
      })
    }
  }, [author, bookName, candidates, hydrateCandidate, options])

  const handleSelect = async (candidate: SourceCandidate) => {
    if (candidate.isCurrent) {
      toast.info(t('source.alreadyCurrentSource', '当前已是该书源'))
      return
    }

    setSwitchingSourceId(candidate.result.sourceId)

    try {
      let details = candidate.details
      let chapters = candidate.chapters
      let targetIndex = candidate.matchedChapterIndex ?? 0

      if (!details) {
        details = await api.details(candidate.result.sourceId, candidate.result.bookUrl, {
          name: candidate.result.name,
          author: candidate.result.author,
          tocUrl: candidate.result.tocUrl,
          bookKind: candidate.result.bookKind,
          variables: candidate.result.variables,
        })
      }
      if (!chapters) {
        chapters = await api.chapters(candidate.result.sourceId, candidate.result.bookUrl, details.tocUrl, {
          name: details.name,
          author: details.author,
          tocUrl: details.tocUrl,
          bookKind: details.bookKind || candidate.result.bookKind,
          variables: details.variables,
        })
        const best = matchBestChapter(chapters, currentChapterTitle, currentChapterIndex)
        targetIndex = best.index
      }

      await onSwitch({
        result: candidate.result,
        chapters,
        targetChapterIndex: targetIndex,
      })

      const targetTitle = chapters[targetIndex]?.title || t('reader.chapterIndex', { count: targetIndex + 1, defaultValue: `第 ${targetIndex + 1} 章` })
      toast.success(t('source.switchSourceSuccess', { source: candidate.result.sourceId, title: targetTitle, defaultValue: `已切换至【${candidate.result.sourceId}】，定位至：${targetTitle}` }))
      onClose()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('source.switchSourceFailed', '切换书源失败'))
    } finally {
      setSwitchingSourceId(null)
    }
  }

  const visibleCandidates = useMemo(
    () => candidates.filter(candidate =>
      candidate.isCurrent ||
      isSourceSwitchBookMatch(
        candidate.result.name,
        bookName,
        candidate.result.author,
        author,
        options.checkAuthor,
      )
    ),
    [author, bookName, candidates, options.checkAuthor],
  )

  const sortedCandidates = useMemo(() => {
    return [...visibleCandidates].sort((a, b) => {
      // Android 仅在「加载字数」开启时切换到字数比较器：超过 1000 字的源优先，
      // 再按当前/末尾章节序号、正文字数和原书源顺序排列。
      if (options.loadWordCount) {
        const aUseful = (a.wordCount ?? -1) > 1000 ? 1 : 0
        const bUseful = (b.wordCount ?? -1) > 1000 ? 1 : 0
        if (aUseful !== bUseful) return bUseful - aUseful
        const chapterDiff = (b.wordCountChapterIndex ?? -1) - (a.wordCountChapterIndex ?? -1)
        if (chapterDiff !== 0) return chapterDiff
        const wordCountDiff = (b.wordCount ?? -1) - (a.wordCount ?? -1)
        if (wordCountDiff !== 0) return wordCountDiff
      }
      return a.arrivalIndex - b.arrivalIndex
    })
  }, [options.loadWordCount, visibleCandidates])

  const progressPercent = searchProgress?.totalSources
    ? Math.round((searchProgress.completedSources / searchProgress.totalSources) * 100)
    : 0

  const optionItems: Array<{
    key: keyof SourceSwitchOptions
    label: string
    hint: string
  }> = [
    {
      key: 'checkAuthor',
      label: t('source.changeSourceCheckAuthor', '校验作者'),
      hint: t('source.changeSourceCheckAuthorHint', '书名匹配后再校验作者是否一致'),
    },
    {
      key: 'loadInfo',
      label: t('source.changeSourceLoadInfo', '加载详情页'),
      hint: t('source.changeSourceLoadInfoHint', '加载详情并补充最新章节'),
    },
    {
      key: 'loadToc',
      label: t('source.changeSourceLoadToc', '加载目录'),
      hint: t('source.changeSourceLoadTocHint', '加载目录并显示章节数与位置'),
    },
    {
      key: 'loadWordCount',
      label: t('source.changeSourceLoadWordCount', '加载字数'),
      hint: t('source.changeSourceLoadWordCountHint', '读取当前章节正文，按字数和耗时排序'),
    },
  ]

  return (
    <Modal
      opened
      onClose={onClose}
      size="lg"
      zIndex={340}
      withCloseButton={false}
      padding="lg"
      aria-label={t('source.switchSourceForBook', { bookName, defaultValue: `切换书源: ${bookName}` })}
    >
      <Stack gap="md">
        <Group justify="space-between" align="flex-start" wrap="nowrap" pb="sm" style={{ borderBottom: '1px solid var(--line)' }}>
          <Stack gap={2} style={{ minWidth: 0 }}>
            <Group gap={6}>
              <Icon name="sliders" size={15} />
              <Text size="xs" fw={700} c="brand" tt="uppercase" lts={0.6}>
                {t('source.switchSourceTitle', '切换书源')}
              </Text>
            </Group>
            <Text fw={700} size="lg" truncate>{bookName}</Text>
            <Text size="xs" c="dimmed" truncate>
              {author ? `${t('library.author', '作者')}: ${author}` : t('library.unknownAuthor', '未知作者')} · {t('source.currentSourceBadge', '当前书源')}：{currentSourceId}
            </Text>
          </Stack>
          <ActionIcon variant="subtle" color="gray" onClick={onClose} aria-label={t('common.close', '关闭')}>
            <Icon name="close" size={16} />
          </ActionIcon>
        </Group>

        <Paper p="sm" withBorder radius="md" aria-label={t('source.changeSourceOptions', '换源加载选项')}>
          <Group justify="space-between" align="center" wrap="wrap" gap="xs">
            <Text size="xs" fw={600} c="dimmed">
              {t('source.changeSourceOptions', '换源加载选项')}
            </Text>
            <Group gap="md" wrap="wrap">
              {optionItems.map(item => (
                <Tooltip key={item.key} label={item.hint}>
                  <Checkbox
                    size="xs"
                    label={item.label}
                    checked={options[item.key]}
                    onChange={event => consumeOptionChange(item.key, event.target.checked)}
                  />
                </Tooltip>
              ))}
            </Group>
          </Group>
        </Paper>

        <Paper p="sm" withBorder radius="md" style={{ background: 'var(--sidebar-bg)' }}>
          <Stack gap={6}>
            <Group justify="space-between" wrap="wrap" gap="xs">
              <Text size="sm" fw={600}>
                {searching
                  ? t('source.searchingSourcesForBook', { bookName, defaultValue: `正在全源检索《${bookName}》...` })
                  : t('source.searchSourcesCompleted', { count: visibleCandidates.length, defaultValue: `全源检索完成，共找到 ${visibleCandidates.length} 个书源` })}
              </Text>
              <Text size="xs" c="dimmed">
                {searchProgress
                  ? t('source.scannedSourcesProgress', { completed: searchProgress.completedSources, total: searchProgress.totalSources, defaultValue: `已扫描 ${searchProgress.completedSources} / ${searchProgress.totalSources} 个书源` })
                  : t('source.preparingSearch', '准备检索...')}
              </Text>
            </Group>
            {searching && (
              <Progress value={Math.max(5, progressPercent)} animated striped size="sm" radius="xl" />
            )}
          </Stack>
        </Paper>

        <ScrollArea.Autosize mah="52vh" offsetScrollbars>
          <Stack gap="xs" pr={4}>
            {sortedCandidates.map(c => {
              const isSwitching = switchingSourceId === c.result.sourceId
              const isLoading = c.status === 'loading'
              const isError = c.status === 'error'
              const isCurrent = c.isCurrent

              let metaText = t('source.clickToFetchTocAndSwitch', '点击拉取目录并切换')
              if (isCurrent) {
                metaText = t('source.currentReadingSource', '当前正在阅读的书源')
              } else if (isLoading) {
                metaText = t('source.extractingTocAndChapters', '正在提取目录与章节...')
              } else if (isError) {
                metaText = c.error || t('source.unableToGetToc', '获取目录失败')
              } else if (c.status === 'loaded') {
                metaText = t('source.totalChaptersAndLatest', { count: c.totalChapters ?? 0, latest: c.latestChapter || t('common.none', '无'), defaultValue: `共 ${c.totalChapters ?? 0} 章 · 最新：${c.latestChapter || '无'}` })
              } else if (c.detailsLoaded) {
                const latest = c.latestChapter || c.result.lastChapter
                metaText = latest
                  ? t('source.detailsLoadedWithLatest', '详情已加载 · 最新：{{latest}}', { latest })
                  : t('source.detailsLoaded', '详情已加载，点击换源时再拉取目录')
              } else if (c.result.lastChapter) {
                metaText = t('source.searchResultLatestChapter', '最新：{{latest}}', { latest: c.result.lastChapter })
              }

              return (
                <Card
                  key={`${c.result.sourceId}-${c.result.bookUrl}`}
                  p="sm"
                  withBorder
                  radius="md"
                  style={{
                    borderColor: isCurrent ? 'var(--accent)' : isError ? 'var(--danger)' : undefined,
                    background: isCurrent ? 'var(--accent-soft)' : undefined,
                  }}
                >
                  <Group justify="space-between" align="center" wrap="nowrap" gap="sm">
                    <Stack gap={4} style={{ flex: 1, minWidth: 0 }}>
                      <Group gap="xs" wrap="wrap">
                        <Text size="sm" fw={700} truncate>{c.result.sourceId}</Text>
                        {isCurrent && (
                          <Badge size="xs" variant="filled" color="brand">
                            {t('source.currentSourceBadge', '当前书源')}
                          </Badge>
                        )}
                        {c.isKnownAlternate && !isCurrent && (
                          <Badge size="xs" variant="light" color="gold">
                            {t('source.candidateBadge', '已收录候选')}
                          </Badge>
                        )}
                      </Group>
                      <Text size="xs" c={isError ? 'red' : 'dimmed'}>{metaText}</Text>
                      {c.matchedChapterTitle && !isCurrent && (
                        <Text size="xs" c="brand">
                          {t('source.smartMatchedPosition', { index: (c.matchedChapterIndex ?? 0) + 1, title: c.matchedChapterTitle, defaultValue: `智能定位至：第 ${(c.matchedChapterIndex ?? 0) + 1} 章 · ${c.matchedChapterTitle}` })}
                        </Text>
                      )}
                      {c.wordCountText && !isCurrent && (
                        <Text size="xs" c="dimmed" style={{ whiteSpace: 'pre-line' }}>
                          {c.wordCountText}
                          {c.respondTimeMs !== undefined && `\n${t('source.respondTime', '耗时')}：${(c.respondTimeMs / 1000).toFixed(1)}s`}
                        </Text>
                      )}
                    </Stack>

                    {isCurrent ? (
                      <Badge variant="light" color="brand" size="md">
                        {t('source.inUse', '使用中')}
                      </Badge>
                    ) : (
                      <Button
                        size="xs"
                        loading={isSwitching}
                        disabled={isLoading || switchingSourceId !== null}
                        onClick={() => void handleSelect(c)}
                      >
                        {isSwitching
                          ? t('source.switching', '切换中...')
                          : isLoading
                            ? t('common.loading', '加载中...')
                            : t('source.switch', '切换')}
                      </Button>
                    )}
                  </Group>
                </Card>
              )
            })}

            {sortedCandidates.length === 0 && !searching && (
              <Stack align="center" gap="xs" py="xl">
                <Icon name="book" size={28} />
                <Text size="sm" c="dimmed">
                  {t('source.noMatchingBookFound', { bookName, defaultValue: `未在其他书源中发现匹配的《${bookName}》` })}
                </Text>
              </Stack>
            )}
          </Stack>
        </ScrollArea.Autosize>
      </Stack>
    </Modal>
  )
}

/* -------------------------------------------------------------------------- */
/*                          换源后的"落库"编排                                  */
/* -------------------------------------------------------------------------- */

export type SwitchBookSourceChosen = {
  result: SearchResult
  chapters: Chapter[]
  targetChapterIndex: number
}

/**
 * `switchBookSource` 需要的最小书籍形状。
 *
 * 刻意**不**引用调用方的 `OpenBook`，只声明真正读到的字段。
 * 小说、漫画与有声书现有的 `OpenBook` 都天然满足。
 */
export type SourceSwitchBook = {
  details: BookDetails
  bookUrl: string
  /** 原书 kind（漫画/有声分派靠它，可选）。 */
  bookKind?: string
}

/** 换源落库的结果：调用方拿它替换自己持有的"当前书籍"。 */
export type SwitchBookSourceResult = {
  /** 更换书源后的书籍（`details` / `bookUrl` / `chapters` 已指向新源）。 */
  book: SourceSwitchBook & { chapters: Chapter[] }
  /** 新目录里的落点下标（由纯函数算出）。 */
  targetChapterIndex: number
  /** 旧源的标识，调用方用它清理"按 [sourceId, bookUrl] 建键"的本地缓存。 */
  previous: { sourceId: string; bookUrl: string }
}

/**
 * 换源的**共用编排**：重新解析新源详情 → 写回书架 → 返回新的当前书籍。
 *
 * 编排顺序保持稳定：封面回退、书名/作者清洗、`alternateSources` 保留。
 *
 * 各阅读器的**差异部分**不在函数里，而在调用方：
 * 换源成功后要重新拉什么清单（正文 / 图片 / 音频）、要清掉什么旧源缓存。
 *
 * @param current 换源前的书籍（只需要 `details` 与 `bookUrl`）
 * @param chosen  弹窗选定的候选源（含已拉取的新目录与落点下标）
 * @param unknownName 拿不到书名时的兜底文案（已翻译）
 */
export async function switchBookSource(
  current: SourceSwitchBook,
  chosen: SwitchBookSourceChosen,
  unknownName: string,
): Promise<SwitchBookSourceResult> {
  const previous = { sourceId: current.details.sourceId, bookUrl: current.bookUrl }
  const details = await api.details(chosen.result.sourceId, chosen.result.bookUrl, {
    name: chosen.result.name || current.details.name,
    author: chosen.result.author || current.details.author,
    tocUrl: chosen.result.tocUrl,
    bookKind: chosen.result.bookKind || current.bookKind,
    variables: current.details.variables,
  })
  const fallbackCover = details.coverUrl?.trim() ||
    chosen.result.coverUrl?.trim() ||
    current.details.coverUrl?.trim() ||
    current.details.alternateSources?.find(s => s.coverUrl?.trim())?.coverUrl?.trim()

  const safeDetails: BookDetails = {
    ...details,
    name: cleanTitle(details.name?.trim() || current.details.name || unknownName) || current.details.name,
    author: cleanAuthor(details.author?.trim() || current.details.author) || current.details.author,
    coverUrl: fallbackCover || undefined,
    intro: details.intro || current.details.intro,
    kind: details.kind || chosen.result.kind || current.details.kind,
    wordCount: details.wordCount || chosen.result.wordCount || current.details.wordCount,
    lastChapter: details.lastChapter || chosen.result.lastChapter || current.details.lastChapter,
    bookKind: details.bookKind || chosen.result.bookKind || current.bookKind,
    alternateSources: current.details.alternateSources,
  }

  const chapters = await api.chapters(safeDetails.sourceId, chosen.result.bookUrl, safeDetails.tocUrl, {
    name: safeDetails.name,
    author: safeDetails.author,
    tocUrl: safeDetails.tocUrl,
    bookKind: safeDetails.bookKind,
    variables: safeDetails.variables,
  })

  await api.switchBookshelfSource({
    oldSourceId: previous.sourceId,
    oldBookUrl: previous.bookUrl,
    book: {
      sourceId: safeDetails.sourceId,
      bookUrl: chosen.result.bookUrl,
      name: safeDetails.name,
      author: safeDetails.author,
      tocUrl: safeDetails.tocUrl,
      coverUrl: safeDetails.coverUrl,
    },
    alternateSources: current.details.alternateSources,
  })

  return {
    book: {
      details: safeDetails,
      bookUrl: chosen.result.bookUrl,
      chapters,
      bookKind: safeDetails.bookKind,
    },
    targetChapterIndex: chosen.targetChapterIndex,
    previous,
  }
}

/**
 * 换源后的落点提示。
 *
 * 标题完全匹配不到时会**静默**停在章节序号处——用户只看到"怎么跳到这一章了"。
 * 这里补一句提示，把"为什么是这个位置"讲清楚。找到匹配时不打扰（正常流程）。
 */
export function notifySourceSwitchFallback(
  remapped: { matched: boolean },
  t: (key: string, options?: Record<string, unknown>) => string,
): void {
  if (remapped.matched) return
  toast.info(t('reader.switchSourceNearestPosition', { defaultValue: '新书源目录没有同名章节，已定位到最接近的位置' }))
}

/** 供 `remapChapterAfterSourceSwitch` 复用的再导出，避免调用方多引一个模块。 */
export { matchBestChapter, normalizeChapterTitle, remapChapterAfterSourceSwitch }
export type { SourceRemapResult } from './sourceSwitchRemap'
