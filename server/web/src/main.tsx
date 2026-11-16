import { FormEvent, useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { createRoot } from 'react-dom/client'
import { useTranslation } from 'react-i18next'
import { api, BookDetails, BookGroup, BookshelfItem, BookshelfRefreshStatus, Chapter, NetworkImportPreview, SearchResult, SearchStreamEvent, setCsrfToken, SourceGroupSummary, SourceRecord, SourceSummary, streamSearch, UNGROUPED_SOURCE_GROUP } from './api'
import { Icon } from './icons'
import { Logo } from './Logo'
import { Login } from './Login'
import type { OpenBook } from './openBook'
import { loadReaderSettings, loadMediaReaderState, ReaderSettings, ReaderTheme, saveReaderSettings } from './readerSettings'
import { AppHeader } from './AppHeader'
import { cleanAuthor, cleanTitle, defaultSearchFilters, filterSearchGroups, isExactMatch, isPopularMatch, SearchFilters, SearchGroup, SortMode } from './searchFilters'
import { groupSearchResults, searchStore, SourceChoice, SourceChoiceStatus, useSearchStore } from './searchStore'
import { SourceSwitchModal } from './SourceSwitchModal'
import { SourceLoginModal } from './SourceLoginModal'
import { NetworkImportModal } from './NetworkImportModal'
import { SourceHealthModal } from './SourceHealthModal'
import { SourceGroupManagerModal } from './SourceGroupManagerModal'
import { SearchBox } from './SearchBox'
import { removeGroupSourceOverrides, SearchScopeBar } from './SearchScopeBar'
import { SearchScopePickerModal } from './SearchScopePickerModal'
import { ShelfKindTag } from './ShelfKindTag'
import { isLocalBook } from './localBook'
import { PwaManager } from './PwaManager'
import { ErrorBoundary } from './ErrorBoundary'
import { VerificationPanel } from './VerificationPanel'
import { clearOfflineBook, flushOfflineProgress } from './offlineStorage'
import { ClearCacheScope, stepsForScope } from './shelfClearCache'
import { SHELF_MODAL_SHELF, shelfModalReducer } from './shelfModalStack'
import { ButtonSpinner } from './ButtonSpinner'
import { toast, ToastContainer } from './Toast'
import { BookExportModal } from './BookExportModal'
import { KindleDevicesModal } from './KindleDevicesModal'
import { ConfigImportModal } from './ConfigImportModal'
import { TextReaderScreen } from './TextReaderScreen'
import { CacheConcurrencyDialog } from './CacheConcurrencyDialog'
import './styles.css'
import './redesign.css'
import './i18n'

import { clearStoredInspections, getInitialOrStoredInspections, inspectAllSourcesConcurrently, SourceHealthInspection } from './sourceInspector'
import { sanitizeImageUrl } from './sourceImport'
import { BookCover } from './BookCover'
import { AutomationCenter } from './AutomationCenter'

export { sanitizeImageUrl }
export type { SourceChoice, SourceChoiceStatus }

/**
 * 解析书架条目应显示的封面地址。
 *
 * 优先用本地缓存副本（`coverKey`，走 `/api/covers/<key>`，无外部依赖且离线可用）；
 * 若没有副本则回退到原始 `coverUrl` 直连。
 *
 * 这个回退必不可少：从 Legado 备份包导入的书架条目**只有 coverUrl、没有本地副本**
 * （导入器不下载封面），若前端只认 coverKey，整架书的封面会全部退化成文字占位符。
 */
function resolveShelfCover(item: { coverKey?: string; coverUrl?: string }): string | null {
  if (item.coverKey) return api.cover(item.coverKey)
  return sanitizeImageUrl(item.coverUrl)
}

// 「本地导入书」的判定（`loc_book` / `local://`）统一走 `./localBook` 的 `isLocalBook`：
// 与服务端 `BookKind.isLocalRef` 同源，角标、书籍管理弹窗、阅读器目录抽屉三处共用同一判据。

type Page = 'sources' | 'library' | 'shelf' | 'devices' | 'reader'
const readerStorageKey = 'legado-open-book-v1'
const pageFromHash = (): Page => location.hash === '#sources'
  ? 'sources'
  : location.hash === '#shelf'
    ? 'shelf'
    : location.hash === '#devices'
      ? 'devices'
      : location.hash === '#reader'
        ? 'reader'
        : 'library'

function SourceChoiceList({
  choices,
  inspections,
  active,
  onChoose,
  onRecheck,
  onInspectSingle,
  checking,
}: {
  choices: SourceChoice[]
  inspections: Map<string, SourceHealthInspection>
  active?: string
  onChoose: (choice: SourceChoice) => void
  onRecheck: () => void
  onInspectSingle?: (choice: SourceChoice) => void
  checking: boolean
}) {
  const { t } = useTranslation()
  const hoverTimerRef = useRef<Record<string, number>>({})

  const handleMouseEnter = (choice: SourceChoice) => {
    const key = `${choice.result.sourceId}\u0000${choice.result.bookUrl}`
    const insp = inspections.get(key)
    if (!insp || insp.status === 'idle') {
      hoverTimerRef.current[key] = window.setTimeout(() => {
        onInspectSingle?.(choice)
      }, 100)
    }
  }

  const handleMouseLeave = (choice: SourceChoice) => {
    const key = `${choice.result.sourceId}\u0000${choice.result.bookUrl}`
    if (hoverTimerRef.current[key]) {
      clearTimeout(hoverTimerRef.current[key])
      delete hoverTimerRef.current[key]
    }
  }

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
    <section className="source-choice-list" aria-label={t('source.sourceChoicesList', '可用书源切换列表')}>
      <header>
        <div className="source-choice-header-left">
          <span>{t('source.availableSources', '可用书源 ({{count}})', { count: choices.length })}</span>
          <small>
            {checking
              ? t('source.checkingHealthProgress', '正在并发校验书源健康度 ({{completed}}/{{total}})...', { completed: completedCount, total: choices.length })
              : t('source.checkedHealthSummary', '{{completed}}/{{total}} 个书源已完成质量检测', { completed: completedCount, total: choices.length })}
          </small>
        </div>
        <button
          type="button"
          className="subtle-button source-recheck-btn"
          onClick={onRecheck}
          disabled={checking}
          title={t('source.probeAllTitle', '探测所有书源的章节可用性与VIP限制')}
        >
          <Icon name="refresh" className={checking ? 'spin' : ''} />
          <span>{checking ? t('source.probing', '探测中') : t('source.recheck', '重新校验')}</span>
        </button>
      </header>
      <div className="source-choice-items">
        {sortedChoices.map(choice => {
          const key = `${choice.result.sourceId}\u0000${choice.result.bookUrl}`
          const isSelected = active === choice.result.bookUrl
          const isLoading = choice.status === 'loading'
          const inspection = inspections.get(key)

          let badge = null
          let statusText = t('source.clickToSwitch', '点击切换为此书源')

          if (inspection) {
            if (inspection.status === 'checking') {
              badge = <span className="source-health-badge health-checking">{t('source.probingWithDots', '探测中...')}</span>
              statusText = t('source.samplingContentAndVip', '正在抽检章节正文与VIP限制...')
            } else if (inspection.status === 'valid') {
              badge = <span className="source-health-badge health-valid">{t('source.healthBadgeValid', '✓ 完整可读')}</span>
              statusText = t('source.inspectionValid', '共 {{total}} 章 · 全本可读 (后段字数充足 均{{avg}}字)', {
                total: inspection.totalChapters ?? 0,
                avg: inspection.avgLateChapterLength ?? 0,
              })
            } else if (inspection.status === 'vip_restricted') {
              badge = <span className="source-health-badge health-vip">{t('source.healthBadgeVip', '⚠ VIP/付费拦截')}</span>
              statusText = t('source.inspectionVip', '共 {{total}} 章 · 后期章节较短/疑似VIP截断 (抽检均{{avg}}字)', {
                total: inspection.totalChapters ?? 0,
                avg: inspection.avgLateChapterLength ?? 0,
              })
            } else if (inspection.status === 'incomplete') {
              badge = <span className="source-health-badge health-incomplete">{t('source.healthBadgeIncomplete', '疑似残卷')}</span>
              statusText = t('source.inspectionIncomplete', '仅 {{total}} 章 · 章节严重缺失', {
                total: inspection.totalChapters ?? 0,
              })
            } else if (inspection.status === 'error') {
              badge = <span className="source-health-badge health-error">{t('source.healthBadgeError', '✕ 无法读取')}</span>
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
            <button
              key={key}
              className={`source-choice-item ${isSelected ? 'selected' : ''} ${isLoading ? 'loading' : ''}`}
              disabled={isLoading}
              onClick={() => onChoose(choice)}
            >
              <div className="source-choice-top">
                <strong>{choice.result.sourceId}</strong>
                {badge}
              </div>
              <small>{statusText}</small>
            </button>
          )
        })}
      </div>
    </section>
  )
}

function BookDetailModal({
  book,
  choices,
  loading,
  error,
  onChooseSource,
  onRead,
  onOpenShelf,
  onClose,
}: {
  book: OpenBook
  choices: SourceChoice[]
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
  const abortControllerRef = useRef<AbortController | null>(null)
  const cancelInspectRef = useRef(false)

  const latestChapter = book.chapters.at(-1)
  const availableSources = choices.length

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

  useEffect(() => {
    if (cacheConcurrencyOpen) return
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        handleClose()
      }
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [cacheConcurrencyOpen, handleClose])

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
    <div className="modal-backdrop" onClick={handleClose}>
      <div
        className="book-detail-modal"
        onClick={e => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label={t('shelf.bookDetailWithTitle', { name: book.details.name, defaultValue: `书籍详情: ${book.details.name}` })}
      >
        <header className="book-detail-modal-header">
          <div className="book-detail-heading">
            {sanitizeImageUrl(book.details.coverUrl) ? (
              <img className="book-detail-cover" src={sanitizeImageUrl(book.details.coverUrl)!} alt="" referrerPolicy="no-referrer" />
            ) : (
              <div className="book-detail-cover-placeholder">{book.details.name.slice(0, 1)}</div>
            )}
            <div className="book-detail-info">
              <span className="section-kicker">{t('shelf.bookDetail', '书籍详情')}</span>
              <h2>{book.details.name}</h2>
              <p>{book.details.author || t('common.unknownAuthor', '未知作者')}</p>
              <div className="book-detail-stats">
                {book.details.kind && <span>{book.details.kind}</span>}
                {book.details.wordCount && <span>{book.details.wordCount}</span>}
                <span>{t('reader.totalChapters', { count: book.chapters.length, defaultValue: `${book.chapters.length} 章` })}</span>
                <span>{t('library.availableSourcesCount', { count: availableSources || 1, defaultValue: `${availableSources || 1} 个可用书源` })}</span>
                {(book.details.lastChapter || latestChapter) && (
                  <span>{t('library.latestChapterWithTitle', { title: book.details.lastChapter || latestChapter!.title, defaultValue: `最新：${book.details.lastChapter || latestChapter!.title}` })}</span>
                )}
              </div>
            </div>
          </div>
          <div className="book-detail-header-actions">
            <button
              type="button"
              className={inShelf ? 'subtle-button shelf-toggle-btn in-shelf' : 'primary-button shelf-first-step'}
              onClick={inShelf ? onOpenShelf : toggleShelf}
              disabled={shelfBusy || inShelf === null || loading || Boolean(error)}
              title={inShelf ? t('shelf.inShelf', '已在书架') : t('shelf.addToShelf', '加入书架')}
            >
              <Icon name={inShelf ? 'check' : 'plus'} />
              <span>{inShelf ? '已在书架 · 去阅读' : '1. 加入书架'}</span>
            </button>
            <button
              type="button"
              className={`subtle-button cache-second-step ${cacheBusy ? 'is-loading' : ''}`}
              disabled={loading || Boolean(error) || cacheBusy || shelfBusy}
              aria-busy={cacheBusy}
              onClick={() => {
                if ((book.details.bookKind ?? 'novel') === 'novel') setCacheConcurrencyOpen(true)
                else void cacheBook()
              }}
            >
              {cacheBusy ? <ButtonSpinner size={14} /> : <Icon name="cloudDownload" />}
              <span>{cacheBusy ? t('shelf.startingCache', '启动缓存...') : '2. 缓存全本'}</span>
            </button>
            <button
              type="button"
              className="subtle-button"
              disabled={loading || Boolean(error) || book.chapters.length === 0}
              onClick={() => onRead(book)}
            >
              <Icon name="book" />
              <span>先读一章</span>
            </button>
            <button className="subtle-button close-btn" onClick={handleClose} aria-label={t('common.close', '关闭')}>
              <Icon name="close" />
            </button>
          </div>
        </header>

        <div className="book-detail-modal-body">
          {loading ? (
            <div className="book-detail-loading" role="status"><ButtonSpinner />{t('library.loadingBookDetail', '正在获取最新书籍详情与目录...')}</div>
          ) : error ? (
            <p className="form-error" role="alert">{error}</p>
          ) : <>
          {choices.length > 1 && (
            <div className="book-detail-section">
              <SourceChoiceList
                choices={choices}
                inspections={inspections}
                active={book.bookUrl}
                onChoose={handleSelectChoice}
                onRecheck={() => runInspection(true)}
                checking={checking}
              />
            </div>
          )}

          {book.details.intro && (
            <div className="book-detail-section">
              <div className={`book-intro ${introExpanded ? 'expanded' : ''}`}>
                <p>{book.details.intro}</p>
                {book.details.intro.length > 120 && (
                  <button className="intro-toggle" onClick={() => setIntroExpanded(value => !value)}>
                    {introExpanded ? t('shelf.collapseIntro', '收起简介') : t('shelf.expandIntro', '展开简介')}
                  </button>
                )}
              </div>
            </div>
          )}

          <div className="book-detail-section">
            <div className="book-detail-section-title">
              <span>{t('reader.previewToc', '目录预览')}</span>
              <small>{t('reader.totalChapters', { count: book.chapters.length, defaultValue: `共 ${book.chapters.length} 章` })}</small>
            </div>
            <div className="preview-chapters">
              {book.chapters.slice(0, 16).map(item => (
                <button disabled key={item.url} className={item.isVolume ? 'volume-chapter' : undefined}>
                  <span>{item.title}</span>
                  {(item.isVip || item.isPay || item.tag || item.wordCount) && (
                    <small>
                      {item.isVip && t('reader.vip', 'VIP')}
                      {item.isPay && t('reader.purchased', '已购')}
                      {item.tag && ` · ${item.tag}`}
                      {item.wordCount && ` · ${item.wordCount}`}
                    </small>
                  )}
                </button>
              ))}
            </div>
            {book.chapters.length > 16 && (
              <p className="chapter-count">共 {book.chapters.length} 章，点击“查看正文”可打开完整目录。</p>
            )}
          </div>
          </>}
        </div>
      </div>
      {cacheConcurrencyOpen && (
        <CacheConcurrencyDialog
          bookName={book.details.name}
          busy={cacheBusy}
          onCancel={() => setCacheConcurrencyOpen(false)}
          onConfirm={chapterConcurrency => void cacheBook(chapterConcurrency)}
        />
      )}
    </div>
  )
}

function SourceEditor({
  selected,
  onSaved,
  onOpenLogin,
}: {
  selected: SourceSummary | null
  onSaved: () => void
  onOpenLogin?: (source: SourceSummary) => void
}) {
  const { t } = useTranslation()
  const [record, setRecord] = useState<SourceRecord | null>(null); const [text, setText] = useState(''); const [status, setStatus] = useState<{ message: string; isError: boolean } | null>(null)
  useEffect(() => { if (!selected) { setRecord(null); setText(''); return }; void api.source(selected.id).then(value => { setRecord(value); setText(value.json); setStatus(null) }).catch(error => setStatus({ message: error.message, isError: true })) }, [selected])
  const save = async () => { if (!record || !selected) return; try { const next = await api.save(selected.id, text, record.version); setRecord(next); setStatus({ message: t('source.saved', '已保存'), isError: false }); onSaved() } catch (error) { setStatus({ message: error instanceof Error ? error.message : t('source.saveFailed', '保存失败'), isError: true }) } }
  const validate = async () => { if (!selected) return; try { const result = await api.validate(selected.id); setStatus({ message: result.valid ? result.warnings.join('；') || t('source.validatePass', '结构校验通过') : result.errors.join('；'), isError: !result.valid }) } catch (error) { setStatus({ message: error instanceof Error ? error.message : t('source.validateFailed', '校验失败'), isError: true }) } }
  if (!selected) return <section className="source-editor empty-editor"><Icon name="book" /><h2>{t('source.selectOneSource', '选择一个书源')}</h2><p>{t('source.selectOneSourceDesc', '从列表选择书源，或导入一个 JSON 文件。')}</p></section>
  return (
    <section className="source-editor">
      <header>
        <div>
          <span className="section-kicker">{t('source.sourceEditKicker', '书源编辑')}</span>
          <div className="source-editor-name-row">
            <h2>{selected.name}</h2>
            {selected.hasLogin && <span className="source-login-badge" title={t('source.supportLoginAuth', '支持登录鉴权')}>{t('source.loginBadge', '登录')}</span>}
          </div>
          <small>{selected.url}</small>
        </div>
        <div className="editor-actions">
          {selected.hasLogin && (
            <button
              type="button"
              className="subtle-button source-login-entry-btn"
              onClick={() => onOpenLogin?.(selected)}
            >
              {t('source.loginButton', '登录')}
            </button>
          )}
          <button type="button" className="subtle-button" onClick={() => void validate()}>{t('source.validateButton', '校验')}</button>
          <button type="button" className="primary-button" onClick={() => void save()}>{t('source.saveButton', '保存')}</button>
        </div>
      </header>
      <textarea aria-label={t('source.editorAria', '书源 JSON 编辑器')} value={text} onChange={event => setText(event.target.value)} spellCheck={false} />
      {status && <footer className={status.isError ? 'form-error' : ''}>{status.message}</footer>}
    </section>
  )
}

function SourcesPage({ selected, onSelect, onSourcesChange }: { selected: SourceSummary | null; onSelect: (source: SourceSummary | null) => void; onSourcesChange: (sources: SourceSummary[]) => void }) {
  const { t } = useTranslation()
  const [sources, setSources] = useState<SourceSummary[]>([])
  /** 服务端聚合的分组概览（名字 + 总数 + 已启用数），供「分组管理」面板使用。 */
  const [groupSummaries, setGroupSummaries] = useState<SourceGroupSummary[]>([])
  const [query, setQuery] = useState('')
  const [groupFilter, setGroupFilter] = useState('')
  const [notice, setNotice] = useState('')
  const [importing, setImporting] = useState(false)
  const [isBatchMode, setIsBatchMode] = useState(false)
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [showHealthModal, setShowHealthModal] = useState(false)
  const [showGroupManager, setShowGroupManager] = useState(false)
  const [busyBatch, setBusyBatch] = useState(false)
  const [loginModalSource, setLoginModalSource] = useState<SourceSummary | null>(null)
  /** 网络导入弹窗是否打开（与「导入 JSON」并列的另一种导入方式）。 */
  const [showNetworkImport, setShowNetworkImport] = useState(false)
  /**
   * 本地文件导入时，预览接口返回的结果与文件名。
   *
   * 有值时弹窗走「本地模式」：不再拉取，直接把这份预览列出来让用户挑。
   */
  const [localImportPreview, setLocalImportPreview] = useState<NetworkImportPreview | null>(null)
  const [localImportLabel, setLocalImportLabel] = useState<string>('')

  const load = useCallback(async () => {
    try {
      const values = await api.sources(query)
      setSources(values)
      onSourcesChange(values)
      // 分组概览由服务端聚合（含「已启用」数）；它只服务于「分组管理」面板，失败不该影响书源列表
      void api.sourceGroups().then(setGroupSummaries).catch(() => undefined)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : t('source.cannotLoad', '无法载入书源'))
    }
  }, [onSourcesChange, query])

  useEffect(() => {
    const timer = window.setTimeout(() => { void load() }, 180)
    return () => window.clearTimeout(timer)
  }, [load])

  const allGroups = useMemo(() => {
    const set = new Set<string>()
    for (const s of sources) {
      if (s.group && s.group.trim()) set.add(s.group.trim())
    }
    return Array.from(set).sort()
  }, [sources])
  const enabledSourceCount = sources.filter(source => source.enabled).length
  const loginSourceCount = sources.filter(source => source.hasLogin).length

  const filteredSources = useMemo(() => {
    return sources.filter(source => {
      if (groupFilter) {
        if (groupFilter === UNGROUPED_SOURCE_GROUP && source.group) return false
        if (groupFilter !== UNGROUPED_SOURCE_GROUP && (source.group ?? '') !== groupFilter) return false
      }
      if (query) {
        const q = query.toLowerCase()
        return source.name.toLowerCase().includes(q) || source.url.toLowerCase().includes(q) || (source.group ?? '').toLowerCase().includes(q)
      }
      return true
    })
  }, [sources, groupFilter, query])

  const toggleSelect = (id: string) => {
    setSelectedIds(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const handleSelectAll = () => {
    setSelectedIds(new Set(filteredSources.map(s => s.id)))
  }

  const handleClearAll = () => {
    setSelectedIds(new Set())
  }

  const handleInvertSelection = () => {
    setSelectedIds(prev => {
      const next = new Set<string>()
      for (const s of filteredSources) {
        if (!prev.has(s.id)) next.add(s.id)
      }
      return next
    })
  }

  const handleBatchEnable = async () => {
    if (selectedIds.size === 0) return
    setBusyBatch(true)
    try {
      const resp = await api.batchSources('enable', Array.from(selectedIds))
      toast.success(t('source.batchEnableSuccess', '已批量启用 {{count}} 个书源', { count: resp.affected }))
      await load()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('source.enableFailed', '启用失败'))
    } finally {
      setBusyBatch(false)
    }
  }

  const handleBatchDisable = async () => {
    if (selectedIds.size === 0) return
    setBusyBatch(true)
    try {
      const resp = await api.batchSources('disable', Array.from(selectedIds))
      toast.success(t('source.batchDisableSuccess', '已批量停用 {{count}} 个书源', { count: resp.affected }))
      await load()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('source.disableFailed', '停用失败'))
    } finally {
      setBusyBatch(false)
    }
  }

  const handleBatchDelete = async () => {
    if (selectedIds.size === 0) return
    const selectedSources = sources.filter(s => selectedIds.has(s.id))
    const namesSummary = selectedSources.slice(0, 3).map(s => s.name).join('、') + (selectedSources.length > 3 ? t('source.etcCount', ' 等共 {{count}} 项', { count: selectedSources.length }) : '')
    if (!confirm(t('source.batchDeleteConfirm', '确定要彻底删除选中的 {{count}} 个书源吗？\n（{{names}}）\n删除后不可恢复！', { count: selectedIds.size, names: namesSummary }))) return
    setBusyBatch(true)
    try {
      const resp = await api.batchSources('delete', Array.from(selectedIds))
      toast.success(t('source.batchDeleteSuccess', '已删除 {{count}} 个书源', { count: resp.affected }))
      setSelectedIds(new Set())
      if (selected && selectedIds.has(selected.id)) {
        onSelect(null)
      }
      await load()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('source.deleteFailed', '删除失败'))
    } finally {
      setBusyBatch(false)
    }
  }

  const handleBatchExport = async () => {
    if (selectedIds.size === 0) return
    setBusyBatch(true)
    try {
      const exportStrings = await api.exportSources(Array.from(selectedIds))
      const parsedList = exportStrings.map(str => {
        try { return JSON.parse(str) } catch { return null }
      }).filter(Boolean)
      const blob = new Blob([JSON.stringify(parsedList, null, 2)], { type: 'application/json' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `legado_sources_export_${new Date().toISOString().slice(0, 10)}.json`
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
      URL.revokeObjectURL(url)
      toast.success(t('source.exportSuccess', '已成功导出 {{count}} 个书源', { count: parsedList.length }))
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('source.exportFailed', '导出失败'))
    } finally {
      setBusyBatch(false)
    }
  }

  /**
   * 本地 JSON 导入：**先出预览列表，再由用户挑**（与网络导入同一个弹窗、同一套票据）。
   *
   * 解析与「新增 / 更新 / 不可导入」的判定都交给服务端的**同一个解析器**，
   * 前端只负责把文件原文读出来 —— 这样本地与网络两条路的规则不会漂移。
   */
  const importSources = async (file: File | undefined) => {
    if (!file) return
    setImporting(true)
    try {
      const rawText = await file.text()
      const result = await api.previewLocalSourceJson(rawText, file.name)
      setLocalImportPreview(result)
      setLocalImportLabel(file.name)
      setShowNetworkImport(true)
    } catch (error) {
      const message = error instanceof Error ? error.message : t('source.invalidFormat', '书源格式无效')
      toast.error(message)
      setNotice(t('source.importFailedPrefix', '导入失败：{{reason}}', { reason: message }))
    } finally {
      setImporting(false)
    }
  }

  const remove = async () => {
    if (!selected || !confirm(t('source.deleteSingleConfirm', '删除“{{name}}”？', { name: selected.name }))) return
    try {
      await api.remove(selected.id)
      onSelect(null)
      await load()
    } catch (error) {
      setNotice(error instanceof Error ? error.message : t('source.deleteFailed', '删除失败'))
    }
  }

  return (
    <main className={`sources-page ${isBatchMode ? 'batch-mode-active' : ''}`}>
      <aside className="source-sidebar">
        <div className="source-sidebar-heading">
          <div className="source-sidebar-title-row">
            <div>
              <span>{t('source.libraryTitle', '书源库')}</span>
              <small>{filteredSources.length} / {sources.length}</small>
            </div>
            <i className="source-sidebar-live-dot" title={t('header.serviceLoggedIn', '服务已连接')} />
          </div>
          <p className="source-sidebar-subtitle">集中维护书源规则、分组与登录状态</p>
          <div className="source-sidebar-top-actions">
            <button
              type="button"
              className="subtle-button icon-button health-probe-btn"
              title={t('source.healthCheck', '书源连通性体检')}
              onClick={() => setShowHealthModal(true)}
            >
              <Icon name="activity" />
              <span>{t('source.healthCheck', '体检')}</span>
            </button>
            <button
              type="button"
              className={`subtle-button batch-mode-btn ${isBatchMode ? 'active-batch-btn' : ''}`}
              title={t('source.batchManageTooltip', '批量启用 / 停用 / 导出 / 删除书源')}
              onClick={() => {
                setIsBatchMode(prev => !prev)
                setSelectedIds(new Set())
              }}
            >
              <Icon name="list" />
              <span>{isBatchMode ? t('common.ok', '退出批量') : t('source.batchManage', '批量管理')}</span>
            </button>
            <button
              type="button"
              className="subtle-button group-manager-btn"
              title={t('source.groupManager', '书源分组管理')}
              onClick={() => setShowGroupManager(true)}
            >
              <Icon name="folder" />
              <span>{t('source.groupManager', '分组管理')}</span>
            </button>
          </div>
        </div>

        {allGroups.length > 0 && (
          <div className="source-group-filter-bar">
            <select
              className="source-group-select"
              value={groupFilter}
              onChange={e => setGroupFilter(e.target.value)}
              aria-label={t('source.groupManager', '按分组筛选书源')}
            >
              <option value="">{t('search.scopeAll', '全部分组')} ({sources.length})</option>
              {allGroups.map(g => (
                <option key={g} value={g}>
                  {g} ({sources.filter(s => s.group === g).length})
                </option>
              ))}
              <option value={UNGROUPED_SOURCE_GROUP}>
                {t('search.scopeUngrouped', '未分组')} ({sources.filter(s => !s.group).length})
              </option>
            </select>
          </div>
        )}

        <div className="source-filter">
          <Icon name="search" />
          <input placeholder={t('source.filterSourcesPlaceholder', '筛选书源')} value={query} onChange={event => setQuery(event.target.value)} />
        </div>

        <label className={`import-button ${importing ? 'disabled' : ''}`}>
          <Icon name="upload" />
          {importing ? t('common.loading', '导入中...') : t('source.importJson', '导入 JSON')}
          <input
            type="file"
            accept="application/json,.json,text/plain,.txt,*"
            disabled={importing}
            onChange={event => {
              const file = event.target.files?.[0]
              event.target.value = ''
              void importSources(file)
            }}
          />
        </label>

        {/* 网络导入：从社区书源站/书源的「更新书源」页给的 URL 直接拉取并导入 */}
        <button
          type="button"
          className="import-button import-button-network"
          onClick={() => setShowNetworkImport(true)}
        >
          <Icon name="cloudDownload" />
          {t('source.networkImport', '网络导入')}
        </button>

        {notice && <p className="sidebar-notice">{notice}</p>}

        <nav className="source-list">
          {filteredSources.map(source => {
            const isChecked = selectedIds.has(source.id)
            const isCurrent = selected?.id === source.id

            if (isBatchMode) {
              return (
                <div
                  key={source.id}
                  className={`source-list-item batch-item ${isChecked ? 'checked' : ''}`}
                  onClick={() => toggleSelect(source.id)}
                >
                  <label className="batch-checkbox-wrap" onClick={e => e.stopPropagation()}>
                    <input
                      type="checkbox"
                      checked={isChecked}
                      onChange={() => toggleSelect(source.id)}
                    />
                  </label>
                  <div className="source-list-item-content">
                    <div className="source-list-item-title">
                      <span>{source.name}</span>
                      {!source.enabled && <span className="source-disabled-badge">{t('common.disabled', '已停用')}</span>}
                      {source.hasLogin && <span className="source-login-badge" title={t('source.supportLoginAuth', '支持登录鉴权')}>{t('source.loginBadge', '登录')}</span>}
                    </div>
                    <small>{source.group || (source.isJsSource ? t('source.jsSource', 'JS 书源') : t('source.normalSource', '书源'))}</small>
                  </div>
                </div>
              )
            }

            return (
              <button
                className={isCurrent ? 'selected' : ''}
                key={source.id}
                type="button"
                onClick={() => onSelect(source)}
              >
                <div className="source-list-item-title">
                  <span>{source.name}</span>
                  {!source.enabled && <span className="source-disabled-badge">{t('common.disabled', '已停用')}</span>}
                  {source.hasLogin && <span className="source-login-badge" title={t('source.supportLoginAuth', '支持登录鉴权')}>{t('source.loginBadge', '登录')}</span>}
                </div>
                <small>{source.group || (source.isJsSource ? t('source.jsSource', 'JS 书源') : t('source.normalSource', '书源'))}</small>
              </button>
            )
          })}
        </nav>
      </aside>

      <section className="sources-content">
        <header className="page-title sources-page-title">
          <div className="page-heading-copy">
            <span className="section-kicker">{t('login.brand', '阅读服务器')}</span>
            <h1>{t('source.headerTitle', '书源管理')}</h1>
            <p>{t('source.headerSubtitle', '导入、校验与维护你的阅读来源。')}</p>
          </div>
          <div className="sources-heading-side">
            <div className="sources-overview-stats" aria-label="书源概览">
              <span><strong>{enabledSourceCount}</strong><small>已启用</small></span>
              <span><strong>{allGroups.length}</strong><small>分组</small></span>
              <span><strong>{loginSourceCount}</strong><small>可登录</small></span>
            </div>
            <div className="page-title-actions">
            {selected && (
              <button type="button" className="danger-button" onClick={() => void remove()}>
                {t('source.deleteSource', '删除书源')}
              </button>
            )}
            </div>
          </div>
        </header>
        <SourceEditor
          selected={selected}
          onSaved={() => void load()}
          onOpenLogin={source => setLoginModalSource(source)}
        />
      </section>

      {/* Floating Batch Action Bar */}
      {isBatchMode && (
        <aside className="source-batch-bar" aria-label={t('source.batchToolbarAria', '书源批量操作工具栏')}>
          <div className="batch-bar-left">
            <span className="batch-bar-count">
              {t('source.selectedCount', '已选 {{count}} / {{total}}', {
                count: selectedIds.size,
                total: filteredSources.length,
              })}
            </span>
            <div className="batch-select-helpers">
              <button type="button" className="subtle-button compact" onClick={handleSelectAll}>
                {t('shelf.selectAll', '全选')}
              </button>
              <button type="button" className="subtle-button compact" onClick={handleClearAll}>
                {t('source.deselectAll', '全不选')}
              </button>
              <button type="button" className="subtle-button compact" onClick={handleInvertSelection}>
                {t('common.invertSelect', '反选')}
              </button>
            </div>
          </div>
          <div className="batch-bar-right">
            <button
              type="button"
              className="subtle-button"
              disabled={selectedIds.size === 0 || busyBatch}
              onClick={() => void handleBatchEnable()}
            >
              {t('source.batchEnable', '批量启用')}
            </button>
            <button
              type="button"
              className="subtle-button"
              disabled={selectedIds.size === 0 || busyBatch}
              onClick={() => void handleBatchDisable()}
            >
              {t('source.batchDisable', '批量停用')}
            </button>
            <button
              type="button"
              className="subtle-button"
              disabled={selectedIds.size === 0 || busyBatch}
              onClick={() => void handleBatchExport()}
            >
              {t('source.batchExport', '导出选中')}
            </button>
            <button
              type="button"
              className="danger-button"
              disabled={selectedIds.size === 0 || busyBatch}
              onClick={() => void handleBatchDelete()}
            >
              {t('source.batchDelete', '批量删除')}
            </button>
            <button
              type="button"
              className="secondary-button"
              onClick={() => {
                setIsBatchMode(false)
                setSelectedIds(new Set())
              }}
            >
              {t('common.ok', '完成')}
            </button>
          </div>
        </aside>
      )}

      {showHealthModal && (
        <SourceHealthModal
          sources={sources}
          onClose={() => setShowHealthModal(false)}
          onSourcesChange={() => void load()}
          onToast={(msg, type) => {
            if (type === 'error') toast.error(msg)
            else if (type === 'success') toast.success(msg)
            else toast.info(msg)
          }}
        />
      )}

      {showGroupManager && (
        <SourceGroupManagerModal
          groups={groupSummaries}
          onChanged={() => void load()}
          onClose={() => setShowGroupManager(false)}
        />
      )}

      {loginModalSource && (
        <SourceLoginModal
          sourceId={loginModalSource.id}
          sourceName={loginModalSource.name}
          onClose={() => setLoginModalSource(null)}
          onToast={(msg, type) => {
            if (type === 'error') toast.error(msg)
            else if (type === 'success') toast.success(msg)
            else toast.info(msg)
          }}
        />
      )}

      {/* 导入弹窗：与上面的弹窗**平级**挂载（严禁嵌套 backdrop，见仓库弹窗架构约定）。
          网络导入与本地 JSON 导入共用它 —— 本地模式由 localImportPreview 提供已算好的预览。 */}
      {showNetworkImport && (
        <NetworkImportModal
          groups={allGroups}
          initialPreview={localImportPreview}
          localLabel={localImportLabel}
          onClose={() => { setShowNetworkImport(false); setLocalImportPreview(null); setLocalImportLabel('') }}
          onImported={() => { void load() }}
          onToast={(msg, type) => {
            if (type === 'error') toast.error(msg)
            else if (type === 'success') toast.success(msg)
            else toast.info(msg)
          }}
        />
      )}
    </main>
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
          <mark key={i} className="search-highlight">{part}</mark>
        ) : (
          part
        )
      )}
    </>
  )
}

