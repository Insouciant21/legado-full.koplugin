import { lazy, Suspense, useEffect, useState } from 'react'
import { MantineProvider } from '@mantine/core'
import { useTranslation } from 'react-i18next'
import { api, BookDetails, BookshelfItem, Chapter, setCsrfToken, SourceSummary } from '../api'
import { AppHeader } from '../AppHeader'
import { pageFromPath, pathForPage, type AppPage } from '../appRoutes'
import { ConfigImportModal } from '../ConfigImportModal'
import { ErrorBoundary } from '../ErrorBoundary'
import { parseBookVariables } from '../lib/bookVariables'
import { Login } from '../Login'
import type { OpenBook } from '../openBook'
import { flushOfflineProgress, getShelfSnapshot } from '../offlineStorage'
import { PwaManager } from '../PwaManager'
import { loadMediaReaderState, loadReaderSettings, ReaderSettings, saveReaderSettings } from '../readerSettings'
import { cleanAuthor, cleanTitle } from '../searchFilters'
import { useSearchStore } from '../searchStore'
import { applyThemeClasses, legadoCssVariablesResolver, legadoTheme, mantineColorSchemeFor } from '../theme'
import { toast, ToastContainer } from '../Toast'
import { VerificationPanel } from '../VerificationPanel'
import '../i18n'

const LibraryPage = lazy(() => import('../features/library/LibraryPage'))
const SourcesPage = lazy(() => import('../features/sources/SourcesPage'))
const ShelfPage = lazy(() => import('../features/shelf/ShelfPage'))
const DevicesPage = lazy(() => import('../features/devices/DevicesPage'))
const ReaderPage = lazy(() => import('../features/reader/ReaderPage'))

type Page = AppPage
const readerStorageKey = 'legado-open-book-v1'
const PAGE_TITLES: Record<Page, string> = {
  library: '找书 · 阅读',
  shelf: '阅读 · 阅读',
  sources: '书源 · 阅读',
  devices: '设备与任务 · 阅读',
  reader: '阅读正文 · 阅读',
}


export default function App() {
  const { t } = useTranslation()
  const [ready, setReady] = useState(false)
  const [authenticated, setAuthenticated] = useState(false)
  const [settings, setSettings] = useState<ReaderSettings>(loadReaderSettings)
  const [page, setPage] = useState<Page>(() => pageFromPath(location.pathname, location.hash))
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
    applyThemeClasses(settings.theme)
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
    void api.session()
      .then(async result => {
        setAuthenticated(result.authenticated)
        setCsrfToken(result.csrfToken ?? null)
        if (result.authenticated) {
          void api.sources().then(setSources).catch(() => undefined)
        }
      })
      .catch(() => {
        // A cached shelf is enough for read-only access while the LAN server is
        // temporarily unreachable. The React pages keep write operations online.
        if (getShelfSnapshot() !== null) setAuthenticated(true)
      })
      .finally(() => setReady(true))
  }, [])

  useEffect(() => {
    const initial = pageFromPath(location.pathname, location.hash)
    const initialPath = pathForPage(initial)
    if (location.pathname !== initialPath || location.hash) {
      history.replaceState(null, '', initialPath)
    }

    const sync = () => {
      const routed = pageFromPath(location.pathname, location.hash)
      setPage(routed)
      if (location.hash) history.replaceState(null, '', pathForPage(routed))
    }
    addEventListener('popstate', sync)
    addEventListener('hashchange', sync)
    return () => {
      removeEventListener('popstate', sync)
      removeEventListener('hashchange', sync)
    }
  }, [])

  useEffect(() => {
    document.title = PAGE_TITLES[page]
  }, [page])

  useEffect(() => {
    if (page !== 'shelf') setBackgroundTaskCount(0)
  }, [page])

  // 旧版本 sessionStorage 可能保存过小说阅读状态。载荷校验已在读取时移除无效会话；
  // 若用户仍停留在旧 #reader 哈希，这里退回书架，避免渲染空分支。
  useEffect(() => {
    if (page !== 'reader' || reader) return
    const path = pathForPage('shelf')
    history.replaceState(null, '', path)
    setPage('shelf')
  }, [page, reader])

  const navigate = (next: Page) => {
    if (next === 'reader' && !reader) return
    const path = pathForPage(next)
    if (location.pathname !== path) history.pushState(null, '', path)
    setPage(next)
    window.scrollTo({ top: 0, behavior: 'instant' })
  }

  const rememberReader = (book: OpenBook, index: number) => {
    const value = { book, index }
    setReader(value)
    try {
      sessionStorage.setItem(readerStorageKey, JSON.stringify(value))
    } catch {
      // 隐私模式仍可继续当前阅读会话。
    }
  }

  const openReader = (book: OpenBook, index: number, origin: Page = 'library') => {
    // 打开正文不会隐式修改书架，避免阅读动作覆盖封面等书籍元数据。
    rememberReader(book, index)
    setReaderReturnPage(origin)
    const path = pathForPage('reader')
    if (location.pathname !== path) history.pushState(null, '', path)
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

  return (
    <MantineProvider
      theme={legadoTheme}
      cssVariablesResolver={legadoCssVariablesResolver}
      forceColorScheme={mantineColorSchemeFor(settings.theme)}
    >
      <ToastContainer />
      <PwaManager />
      {!ready ? (
        <main className={`app-loading theme-${settings.theme}`}>
          <span>{t('common.openingReader', '正在准备服务...')}</span>
        </main>
      ) : !authenticated ? (
        <div className={`theme-${settings.theme}`}>
          <Login
            onLogin={() => {
              setAuthenticated(true)
              void api.sources().then(setSources).catch(() => undefined)
            }}
          />
        </div>
      ) : page === 'reader' && reader ? (
        <div className={`theme-${settings.theme}`}>
          <Suspense fallback={<main className="app-loading"><span>{t('common.openingReader', '正在准备阅读器...')}</span></main>}>
            <ReaderPage
              book={reader.book}
              startIndex={reader.index}
              onClose={() => navigate(readerReturnPage)}
              onBookChange={rememberReader}
              source={sources.find(source => source.id === reader.book.details.sourceId)}
              theme={settings.theme}
            />
          </Suspense>
          <VerificationPanel />
        </div>
      ) : (
        <div className={`theme-${settings.theme}`}>
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
          >
            <ErrorBoundary>
              <Suspense fallback={<main className="app-loading"><span>{t('common.loading', '正在载入页面...')}</span></main>}>
                {page === 'sources' ? (
                  <SourcesPage key={`sources-${dataRefreshVersion}`} selected={selected} onSelect={setSelected} onSourcesChange={setSources} />
                ) : page === 'shelf' ? (
                  <ShelfPage
                    key={`shelf-${dataRefreshVersion}`}
                    theme={settings.theme}
                    sources={sources}
                    onOpenBook={item => void openShelfItem(item)}
                    onOpenTasks={() => navigate('devices')}
                    onTaskCountChange={setBackgroundTaskCount}
                  />
                ) : page === 'devices' ? (
                  <DevicesPage theme={settings.theme} />
                ) : (
                  <LibraryPage
                    sources={sources}
                    onRead={book => openReader(book, book.progress?.chapterIndex ?? 0)}
                    onOpenShelf={() => navigate('shelf')}
                  />
                )}
              </Suspense>
            </ErrorBoundary>
          </AppHeader>
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
          <VerificationPanel />
        </div>
      )}
    </MantineProvider>
  )
}