function LibraryPage({ sources, onRead }: { sources: SourceSummary[]; onRead: (book: OpenBook) => void }) {
  const { t } = useTranslation()
  const search = useSearchStore()
  const [sourceGroups, setSourceGroups] = useState<SourceGroupSummary[]>([])
  const [showScopePicker, setShowScopePicker] = useState(false)
  const [showSourceFailures, setShowSourceFailures] = useState(false)
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
    <main className="library-page">
      <section className="library-hero">
        <div className="page-heading-grid library-heading-grid">
          <div className="page-heading-copy">
            <span className="section-kicker">{t('library.heroKicker', '在线书库')}</span>
            <h1>{t('library.heroTitle', '找一本书，安静地读下去。')}</h1>
            <p>跨书源搜索书名与作者，确认目录后直接加入书架、缓存或上架 Kindle。</p>
          </div>
          <div className="library-overview-panel" aria-label="书库概览">
            <div className="library-overview-primary">
              <span>可用书源</span>
              <strong>{enabledSources}</strong>
              <small>{sources.length - enabledSources > 0 ? `${sources.length - enabledSources} 个已停用` : '全部书源已启用'}</small>
            </div>
            <div className="library-overview-secondary">
              <span><strong>{searchableGroups}</strong><small>搜索分组</small></span>
              <span><strong>{groups.length || '—'}</strong><small>本次结果</small></span>
            </div>
          </div>
        </div>
        <div className="library-search-workspace">
          <SearchBox
            keyword={search.keyword}
            loading={search.loading}
            onChange={search.setKeyword}
            onSubmit={() => search.startSearch()}
            onStop={search.stopSearch}
          />
          {/* 搜索范围：快速分组选项卡 + 多分组/多书源选择器 */}
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
                // 重新选中整组时收回组内独立勾选；之后取消整组才能一并取消这些书源。
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
        </div>
        {showScopePicker && (
          <SearchScopePickerModal
            selectedGroups={search.selectedGroups}
            selectedSourceIds={search.selectedSourceIds}
            onApply={(groups, sourceIds) => search.setSearchScope(groups, sourceIds)}
            onClose={() => setShowScopePicker(false)}
          />
        )}
        {(search.loading || search.stopped) && (
          <p className="library-search-status">
            {search.stopped
              ? t('library.searchStatusStopped', { count: groups.length, defaultValue: `已停止，已获得 ${groups.length} 本书。` })
              : t('library.searchStatusRunning', { count: groups.length, completed, total, defaultValue: `已获得 ${groups.length} 本书，已检查 ${completed} / ${total} 个书源` }) +
                (failures || empty ? t('library.searchStatusFailures', { failed: failures, empty, defaultValue: `，失败 ${failures} 个、无结果 ${empty} 个` }) : '') + '。'}
          </p>
        )}
        {searchFinished && groups.length === 0 && (
          <p className="library-filter-empty" role="status">
            {t('library.noMatches', '没有匹配结果。')}
          </p>
        )}
        {search.sourceFailures.length > 0 && (
          <div className="search-failure-panel">
            <button
              type="button"
              className="subtle-button"
              aria-expanded={showSourceFailures}
              onClick={() => setShowSourceFailures(value => !value)}
            >
              {t('library.searchFailureDetails', { count: search.sourceFailures.length, defaultValue: `失败详情（${search.sourceFailures.length}）` })}
              <Icon name="chevronDown" />
            </button>
            {showSourceFailures && (
              <ul>
                {search.sourceFailures.map(failure => (
                  <li key={failure.sourceId}>
                    <strong>{failure.sourceId}</strong>
                    <span>{failureCategoryLabels[failure.category]}</span>
                    {failure.reason && <small>{failure.reason}</small>}
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}
      </section>
      {search.message && <p className="form-error library-message">{search.message}</p>}
      {groups.length > 0 && (
        <>
          <section className="library-result-filters" aria-label={t('library.filterResults', '筛选搜索结果')}>
            <label>
              <Icon name="search" />
              <input
                value={search.filters.query}
                onChange={event => search.setFilters(current => ({ ...current, query: event.target.value }))}
                placeholder={t('library.filterPlaceholder', '筛选书名或作者')}
              />
            </label>
            <label>
              {t('library.sortLabel', '排序')}
              <select
                value={search.filters.sortMode}
                onChange={event => search.setFilters(current => ({ ...current, sortMode: event.target.value as SortMode }))}
              >
                <option value="smart">{t('library.sortSmart', '智能推荐')}</option>
                <option value="sources">{t('library.sortSources', '书源最多')}</option>
                <option value="exact">{t('library.sortExact', '精准优先')}</option>
                <option value="name">{t('library.sortName', '书名 A-Z')}</option>
              </select>
            </label>
            <label>
              {t('header.sources', '书源')}
              <select
                value={search.filters.minimumSources}
                onChange={event => search.setFilters(current => ({ ...current, minimumSources: Number(event.target.value) as SearchFilters['minimumSources'] }))}
              >
                <option value={1}>{t('common.all', '全部')}</option>
                <option value={2}>{t('library.minSources2', '2 个及以上')}</option>
                <option value={3}>{t('library.minSources3', '3 个及以上')}</option>
              </select>
            </label>
            <label>
              <input
                type="checkbox"
                checked={search.filters.withIntro}
                onChange={event => search.setFilters(current => ({ ...current, withIntro: event.target.checked }))}
              />
              {t('library.withIntro', '有简介')}
            </label>
            <label>
              <input
                type="checkbox"
                checked={search.filters.withCover}
                onChange={event => search.setFilters(current => ({ ...current, withCover: event.target.checked }))}
              />
              {t('library.withCover', '有封面')}
            </label>
          </section>
          <section className="library-results">
            <header>
              <h2>{t('library.searchResults', '搜索结果')}</h2>
              <small>{t('shelf.booksInGroup', '{{count}} 本书', { count: visibleGroups.length })}{hasFilters && ` / ${groups.length}`}</small>
            </header>
            <div className="library-results-grid">
              {visibleGroups.map(group => {
                const isExact = isExactMatch(group, search.keyword)
                const isPopular = isPopularMatch(group)
                const coverUrl = group.sources.find(source => source.coverUrl?.trim())?.coverUrl
                return (
                  <button
                    key={group.key}
                    className={`search-result-item ${isExact ? 'exact-match' : ''}`}
                    data-source-ids={JSON.stringify(group.sources.map(source => source.sourceId))}
                    data-book-urls={JSON.stringify(group.sources.map(source => source.bookUrl))}
                    onClick={() => void search.openGroup(group)}
                    disabled={search.detailLoading}
                  >
                    <span className="result-cover">
                      <BookCover
                        coverUrl={coverUrl}
                        name={group.name}
                        className="result-cover-image"
                        fallbackClassName="result-cover-fallback"
                      />
                      <span className="result-cover-glow" aria-hidden="true" />
                    </span>
                    <span className="result-main-info">
                      <div className="result-title-row">
                        <strong><HighlightText text={group.name} keyword={search.keyword} /></strong>
                        {isExact && <span className="result-badge result-badge-exact">{t('library.exactMatch', '精准匹配')}</span>}
                        {isPopular && <span className="result-badge result-badge-popular">{t('library.sourcesBadge', '{{count}} 源', { count: group.sources.length })}</span>}
                      </div>
                      <small>
                        <HighlightText text={group.author || t('common.unknownAuthor', '未知作者')} keyword={search.keyword} />
                        {!isPopular && ` · ${t('library.sourcesCount', '{{count}} 个书源', { count: group.sources.length })}`}
                      </small>
                      {(group.sources.some(source => source.kind || source.wordCount || source.lastChapter)) && (
                        <small className="result-metadata">
                          {[
                            group.sources.find(source => source.kind?.trim())?.kind,
                            group.sources.find(source => source.wordCount?.trim())?.wordCount,
                            group.sources.find(source => source.lastChapter?.trim())?.lastChapter && t('library.latestChapterShort', { title: group.sources.find(source => source.lastChapter?.trim())!.lastChapter!, defaultValue: `最新 ${group.sources.find(source => source.lastChapter?.trim())!.lastChapter!}` }),
                          ].filter(Boolean).join(' · ')}
                        </small>
                      )}
                    </span>
                    <Icon name="arrowRight" />
                  </button>
                )
              })}
            </div>
            {visibleGroups.length === 0 && <p className="library-filter-empty">{t('library.filterEmpty', '没有符合当前筛选条件的书籍。')}</p>}
            <div className="library-pagination">
              <button
                type="button"
                className="subtle-button"
                disabled={search.loading}
                onClick={search.loadMore}
              >
                {search.nextPageLoading
                  ? t('library.loadingNextPage', '正在加载下一页...')
                  : t('library.nextSearchPage', { page: search.page + 1, defaultValue: `加载第 ${search.page + 1} 页` })}
              </button>
            </div>
          </section>
        </>
      )}
      {search.openBook && (
        <BookDetailModal
          book={search.openBook}
          choices={search.choices}
          loading={search.detailLoading}
          error={search.detailError}
          onChooseSource={choice => { if (!search.detailLoading) void search.chooseSource(choice) }}
          onRead={selectedBook => {
            search.setOpenBook(null)
            onRead(selectedBook)
          }}
          onOpenShelf={() => {
            search.setOpenBook(null)
            location.hash = '#shelf'
          }}
          onClose={() => search.setOpenBook(null)}
        />
      )}
    </main>
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
function readCustomVariable(raw?: string): string {
  if (!raw) return ''
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown> | null
    const value = parsed && typeof parsed === 'object' ? parsed.custom : undefined
    return typeof value === 'string' ? value : ''
  } catch {
    return ''
  }
}

function parseBookVariables(raw?: string): Record<string, string> {
  if (!raw) return {}
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>
    return Object.fromEntries(
      Object.entries(parsed).filter((entry): entry is [string, string] => typeof entry[1] === 'string')
    )
  } catch {
    return {}
  }
}

function BookInfoEditModal({
  item,
  groups,
  onSaved,
  onClose,
}: {
  item: BookshelfItem
  groups: BookGroup[]
  onSaved: (updated: BookshelfItem) => void
  onClose: () => void
}) {
  const { t } = useTranslation()
  const [name, setName] = useState(item.name)
  const [author, setAuthor] = useState(item.author || '')
  const [groupName, setGroupName] = useState<string | undefined>(item.groupName)
  const [coverUrl, setCoverUrl] = useState<string | null>(null) // null = keep existing, '' = clear, string = new URL
  const [uploadedCoverKey, setUploadedCoverKey] = useState<string | null>(null)
  const [uploadingCover, setUploadingCover] = useState(false)
  const [alternateSources, setAlternateSources] = useState<SearchResult[]>(item.alternateSources || [])
  // 书籍变量里的 `custom` 值（听书音色/朗读者）。初值来自书架条目携带的 `variable` JSON。
  const [customVariable, setCustomVariable] = useState(() => readCustomVariable(item.variable))
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const fileInputRef = useRef<HTMLInputElement | null>(null)

  // In-modal online search completion states
  const [searchOpen, setSearchOpen] = useState(false)
  const [searchKeyword, setSearchKeyword] = useState(item.name)
  const [searching, setSearching] = useState(false)
  const [searchResults, setSearchResults] = useState<SearchResult[]>([])
  const [searchProgress, setSearchProgress] = useState<SearchStreamEvent | null>(null)
  const [searchError, setSearchError] = useState('')
  const searchSocketRef = useRef<WebSocket | null>(null)

  const stopSearch = useCallback(() => {
    if (searchSocketRef.current) {
      searchSocketRef.current.close()
      searchSocketRef.current = null
    }
    setSearching(false)
  }, [])

  useEffect(() => {
    return () => {
      if (searchSocketRef.current) {
        searchSocketRef.current.close()
        searchSocketRef.current = null
      }
    }
  }, [])

  const handleStartSearch = useCallback((overrideKeyword?: string) => {
    const kw = (overrideKeyword ?? searchKeyword).trim()
    if (!kw) {
      setSearchError(t('library.inputKeyword', '请输入搜索关键词'))
      return
    }

    stopSearch()
    setSearching(true)
    setSearchError('')
    setSearchResults([])
    setSearchProgress(null)

    const socket = streamSearch(
      kw,
      undefined,
      event => {
        if (event.type === 'start' || event.type === 'progress' || event.type === 'done') {
          setSearchProgress(event)
        }
        if (event.type === 'results' && event.results.length > 0) {
          setSearchResults(prev => {
            const existingKeys = new Set(prev.map(r => `${r.sourceId}\u0000${r.bookUrl}`))
            const fresh = event.results.filter(r => !existingKeys.has(`${r.sourceId}\u0000${r.bookUrl}`))
            return fresh.length > 0 ? [...prev, ...fresh] : prev
          })
        }
        if (event.type === 'done') {
          setSearching(false)
        }
      },
      err => {
        setSearchError(err)
        setSearching(false)
      },
      () => {
        setSearching(false)
      }
    )
    searchSocketRef.current = socket
  }, [searchKeyword, stopSearch, t])

  const handleApplyCandidate = useCallback((candidate: SearchResult) => {
    if (candidate.author) {
      setAuthor(candidate.author)
    }
    if (candidate.coverUrl) {
      setCoverUrl(candidate.coverUrl)
    }
    // Merge candidate and all search results into alternateSources
    setAlternateSources(prev => {
      const existing = new Set(prev.map(s => `${s.sourceId}\u0000${s.bookUrl}`))
      const toAdd: SearchResult[] = []
      const candKey = `${candidate.sourceId}\u0000${candidate.bookUrl}`
      if (!existing.has(candKey)) {
        toAdd.push(candidate)
        existing.add(candKey)
      }
      for (const r of searchResults) {
        const k = `${r.sourceId}\u0000${r.bookUrl}`
        if (!existing.has(k)) {
          toAdd.push(r)
          existing.add(k)
        }
      }
      return [...toAdd, ...prev]
    })
    toast.success(t('shelf.appliedCandidateInfo', '已应用来自【{{source}}】的书籍信息', { source: candidate.sourceId }))
  }, [searchResults, t])

  const candidateCovers = useMemo(() => {
    const map = new Map<string, { sourceId: string; coverUrl: string }>()
    for (const alt of alternateSources) {
      const url = sanitizeImageUrl(alt.coverUrl)
      if (url && !map.has(url)) {
        map.set(url, { sourceId: alt.sourceId, coverUrl: url })
      }
    }
    return Array.from(map.values())
  }, [alternateSources])

  const previewSrc = useMemo(() => {
    if (uploadedCoverKey) return api.cover(uploadedCoverKey)
    if (coverUrl === '') return null
    if (coverUrl) return sanitizeImageUrl(coverUrl)
    if (item.coverKey) return api.cover(item.coverKey)
    return null
  }, [uploadedCoverKey, coverUrl, item.coverKey])

  const handleUploadCover = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    const validExtensions = /\.(jpe?g|png|webp|gif|bmp)$/i
    if (!file.type.startsWith('image/') && !validExtensions.test(file.name)) {
      toast.error(t('shelf.coverFileLimitHint', '支持 JPG、PNG、WebP、GIF、BMP 格式，最大 5MB'))
      if (fileInputRef.current) fileInputRef.current.value = ''
      return
    }
    if (file.size > 5 * 1024 * 1024) {
      toast.error(t('shelf.coverFileLimitHint', '支持 JPG、PNG、WebP、GIF、BMP 格式，最大 5MB'))
      if (fileInputRef.current) fileInputRef.current.value = ''
      return
    }
    setUploadingCover(true)
    try {
      const res = await api.uploadCover(file)
      setUploadedCoverKey(res.coverKey)
      setCoverUrl(null) // clear external text url since we now have uploaded key
      toast.success(t('shelf.coverUploadSuccess', '封面上传成功'))
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.uploadCoverFailed', '上传封面失败'))
    } finally {
      setUploadingCover(false)
      if (fileInputRef.current) fileInputRef.current.value = ''
    }
  }

  const handleSave = async (e: FormEvent) => {
    e.preventDefault()
    const trimmedName = name.trim()
    if (!trimmedName) {
      setError(t('shelf.bookTitleEmptyError', '书名不能为空'))
      return
    }

    setSaving(true)
    setError('')
    try {
      // 不要把本服务自己的封面接口地址当"外部封面地址"回写。
      // 之前 coverUrl 为空时会回退到 api.cover(coverKey)，于是存回 `/api/covers/<自己的 key>`，
      // 形成自引用。封面本来就由 coverKey 表达，这里只提交真实外部 URL。
      // 三种情形必须区分开（服务端语义：缺省=保留，空串=清除）：
      //   ① 用户没动过封面（coverUrl === null）⇒ 提交 undefined，服务端保留原值。
      //      原实现这里区分不开，于是「只改书名点保存」会把 cover_url 抹成 NULL。
      //   ② 用户点了「清除封面」（coverUrl === ''）⇒ 必须显式提交空串，否则清除不掉
      //      （空串会被下面的 externalCover 折成 undefined，看起来像「没动过」）。
      //   ③ 用户填了外部地址 ⇒ 提交该地址；若它是本服务自己的 /api/covers/<key>（自引用），
      //      则不提交 —— 封面本来就由 coverKey 表达。
      const externalCover = coverUrl && !coverUrl.startsWith('/api/covers/') ? coverUrl : undefined
      const coverUrlField = uploadedCoverKey ? undefined : coverUrl === null ? undefined : coverUrl === '' ? '' : externalCover
      const coverKeyField = uploadedCoverKey || (coverUrl === '' ? '' : undefined)
      const updated = await api.updateBookshelfInfo({
        sourceId: item.sourceId,
        bookUrl: item.bookUrl,
        name: trimmedName,
        author: author.trim() || undefined,
        coverUrl: coverUrlField,
        coverKey: coverKeyField,
        groupName: groupName || undefined,
        alternateSources,
        // 书籍变量里的 `custom`（Legado 的 `putCustomVariable`）：有声书用它切换朗读者/音色。
        // 始终提交当前值 —— "清空输入框"本身就是一个有意义的操作（下次用默认音色）。
        customVariable,
      })
      toast.success(t('shelf.bookInfoUpdated', '《{{name}}》信息已更新', { name: updated.name }))
      onSaved(updated)
      onClose()
    } catch (err) {
      setError(err instanceof Error ? err.message : t('shelf.bookInfoUpdateFailed', '更新书籍信息失败'))
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="modal-backdrop top-layer-modal-backdrop" onClick={onClose}>
      <div
        className="book-info-edit-modal"
        onClick={e => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label={t('shelf.editBookWithTitle', '编辑书籍信息: {{name}}', { name: item.name })}
      >
        <header className="book-info-edit-header">
          <div>
            <span className="section-kicker">{t('shelf.bookDetail', '书籍信息')}</span>
            <h2>{t('shelf.editBookInfo', '编辑书籍信息')}</h2>
          </div>
          <button className="subtle-button close-btn" onClick={onClose} aria-label={t('common.close', '关闭')}>
            <Icon name="close" />
          </button>
        </header>

        <form onSubmit={handleSave} className="book-info-edit-form">
          <div className="book-info-edit-body">
            {/* Online Search Completion Trigger & Panel */}
            <div className="meta-search-container">
              <div className="meta-search-header-row">
                <button
                  type="button"
                  className={`meta-search-toggle-btn ${searchOpen ? 'active' : ''}`}
                  onClick={() => {
                    const next = !searchOpen
                    setSearchOpen(next)
                    if (next && searchResults.length === 0 && !searching) {
                      handleStartSearch(searchKeyword || name)
                    }
                  }}
                >
                  <Icon name="search" />
                  <span>{searchOpen ? t('shelf.collapseMetaSearch', '收起联网搜索补全') : t('shelf.expandMetaSearch', '联网搜索补全信息')}</span>
                  {item.sourceId === 'loc_book' && (!item.author || candidateCovers.length === 0) && (
                    <span className="meta-search-badge">{t('common.recommended', '推荐')}</span>
                  )}
                </button>
                {searchOpen && searching && (
                  <span className="meta-search-status-inline">
                    <Icon name="refresh" className="spin" />
                    <span>{t('shelf.searchingSources', '检索书源中...')}</span>
                  </span>
                )}
              </div>

              {searchOpen && (
                <div className="meta-search-panel">
                  <div className="meta-search-bar">
                    <div className="input-with-icon meta-search-input-wrap">
                      <Icon name="search" />
                      <input
                        type="text"
                        placeholder={t('shelf.metaSearchPlaceholder', '输入小说名称搜索网络书源...')}
                        value={searchKeyword}
                        onChange={e => setSearchKeyword(e.target.value)}
                        onKeyDown={e => {
                          if (e.key === 'Enter') {
                            e.preventDefault()
                            handleStartSearch()
                          }
                        }}
                      />
                    </div>
                    {searching ? (
                      <button
                        type="button"
                        className="subtle-button meta-search-btn stop-btn is-loading"
                        onClick={stopSearch}
                        aria-busy="true"
                      >
                        <ButtonSpinner size={12} />
                        <span>{t('common.pause', '停止')}</span>
                      </button>
                    ) : (
                      <button
                        type="button"
                        className="primary-button meta-search-btn"
                        onClick={() => handleStartSearch()}
                      >
                        <Icon name="search" />
                        <span>{t('common.search', '搜索')}</span>
                      </button>
                    )}
                  </div>

                  {/* Progress / Status */}
                  {searchProgress && (
                    <div className="meta-search-progress-bar">
                      <div className="meta-search-progress-text">
                        <span>
                          {t('shelf.metaSearchProgress', '已检索 {{completed}}/{{total}} 个书源{{matchedText}}', {
                            completed: searchProgress.completedSources,
                            total: searchProgress.totalSources,
                            matchedText: searchProgress.matchedSources > 0 ? t('shelf.metaSearchMatched', ' · 命中 {{count}} 个', { count: searchProgress.matchedSources }) : '',
                          })}
                        </span>
                        <span className="meta-search-count-pill">
                          {t('shelf.metaSearchResultsCount', '共 {{count}} 条结果', { count: searchResults.length })}
                        </span>
                      </div>
                      <div className="meta-progress-track">
                        <div
                          className="meta-progress-fill"
                          style={{
                            width: `${searchProgress.totalSources > 0 ? (searchProgress.completedSources / searchProgress.totalSources) * 100 : 0}%`,
                          }}
                        />
                      </div>
                    </div>
                  )}

                  {searchError && (
                    <div className="meta-search-error-msg">{searchError}</div>
                  )}

                  {/* Results List */}
                  {searchResults.length > 0 ? (
                    <div className="meta-search-results-list">
                      {searchResults.map((cand, idx) => {
                        const candCover = sanitizeImageUrl(cand.coverUrl)
                        const isChosen = (coverUrl === cand.coverUrl) && (author === cand.author)
                        return (
                          <div key={`${cand.sourceId}_${cand.bookUrl}_${idx}`} className={`meta-search-card ${isChosen ? 'chosen' : ''}`}>
                            <div className="meta-search-card-cover">
                              {candCover ? (
                                <img src={candCover} alt={t('shelf.coverPreview', '封面')} referrerPolicy="no-referrer" />
                              ) : (
                                <div className="meta-cover-fallback">
                                  <span>{cand.name.slice(0, 1) || t('common.bookChar', '书')}</span>
                                </div>
                              )}
                            </div>
                            <div className="meta-search-card-info">
                              <div className="meta-search-card-title-row">
                                <strong className="meta-search-card-name" title={cand.name}>{cand.name}</strong>
                                <span className="meta-search-card-source">{cand.sourceId}</span>
                              </div>
                              <div className="meta-search-card-author">
                                {t('shelf.author', '作者')}：<span>{cand.author || t('common.unknownAuthor', '未知作者')}</span>
                              </div>
                              {cand.intro && (
                                <p className="meta-search-card-intro" title={cand.intro}>
                                  {cand.intro}
                                </p>
                              )}
                            </div>
                            <div className="meta-search-card-action">
                              <button
                                type="button"
                                className={`subtle-button meta-apply-btn ${isChosen ? 'applied' : ''}`}
                                onClick={() => handleApplyCandidate(cand)}
                                title={t('shelf.applyCandidateTitle', '采用此候选的封面和作者')}
                              >
                                <Icon name={isChosen ? 'check' : 'plus'} />
                                <span>{isChosen ? t('shelf.appliedCandidate', '已选用') : t('shelf.applyCandidate', '选用')}</span>
                              </button>
                            </div>
                          </div>
                        )
                      })}
                    </div>
                  ) : !searching && searchProgress?.completedSources ? (
                    <div className="meta-search-empty-tip">
                      {t('shelf.metaSearchEmpty', '未检索到匹配结果，可尝试修改搜索关键词后再次检索')}
                    </div>
                  ) : null}
                </div>
              )}
            </div>
            {/* Cover Preview & Options */}
            <div className="edit-cover-section">
              <div className="edit-cover-preview-box">
                {previewSrc && sanitizeImageUrl(previewSrc) ? (
                  <img src={sanitizeImageUrl(previewSrc)!} alt={t('shelf.coverPreview', '封面预览')} referrerPolicy="no-referrer" />
                ) : (
                  <div className="edit-cover-fallback">
                    <span>{name.trim().slice(0, 1) || t('common.bookChar', '书')}</span>
                  </div>
                )}
                {(uploadedCoverKey || (coverUrl !== '' && (item.coverKey || coverUrl))) && (
                  <button
                    type="button"
                    className="subtle-button clear-cover-btn"
                    onClick={() => {
                      setUploadedCoverKey(null)
                      setCoverUrl('')
                    }}
                    title={t('shelf.clearCover', '清除并使用文字占位封面')}
                  >
                    {t('shelf.clearCover', '清除封面')}
                  </button>
                )}
                {(uploadedCoverKey !== null || coverUrl === '') && (
                  <button
                    type="button"
                    className="subtle-button reset-cover-btn"
                    onClick={() => {
                      setUploadedCoverKey(null)
                      setCoverUrl(null)
                    }}
                    title={t('shelf.restoreCover', '恢复原封面')}
                  >
                    {t('shelf.restoreCover', '恢复原封面')}
                  </button>
                )}
              </div>

              <div className="edit-cover-inputs">
                <div className="edit-cover-upload-row">
                  <input
                    type="file"
                    ref={fileInputRef}
                    style={{ display: 'none' }}
                    accept="image/jpeg,image/png,image/webp,image/gif,image/bmp,.jpg,.jpeg,.png,.webp,.gif,.bmp"
                    onChange={handleUploadCover}
                  />
                  <button
                    type="button"
                    className={`secondary-button upload-cover-btn ${uploadingCover ? 'is-loading' : ''}`}
                    disabled={uploadingCover}
                    aria-busy={uploadingCover}
                    onClick={() => fileInputRef.current?.click()}
                    title={t('shelf.coverFileLimitHint', '支持 JPG、PNG、WebP、GIF、BMP 格式，最大 5MB')}
                  >
                    {uploadingCover ? <ButtonSpinner size={12} /> : <Icon name="upload" />}
                    <span>{uploadingCover ? t('shelf.uploadingCover', '正在上传封面...') : t('shelf.uploadCover', '上传本地封面')}</span>
                  </button>
                  <span className="upload-cover-hint">{t('shelf.coverFileLimitHint', '支持 JPG、PNG、WebP、GIF、BMP 格式，最大 5MB')}</span>
                </div>

                <label className="edit-form-label">
                  <span>{t('shelf.coverUrl', '封面图片 URL')}</span>
                  <div className="input-with-icon">
                    <Icon name="image" />
                    <input
                      type="url"
                      placeholder="https://example.com/cover.jpg"
                      value={coverUrl === null ? '' : coverUrl}
                      onChange={e => {
                        setUploadedCoverKey(null)
                        setCoverUrl(e.target.value)
                      }}
                    />
                  </div>
                  <small>{t('shelf.coverUrlHint', '可粘贴图片网络地址，保存时将自动拉取并缓存到服务器')}</small>
                </label>

                {candidateCovers.length > 0 && (
                  <div className="candidate-covers-picker">
                    <span className="candidate-covers-title">{t('shelf.chooseCoverFromCandidates', '从备选书源选择封面 ({{count}})：', { count: candidateCovers.length })}</span>
                    <div className="candidate-covers-grid">
                      {candidateCovers.map(c => {
                        const isSelected = !uploadedCoverKey && coverUrl === c.coverUrl
                        return (
                          <button
                            key={c.coverUrl}
                            type="button"
                            className={`candidate-cover-card ${isSelected ? 'selected' : ''}`}
                            onClick={() => {
                              setUploadedCoverKey(null)
                              setCoverUrl(c.coverUrl)
                            }}
                            title={t('shelf.useSourceCoverTitle', '使用来自【{{source}}】的封面', { source: c.sourceId })}
                          >
                            {sanitizeImageUrl(c.coverUrl) ? (
                              <img src={sanitizeImageUrl(c.coverUrl)!} alt={c.sourceId} referrerPolicy="no-referrer" />
                            ) : (
                              <div className="candidate-cover-fallback">
                                <span>{(c.sourceId || t('common.bookChar', '书')).slice(0, 1)}</span>
                              </div>
                            )}
                            <small>{c.sourceId}</small>
                          </button>
                        )
                      })}
                    </div>
                  </div>
                )}
              </div>
            </div>

            {/* Title & Author & Group Fields */}
            <div className="edit-fields-section">
              <label className="edit-form-label">
                <span>{t('shelf.bookTitle', '书名')} <span className="required-mark">*</span></span>
                <input
                  type="text"
                  required
                  value={name}
                  onChange={e => setName(e.target.value)}
                  placeholder={t('shelf.bookTitleRequired', '请输入书名')}
                />
              </label>

              <label className="edit-form-label">
                <span>{t('shelf.author', '作者')}</span>
                <input
                  type="text"
                  value={author}
                  onChange={e => setAuthor(e.target.value)}
                  placeholder={t('shelf.authorOptional', '作者（可选）')}
                />
              </label>

              <label className="edit-form-label">
                <span>{t('shelf.group', '所属分组')}</span>
                <select
                  value={groupName || ''}
                  onChange={e => setGroupName(e.target.value || undefined)}
                  className="edit-select-input"
                >
                  <option value="">({t('search.scopeUngrouped', '未分组')})</option>
                  {groups.map(g => (
                    <option key={g.id} value={g.name}>{g.name}</option>
                  ))}
                </select>
              </label>

              {/* 书籍变量：对齐开源阅读的编辑形态（`legado-with-MD3` 的 VariableEditorSheet）——
                  一个输入框编辑 `custom` 键 + 下方给出用法提示，而不是键值对列表。
                  有声书的"切换朗读者"就是改这个值；书籍变量会随规则执行注入 `book` 对象。 */}
              <label className="edit-form-label">
                <span>{t('shelf.bookVariable', '书籍变量')}</span>
                <input
                  type="text"
                  value={customVariable}
                  onChange={e => setCustomVariable(e.target.value)}
                  placeholder={t('shelf.bookVariablePlaceholder', '如音色编号：3')}
                />
                <small className="edit-form-hint">
                  {t('shelf.bookVariableHint', '书源规则通过 book.getVariable("custom") 读取本值；听书填书籍详情里显示的可用音色编号即可切换朗读者，留空用默认音色')}
                </small>
              </label>
            </div>

            {error && <p className="form-error">{error}</p>}
          </div>

          <footer className="book-info-edit-footer">
            <button type="button" className="subtle-button" onClick={onClose} disabled={saving}>
              {t('common.cancel', '取消')}
            </button>
            <button type="submit" className={`primary-button ${saving ? 'is-loading' : ''}`} disabled={saving} aria-busy={saving}>
              {saving && <ButtonSpinner size={14} />}
              {saving ? t('common.saving', '保存中...') : t('common.saveChanges', '保存修改')}
            </button>
          </footer>
        </form>
      </div>
    </div>
  )
}

function BookManageModal({
  item,
  groups,
  onClose,
  onOpenDetail,
  onExport,
  onSwitchSource,
  onCache,
  onCancelCache,
  onSetCanUpdate,
  updateSettingBusy,
  onToggleCompleted,
  onUpdateInfo,
  onClearCache,
  onRemove,
}: {
  item: BookshelfItem
  groups: BookGroup[]
  onClose: () => void
  onOpenDetail: () => void
  onExport: () => void
  onSwitchSource: () => void
  onCache: (chapterConcurrency?: number) => Promise<boolean>
  onCancelCache: () => void
  onSetCanUpdate: (canUpdate: boolean) => Promise<void>
  updateSettingBusy: boolean
  onToggleCompleted: () => void
  onUpdateInfo: (updated: BookshelfItem) => void
  onClearCache: () => void
  onRemove: () => void
}) {
  const { t } = useTranslation()
  const [editingInfo, setEditingInfo] = useState(false)
  const [recleaning, setRecleaning] = useState(false)
  const [reparsing, setReparsing] = useState(false)
  const [cacheConcurrencyOpen, setCacheConcurrencyOpen] = useState(false)
  const [cacheStarting, setCacheStarting] = useState(false)
  const [ignoringEmptyChapter, setIgnoringEmptyChapter] = useState(false)
  const isCaching = item.cacheState === 'caching'
  const isReady = item.cacheState === 'ready'
  const isFailed = item.cacheState === 'failed'
  const hasEmptyContentFailure = isFailed && Boolean(item.cacheError?.includes('正文规则未提取到内容'))
  const percent = Math.min(100, Math.round((item.cachedChapters / Math.max(1, item.totalChapters || 1)) * 100))

  // ESC ≡ 点遮罩 ≡ 关闭一级（回书架）。二级有自己的 ESC（只退一级），
  // 而两级**互斥挂载**，所以永远不会出现"一次 ESC 连退两级"。
  // 编辑子页（BookInfoEditModal）自己管自己，这里不抢它的 ESC。
  useEffect(() => {
    if (editingInfo || cacheConcurrencyOpen) return
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [cacheConcurrencyOpen, editingInfo, onClose])

  if (editingInfo) {
    return (
      <BookInfoEditModal
        item={item}
        groups={groups}
        onSaved={updated => {
          onUpdateInfo(updated)
          setEditingInfo(false)
        }}
        onClose={() => setEditingInfo(false)}
      />
    )
  }

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="book-manage-sheet" onClick={e => e.stopPropagation()} role="dialog" aria-modal="true" aria-label={t('shelf.bookManageWithTitle', '书籍管理: {{name}}', { name: item.name })}>
        <header className="manage-sheet-header">
          <div className="manage-sheet-cover">
            <BookCover coverKey={item.coverKey} coverUrl={item.coverUrl} name={item.name} />
          </div>
          <div className="manage-sheet-info">
            <h3>{item.name}</h3>
            <p>{item.author || t('common.unknownAuthor', '未知作者')}</p>
            <small>
              {item.isReadFinished
                ? t('shelf.statusRead', '已读')
                : item.isReading
                  ? t('shelf.readingProgress', '读至：{{chapter}}', { chapter: t('shelf.chapterAt', '第 {{count}} 章', { count: (item.chapterIndex ?? 0) + 1 }) })
                  : item.isUnread
                    ? t('shelf.statusUnread', '未读')
                    : item.completed
                      ? t('shelf.completed', '已读完')
                      : item.chapterIndex === undefined
                        ? t('shelf.justAdded', '刚加入书架')
                        : t('shelf.readingProgress', '读至：{{chapter}}', { chapter: t('shelf.chapterAt', '第 {{count}} 章', { count: item.chapterIndex + 1 }) })}
            </small>
            {item.updateError && (
              <small className="manage-update-error">{t('shelf.lastRefreshFailed', '上次目录刷新失败，已保留原目录')}</small>
            )}
          </div>
          <button className="subtle-button close-btn" onClick={onClose} aria-label={t('common.close', '关闭')}><Icon name="close" /></button>
        </header>

        <div className="manage-sheet-actions">
          {/* Quick Group Selector */}
          <div className="manage-group-row">
            <div className="action-icon"><Icon name="bookmark" /></div>
            <div className="action-text">
              <strong>{t('shelf.group', '所属分组')}</strong>
              <small>{t('shelf.currentGroup', '当前：{{group}}', { group: item.groupName || t('search.scopeUngrouped', '未分组') })}</small>
            </div>
            <select
              value={item.groupName || ''}
              onChange={async (e) => {
                const newGroup = e.target.value || null
                try {
                  const updated = await api.updateBookGroup(item.sourceId, item.bookUrl, newGroup)
                  onUpdateInfo(updated)
                  toast.success(newGroup ? t('shelf.movedToGroup', '已移入「{{group}}」分组', { group: newGroup }) : t('shelf.movedToUngrouped', '已移入「未分组」'))
                } catch (err) {
                  toast.error(err instanceof Error ? err.message : t('shelf.updateGroupFailed', '更新分组失败'))
                }
              }}
              className="manage-group-select"
              aria-label={t('shelf.modifyGroup', '修改所属分组')}
            >
              <option value="">{t('search.scopeUngrouped', '未分组')}</option>
              {groups.map(g => (
                <option key={g.id} value={g.name}>{g.name}</option>
              ))}
            </select>
          </div>

          {!isLocalBook(item) && (
            <button
              type="button"
              className={`manage-action-row ${updateSettingBusy ? 'is-loading' : ''}`}
              disabled={updateSettingBusy}
              aria-busy={updateSettingBusy}
              onClick={() => void onSetCanUpdate(!item.canUpdate)}
            >
              <div className="action-icon"><Icon name={item.canUpdate === false ? 'refresh' : 'stop'} /></div>
              <div className="action-text">
                <strong>{item.canUpdate === false ? t('shelf.resumeUpdates', '恢复目录更新') : t('shelf.pauseUpdates', '停止目录更新')}</strong>
                <small>{item.canUpdate === false
                  ? t('shelf.resumeUpdatesDesc', '允许这本书重新参与书架目录刷新')
                  : t('shelf.pauseUpdatesDesc', '刷新书架时跳过这本书，阅读进度和缓存不受影响')}
                </small>
              </div>
              {updateSettingBusy ? <ButtonSpinner size={14} /> : <Icon name="arrowRight" />}
            </button>
          )}

          <button className="manage-action-row" onClick={() => { onClose(); onOpenDetail() }}>
            <div className="action-icon"><Icon name="file" /></div>
            <div className="action-text">
              <strong>{t('shelf.viewDetails', '查看书籍详情')}</strong>
              <small>阅读进度、缓存状态、简介与更新情况</small>
            </div>
            <Icon name="arrowRight" />
          </button>

          <button className="manage-action-row" onClick={() => setEditingInfo(true)}>
            <div className="action-icon"><Icon name="edit" /></div>
            <div className="action-text">
              <strong>{t('shelf.editBookInfo', '编辑书籍信息')}</strong>
              <small>{t('shelf.editBookInfoDesc', '修改书名、作者或更换封面')}</small>
            </div>
            <Icon name="arrowRight" />
          </button>

          <button className="manage-action-row" onClick={onExport}>
            <div className="action-icon"><Icon name="download" /></div>
            <div className="action-text">
              <strong>导出与推送到 Kindle</strong>
              <small>导出 TXT / EPUB，EPUB 可直接推送到已配对设备</small>
            </div>
            <Icon name="arrowRight" />
          </button>

          {!isLocalBook(item) && (
            <button className="manage-action-row" onClick={() => { onClose(); onSwitchSource() }}>
              <div className="action-icon"><Icon name="sliders" /></div>
              <div className="action-text">
                <strong>{t('source.switchSourceTitle', '切换书源')}</strong>
                <small>{item.alternateSources?.length ? t('shelf.switchSourceDescWithCount', '已有 {{count}} 个备选书源，可全网检索', { count: item.alternateSources.length }) : t('shelf.switchSourceDesc', '在其他书源中搜索匹配并无缝替换')}</small>
              </div>
              <Icon name="arrowRight" />
            </button>
          )}

          {/* 「离线缓存全本 / 重新缓存 / 重试离线缓存」对本地书**整段不渲染**（issue #66 用户原话：
              「缓存按钮也不该有」）。原因是本地书正文就是用户上传文件解析后落库的那份，
              没有"抓取"这一步 —— 摆一个永远无事可做的缓存按钮只会误导。 */}
          {!isLocalBook(item) && (
            isCaching ? (
              <div className="manage-cache-box">
                <div className="manage-cache-info-row">
                  <div className="action-icon"><Icon name="download" /></div>
                  <div className="action-text">
                    <strong>{t('shelf.cachingAll', '正在离线缓存全本')}</strong>
                    <small>{percent}% ({item.cachedChapters} / {item.totalChapters || '?'}) {t('reader.cacheCustomUnit', '章')}</small>
                  </div>
                  <button className="subtle-button cancel-cache-link" onClick={onCancelCache}>{t('shelf.cancelCacheLink', '取消缓存')}</button>
                </div>
                <div className="manage-cache-bar-track">
                  <div className="manage-cache-bar-fill" style={{ width: `${percent}%` }} />
                </div>
              </div>
            ) : (
              <button
                className="manage-action-row"
                onClick={() => {
                  if ((item.bookKind ?? 'novel') === 'novel') setCacheConcurrencyOpen(true)
                  else void onCache()
                }}
              >
                <div className="action-icon"><Icon name="download" /></div>
                <div className="action-text">
                  <strong>{isReady ? t('shelf.recacheOrVerify', '重新缓存 / 校验全本') : isFailed ? t('shelf.retryCache', '重试离线缓存') : t('shelf.cacheAllTitle', '离线缓存全本')}</strong>
                  <small>{isReady ? t('shelf.cacheAllDescReady', '已离线缓存 {{count}} 章 ✓', { count: item.cachedChapters }) : isFailed ? (item.cacheError || t('shelf.cacheAllDescFailed', '部分章节未缓存，点击重试')) : t('shelf.cacheAllDescIdle', '预先下载全书正文以供离线阅读')}</small>
                </div>
                <Icon name="arrowRight" />
              </button>
            )
          )}

          {!isLocalBook(item) && hasEmptyContentFailure && (
            <button
              className={`manage-action-row ${ignoringEmptyChapter ? 'is-loading' : ''}`}
              disabled={ignoringEmptyChapter}
              aria-busy={ignoringEmptyChapter}
              onClick={async () => {
                if (!window.confirm(t(
                  'shelf.ignoreEmptyChapterConfirm',
                  '已确认该章在书源页面中确实没有正文吗？确认后会将该失败章标记为空卷标题，不再抓取正文；EPUB 中保留为卷标题，Kindle 上架中不作为可读章节，并重新校验全书。',
                ))) return
                setIgnoringEmptyChapter(true)
                try {
                  const result = await api.ignoreFailedEmptyChapter(item.sourceId, item.bookUrl)
                  toast.success(t(
                    'shelf.ignoreEmptyChapterSuccess',
                    '已将「{{title}}」标记为空卷，正在重新校验全书缓存',
                    { title: result.title },
                  ))
                  onUpdateInfo({ ...item, cacheState: 'caching', cacheError: undefined })
                  onClose()
                } catch (err) {
                  toast.error(err instanceof Error ? err.message : t(
                    'shelf.ignoreEmptyChapterFailed',
                    '标记空卷失败',
                  ))
                } finally {
                  setIgnoringEmptyChapter(false)
                }
              }}
            >
              <div className="action-icon"><Icon name="volume2" /></div>
              <div className="action-text">
                <strong>{ignoringEmptyChapter
                  ? t('shelf.ignoreEmptyChapterBusy', '正在标记并重新校验...')
                  : t('shelf.ignoreEmptyChapter', '将失败空章标记为空卷')}</strong>
                <small>{t(
                  'shelf.ignoreEmptyChapterDesc',
                  '仅用于书源页面明确显示 0 字的卷分隔页；普通章节不会被自动忽略',
                )}</small>
              </div>
              {ignoringEmptyChapter ? <ButtonSpinner size={14} /> : <Icon name="arrowRight" />}
            </button>
          )}

          <button
            className={`manage-action-row ${recleaning ? 'is-loading' : ''}`}
            disabled={recleaning}
            aria-busy={recleaning}
            onClick={async () => {
              setRecleaning(true)
              try {
                const res = await api.recleanBookCache(item.sourceId, item.bookUrl)
                if (res.recleanedChapters > 0) {
                  toast.success(t('shelf.recleanSuccess', '《{{name}}》重新清洗完成，共处理 {{count}} 章', { name: item.name, count: res.recleanedChapters }))
                } else {
                  toast.info(t('shelf.recleanNoChapters', '《{{name}}》暂无已缓存章节', { name: item.name }))
                }
              } catch (err) {
                toast.error(err instanceof Error ? err.message : t('shelf.recleanFailed', '重新清洗失败'))
              } finally {
                setRecleaning(false)
              }
            }}
          >
            <div className="action-icon"><Icon name="sliders" /></div>
            <div className="action-text">
              <strong>{recleaning ? t('shelf.recleaningDesc', '正在重新清洗正文...') : t('shelf.recleanRules', '重新应用净化规则')}</strong>
              <small>{t('shelf.recleanRulesDesc', '基于原文副本重新运行当前启用的替换规则')}</small>
            </div>
            {recleaning ? <ButtonSpinner size={14} /> : <Icon name="arrowRight" />}
          </button>

          {/* 本地书专用：解析器缺陷修复之后，老书需要按留存的原文件重新解析才能拿到分段正文。
              线上书源的书走不到这里（它们的正文是即时抓取的，不涉及解析器版本）。 */}
          {isLocalBook(item) && (
            <button
              className={`manage-action-row ${reparsing ? 'is-loading' : ''}`}
              disabled={reparsing}
              aria-busy={reparsing}
              onClick={async () => {
                setReparsing(true)
                try {
                  const res = await api.reparseLocalBooks({ sourceId: item.sourceId, bookUrl: item.bookUrl })
                  if (res.reparsed > 0) {
                    toast.success(t('shelf.reparseLocalSuccess', '《{{name}}》已重新解析，共 {{count}} 章', { name: item.name, count: res.chapters }))
                    // 复用既有回调：让书架列表重新拉一次服务端状态
                    onUpdateInfo(item)
                  } else {
                    toast.info(res.items[0]?.error ?? t('shelf.reparseLocalSkipped', '《{{name}}》无需重新解析', { name: item.name }))
                  }
                } catch (err) {
                  toast.error(err instanceof Error ? err.message : t('shelf.reparseLocalFailed', '重新解析失败'))
                } finally {
                  setReparsing(false)
                }
              }}
            >
              <div className="action-icon"><Icon name="refresh" /></div>
              <div className="action-text">
                <strong>{reparsing ? t('shelf.reparsingDesc', '正在重新解析本地文件...') : t('shelf.reparseLocalRules', '重新解析本地文件')}</strong>
                <small>{t('shelf.reparseLocalRulesDesc', '按留存的 TXT / EPUB 原文件重建目录与正文，阅读进度保留')}</small>
              </div>
              {reparsing ? <ButtonSpinner size={14} /> : <Icon name="arrowRight" />}
            </button>
          )}

          <button className="manage-action-row" onClick={() => { onClose(); onToggleCompleted() }}>
            <div className="action-icon"><Icon name="check" /></div>
            <div className="action-text">
              <strong>{item.completed ? t('shelf.markAsReading', '恢复为正在阅读') : t('shelf.markAsCompleted', '标记为已读完')}</strong>
              <small>{item.completed ? t('shelf.markAsReadingDesc', '状态恢复为正在阅读') : t('shelf.markAsCompletedDesc', '状态标记为已读完')}</small>
            </div>
            <Icon name="arrowRight" />
          </button>

          {/* 「清除缓存」与「移出书架」同为**危险动作**（都不可逆、都要重新联网下载），
              因此共用 danger 红色配色；但语义严格区分：本行只回收磁盘，书还在书架上、
              进度与封面都不动。
              本地书（issue #66 用户原话：「本地书根本不要有清除缓存的按钮」）**整行不渲染**：
              它的正文只能从留存的原文件重新解析得到，不存在"清掉再下载"这条路径。 */}
          {!isLocalBook(item) && (
            <button className="manage-action-row danger" onClick={() => onClearCache()}>
              <div className="action-icon"><Icon name="trash" /></div>
              <div className="action-text">
                <strong>{t('shelf.clearCache', '清除缓存')}</strong>
                <small>{t('shelf.clearCacheDesc', '清除本书已下载的图片、音频与正文缓存（含本机离线）')}</small>
              </div>
              <Icon name="arrowRight" />
            </button>
          )}

          <button className="manage-action-row danger" onClick={() => { onClose(); onRemove() }}>
            <div className="action-icon"><Icon name="close" /></div>
            <div className="action-text">
              <strong>{t('shelf.removeFromShelf', '移出书架')}</strong>
              <small>{t('shelf.removeFromShelfDesc', '清除阅读进度与离线缓存')}</small>
            </div>
            <Icon name="arrowRight" />
          </button>
        </div>
        {cacheConcurrencyOpen && (
          <CacheConcurrencyDialog
            bookName={item.name}
            busy={cacheStarting}
            onCancel={() => setCacheConcurrencyOpen(false)}
            onConfirm={chapterConcurrency => {
              setCacheStarting(true)
              void onCache(chapterConcurrency)
                .then(success => {
                  if (success) setCacheConcurrencyOpen(false)
                })
                .finally(() => setCacheStarting(false))
            }}
          />
        )}
      </div>
    </div>
  )
}

/**
 * 「清除缓存」的范围选择弹窗：**服务器 / 浏览器 / 两者**三选一。
 *
 * 用户原话：「删除时添加新弹窗三个选项，清除服务器缓存，清除浏览器缓存，清理服务器和浏览器缓存」
 * 「并且也都是红色配色」⇒ 三个选项一律 `manage-action-row danger`（红色与「移出书架」同源，
 * 都来自 `.manage-action-row.danger { color: var(--danger) }`），**取消**用中性 `manage-action-row`。
 *
 * 为什么用弹窗而不是 `confirm()`：原生 confirm 只能"确定/取消"，表达不了三种范围。
 *
 * 样式铁律（AGENTS.md）：① 浮层用 `createPortal(..., document.body)` 逃出带 `backdrop-filter`
 * 的包含块，并**显式**绑 `theme-${theme}` —— 否则脱离 `.app-shell` 后主题变量回退，夜间模式下
 * 会出现透光背景 + 隐形黑字；② 本弹窗由书架页按**互斥层级**挂载（此时一级「书籍管理」不渲染，
 * 但它的书由状态机保留）⇒ 一层 backdrop，杜绝"带动画的 `modal-backdrop` 里再嵌一层"；
 * ③ 所有按钮显式 `type="button"`。
 *
 * 关闭语义（issue #66）：取消 / ESC / 点遮罩三者**完全等价** —— 都只调 `onClose`，
 * 由父级把它解释成「退回一级书籍管理」，不做任何清理；清理执行完也走同一个转移。
 */
function ClearCacheScopeModal({
  item,
  theme,
  busy,
  busyScope,
  onPick,
  onClose,
}: {
  item: BookshelfItem
  theme: ReaderTheme
  busy: boolean
  busyScope?: ClearCacheScope | null
  onPick: (scope: ClearCacheScope) => void
  onClose: () => void
}) {
  const { t } = useTranslation()

  // ESC ≡ 取消（清理中忽略，避免把正在跑的清理"关掉"造成误解）
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !busy) onClose()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [busy, onClose])

  return createPortal(
    <div className={`modal-backdrop top-layer-modal-backdrop theme-${theme}`} onClick={busy ? undefined : onClose}>
      <div
        className="book-manage-sheet"
        onClick={event => event.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label={t('shelf.clearCacheTitle', '清除缓存')}
      >
        <header className="manage-sheet-header">
          <div className="manage-sheet-cover">
            <BookCover coverKey={item.coverKey} coverUrl={item.coverUrl} name={item.name} />
          </div>
          <div className="manage-sheet-info">
            <h3>{item.name}</h3>
            <p>{t('shelf.clearCacheTitle', '清除缓存')}</p>
            <small>{t('shelf.clearCacheHint', '将清除《{{name}}》已下载的缓存；阅读进度、书架记录与封面不受影响，请选择清除范围。', { name: item.name })}</small>
          </div>
          <button type="button" className="subtle-button close-btn" disabled={busy} onClick={onClose} aria-label={t('common.close', '关闭')}><Icon name="close" /></button>
        </header>

        <div className="manage-sheet-actions">
          {/* 三个选项一律 danger（红色与「移出书架」同源），互斥三选一 */}
          <button type="button" className="manage-action-row danger" disabled={busy} aria-busy={busyScope === 'server'} onClick={() => onPick('server')}>
            <div className="action-icon"><Icon name="cloudDownload" /></div>
            <div className="action-text">
              <strong>{t('shelf.clearCacheServer', '清除服务器缓存')}</strong>
              <small>{isLocalBook(item) ? t('shelf.clearCacheServerLocalDesc', '本地书正文由原文件解析而来，清除缓存不会删除原文件') : t('shelf.clearCacheServerDesc', '清掉服务端已下载的正文与插图，下次阅读会重新获取')}</small>
            </div>
            {busyScope === 'server' ? <ButtonSpinner size={14} /> : <Icon name="arrowRight" />}
          </button>

          <button type="button" className="manage-action-row danger" disabled={busy} aria-busy={busyScope === 'browser'} onClick={() => onPick('browser')}>
            <div className="action-icon"><Icon name="download" /></div>
            <div className="action-text">
              <strong>{t('shelf.clearCacheBrowser', '清除浏览器缓存')}</strong>
              <small>{t('shelf.clearCacheBrowserDesc', '只清本机已下载的离线正文，不影响服务端')}</small>
            </div>
            {busyScope === 'browser' ? <ButtonSpinner size={14} /> : <Icon name="arrowRight" />}
          </button>

          <button type="button" className="manage-action-row danger" disabled={busy} aria-busy={busyScope === 'both'} onClick={() => onPick('both')}>
            <div className="action-icon"><Icon name="trash" /></div>
            <div className="action-text">
              <strong>{t('shelf.clearCacheBoth', '清理服务器和浏览器缓存')}</strong>
              <small>{t('shelf.clearCacheBothDesc', '一次清干净：服务端与本机一起清')}</small>
            </div>
            {busyScope === 'both' ? <ButtonSpinner size={14} /> : <Icon name="arrowRight" />}
          </button>

          {/* 取消：中性色（**不**加 danger），点了什么都不做，只关弹窗 */}
          <button type="button" className="manage-action-row" disabled={busy} onClick={onClose}>
            <div className="action-icon"><Icon name="close" /></div>
            <div className="action-text">
              <strong>{t('shelf.clearCacheCancel', '取消')}</strong>
              <small>{t('shelf.clearCacheCancelDesc', '不做任何清理，返回书籍管理')}</small>
            </div>
            <Icon name="arrowRight" />
          </button>
        </div>
      </div>
    </div>,
    document.body,
  )
}

function GroupManageModal({
  groups,
  onClose,
  onGroupsChanged,
}: {
  groups: BookGroup[]
  onClose: () => void
  onGroupsChanged: () => Promise<void>
}) {
  const { t } = useTranslation()
  const [newGroupName, setNewGroupName] = useState('')
  const [adding, setAdding] = useState(false)
  const [editingId, setEditingId] = useState<number | null>(null)
  const [editingName, setEditingName] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const handleAddGroup = async (e: FormEvent) => {
    e.preventDefault()
    const trimmed = newGroupName.trim()
    if (!trimmed) return
    setAdding(true)
    setError('')
    try {
      await api.createBookGroup(trimmed)
      setNewGroupName('')
      await onGroupsChanged()
      toast.success(t('shelf.groupCreated', '分组「{{name}}」创建成功', { name: trimmed }))
    } catch (err) {
      setError(err instanceof Error ? err.message : t('shelf.createGroupFailed', '创建分组失败'))
    } finally {
      setAdding(false)
    }
  }

  const handleRename = async (group: BookGroup) => {
    const trimmed = editingName.trim()
    if (!trimmed || trimmed === group.name) {
      setEditingId(null)
      return
    }
    setBusy(true)
    setError('')
    try {
      await api.renameBookGroup(group.name, trimmed)
      setEditingId(null)
      await onGroupsChanged()
      toast.success(t('shelf.groupRenamed', '分组已重命名为「{{name}}」', { name: trimmed }))
    } catch (err) {
      setError(err instanceof Error ? err.message : t('shelf.renameGroupFailed', '重命名失败'))
    } finally {
      setBusy(false)
    }
  }

  const handleDelete = async (group: BookGroup) => {
    const confirmMsg = group.bookCount > 0
      ? t('shelf.deleteGroupConfirmWithCount', '确定删除分组「{{name}}」吗？组内 {{count}} 本书籍将自动归入“未分组”，书籍不会被删除。', { name: group.name, count: group.bookCount })
      : t('shelf.deleteGroupConfirm', '确定删除分组「{{name}}」吗？', { name: group.name })
    if (!confirm(confirmMsg)) return
    setBusy(true)
    setError('')
    try {
      await api.deleteBookGroup(group.name)
      await onGroupsChanged()
      toast.info(t('shelf.groupDeleted', '已删除分组「{{name}}」', { name: group.name }))
    } catch (err) {
      setError(err instanceof Error ? err.message : t('shelf.deleteGroupFailed', '删除失败'))
    } finally {
      setBusy(false)
    }
  }

  const handleMove = async (index: number, direction: 'up' | 'down') => {
    const targetIndex = direction === 'up' ? index - 1 : index + 1
    if (targetIndex < 0 || targetIndex >= groups.length) return
    const reordered = [...groups]
    const temp = reordered[index]
    reordered[index] = reordered[targetIndex]
    reordered[targetIndex] = temp
    setBusy(true)
    try {
      await api.reorderBookGroups(reordered.map(g => g.name))
      await onGroupsChanged()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.reorderGroupFailed', '调整排序失败'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="modal-backdrop top-layer-modal-backdrop" onClick={onClose}>
      <div className="group-manage-modal" onClick={e => e.stopPropagation()} role="dialog" aria-modal="true" aria-label={t('shelf.manageGroups', '管理书架分组')}>
        <header className="group-manage-header">
          <div>
            <span className="section-kicker">{t('shelf.groupManageKicker', '书架分类')}</span>
            <h2>{t('shelf.groupManageTitle', '书架分组管理')}</h2>
          </div>
          <button className="subtle-button close-btn" onClick={onClose} aria-label={t('common.close', '关闭')}><Icon name="close" /></button>
        </header>

        <div className="group-manage-body">
          <form className="group-add-form" onSubmit={handleAddGroup}>
            <input
              type="text"
              value={newGroupName}
              onChange={e => setNewGroupName(e.target.value)}
              placeholder={t('shelf.groupNamePlaceholder', '输入新分组名称...')}
              maxLength={20}
              disabled={adding || busy}
            />
            <button type="submit" className="primary-button" disabled={!newGroupName.trim() || adding || busy}>
              {adding ? t('shelf.creatingGroup', '创建中...') : t('shelf.createGroup', '新建分组')}
            </button>
          </form>

          {error && <p className="form-error">{error}</p>}

          <div className="group-list">
            {groups.length === 0 ? (
              <p className="group-list-empty">{t('shelf.groupEmptyTip', '暂无自定义分组，创建后可自由归类书籍')}</p>
            ) : (
              groups.map((group, idx) => (
                <div key={group.id} className="group-item-row">
                  {editingId === group.id ? (
                    <div className="group-item-editing">
                      <input
                        type="text"
                        value={editingName}
                        onChange={e => setEditingName(e.target.value)}
                        autoFocus
                        maxLength={20}
                        onKeyDown={e => {
                          if (e.key === 'Enter') void handleRename(group)
                          if (e.key === 'Escape') setEditingId(null)
                        }}
                      />
                      <button type="button" className="subtle-button confirm-btn" onClick={() => void handleRename(group)} disabled={busy} title={t('common.save', '保存')}>
                        <Icon name="check" />
                      </button>
                      <button type="button" className="subtle-button" onClick={() => setEditingId(null)} title={t('common.cancel', '取消')}>
                        <Icon name="close" />
                      </button>
                    </div>
                  ) : (
                    <>
                      <div className="group-item-info">
                        <span className="group-item-name">{group.name}</span>
                        <span className="group-item-count">{t('shelf.booksInGroup', '{{count}} 本', { count: group.bookCount })}</span>
                      </div>
                      <div className="group-item-actions">
                        <button
                          type="button"
                          className="subtle-button"
                          disabled={idx === 0 || busy}
                          onClick={() => void handleMove(idx, 'up')}
                          title={t('shelf.moveUp', '上移')}
                        >
                          ↑
                        </button>
                        <button
                          type="button"
                          className="subtle-button"
                          disabled={idx === groups.length - 1 || busy}
                          onClick={() => void handleMove(idx, 'down')}
                          title={t('shelf.moveDown', '下移')}
                        >
                          ↓
                        </button>
                        <button
                          type="button"
                          className="subtle-button"
                          onClick={() => {
                            setEditingId(group.id)
                            setEditingName(group.name)
                          }}
                          title={t('shelf.rename', '重命名')}
                        >
                          <Icon name="edit" />
                        </button>
                        <button
                          type="button"
                          className="subtle-button danger-icon-btn"
                          onClick={() => void handleDelete(group)}
                          title={t('shelf.deleteGroup', '删除分组')}
                        >
                          <Icon name="close" />
                        </button>
                      </div>
                    </>
                  )}
                </div>
              ))
            )}
          </div>
        </div>

        <footer className="group-manage-footer">
          <button type="button" className="primary-button" onClick={onClose}>{t('common.ok', '完成')}</button>
        </footer>
      </div>
    </div>
  )
}

function BatchMoveGroupModal({
  groups,
  selectedCount,
  onClose,
  onSelectGroup,
}: {
  groups: BookGroup[]
  selectedCount: number
  onClose: () => void
  onSelectGroup: (groupName: string | null) => Promise<void>
}) {
  const { t } = useTranslation()
  const [busy, setBusy] = useState(false)

  const handleSelect = async (groupName: string | null) => {
    setBusy(true)
    try {
      await onSelectGroup(groupName)
      onClose()
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="modal-backdrop top-layer-modal-backdrop" onClick={onClose}>
      <div className="batch-move-modal" onClick={e => e.stopPropagation()} role="dialog" aria-modal="true" aria-label={t('shelf.batchMoveToGroup', '移动书籍至分组')}>
        <header className="group-manage-header">
          <div>
            <span className="section-kicker">{t('shelf.batchKicker', '批量操作')}</span>
            <h2>{t('shelf.batchMoveToGroup', '移动到分组')}</h2>
            <small>{t('shelf.selectedBooksCount', '已选择 {{count}} 本书籍', { count: selectedCount })}</small>
          </div>
          <button className="subtle-button close-btn" onClick={onClose} aria-label={t('common.close', '关闭')}><Icon name="close" /></button>
        </header>

        <div className="batch-move-list">
          <button type="button" className="batch-move-option" disabled={busy} onClick={() => void handleSelect(null)}>
            <div className="option-name">{t('search.scopeUngrouped', '未分组')}</div>
            <small>{t('shelf.clearGroupBelonging', '清除当前分组归属')}</small>
          </button>
          {groups.map(g => (
            <button key={g.id} type="button" className="batch-move-option" disabled={busy} onClick={() => void handleSelect(g.name)}>
              <div className="option-name">{g.name}</div>
              <small>{t('shelf.booksInGroup', '{{count}} 本书', { count: g.bookCount })}</small>
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}

/**
 * 用户点「缓存」之后**无论如何都继续轮询**的宽限期（毫秒）。
 *
 * 存在的理由见 `ShelfPage` 里 `pollGraceRef` 的注释：服务端在「入队 → 第一章进度登账」
 * 之间会短暂报 ready/idle，而轮询门只认 `cacheState === 'caching'`。没有宽限期，
 * 一拍踩空就会永久熄火（表现为「退回书架后缓存不动了」）。
 */
const CACHE_POLL_GRACE_MS = 30_000
const SHELF_REFRESH_POLL_MS = 900
const SHELF_REFRESH_ONLY_FINISHED_KEY = 'legado-shelf-refresh-only-finished-v1'

function readOnlyFinishedPreference(group: string): boolean {
  try {
    const raw = localStorage.getItem(SHELF_REFRESH_ONLY_FINISHED_KEY)
    if (!raw) return false
    const parsed = JSON.parse(raw) as unknown
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return false
    const values = parsed as Record<string, unknown>
    return values[group] === true
  } catch {
    return false
  }
}

function saveOnlyFinishedPreference(group: string, value: boolean) {
  try {
    const raw = localStorage.getItem(SHELF_REFRESH_ONLY_FINISHED_KEY)
    const parsed = raw ? JSON.parse(raw) as unknown : null
    const values = parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : {}
    values[group] = value
    localStorage.setItem(SHELF_REFRESH_ONLY_FINISHED_KEY, JSON.stringify(values))
  } catch {
    // 隐私模式下 localStorage 可能不可用；刷新本身仍可正常使用。
  }
}

function ShelfBookDetailModal({
  item,
  onClose,
  onRead,
  onManage,
}: {
  item: BookshelfItem
  onClose: () => void
  onRead: () => void
  onManage: () => void
}) {
  const { t } = useTranslation()
  const [details, setDetails] = useState<BookDetails | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [introExpanded, setIntroExpanded] = useState(false)

  useEffect(() => {
    const controller = new AbortController()
    setDetails(null)
    setError('')
    setLoading(true)
    void api.details(item.sourceId, item.bookUrl, {
      name: item.name,
      author: item.author,
      tocUrl: item.tocUrl,
      bookKind: item.bookKind,
      variables: parseBookVariables(item.variable),
    }, controller.signal).then(setDetails).catch(cause => {
      if (!controller.signal.aborted) {
        setError(cause instanceof Error ? cause.message : t('shelf.detailsLoadFailed', '无法从书源更新详情，已显示书架中的已有信息'))
      }
    }).finally(() => {
      if (!controller.signal.aborted) setLoading(false)
    })
    return () => controller.abort()
  }, [item.author, item.bookKind, item.bookUrl, item.name, item.sourceId, item.tocUrl, item.variable, t])

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [onClose])

  const name = cleanTitle(details?.name || item.name) || item.name
  const author = cleanAuthor(details?.author || item.author || '') || t('common.unknownAuthor', '未知作者')
  const resolvedKind = details?.bookKind || item.bookKind
  const kind = isLocalBook(item) || resolvedKind === 'local'
    ? t('shelf.localTag', '本地')
    : resolvedKind === 'comic'
      ? t('shelf.comicTag', '漫画')
      : resolvedKind === 'audio'
        ? t('shelf.audioTag', '听书')
        : t('shelf.novelTag', '小说')
  const latestChapter = details?.lastChapter?.trim() || item.latestChapterTitle || undefined
  const chapterIndex = item.chapterIndex == null ? null : item.chapterIndex + 1
  const status = item.isReadFinished
    ? t('shelf.statusRead', '已读')
    : item.isReading
      ? t('shelf.statusReading', '在读')
      : item.isUnread
        ? t('shelf.statusUnread', '未读')
        : item.completed
          ? t('shelf.completed', '已读完')
          : item.chapterIndex === undefined
            ? t('shelf.justAdded', '刚加入书架')
            : t('shelf.readingProgress', '读至：{{chapter}}', { chapter: t('shelf.chapterAt', '第 {{count}} 章', { count: item.chapterIndex + 1 }) })

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div
        className="book-detail-modal shelf-book-detail-modal"
        onClick={event => event.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label={t('shelf.bookDetailWithTitle', '书籍详情: {{name}}', { name: item.name })}
      >
        <header className="book-detail-modal-header">
          <div className="book-detail-heading">
            <BookCover
              coverKey={item.coverKey}
              coverUrl={details?.coverUrl || item.coverUrl}
              name={name}
              className="book-detail-cover"
              fallbackClassName="book-detail-cover-placeholder"
            />
            <div className="book-detail-info">
              <span className="section-kicker">{t('shelf.bookDetail', '书籍详情')}</span>
              <h2>{name}</h2>
              <p>{author}</p>
              <div className="book-detail-stats">
                <span>{kind}</span>
                <span>{status}</span>
                <span>{t('reader.totalChapters', '{{count}} 章', { count: item.catalogChapters || item.totalChapters || 0 })}</span>
                {latestChapter && <span>{t('shelf.latestChapterWithTitle', '最新：{{title}}', { title: latestChapter })}</span>}
              </div>
            </div>
          </div>
          <div className="book-detail-header-actions">
            <button type="button" className="subtle-button shelf-toggle-btn" onClick={onManage}>
              <Icon name="settings" />
              <span>{t('shelf.bookManage', '书籍管理')}</span>
            </button>
            <button type="button" className="primary-button read-btn" onClick={onRead}>
              <Icon name="book" />
              <span>{t('shelf.readNow', '查看正文')}</span>
            </button>
            <button type="button" className="subtle-button close-btn" onClick={onClose} aria-label={t('common.close', '关闭')}>
              <Icon name="close" />
            </button>
          </div>
        </header>

        <div className="book-detail-modal-body shelf-book-detail-body">
          {loading && (
            <div className="book-detail-loading" role="status">
              <ButtonSpinner />
              {t('shelf.loadingDetails', '正在从书源更新书籍详情...')}
            </div>
          )}
          {error && <p className="shelf-detail-warning" role="status">{error}</p>}

          <section className="book-detail-section">
            <div className="shelf-detail-meta-grid">
              <div>
                <small>{t('shelf.readingStatus', '阅读状态')}</small>
                <strong>{status}</strong>
              </div>
              <div>
                <small>{t('shelf.readingProgressLabel', '阅读进度')}</small>
                <strong>
                  {chapterIndex == null
                    ? t('shelf.notStarted', '尚未开始')
                    : `${chapterIndex} / ${item.catalogChapters || item.totalChapters || '?'}`}
                </strong>
              </div>
              <div>
                <small>{t('shelf.group', '所属分组')}</small>
                <strong>{item.groupName || t('search.scopeUngrouped', '未分组')}</strong>
              </div>
              <div>
                <small>{t('shelf.cacheStatus', '离线缓存')}</small>
                <strong>{item.cachedChapters} / {item.totalChapters || item.catalogChapters || '?'}</strong>
              </div>
              <div>
                <small>{t('shelf.updateStatus', '目录更新')}</small>
                <strong>
                  {item.canUpdate === false
                    ? t('shelf.updatesPaused', '已停更')
                    : item.updateError
                      ? t('shelf.refreshFailedShort', '更新失败')
                      : t('shelf.updatesEnabled', '已启用')}
                </strong>
              </div>
              {details?.kind && (
                <div>
                  <small>{t('shelf.category', '分类')}</small>
                  <strong>{details.kind}</strong>
                </div>
              )}
              {details?.wordCount && (
                <div>
                  <small>{t('library.wordCount', '字数')}</small>
                  <strong>{details.wordCount}</strong>
                </div>
              )}
              <div className="wide">
                <small>{t('shelf.source', '书源')}</small>
                <strong title={item.sourceId}>{item.sourceId}</strong>
              </div>
            </div>
          </section>

          <section className="book-detail-section">
            <div className="book-detail-section-title">
              <span>{t('shelf.bookIntro', '书籍简介')}</span>
            </div>
            {details?.intro ? (
              <div className={`book-intro ${introExpanded ? 'expanded' : ''}`}>
                <p>{details.intro}</p>
                {details.intro.length > 140 && (
                  <button type="button" className="intro-toggle" onClick={() => setIntroExpanded(value => !value)}>
                    {introExpanded ? t('shelf.collapseIntro', '收起简介') : t('shelf.expandIntro', '展开简介')}
                  </button>
                )}
              </div>
            ) : !loading ? (
              <p className="shelf-detail-empty">{t('shelf.noIntro', '该书源没有提供简介')}</p>
            ) : null}
          </section>
        </div>
      </div>
    </div>
  )
}

function ShelfPage({ onOpenBook, onOpenTasks, onTaskCountChange, theme }: {
  onOpenBook: (item: BookshelfItem) => void
  onOpenTasks: () => void
  onTaskCountChange: (count: number) => void
  theme: ReaderTheme
}) {
  const { t } = useTranslation()
  const [items, setItems] = useState<BookshelfItem[]>([])
  const [groups, setGroups] = useState<BookGroup[]>([])
  const [selectedGroup, setSelectedGroup] = useState<string>('all') // 'all' | '__ungrouped__' | custom group name
  const [statusFilter, setStatusFilter] = useState<'all' | 'unread' | 'reading' | 'finished'>('all')
  const [message, setMessage] = useState('')
  const [switchingItem, setSwitchingItem] = useState<BookshelfItem | null>(null)
  const [exportingItem, setExportingItem] = useState<BookshelfItem | null>(null)
  const [detailItem, setDetailItem] = useState<BookshelfItem | null>(null)
  /**
   * 书籍管理（一级）与「清除缓存」范围选择（二级）的**层级状态机**（见 `src/shelfModalStack.ts`）。
   *
   * 修复 issue #66：原先这里是两个彼此独立的可空状态，打开二级时把一级置 `null`，
   * 于是二级的「取消」只关掉自己 ⇒ 两级一起消失、回到书架，与文案「返回书籍管理」矛盾。
   * 现在层级只有这一份状态，`closeClearCacheScope` 只退一级 ⇒ 一级的书永远还在。
   */
  const [shelfModal, dispatchShelfModal] = useReducer(shelfModalReducer, SHELF_MODAL_SHELF)
  /** 当前可见的一级 / 二级（两者**互斥**：同一时刻最多一个非 null ⇒ 不会双层遮罩）。 */
  const managingItem = shelfModal.layer === 'manage' ? shelfModal.item : null
  const clearingCacheItem = shelfModal.layer === 'clearCacheScope' ? shelfModal.item : null
  const [clearingCache, setClearingCache] = useState(false)
  const [clearingScope, setClearingScope] = useState<ClearCacheScope | null>(null)
  const [uploading, setUploading] = useState(false)
  const [dragOver, setDragOver] = useState(false)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const [managingGroups, setManagingGroups] = useState(false)
  const [batchMode, setBatchMode] = useState(false)
  const [selectedKeys, setSelectedKeys] = useState<Set<string>>(new Set())
  const [batchMoving, setBatchMoving] = useState(false)
  const previousStateRef = useRef<Map<string, string>>(new Map())
  const [refreshStatus, setRefreshStatus] = useState<BookshelfRefreshStatus | null>(null)
  const refreshWasRunningRef = useRef(false)
  const [refreshStarting, setRefreshStarting] = useState(false)
  const [onlyFinishedRefresh, setOnlyFinishedRefresh] = useState(() => readOnlyFinishedPreference('all'))
  const [updatingRefreshSettingKey, setUpdatingRefreshSettingKey] = useState<string | null>(null)

  const load = useCallback(async () => {
    try {
      const [list, groupList] = await Promise.all([
        api.bookshelf(),
        api.bookGroups(),
      ])
      list.forEach(curr => {
        const key = `${curr.sourceId}\u0000${curr.bookUrl}`
        const prevState = previousStateRef.current.get(key)
        if (prevState === 'caching' && curr.cacheState === 'ready') {
          toast.success(t('shelf.allCachedDone', '《{{name}}》全本离线缓存完成（共 {{count}} 章）', { name: curr.name, count: curr.cachedChapters }))
        } else if (prevState === 'caching' && curr.cacheState === 'failed') {
          toast.warning(t('shelf.cacheInterrupted', '《{{name}}》缓存中断：{{error}}', { name: curr.name, error: curr.cacheError || t('reader.incomplete', '未全部完成') }))
        }
        previousStateRef.current.set(key, curr.cacheState)
      })
      setItems(list)
      setGroups(groupList)
      setDetailItem(current => current
        ? list.find(item => item.sourceId === current.sourceId && item.bookUrl === current.bookUrl) ?? null
        : null)
    } catch (error) {
      setMessage(error instanceof Error ? error.message : t('shelf.cannotLoad', '无法载入书架'))
    }
  }, [t])

  useEffect(() => {
    void load()
  }, [load])

  const applyRefreshStatus = useCallback((status: BookshelfRefreshStatus) => {
    const wasRunning = refreshWasRunningRef.current
    setRefreshStatus(status)
    if (status.state === 'running') {
      refreshWasRunningRef.current = true
      return
    }
    if (!wasRunning) return

    refreshWasRunningRef.current = false
    void load()
    if (status.total === 0) {
      toast.info(t('shelf.refreshNoEligible', '当前范围内没有可刷新的在线书籍'))
      return
    }
    const newChapters = status.items.reduce((total, item) => total + Math.max(0, item.newChapters), 0)
    if (status.failed > 0) {
      toast.warning(t('shelf.refreshFinishedPartial', '目录刷新完成：成功 {{success}} 本，失败 {{failed}} 本，新增 {{chapters}} 章', {
        success: status.succeeded,
        failed: status.failed,
        chapters: newChapters,
      }))
    } else {
      toast.success(t('shelf.refreshFinished', '目录刷新完成：更新 {{count}} 本，新增 {{chapters}} 章', {
        count: status.succeeded,
        chapters: newChapters,
      }))
    }
  }, [load, t])

  useEffect(() => {
    let active = true
    void api.bookshelfRefreshStatus().then(status => {
      if (active) applyRefreshStatus(status)
    }).catch(() => undefined)
    return () => {
      active = false
    }
  }, [applyRefreshStatus])

  useEffect(() => {
    if (refreshStatus?.state !== 'running') return
    let active = true
    let polling = false
    const poll = async () => {
      if (polling) return
      polling = true
      try {
        const status = await api.bookshelfRefreshStatus()
        if (active) applyRefreshStatus(status)
      } catch {
        // 单次轮询失败不终止；下一次继续读取服务端任务状态。
      } finally {
        polling = false
      }
    }
    const timer = window.setInterval(() => void poll(), SHELF_REFRESH_POLL_MS)
    return () => {
      active = false
      window.clearInterval(timer)
    }
  }, [applyRefreshStatus, refreshStatus?.state])

  useEffect(() => {
    setOnlyFinishedRefresh(readOnlyFinishedPreference(selectedGroup))
  }, [selectedGroup])

  const setOnlyFinished = (value: boolean) => {
    setOnlyFinishedRefresh(value)
    saveOnlyFinishedPreference(selectedGroup, value)
  }

  const refreshBooks = async (scope: 'visible' | 'selected') => {
    if (refreshStarting || refreshStatus?.state === 'running') return
    const sourceItems = scope === 'selected'
      ? visibleItems.filter(item => selectedKeys.has(`${item.sourceId}\u0000${item.bookUrl}`))
      : visibleItems
    if (sourceItems.length === 0) {
      toast.info(t('shelf.refreshNothingSelected', '当前没有可刷新的书籍'))
      return
    }
    refreshWasRunningRef.current = true
    setRefreshStarting(true)
    try {
      const status = await api.refreshBookshelf({
        books: sourceItems.map(item => ({ sourceId: item.sourceId, bookUrl: item.bookUrl })),
        onlyFinished: onlyFinishedRefresh,
        concurrency: 9,
      })
      applyRefreshStatus(status)
    } catch (error) {
      refreshWasRunningRef.current = false
      toast.error(error instanceof Error ? error.message : t('shelf.refreshStartFailed', '无法开始刷新书架'))
    } finally {
      setRefreshStarting(false)
    }
  }

  const setCanUpdate = async (item: BookshelfItem, canUpdate: boolean) => {
    const key = `${item.sourceId}\u0000${item.bookUrl}`
    setUpdatingRefreshSettingKey(key)
    try {
      const updated = await api.setBookshelfCanUpdate(item.sourceId, item.bookUrl, canUpdate)
      setItems(values => values.map(value => value.sourceId === updated.sourceId && value.bookUrl === updated.bookUrl ? updated : value))
      dispatchShelfModal({ type: 'updateItem', item: updated })
      toast.success(canUpdate
        ? t('shelf.resumeUpdatesSuccess', '已恢复《{{name}}》的目录更新', { name: item.name })
        : t('shelf.pauseUpdatesSuccess', '已停止《{{name}}》的目录更新', { name: item.name }))
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('shelf.updateRefreshSettingFailed', '更新目录设置失败'))
    } finally {
      setUpdatingRefreshSettingKey(null)
    }
  }

  const handleImportFiles = async (files: FileList | File[]) => {
    const list = Array.from(files).filter(f => {
      const n = f.name.toLowerCase()
      return n.endsWith('.txt') || n.endsWith('.epub') || n.endsWith('.text')
    })
    if (list.length === 0) {
      toast.warning(t('shelf.pleaseSelectEbook', '请选择 .txt 或 .epub 格式的电子书文件'))
      return
    }
    setUploading(true)
    toast.info(t('shelf.parsingImportingBooks', '正在解析并导入 {{count}} 本本地书籍...', { count: list.length }))
    try {
      const resp = await api.importLocalBooks(list)
      if (resp.imported > 0) {
        toast.success(t('shelf.importSuccessBooks', '成功导入 {{count}} 本本地书籍！', { count: resp.imported }))
      }
      if (resp.failed > 0) {
        const errorMsg = resp.results.filter(r => !r.success).map(r => `${r.filename}: ${r.error}`).join('; ')
        toast.error(t('shelf.importPartialFailedBooks', '部分书籍导入失败 ({{count}} 本): {{error}}', { count: resp.failed, error: errorMsg }))
      }
      await load()
    } catch (e) {
      toast.error(e instanceof Error ? e.message : t('shelf.importLocalBooksFailed', '导入本地书籍失败'))
    } finally {
      setUploading(false)
    }
  }

  /**
   * 书架列表的进度轮询门。
   *
   * ## 为什么不能只写 `if (!caching) return`
   * `caching` 完全来自**服务端快照**。而服务端从"入队"到"第一章进度登账"之间有一小段
   * （抓目录 / 解析第一章清单，实测 300ms~数秒）状态接口返回空 ⇒ 列表这一拍是
   * `ready`/`idle` ⇒ 上面那个写法会**在这一次就 return，而且永远不再重新评估**
   * （没有定时器 ⇒ 没有新的 load() ⇒ `caching` 不会变）⇒ 用户看到「退到书架后缓存就不动了」。
   *
   * 因此：用户刚点过缓存 ⇒ 给一个**宽限期**，期间即使某一拍不是 caching 也继续轮询；
   * 宽限期结束后由定时器自己收尾（服务端那边已改成入队即登账，正常情况下这一拍就是 caching）。
   */
  const caching = items.some(item => item.cacheState === 'caching')
  const cachingRef = useRef(caching)
  cachingRef.current = caching
  const pollGraceRef = useRef(0)
  useEffect(() => {
    if (!caching && Date.now() > pollGraceRef.current) return
    const timer = window.setInterval(() => {
      if (!cachingRef.current && Date.now() > pollGraceRef.current) {
        // 宽限期过了且这一拍确实没在缓存 ⇒ 收尾，别让列表无意义地每秒重拉
        window.clearInterval(timer)
        return
      }
      void load()
    }, 1200)
    return () => window.clearInterval(timer)
  }, [caching, load])

  /**
   * 让**书籍管理弹窗**跟着列表一起刷新。
   *
   * 弹窗里的 item 是打开那一刻的**快照**，而进度是由上面那个定时 `load()` 写进 `items` 的。
   * 不把新进度回灌进弹窗，弹窗里的「x/y 章」就永远停在打开时的数字 —— 这正是用户反馈的
   * 「弹窗里的缓存还是有问题 / 缓存不动」：服务端在跑、列表也在涨，唯独弹窗那一份数据是死的。
   *
   * 回灌逻辑搬进状态机的 `syncSnapshot`：只同步**进度相关字段**，不动书名/封面等可编辑字段
   * （编辑流程走 `updateItem`），且「没变化就返回同一个 state」⇒ 不会多渲染一次。
   */
  useEffect(() => {
    dispatchShelfModal({ type: 'syncSnapshot', items })
  }, [items])

  const remove = async (item: BookshelfItem) => {
    if (!confirm(t('shelf.removeFromShelfConfirmDetailed', '移出“{{name}}”将清除书架、阅读进度和缓存封面，确定继续吗？', { name: item.name }))) return
    try {
      await api.removeFromBookshelf(item.sourceId, item.bookUrl)
      setItems(values => values.filter(value => value.sourceId !== item.sourceId || value.bookUrl !== item.bookUrl))
      toast.info(t('shelf.bookRemoved', '《{{name}}》已移出书架', { name: item.name }))
      void load()
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('shelf.removeFailed', '移出失败'))
    }
  }

  const cache = async (item: BookshelfItem, chapterConcurrency?: number): Promise<boolean> => {
    try {
      await api.cacheBookshelfBook(item.sourceId, item.bookUrl, chapterConcurrency)
      // 宽限期：服务端「入队 → 第一章进度登账」之间有亚秒~数秒空窗（抓目录时更久），
      // 这段列表会报 ready/idle。不给宽限期的话轮询门会在这一拍永久熄火（见 pollGraceRef 注释）。
      pollGraceRef.current = Date.now() + CACHE_POLL_GRACE_MS
      setItems(values => values.map(value => value.sourceId === item.sourceId && value.bookUrl === item.bookUrl ? { ...value, cacheState: 'caching', cacheError: undefined } : value))
      previousStateRef.current.set(`${item.sourceId}\u0000${item.bookUrl}`, 'caching')
      toast.info(chapterConcurrency == null
        ? t('shelf.addedToCacheQueue', { name: item.name, defaultValue: `已加入离线缓存队列，正在下载《${item.name}》...` })
        : t('shelf.addedToCacheQueueWithConcurrency', {
            name: item.name,
            count: chapterConcurrency,
            defaultValue: `《${item.name}》已按 ${chapterConcurrency} 章并发加入缓存队列`,
          }))
      return true
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('shelf.cannotStartCache', '无法开始缓存'))
      return false
    }
  }

  const cancelCache = async (item: BookshelfItem) => {
    try {
      await api.cancelBookCache(item.sourceId, item.bookUrl)
      setItems(values => values.map(value => value.sourceId === item.sourceId && value.bookUrl === item.bookUrl ? { ...value, cacheState: 'failed', cacheError: t('shelf.cacheErrorCancelled', '已取消缓存') } : value))
      previousStateRef.current.set(`${item.sourceId}\u0000${item.bookUrl}`, 'failed')
      toast.info(t('shelf.cacheCancelled', '已取消《{{name}}》的离线缓存', { name: item.name }))
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('shelf.cancelCacheFailed', '取消缓存失败'))
    }
  }

  /**
   * 按**用户选定的范围**清除这一本书已下载的缓存。
   *
   * 范围模型见 `shelfClearCache.ts`：`server` 只打三个服务端端点、`browser` 只清本机
   * IndexedDB、`both` 四步全做；**调用集合完全由 `stepsForScope(scope)` 决定**。
   *
   * 作用域**永远只带 `item.sourceId` + `item.bookUrl`**（用户口径：「只清这本书的」），
   * 四个步骤共用同一张表 ⇒ 不会出现"改了一条分支忘了另一条"而串范围。
   *
   * 每一步独立 `try/catch` 记账：只报「全成功」或「具体哪一部分没清掉」，
   * 且点名只点**实际执行过**的段（只清服务器时不会冒出「本机离线正文」）。
   */
  const clearCache = async (item: BookshelfItem, scope: ClearCacheScope) => {
    setClearingCache(true)
    setClearingScope(scope)
    const failedParts: string[] = []
    try {
      for (const step of stepsForScope(scope)) {
        try {
          if (step === 'content') {
            await api.clearBookCacheData(item.sourceId, item.bookUrl)
          } else {
            // 本机 IndexedDB 里的离线正文（「本机离线缓存管理」用的同一套存储）。按书删，不做全清。
            await clearOfflineBook(item.sourceId, item.bookUrl)
          }
        } catch {
          failedParts.push(
            step === 'content'
              ? t('shelf.clearCachePartContent', '正文缓存')
              : t('shelf.clearCachePartLocal', '本机离线正文'),
          )
        }
      }
    } finally {
      setClearingCache(false)
      setClearingScope(null)
      // 清理执行完的落点：**退回一级「书籍管理」**（与取消 / ESC / 点遮罩同一个转移）。
      // 为什么不是回书架：清缓存是从这本书的管理弹窗里发起的，执行完立刻在**同一本书**上
      // 看到「0 章已缓存」比把人踢回书架更符合最小惊讶，也省掉"再点进去确认"的一步。
      dispatchShelfModal({ type: 'closeClearCacheScope' })
    }
    if (failedParts.length === 0) {
      toast.success(t('shelf.clearCacheSuccess', '《{{name}}》缓存已清除', { name: item.name }))
    } else {
      toast.warning(t('shelf.clearCachePartial', '《{{name}}》部分缓存未清除：{{parts}}，可稍后重试', { name: item.name, parts: failedParts.join('、') }))
    }
    // 离线章数已归零：回书架拉一次最新状态，缓存进度条才不会停在旧值上
    void load()
  }

  const handleSwitchShelfSource = async (chosen: { result: SearchResult; chapters: Chapter[]; targetChapterIndex: number }) => {
    if (!switchingItem) return
    const details = await api.details(chosen.result.sourceId, chosen.result.bookUrl, {
      name: chosen.result.name || switchingItem.name,
      author: chosen.result.author || switchingItem.author,
      tocUrl: chosen.result.tocUrl,
      bookKind: chosen.result.bookKind || switchingItem.bookKind,
      variables: parseBookVariables(switchingItem.variable),
    })
    const fallbackCover = details.coverUrl?.trim() ||
      chosen.result.coverUrl?.trim() ||
      switchingItem.alternateSources?.find(s => s.coverUrl?.trim())?.coverUrl?.trim()

    await api.switchBookshelfSource({
      oldSourceId: switchingItem.sourceId,
      oldBookUrl: switchingItem.bookUrl,
      book: {
        sourceId: details.sourceId,
        bookUrl: chosen.result.bookUrl,
        name: cleanTitle(details.name?.trim() || switchingItem.name) || switchingItem.name,
        author: cleanAuthor(details.author?.trim() || switchingItem.author) || switchingItem.author,
        tocUrl: details.tocUrl,
        coverUrl: fallbackCover || undefined,
        groupName: switchingItem.groupName,
        catalogChapters: chosen.chapters.length,
      },
      alternateSources: switchingItem.alternateSources,
    })
    setSwitchingItem(null)
    await load()
  }

  const setCompleted = async (item: BookshelfItem, completed: boolean) => {
    try {
      const updated = await api.setBookshelfCompleted(item.sourceId, item.bookUrl, completed)
      setItems(values => values.map(value => value.sourceId === item.sourceId && value.bookUrl === item.bookUrl ? updated : value))
      toast.success(completed ? t('shelf.updateReadingStatusSuccess', '已将《{{name}}》标记为已读完', { name: item.name }) : t('shelf.updateReadingStatusResume', '已将《{{name}}》恢复为正在阅读', { name: item.name }))
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('shelf.updateReadingStatusFailed', '更新阅读状态失败'))
    }
  }

  const cacheBadge = (item: BookshelfItem) => {
    if (isLocalBook(item)) {
      const count = item.cachedChapters || item.totalChapters || 0
      return count > 0 ? t('shelf.chaptersCached', '{{count}}章已缓存', { count }) : null
    }
    if (item.cacheState === 'caching') return `${Math.min(100, Math.round((item.cachedChapters / Math.max(1, item.totalChapters || 1)) * 100))}% ${t('shelf.caching', '缓存中')}`
    if (item.cacheState === 'ready') return t('shelf.chaptersCached', '{{count}}章已缓存', { count: item.cachedChapters })
    if (item.cacheState === 'failed') return `${item.cachedChapters}/${item.totalChapters || '?'} · ${t('shelf.cacheFailed', '缓存中断')}`
    if (item.cacheState === 'paused') return `${item.cachedChapters}/${item.totalChapters || '?'} · ${t('shelf.cachePaused', '缓存已暂停')}`
    return null
  }

  const groupFilteredItems = useMemo(() => {
    if (selectedGroup === 'all') return items
    if (selectedGroup === '__ungrouped__') return items.filter(i => !i.groupName)
    return items.filter(i => i.groupName === selectedGroup)
  }, [items, selectedGroup])

  const visibleItems = useMemo(() => {
    if (statusFilter === 'all') return groupFilteredItems
    if (statusFilter === 'finished') return groupFilteredItems.filter(i => i.isReadFinished)
    if (statusFilter === 'reading') return groupFilteredItems.filter(i => i.isReading)
    return groupFilteredItems.filter(i => i.isUnread)
  }, [groupFilteredItems, statusFilter])

  const refreshStatusByBook = useMemo(() => {
    return new Map((refreshStatus?.items ?? []).map(item => [
      `${item.sourceId}\u0000${item.bookUrl}`,
      item,
    ]))
  }, [refreshStatus])

  const visibleRefreshableItems = useMemo(() => visibleItems.filter(item =>
    item.canUpdate !== false && !isLocalBook(item) && (!onlyFinishedRefresh || item.isReadFinished)
  ), [onlyFinishedRefresh, visibleItems])

  const refreshRunning = refreshStarting || refreshStatus?.state === 'running'

  const groupCounts = useMemo(() => {
    let ungrouped = 0
    items.forEach(i => {
      if (!i.groupName) ungrouped++
    })
    return { ungrouped, all: items.length }
  }, [items])

  const statusCounts = useMemo(() => ({
    all: groupFilteredItems.length,
    unread: groupFilteredItems.filter(i => i.isUnread).length,
    reading: groupFilteredItems.filter(i => i.isReading).length,
    finished: groupFilteredItems.filter(i => i.isReadFinished).length,
  }), [groupFilteredItems])
  const shelfMetrics = useMemo(() => ({
    reading: items.filter(item => item.isReading).length,
    cached: items.filter(item => item.cacheState === 'ready').length,
    interrupted: items.filter(item => item.cacheState === 'failed' || item.cacheState === 'paused' || item.updateError).length,
  }), [items])

  const continueReading = useMemo(() => (
    [...items]
      .filter(item => item.isReading && !item.isReadFinished)
      .sort((left, right) => right.lastReadAt - left.lastReadAt)
      .slice(0, 3)
  ), [items])

  const recentlyAdded = useMemo(() => (
    [...groupFilteredItems]
      .sort((left, right) => right.lastReadAt - left.lastReadAt)
      .slice(0, 3)
  ), [groupFilteredItems])

  useEffect(() => {
    const activeCache = items.filter(item => item.cacheState === 'caching').length
    const refreshTasks = refreshStatus?.state === 'running' ? 1 : 0
    onTaskCountChange(activeCache + refreshTasks + shelfMetrics.interrupted)
  }, [items, onTaskCountChange, refreshStatus?.state, shelfMetrics.interrupted])

  const toggleSelectKey = (key: string) => {
    setSelectedKeys(prev => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }

  const selectAllVisible = () => {
    const keys = visibleItems.map(i => `${i.sourceId}\u0000${i.bookUrl}`)
    setSelectedKeys(new Set(keys))
  }

  const deselectAll = () => {
    setSelectedKeys(new Set())
  }

  const getSelectedBookKeys = () => {
    return Array.from(selectedKeys).map(k => {
      const parts = k.split('\u0000')
      return { sourceId: parts[0], bookUrl: parts[1] }
    })
  }

  const handleBatchMoveGroup = async (targetGroup: string | null) => {
    const keys = getSelectedBookKeys()
    if (keys.length === 0) return
    try {
      await api.batchBookshelf({
        action: 'move_group',
        items: keys,
        targetGroup: targetGroup || undefined,
      })
      toast.success(targetGroup ? t('shelf.batchMovedToGroup', '已将 {{count}} 本书籍移动至「{{group}}」', { count: keys.length, group: targetGroup }) : t('shelf.batchMovedToUngrouped', '已将 {{count}} 本书籍移至「未分组」', { count: keys.length }))
      setSelectedKeys(new Set())
      setBatchMode(false)
      await load()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.batchMoveFailed', '批量移动失败'))
    }
  }

  const handleBatchMarkCompleted = async (completed: boolean) => {
    const keys = getSelectedBookKeys()
    if (keys.length === 0) return
    try {
      await api.batchBookshelf({
        action: 'mark_completed',
        items: keys,
        completed,
      })
      toast.success(completed ? t('shelf.batchMarkCompletedSuccess', '已将 {{count}} 本书籍标记为已读完', { count: keys.length }) : t('shelf.batchMarkReadingSuccess', '已将 {{count}} 本书籍恢复为正在阅读', { count: keys.length }))
      setSelectedKeys(new Set())
      await load()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.batchUpdateStatusFailed', '批量更新阅读状态失败'))
    }
  }

  const handleBatchDelete = async () => {
    const keys = getSelectedBookKeys()
    if (keys.length === 0) return
    if (!confirm(t('shelf.batchDeleteConfirm', '确定将选中的 {{count}} 本书籍移出书架吗？将清除阅读进度与离线缓存。', { count: keys.length }))) return
    try {
      await api.batchBookshelf({
        action: 'delete',
        items: keys,
      })
      toast.info(t('shelf.batchRemovedSuccess', '已移出 {{count}} 本书籍', { count: keys.length }))
      setSelectedKeys(new Set())
      setBatchMode(false)
      await load()
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.batchDeleteFailed', '批量移出失败'))
    }
  }

  const handleBatchReclean = async () => {
    const keys = getSelectedBookKeys()
    if (keys.length === 0) return
    try {
      const res = await api.batchRecleanBookCache(keys)
      toast.success(t('shelf.batchRecleanSuccess', '批量重洗完成，共处理 {{count}} 章', { count: res.totalRecleaned }))
      setSelectedKeys(new Set())
      setBatchMode(false)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('shelf.batchRecleanFailed', '批量重洗失败'))
    }
  }

  return (
    <main
      className={`shelf-page ${dragOver ? 'drag-active' : ''}`}
      onDragOver={e => { e.preventDefault(); setDragOver(true) }}
      onDragLeave={e => {
        if (!e.currentTarget.contains(e.relatedTarget as Node)) {
          setDragOver(false)
        }
      }}
      onDrop={e => {
        e.preventDefault()
        setDragOver(false)
        if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
          void handleImportFiles(e.dataTransfer.files)
        }
      }}
    >
      <header className="page-title shelf-page-header">
        <div className="page-heading-copy">
          <span className="section-kicker">{t('shelf.headerTitle', '我的书架')}</span>
          <h1>{t('header.shelf', '书架')}</h1>
          <p>查看阅读进度与缓存状态，整理分组并从封面直接继续阅读。</p>
        </div>
        <div className="shelf-header-actions">
          <label className="shelf-refresh-only-finished" title={t('shelf.refreshOnlyFinishedHint', '刷新时只处理已经没有未读章节的书籍')}>
            <input
              type="checkbox"
              checked={onlyFinishedRefresh}
              onChange={event => setOnlyFinished(event.target.checked)}
              disabled={refreshRunning}
            />
            <span>{t('shelf.refreshOnlyFinished', '仅更新已读完')}</span>
          </label>
          <button
            type="button"
            className={`shelf-refresh-btn ${refreshRunning ? 'is-loading' : ''}`}
            disabled={refreshRunning || uploading || visibleRefreshableItems.length === 0}
            aria-busy={refreshRunning}
            onClick={() => void refreshBooks('visible')}
            title={t('shelf.refreshCurrentScopeHint', '更新当前分组与状态筛选中的在线书籍目录')}
          >
            {refreshRunning ? <ButtonSpinner size={14} /> : <Icon name="refresh" />}
            <span>
              {refreshRunning
                ? t('shelf.refreshingProgress', '刷新中 {{completed}}/{{total}}', {
                    completed: refreshStatus?.completed ?? 0,
                    total: refreshStatus?.total ?? 0,
                  })
                : t('shelf.refreshCurrentScope', '更新当前书架')}
            </span>
          </button>
          <input
            ref={fileInputRef}
            type="file"
            multiple
            accept=".txt,.epub,.text,application/epub+zip,text/plain"
            style={{ display: 'none' }}
            onChange={e => {
              if (e.target.files && e.target.files.length > 0) {
                void handleImportFiles(e.target.files)
                e.target.value = ''
              }
            }}
          />
          <button
            type="button"
            className="shelf-import-btn"
            disabled={uploading}
            onClick={() => fileInputRef.current?.click()}
            title={t('shelf.importBook', '导入本地图书')}
          >
            <Icon name="upload" />
            <span>{uploading ? t('common.loading', '导入中...') : t('shelf.importBook', '导入本地')}</span>
          </button>
          <small>{t('shelf.bookCount', { count: visibleItems.length, defaultValue: `${visibleItems.length} 本书` })}</small>
          <button
            type="button"
            className={`shelf-batch-toggle-btn ${batchMode ? 'active' : ''}`}
            onClick={() => {
              if (batchMode) {
                setBatchMode(false)
                setSelectedKeys(new Set())
              } else {
                setBatchMode(true)
              }
            }}
          >
            <Icon name={batchMode ? 'check' : 'list'} />
            {batchMode ? t('common.ok', '完成') : t('shelf.batchManage', '批量管理')}
          </button>
        </div>
      </header>

      {(continueReading.length > 0 || shelfMetrics.interrupted > 0) && (
        <section className="shelf-quick-workspace" aria-label="阅读快捷入口">
          {continueReading.length > 0 && (
            <article className="quick-reading-stack">
              <header>
                <span><Icon name="bookmark" />继续阅读</span>
                <small>最近打开的在线书</small>
              </header>
              <div className="quick-reading-list">
                {continueReading.map(item => {
                  const total = item.catalogChapters || item.totalChapters || 0
                  const current = total > 0 ? Math.min(total, (item.chapterIndex ?? 0) + 1) : 0
                  return (
                    <button key={`${item.sourceId}\u0000${item.bookUrl}`} type="button" onClick={() => onOpenBook(item)}>
                      <BookCover coverKey={item.coverKey} coverUrl={item.coverUrl} name={item.name} />
                      <span>
                        <strong>{item.name}</strong>
                        <small>{current > 0 ? `第 ${current} 章` : '从开头继续'} · {total > 0 ? `${current}/${total}` : '上次阅读'}</small>
                      </span>
                      <Icon name="arrowRight" />
                    </button>
                  )
                })}
              </div>
            </article>
          )}
          <article className="quick-recovery-card">
            <header>
              <span><Icon name={shelfMetrics.interrupted > 0 ? 'activity' : 'check'} />阅读准备情况</span>
              <small>{shelfMetrics.interrupted > 0 ? '有任务需要处理' : '可以安心离线阅读'}</small>
            </header>
            <div className="quick-recovery-state">
              <strong>{shelfMetrics.cached}</strong>
              <span>
                <b>本已缓存</b>
                <small>{shelfMetrics.interrupted > 0 ? `${shelfMetrics.interrupted} 本缓存或目录异常` : '当前书架状态正常'}</small>
              </span>
            </div>
            <footer>
              {shelfMetrics.interrupted > 0
                ? <button type="button" onClick={() => setStatusFilter('all')}>查看需要处理的书 <Icon name="arrowRight" /></button>
                : <button type="button" onClick={() => setBatchMode(true)}>选择书籍批量管理 <Icon name="arrowRight" /></button>}
            </footer>
          </article>
          {recentlyAdded.length > 0 && (
            <article className="quick-added-card">
              <header>
                <span><Icon name="plus" />最近加入</span>
                <small>最快的下一步</small>
              </header>
              <div className="quick-added-list">
                {recentlyAdded.map(item => (
                  <button key={`${item.sourceId}\u0000${item.bookUrl}`} type="button" onClick={() => setDetailItem(item)}>
                    <span>{item.name}</span>
                    <small>{item.groupName || '未分组'}</small>
                  </button>
                ))}
              </div>
            </article>
          )}
        </section>
      )}

      <AutomationCenter
        items={items}
        refreshStatus={refreshStatus}
        caching={caching}
        onOpenBook={item => dispatchShelfModal({ type: 'openManage', item })}
        onOpenTasks={onOpenTasks}
      />

      <section className="shelf-overview-grid" aria-label="书架概览">
        <article className="shelf-overview-card shelf-overview-card-primary">
          <span className="shelf-overview-icon"><Icon name="library" /></span>
          <span>
            <small>书架藏书</small>
            <strong>{items.length}</strong>
            <em>{items.length === 0 ? '等待加入第一本书' : `${groupCounts.ungrouped} 本未分组`}</em>
          </span>
        </article>
        <article className="shelf-overview-card">
          <span className="shelf-overview-icon"><Icon name="bookmark" /></span>
          <span>
            <small>正在阅读</small>
            <strong>{shelfMetrics.reading}</strong>
            <em>{statusCounts.finished} 本已读</em>
          </span>
        </article>
        <article className="shelf-overview-card">
          <span className="shelf-overview-icon"><Icon name="cloudDownload" /></span>
          <span>
            <small>离线已就绪</small>
            <strong>{shelfMetrics.cached}</strong>
            <em>{caching ? '有缓存任务正在运行' : '离线内容可随时阅读'}</em>
          </span>
        </article>
        <article className={`shelf-overview-card ${shelfMetrics.interrupted > 0 ? 'needs-attention' : ''}`}>
          <span className="shelf-overview-icon"><Icon name={shelfMetrics.interrupted > 0 ? 'activity' : 'check'} /></span>
          <span>
            <small>需要处理</small>
            <strong>{shelfMetrics.interrupted}</strong>
            <em>{shelfMetrics.interrupted > 0 ? '点击对应书卡查看原因' : '缓存与目录更新正常'}</em>
          </span>
        </article>
      </section>

      <section className="shelf-filter-surface">
        {/* Primary Group Tabs */}
        <nav className="shelf-tabs shelf-group-tabs" aria-label={t('shelf.manageGroups', '书架分组')}>
        <button
          type="button"
          className={selectedGroup === 'all' ? 'active' : ''}
          onClick={() => setSelectedGroup('all')}
        >
          {t('common.all', '全部')}<small>{groupCounts.all}</small>
        </button>
        <button
          type="button"
          className={selectedGroup === '__ungrouped__' ? 'active' : ''}
          onClick={() => setSelectedGroup('__ungrouped__')}
        >
          {t('search.scopeUngrouped', '未分组')}<small>{groupCounts.ungrouped}</small>
        </button>
        {groups.map(g => (
          <button
            key={g.id}
            type="button"
            className={selectedGroup === g.name ? 'active' : ''}
            onClick={() => setSelectedGroup(g.name)}
          >
            {g.name}<small>{g.bookCount}</small>
          </button>
        ))}
        <button
          type="button"
          className="shelf-manage-group-btn"
          onClick={() => setManagingGroups(true)}
          title={t('shelf.manageGroups', '管理与创建分组')}
        >
          <Icon name="settings" />
          <span>{t('shelf.manageGroups', '管理分组')}</span>
        </button>
        </nav>

        {/* Secondary Status Filter Pills */}
        <div className="shelf-subfilter-bar">
          <div className="shelf-status-pills">
            {([
              ['all', t('common.all', '全部')],
              ['unread', t('shelf.statusUnread', '未读')],
              ['reading', t('shelf.statusReading', '在读')],
              ['finished', t('shelf.statusRead', '已读')],
            ] as const).map(([key, label]) => (
              <button
                key={key}
                type="button"
                className={`shelf-pill-btn ${statusFilter === key ? 'active' : ''}`}
                onClick={() => setStatusFilter(key)}
              >
                {label} ({statusCounts[key]})
              </button>
            ))}
          </div>
          <small className="shelf-filter-summary">当前显示 {visibleItems.length} 本</small>
        </div>
      </section>

      {message && <p className="form-error">{message}</p>}

      {refreshStatus && refreshStatus.total > 0 && (refreshStatus.state === 'running' || refreshStatus.failed > 0) && (
        <section className={`shelf-refresh-status ${refreshStatus.state}`} role="status" aria-live="polite">
          <div className="shelf-refresh-status-heading">
            <Icon name={refreshStatus.state === 'running' ? 'refresh' : 'activity'} className={refreshStatus.state === 'running' ? 'spin' : ''} />
            <strong>
              {refreshStatus.state === 'running'
                ? t('shelf.refreshingBooks', '正在刷新目录')
                : t('shelf.refreshCompletedWithFailures', '目录刷新完成')}
            </strong>
            <span>{refreshStatus.completed} / {refreshStatus.total}</span>
          </div>
          <div className="shelf-refresh-progress-track">
            <div
              className="shelf-refresh-progress-fill"
              style={{ width: `${Math.round((refreshStatus.completed / Math.max(1, refreshStatus.total)) * 100)}%` }}
            />
          </div>
          {refreshStatus.failed > 0 && (
            <div className="shelf-refresh-failures">
              {refreshStatus.items.filter(item => item.state === 'failed').slice(0, 4).map(item => (
                <span key={`${item.sourceId}\u0000${item.bookUrl}`} title={item.error || undefined}>
                  {item.name}{item.error ? `：${item.error}` : ''}
                </span>
              ))}
              {refreshStatus.failed > 4 && <span>+{refreshStatus.failed - 4}</span>}
            </div>
          )}
        </section>
      )}

      {items.length === 0 && !message ? (
        <section className="shelf-empty">
          <Icon name="book" />
          <h2>{t('shelf.emptyTitle', '书架还是空的')}</h2>
          <p>从搜书页加入书籍，或直接导入本地 TXT / EPUB。</p>
          <button
            type="button"
            className="shelf-import-btn"
            style={{ marginTop: '12px' }}
            disabled={uploading}
            onClick={() => fileInputRef.current?.click()}
          >
            <Icon name="upload" />
            <span>{uploading ? t('common.loading', '正在解析导入...') : t('shelf.importBook', '导入本地 TXT / EPUB')}</span>
          </button>
        </section>
      ) : visibleItems.length === 0 ? (
        <section className="shelf-empty">
          <Icon name="book" />
          <h2>{t('shelf.emptyFilterTitle', '当前分组与筛选下没有书籍')}</h2>
        </section>
      ) : (
        <section className="shelf-grid">
          {visibleItems.map(item => {
            const openItem = () => onOpenBook(item)
            const badge = cacheBadge(item)
            const isCaching = item.cacheState === 'caching'
            const percent = Math.min(100, Math.round((item.cachedChapters / Math.max(1, item.totalChapters || 1)) * 100))
            const itemKey = `${item.sourceId}\u0000${item.bookUrl}`
            const isSelected = selectedKeys.has(itemKey)
            const refreshItemStatus = refreshStatusByBook.get(itemKey)
            const isRefreshingItem = refreshItemStatus?.state === 'queued' || refreshItemStatus?.state === 'running'
            const readingTotal = item.catalogChapters || item.totalChapters || 0
            const readingChapter = readingTotal > 0
              ? item.isUnread && !item.isReadFinished
                ? 0
                : Math.min(readingTotal, item.chapterIndex == null ? 0 : item.chapterIndex + 1)
              : 0

            return (
              <article
                key={itemKey}
                className={`shelf-card ${batchMode ? 'batch-selectable' : ''} ${isSelected ? 'selected' : ''} ${isRefreshingItem ? 'is-refreshing' : ''} ${item.updateError ? 'has-update-error' : ''}`}
                onClick={batchMode ? () => toggleSelectKey(itemKey) : undefined}
              >
                {/* Upper Half: Large Cover directly opens reader */}
                <div
                  className="shelf-card-cover"
                  onClick={batchMode ? (e) => { e.stopPropagation(); toggleSelectKey(itemKey) } : openItem}
                  role="button"
                  tabIndex={0}
                  aria-label={batchMode ? t('shelf.selectBook', '选择 {{name}}', { name: item.name }) : `查看正文 ${item.name}`}
                >
                  {batchMode && (
                    <div className={`shelf-card-checkbox ${isSelected ? 'checked' : ''}`}>
                      {isSelected && <Icon name="check" />}
                    </div>
                  )}
                  <BookCover
                    coverKey={item.coverKey}
                    coverUrl={item.coverUrl}
                    name={item.name}
                    fallbackClassName="cover-fallback"
                  />
                  {/* 四类角标（本地 / 漫画 / 听书 / 小说）互斥，唯一产出点是 ShelfKindTag。
                      `local` 按身份判（`loc_book` / `local://`），与服务端 `book_kind='local'` 双保险。 */}
                  <ShelfKindTag bookKind={item.bookKind} local={isLocalBook(item)} />
                  {badge && <span className={`shelf-card-badge ${item.cacheState}`}>{badge}</span>}
                  {isRefreshingItem && (
                    <div className="shelf-card-refresh-overlay">
                      <ButtonSpinner size={20} />
                      <span>{refreshItemStatus?.state === 'running'
                        ? t('shelf.refreshingBook', '正在刷新目录')
                        : t('shelf.refreshQueued', '等待刷新')}
                      </span>
                    </div>
                  )}
                  {isCaching && (
                    <div className="shelf-card-progress-track">
                      <div className="shelf-card-progress-fill" style={{ width: `${percent}%` }} />
                    </div>
                  )}
                </div>

                {/* Middle: Title, Author, Reading Progress, Group Tag */}
                <div className="shelf-card-info">
                  <h3
                    className="shelf-card-name"
                    onClick={batchMode ? (e) => { e.stopPropagation(); toggleSelectKey(itemKey) } : openItem}
                    title={item.name}
                  >
                    {item.name}
                  </h3>
                  <p className="shelf-card-author">{item.author || t('common.unknownAuthor', '未知作者')}</p>
                  {item.latestChapterTitle && (
                    <p className="shelf-card-latest-chapter" title={item.latestChapterTitle}>
                      {t('shelf.latestChapterWithTitle', '最新：{{title}}', { title: item.latestChapterTitle })}
                    </p>
                  )}
                  {(item.cacheState === 'failed' || item.cacheState === 'paused') && (
                    <button
                      type="button"
                      className="shelf-card-cache-error"
                      onClick={() => dispatchShelfModal({ type: 'openManage', item })}
                      title={item.cacheError || t('shelf.cacheFailed', '缓存中断')}
                    >
                      <Icon name="activity" />
                      <span>{item.cacheError || t('shelf.cacheInterruptedNoReason', '缓存任务已中断')}</span>
                      <b>{t('shelf.handle', '处理')}</b>
                    </button>
                  )}
                  <div className="shelf-card-meta">
                    <span className={`shelf-meta-chapter ${item.isReadFinished ? 'completed' : ''}`}>
                      {item.isReadFinished
                        ? t('shelf.statusRead', '已读')
                        : item.isReading
                          ? t('shelf.statusReading', '在读')
                          : item.isUnread
                            ? t('shelf.statusUnread', '未读')
                            : item.completed
                              ? t('shelf.completed', '已读完')
                              : item.chapterIndex === undefined
                                ? t('shelf.justAdded', '刚加入书架')
                                : t('shelf.chapterAt', '第 {{count}} 章', { count: item.chapterIndex + 1 })}
                    </span>
                    {readingTotal > 0 && (
                      <span
                        className="shelf-meta-progress"
                        title={t('shelf.readingProgressLabel', '阅读进度')}
                      >
                        ({readingChapter}/{readingTotal})
                      </span>
                    )}
                    {item.groupName && (
                      <span className="shelf-card-group-tag" title={item.groupName}>
                        {item.groupName}
                      </span>
                    )}
                    {item.canUpdate === false && !isLocalBook(item) && (
                      <span className="shelf-card-update-disabled">{t('shelf.updatesPaused', '已停更')}</span>
                    )}
                    {item.updateError && (
                      <span className="shelf-card-update-error" title={t('shelf.lastRefreshFailed', '上次目录刷新失败，已保留原目录')}>
                        {t('shelf.refreshFailedShort', '更新失败')}
                      </span>
                    )}
                  </div>
                </div>

                {/* Bottom Action Section: Details / Export / Manage. Cover and title remain direct reader entries. */}
                {!batchMode && (
                  <div className="shelf-card-footer">
                    <button type="button" className="shelf-btn-detail" onClick={() => openItem()}>
                      <Icon name="book" />
                      <span>{t('shelf.continueReading', '继续阅读')}</span>
                    </button>
                    <button
                      type="button"
                      className="shelf-btn-manage"
                      onClick={() => dispatchShelfModal({ type: 'openManage', item })}
                      aria-label={t('shelf.moreActions', '更多操作: {{name}}', { name: item.name })}
                      title={t('shelf.moreActions', '更多操作')}
                    >
                      <Icon name="more" />
                    </button>
                  </div>
                )}
              </article>
            )
          })}
        </section>
      )}

      {/* Floating Batch Action Toolbar */}
      {batchMode && (
        <aside className="shelf-batch-bar" role="toolbar" aria-label={t('shelf.batchToolbar', '批量操作栏')}>
          <div className="shelf-batch-info">
            <strong>{t('common.selectedBooks', '已选 {{count}} 本', { count: selectedKeys.size })}</strong>
            <button
              type="button"
              className="subtle-button"
              onClick={selectedKeys.size === visibleItems.length ? deselectAll : selectAllVisible}
            >
              {selectedKeys.size === visibleItems.length && visibleItems.length > 0 ? t('shelf.deselectAll', '取消全选') : t('common.selectAllCurrent', '全选当前')}
            </button>
          </div>
          <div className="shelf-batch-buttons">
            <button
              type="button"
              className="shelf-batch-action-btn"
              disabled={selectedKeys.size === 0 || refreshRunning}
              onClick={() => void refreshBooks('selected')}
            >
              {refreshRunning ? <ButtonSpinner size={13} /> : <Icon name="refresh" />}
              <span>{t('shelf.refreshSelected', '更新目录')}</span>
            </button>
            <button
              type="button"
              className="shelf-batch-action-btn"
              disabled={selectedKeys.size === 0}
              onClick={() => setBatchMoving(true)}
            >
              <Icon name="bookmark" />
              <span>{t('shelf.batchMoveGroup', '移动分组')}</span>
            </button>
            <button
              type="button"
              className="shelf-batch-action-btn"
              disabled={selectedKeys.size === 0}
              onClick={() => void handleBatchMarkCompleted(true)}
            >
              <Icon name="check" />
              <span>{t('shelf.markRead', '标为已读')}</span>
            </button>
            <button
              type="button"
              className="shelf-batch-action-btn"
              disabled={selectedKeys.size === 0}
              onClick={() => void handleBatchMarkCompleted(false)}
            >
              <Icon name="refresh" />
              <span>{t('shelf.markReading', '标为在读')}</span>
            </button>
            <button
              type="button"
              className="shelf-batch-action-btn"
              disabled={selectedKeys.size === 0}
              onClick={() => void handleBatchReclean()}
            >
              <Icon name="sliders" />
              <span>{t('shelf.batchClean', '重洗规则')}</span>
            </button>
            <button
              type="button"
              className="shelf-batch-action-btn danger"
              disabled={selectedKeys.size === 0}
              onClick={() => void handleBatchDelete()}
            >
              <Icon name="close" />
              <span>{t('shelf.removeFromShelf', '移出书架')}</span>
            </button>
            <button
              type="button"
              className="shelf-batch-action-btn complete-btn"
              onClick={() => {
                setBatchMode(false)
                setSelectedKeys(new Set())
              }}
            >
              {t('common.ok', '完成')}
            </button>
          </div>
        </aside>
      )}

      {detailItem && (
        <ShelfBookDetailModal
          key={`${detailItem.sourceId}\u0000${detailItem.bookUrl}`}
          item={detailItem}
          onClose={() => setDetailItem(null)}
          onRead={() => {
            const target = detailItem
            setDetailItem(null)
            onOpenBook(target)
          }}
          onManage={() => {
            const target = detailItem
            setDetailItem(null)
            dispatchShelfModal({ type: 'openManage', item: target })
          }}
        />
      )}

      {/* Book Management Modal（一级）：只在 `manage` 层挂载。打开二级时它**不渲染**，
          但它在状态机里的 item 仍被保留 ⇒ 取消 / ESC / 点遮罩 / 清理执行完都能回到它 */}
      {managingItem && (
        <BookManageModal
          item={managingItem}
          groups={groups}
          onClose={() => dispatchShelfModal({ type: 'closeManage' })}
          onOpenDetail={() => {
            const target = managingItem
            dispatchShelfModal({ type: 'closeManage' })
            setDetailItem(target)
          }}
          onExport={() => {
            const target = managingItem
            dispatchShelfModal({ type: 'closeManage' })
            setExportingItem(target)
          }}
          onSwitchSource={() => {
            const target = managingItem
            dispatchShelfModal({ type: 'closeManage' })
            setSwitchingItem(target)
          }}
          onCache={chapterConcurrency => cache(managingItem, chapterConcurrency)}
          onCancelCache={() => {
            void cancelCache(managingItem)
            dispatchShelfModal({ type: 'updateItem', item: { ...managingItem, cacheState: 'failed', cacheError: t('shelf.cacheErrorCancelled', '已取消缓存') } })
          }}
          onSetCanUpdate={canUpdate => setCanUpdate(managingItem, canUpdate)}
          updateSettingBusy={updatingRefreshSettingKey === `${managingItem.sourceId}\u0000${managingItem.bookUrl}`}
          onToggleCompleted={() => setCompleted(managingItem, !managingItem.completed)}
          onUpdateInfo={updated => {
            setItems(values => values.map(v => v.sourceId === updated.sourceId && v.bookUrl === updated.bookUrl ? updated : v))
            dispatchShelfModal({ type: 'updateItem', item: updated })
            void load()
          }}
          // issue #66：这里**只叠加二级**，绝不关闭一级 —— 一级是哪本书由状态机保留，
          // 二级「取消」才能回到「书籍管理」（文案承诺的行为）。
          onClearCache={() => dispatchShelfModal({ type: 'openClearCacheScope' })}
          onRemove={() => remove(managingItem)}
        />
      )}

      {/* 「清除缓存」范围选择弹窗（二级）：与一级**互斥**挂载（同一时刻只渲染一层，不是嵌在
          一级的 modal-backdrop 里），且自带 portal。取消 / ESC / 点遮罩 / 执行完都只退一级 */}
      {clearingCacheItem && (
        <ClearCacheScopeModal
          item={clearingCacheItem}
          theme={theme}
          busy={clearingCache}
          busyScope={clearingScope}
          onClose={() => dispatchShelfModal({ type: 'closeClearCacheScope' })}
          onPick={scope => void clearCache(clearingCacheItem, scope)}
        />
      )}

      {/* Standalone Source Switch Modal for Shelf Book */}
      {switchingItem && (
        <SourceSwitchModal
          bookName={switchingItem.name}
          author={switchingItem.author}
          currentSourceId={switchingItem.sourceId}
          currentBookUrl={switchingItem.bookUrl}
          currentChapterIndex={switchingItem.chapterIndex}
          knownAlternateSources={switchingItem.alternateSources}
          onSwitch={handleSwitchShelfSource}
          onClose={() => setSwitchingItem(null)}
        />
      )}

      {exportingItem && (
        <BookExportModal item={exportingItem} onClose={() => setExportingItem(null)} />
      )}

      {/* Group Management Modal */}
      {managingGroups && (
        <GroupManageModal
          groups={groups}
          onClose={() => setManagingGroups(false)}
          onGroupsChanged={load}
        />
      )}

      {/* Batch Move Group Modal */}
      {batchMoving && (
        <BatchMoveGroupModal
          groups={groups}
          selectedCount={selectedKeys.size}
          onClose={() => setBatchMoving(false)}
          onSelectGroup={handleBatchMoveGroup}
        />
      )}
    </main>
  )
}

function App() {
  const { t } = useTranslation()
  const [ready, setReady] = useState(false)
  const [authenticated, setAuthenticated] = useState(false)
  const [settings, setSettings] = useState<ReaderSettings>(loadReaderSettings)
  const [page, setPage] = useState<Page>(pageFromHash)
  const [readerReturnPage, setReaderReturnPage] = useState<Page>('shelf')
  const [configImportOpen, setConfigImportOpen] = useState(false)
  const [dataRefreshVersion, setDataRefreshVersion] = useState(0)
  const [backgroundTaskCount, setBackgroundTaskCount] = useState(0)
  const [sources, setSources] = useState<SourceSummary[]>([])
  const [selected, setSelected] = useState<SourceSummary | null>(null)
  const [reader, setReader] = useState<{ book: OpenBook; index: number } | null>(() => {
    // Even evaluating `sessionStorage` can throw in a blocked privacy mode;
    // startup must recover to the shelf instead of crashing before React mounts.
    try {
      return loadMediaReaderState<{ book: OpenBook; index: number }>(sessionStorage, readerStorageKey)
    } catch {
      return null
    }
  })
  const search = useSearchStore()

  useEffect(() => {
    saveReaderSettings(settings)
    if (typeof document !== 'undefined') {
      document.documentElement.classList.remove('theme-light', 'theme-paper', 'theme-dark')
      document.documentElement.classList.add(`theme-${settings.theme}`)
      document.body.classList.remove('theme-light', 'theme-paper', 'theme-dark')
      document.body.classList.add(`theme-${settings.theme}`)
    }
  }, [settings])

  useEffect(() => {
    const handleOnline = () => {
      void flushOfflineProgress(async (item) => {
        await api.saveProgress(item.sourceId, item.bookUrl, item.chapterUrl, item.chapterIndex, item.scrollPosition)
      })
    }
    window.addEventListener('online', handleOnline)
    return () => window.removeEventListener('online', handleOnline)
  }, [])

  useEffect(() => {
    void api.session().then(async result => {
      setAuthenticated(result.authenticated)
      setCsrfToken(result.csrfToken ?? null)
      if (result.authenticated) {
        void api.sources().then(setSources).catch(() => undefined)
      }
    }).finally(() => setReady(true))
  }, [])

  useEffect(() => {
    const sync = () => setPage(pageFromHash())
    addEventListener('hashchange', sync)
    return () => removeEventListener('hashchange', sync)
  }, [])

  useEffect(() => {
    if (page !== 'shelf') setBackgroundTaskCount(0)
  }, [page])

  // 旧版本 sessionStorage 可能保存过小说阅读状态。载荷校验已在读取时移除无效会话；
  // 若用户仍停留在旧 #reader 哈希，这里退回书架，避免渲染空分支。
  useEffect(() => {
    if (page !== 'reader' || reader) return
    setPage('shelf')
    if (location.hash !== '#shelf') location.hash = '#shelf'
  }, [page, reader])

  const navigate = (next: Page) => {
    if (next === 'reader' && !reader) return
    location.hash = `#${next}`
    setPage(next)
  }

  const openReader = (book: OpenBook, index: number, origin: Page = 'library') => {
    // 打开正文不会隐式修改书架，避免阅读动作覆盖封面等书籍元数据。
    const value = { book, index }
    setReader(value)
    setReaderReturnPage(origin)
    sessionStorage.setItem(readerStorageKey, JSON.stringify(value))
    location.hash = '#reader'
    setPage('reader')
  }

  const openShelfItem = async (item: BookshelfItem) => {
    // 阅读器封面依次使用本地副本、兄弟书源地址和书架原地址。
    const fallbackCover = item.coverKey
      ? api.cover(item.coverKey)
      : (item.alternateSources?.find(s => s.coverUrl?.trim())?.coverUrl?.trim() || item.coverUrl || undefined)
    const safeDetails: BookDetails = {
      sourceId: item.sourceId,
      name: cleanTitle(item.name) || item.name,
      author: cleanAuthor(item.author) || item.author,
      coverUrl: fallbackCover,
      intro: undefined,
      tocUrl: item.tocUrl,
      variables: parseBookVariables(item.variable),
      bookKind: item.bookKind,
      alternateSources: item.alternateSources,
    }

    try {
      const [chapters, progress] = await Promise.all([
        api.chapters(safeDetails.sourceId, item.bookUrl, safeDetails.tocUrl, {
          name: safeDetails.name,
          author: safeDetails.author,
          tocUrl: safeDetails.tocUrl,
          bookKind: safeDetails.bookKind,
          variables: safeDetails.variables,
        }),
        api.progress(safeDetails.sourceId, item.bookUrl).catch(() => undefined),
      ])

      // 与手机端 bookProgress 文件夹合并：取「数据库」与「进度文件」中较新的一份。
      // 失败（文件夹不存在/网络异常）时静默退回数据库进度，绝不影响开书。
      let mergedProgress = progress
      try {
        const merged = await api.mergeProgress({
          sourceId: safeDetails.sourceId,
          bookUrl: item.bookUrl,
          chapters,
          bookKind: item.bookKind,
        })
        if (merged?.progress) mergedProgress = merged.progress
      } catch {
        // 忽略：进度文件同步是增强能力，不是开书的前置条件
      }

      const resumeIdx = mergedProgress?.chapterIndex ?? item.chapterIndex ?? 0
      openReader({
        details: safeDetails,
        bookUrl: item.bookUrl,
        chapters,
        bookKind: item.bookKind,
        progress: mergedProgress || (item.chapterIndex !== undefined ? {
          sourceId: item.sourceId,
          bookUrl: item.bookUrl,
          chapterUrl: chapters[resumeIdx]?.url || '',
          chapterIndex: resumeIdx,
          scrollPosition: item.scrollPosition ?? 0,
          updatedAt: item.lastReadAt,
        } : undefined),
      }, resumeIdx, 'shelf')
    } catch {
      // Offline / network fallback: allow entering reader so user can read local cached chapters
      const resumeIdx = item.chapterIndex ?? 0
      const fallbackChapters: Chapter[] = [
        { index: resumeIdx, title: t('shelf.chapterAt', '第 {{count}} 章', { count: resumeIdx + 1 }), url: item.tocUrl }
      ]
      openReader({
        details: safeDetails,
        bookUrl: item.bookUrl,
        chapters: fallbackChapters,
        progress: {
          sourceId: item.sourceId,
          bookUrl: item.bookUrl,
          chapterUrl: item.tocUrl,
          chapterIndex: resumeIdx,
          scrollPosition: item.scrollPosition ?? 0,
          updatedAt: item.lastReadAt,
        },
        bookKind: item.bookKind,
      }, resumeIdx, 'shelf')
      toast.warning(t('reader.slowSourceOfflineFallback', '书源网络较慢，已为您进入离线阅读模式'))
    }
  }

  const logout = async () => {
    try {
      await api.logout()
    } finally {
      setCsrfToken(null)
      setAuthenticated(false)
    }
  }

  if (!ready) return <main className={`app-loading theme-${settings.theme}`}><span>{t('common.openingReader', '正在准备服务...')}</span></main>
  if (!authenticated) {
    return (
      <div className={`app-shell theme-${settings.theme}`}>
        <ToastContainer />
        <PwaManager />
        <Login onLogin={() => {
          setAuthenticated(true)
          void api.sources().then(setSources).catch(() => undefined)
        }} />
        {/* 书源人工验证面板挂在 App shell 上：搜索/登录请求被 await 挂起时也要能看到并操作会话。 */}
        <VerificationPanel />
      </div>
    )
  }

  if (page === 'reader' && reader) {
    const closeReader = () => {
      navigate(readerReturnPage)
    }
    return (
      <div className={`app-shell theme-${settings.theme}`}>
        <ToastContainer />
        <TextReaderScreen openBook={reader.book} startIndex={reader.index} onClose={closeReader} theme={settings.theme} />
        <VerificationPanel />
      </div>
    )
  }

  return (
    <div className={`app-shell theme-${settings.theme}`}>
      <ToastContainer />
      <PwaManager />
      <AppHeader
        page={page}
        settings={settings}
        searching={search.loading}
        taskCount={backgroundTaskCount}
        onTaskCountChange={setBackgroundTaskCount}
        onSettingsChange={setSettings}
        onNavigate={navigate}
        onOpenConfigImport={() => setConfigImportOpen(true)}
        onLogout={() => void logout()}
      />
      <div className="app-main">
        <ErrorBoundary>
          {page === 'sources' ? (
            <SourcesPage key={`sources-${dataRefreshVersion}`} selected={selected} onSelect={setSelected} onSourcesChange={setSources} />
          ) : page === 'shelf' ? (
            <ShelfPage
              key={`shelf-${dataRefreshVersion}`}
              theme={settings.theme}
              onOpenBook={item => void openShelfItem(item)}
              onOpenTasks={() => navigate('devices')}
              onTaskCountChange={setBackgroundTaskCount}
            />
          ) : page === 'devices' ? (
            <main className="devices-page">
              <KindleDevicesModal theme={settings.theme} mode="page" />
            </main>
          ) : (
            <LibraryPage sources={sources} onRead={book => openReader(book, book.progress?.chapterIndex ?? 0)} />
          )}
        </ErrorBoundary>
      </div>
      {configImportOpen && (
        <ConfigImportModal
          theme={settings.theme}
          onClose={() => setConfigImportOpen(false)}
          onImported={() => {
            setDataRefreshVersion(version => version + 1)
            void api.sources().then(setSources).catch(() => undefined)
          }}
        />
      )}
      {/* 全局人工验证入口：只在服务端存在 manual 会话时出现，没有 pending 时不渲染任何浮层。 */}
      <VerificationPanel />
    </div>
  )
}

createRoot(document.getElementById('root')!).render(
  <ErrorBoundary>
    <App />
  </ErrorBoundary>
)
