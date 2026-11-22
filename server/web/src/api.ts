import {
  putOfflineChapter,
  getOfflineChapter,
  saveShelfSnapshot,
  getShelfSnapshot,
  enqueueOfflineProgress,
  flushOfflineProgress,
} from './offlineStorage'
import i18n, { getCurrentLocale } from './i18n'

export type SourceSummary = { id: string; name: string; url: string; group?: string; enabled: boolean; isJsSource: boolean; hasLogin: boolean; updatedAt: number; version: number }
export type SourceRecord = { id: string; json: string; version: number; updatedAt: number }
export type SearchResult = {
  sourceId: string
  name: string
  author?: string
  bookUrl: string
  coverUrl?: string
  intro?: string
  /** Android 分类标签（如“玄幻”）；bookKind 是前端分派屏幕用的 wire kind。 */
  kind?: string
  wordCount?: string
  lastChapter?: string
  tocUrl?: string
  variables?: Record<string, string>
  bookKind?: string
}
export type BookDetails = {
  sourceId: string
  name: string
  author?: string
  intro?: string
  coverUrl?: string
  tocUrl: string
  kind?: string
  wordCount?: string
  lastChapter?: string
  variables?: Record<string, string>
  bookKind?: string
  alternateSources?: SearchResult[]
}
export type Chapter = {
  index: number
  title: string
  url: string
  isVolume?: boolean
  isVip?: boolean
  isPay?: boolean
  tag?: string
  wordCount?: string
}
export type ReadingProgress = { sourceId: string; bookUrl: string; chapterUrl: string; chapterIndex: number; scrollPosition: number; positionStarted?: boolean; updatedAt: number; positionMs?: number | null; bookKind?: string }
/** 手机端进度文件（bookProgress/*.json）同步配置 */

export type ProgressMergeResponse = { source: 'file' | 'database'; progress?: ReadingProgress; fileFound: boolean; alignedIndex?: number }
export type BookshelfItem = { sourceId: string; bookUrl: string; name: string; author?: string; tocUrl: string; coverKey?: string; coverUrl?: string; chapterIndex?: number; scrollPosition?: number; lastReadAt: number; cachedChapters: number; totalChapters: number; catalogChapters: number; latestChapterTitle?: string | null; latestChapterTime: number; lastCheckTime: number; lastCheckCount: number; canUpdate: boolean; updateError: boolean; cacheState: 'idle' | 'pending' | 'caching' | 'ready' | 'failed' | 'paused'; cacheError?: string; completed: boolean; isUnread: boolean; isReading: boolean; isReadFinished: boolean; alternateSources?: SearchResult[]; groupName?: string; bookKind?: string; variable?: string }
export type BookshelfWrite = { sourceId: string; bookUrl: string; name: string; author?: string; tocUrl: string; coverUrl?: string; alternateSources?: SearchResult[]; groupName?: string; bookKind?: string; catalogChapters?: number }
export type BookshelfRefreshTarget = { sourceId: string; bookUrl: string }
export type BookshelfRefreshItemStatus = { sourceId: string; bookUrl: string; name: string; state: 'queued' | 'running' | 'succeeded' | 'failed'; error?: string | null; previousChapters: number; totalChapters: number; newChapters: number }
export type BookshelfRefreshStatus = { state: 'idle' | 'running' | 'completed'; total: number; completed: number; succeeded: number; failed: number; items: BookshelfRefreshItemStatus[] }
export type BookshelfExportRequest = {
  sourceId: string
  bookUrl: string
  format?: 'txt' | 'epub'
  parallel?: boolean
  useReplace?: boolean
  includeChapterTitle?: boolean
  epubScope?: string
  epubSize?: number
  charset?: string
  pushToKindle?: boolean
  kindleDeviceIds?: string[]
}
export type BookshelfExportFile = {
  fileId: string
  fileName: string
  contentType: string
  sizeBytes: number
  sha256: string
  downloadUrl: string
}
export type BookshelfExportStatus = {
  jobId: string
  sourceId: string
  bookUrl: string
  bookName: string
  format: 'txt' | 'epub'
  status: 'queued' | 'running' | 'ready' | 'failed'
  totalChapters: number
  selectedChapters: number
  processedChapters: number
  completedChapters: number
  failedChapters: number
  imageFailures: number
  chapterConcurrency: number
  bookConcurrency: number
  message: string
  files: BookshelfExportFile[]
  fileName?: string
  sizeBytes?: number
  sha256?: string
  downloadUrl?: string
  kindleDeliveryId?: string
  kindlePushState?: 'queued' | 'partial' | 'delivered' | 'canceled' | 'skipped' | 'failed'
  kindlePushMessage?: string
  createdAt: string
  updatedAt: string
}

export type KindleDevice = {
  device_id: string
  device_name: string
  last_seen_at?: string | null
  acked_cursor?: string | null
  revoked_at?: string | null
}

export type KindleDevicesResponse = { devices: KindleDevice[] }

export type KindlePairingCode = {
  pairing_code: string
  expires_at: string
}

export type KindlePushDelivery = {
  delivery_id: string
  book_name: string
  format: string
  state: 'queued' | 'partial' | 'delivered' | 'canceled'
  file_count: number
  total_bytes: number
  target_count: number
  delivered_count: number
  pending_count: number
  canceled_count: number
  created_at: string
  updated_at: string
}

export type KindlePushDeliveriesResponse = { deliveries: KindlePushDelivery[] }

export type KindleDraftChange = {
  operation: 'add_book' | 'delete_book' | 'change_source' | 'update_book' | string
  book_id: string
  title: string
}

export type KindleDraftResponse = {
  draft_version: string
  base_publication_id?: string | null
  changes: KindleDraftChange[]
}

export type KindlePublication = {
  publication_id: string
  draft_version: string
  published_at: string
}

export type KindleAutoPublishBlocker = {
  book_id: string
  title: string
  state: 'not_started' | 'idle' | 'pending' | 'caching' | 'ready' | 'partial' | 'failed' | 'paused' | string
  cached_chapters: number
  total_chapters: number
  last_error?: string | null
}

export type KindleAutoPublishStatus = {
  enabled: boolean
  state: 'disabled' | 'observing' | 'caching' | 'blocked' | 'waiting' | 'publishing' | 'failed' | string
  draft_version?: string | null
  changes: number
  blockers: KindleAutoPublishBlocker[]
  current_book_id?: string | null
  current_book_title?: string | null
  waiting_since?: string | null
  last_publication_id?: string | null
  last_published_at?: string | null
  last_error?: string | null
  next_retry_at?: string | null
}

export type KindleProgressPosition = {
  progress_version?: string | null
  chapter_id: string
  chapter_index: number
  chapter_progress: number
  device_id?: string | null
  device_name?: string | null
  recorded_at?: string | null
}

export type KindleProgressConflict = {
  conflict_id: string
  book_id: string
  title: string
  current?: KindleProgressPosition | null
  candidate: KindleProgressPosition
  binding_version?: string | null
  event_id?: string | null
  created_at: string
  status: 'unresolved' | 'resolved' | string
  resolved_at?: string | null
  resolution?: 'server' | 'kindle' | string | null
  resolved_progress_version?: string | null
}

export type KindleProgressConflictsResponse = {
  conflicts: KindleProgressConflict[]
}

export type KindleConflictResolutionResponse = {
  conflict_id: string
  resolution: 'server' | 'kindle'
  resolved_at: string
  progress?: KindleProgressPosition | null
}

// Safari momentum scrolling can schedule several saves while a production request is still in flight.
// Serialize saves per book so an older response cannot arrive after a newer position and overwrite it.
const progressSaveQueues = new Map<string, Promise<void>>()
export type BookshelfSourceSwitch = { oldSourceId: string; oldBookUrl: string; book: BookshelfWrite; alternateSources?: SearchResult[] }
export type BookGroup = { id: number; name: string; sortOrder: number; bookCount: number }
export type BookshelfBatchRequest = {
  action: 'move_group' | 'mark_completed' | 'delete'
  items: { sourceId: string; bookUrl: string }[]
  targetGroup?: string
  completed?: boolean
}
export type CoverUploadResponse = { coverKey: string; contentType: string; url: string }
export type ImportResponse = { imported: number; updated: number; skipped: number; errors: string[]; sourceGroups?: number }
export type BackupImportSummary = {
  sources: number
  sourcesUpdated: number
  rules: number
  rulesUpdated: number
  books: number
  booksUpdated: number
  progress: number
  skippedLocal: number
  coversFetched: number
  coversResourced: number
  coversFailed: number
  coversQueued: number
  bookmarks: number
  bookmarksSkipped: number
  sourceGroups: number
}
export type ExternalWebDavConfig = {
  url: string
  username: string
  password: string
  directory: string
}
export type ExternalWebDavBackup = {
  name: string
  href: string
  size: number
  modifiedAt: number
}
export type ExternalWebDavListResponse = {
  rootUrl: string
  files: ExternalWebDavBackup[]
}

/** 网络导入预览列表里的一条书源；`invalid` 表示该条注定无法导入（`reason` 说明原因）。 */
export type NetworkImportPreviewItem = {
  index: number
  name: string
  url: string
  status: 'new' | 'update' | 'invalid'
  reason?: string | null
}

/**
 * 网络导入预览结果。
 *
 * **只含元数据**：完整书源原文留在服务端内存缓存里，由 `token` 引用。
 * 因此 383 条 / 1.63 MB 的集合不会在浏览器与服务端之间来回搬运两趟。
 */
export type NetworkImportPreview = {
  token: string
  url: string
  total: number
  newCount: number
  updateCount: number
  invalidCount: number
  sources: NetworkImportPreviewItem[]
}
export type LocalBookImportItem = { filename: string; success: boolean; bookUrl?: string; name?: string; author?: string; totalChapters: number; error?: string }
export type LocalBookImportResponse = { total: number; imported: number; failed: number; results: LocalBookImportItem[] }
/** 单本本地书的重新解析结果。`status` 取 `reparsed` / `skipped` / `failed`。 */
export type LocalReparseItem = { bookUrl: string; name: string; chapters: number; status: 'reparsed' | 'skipped' | 'failed'; error?: string | null }
export type LocalReparseResponse = { total: number; reparsed: number; skipped: number; failed: number; chapters: number; items: LocalReparseItem[] }
export type SearchStreamEvent = {
  type: 'start' | 'results' | 'progress' | 'done' | 'error' | 'source_failed'
  totalSources: number
  completedSources: number
  matchedSources: number
  emptySources: number
  failedSources: number
  resultCount: number
  results: SearchResult[]
  message?: string
  sourceId?: string
  error?: string
}

/** `/books/*` 请求携带的未入架书籍上下文；字段与后端 BookRequest 扁平契约一致。 */
export type BookRequestContext = {
  name?: string
  author?: string
  tocUrl?: string
  bookKind?: string
  variables?: Record<string, string>
}

export type BatchSourceAction = 'enable' | 'disable' | 'delete' | 'set_group'
export type BatchSourceRequest = {
  action: BatchSourceAction
  ids: string[]
  group?: string
}

export type BatchSourceResponse = {
  ok: boolean
  affected: number
  action: string
  message?: string
}

/** 一个书源分组：`sourceCount` 是组内总数，`enabledCount` 是其中已启用的（搜索实际会用到的）。 */
export type SourceGroupSummary = {
  name: string
  sourceCount: number
  enabledCount: number
}

export type SourcePickerResponse = {
  items: SourceSummary[]
  total: number
}

export type SourceGroupMutationResponse = {
  ok: boolean
  affected: number
  message: string
}

/**
 * 「未分组」在搜索范围里的取值。
 *
 * 必须与服务端 `SourceGroupFilter.UNGROUPED` 一致：服务端据此翻译成
 * `source_group is null or trim(source_group) = ''`，而不是当成一个真的分组名。
 */
export const UNGROUPED_SOURCE_GROUP = '__ungrouped__'

export type SourceHealthCheckItem = {
  id: string
  name: string
  ok: boolean
  latencyMs: number
  statusCode: number
  statusCategory: 'valid' | 'slow' | 'failed' | 'blocked'
  error?: string
}

export type SourceHealthCheckResponse = {
  total: number
  successCount: number
  slowCount: number
  failedCount: number
  durationMs: number
  results: SourceHealthCheckItem[]
}


export type BookRecleanResponse = {
  sourceId: string
  bookUrl: string
  recleanedChapters: number
  totalChapters: number
}

export type BatchBookRecleanResponse = {
  totalRecleaned: number
  results: BookRecleanResponse[]
}

export type FlexChildStyle = {
  layout_flexGrow?: number
  layout_flexShrink?: number
  layout_alignSelf?: string
  layout_flexBasisPercent?: number
  layout_wrapBefore?: boolean
  layout_justifySelf?: string
}

export type SourceLoginUiItem = {
  name: string
  type: string
  action?: string
  chars?: (string | null)[]
  default?: string
  viewName?: string
  style?: FlexChildStyle
  key?: string
  hint?: string
  value?: string
  options?: string[]
  countdown?: number
}

export type SourceLoginUiResponse = {
  sourceId: string
  sourceName: string
  hasLogin: boolean
  loginUi: SourceLoginUiItem[]
  loginUrl?: string
  loginInfo: Record<string, string>
  loginHeader?: string
  sourceVariable?: string
}

export type SourceLoginActionResult = {
  success: boolean
  toastMessages: string[]
  openUrl?: string
  copyText?: string
  updatedLoginInfo?: Record<string, string>
  updatedLoginHeader?: string
  updatedVariable?: string
  reRenderUi: boolean
  error?: string
  bookRefresh?: SourceLoginBookRefresh
}

export type SourceLoginContext = {
  book: BookRequestContext & { sourceId: string; bookUrl: string }
  chapter?: Chapter
}

export type SourceLoginBookRefresh = {
  details?: BookDetails
  chapters?: Chapter[]
  tocUrl?: string
  content?: { title?: string; content: string }
  variables?: Record<string, string>
  errors?: string[]
}

export type SourceLoginCheckResult = {
  loggedIn: boolean
  message?: string
}

export type SourceBrowserSession = {
  token: string
  startUrl: string
  expiresInSeconds: number
  inlineOnly?: boolean
}

export type SourceBrowserCookies = {
  count: number
  domains: string[]
  cookies: Record<string, string>
}
export type SourceBrowserResult = {
  saved: boolean
  keys: number
}

/**
 * 书源人工验证会话（全局面板）。
 *
 * `mode` 区分人工/自动任务（面板只处理 `manual`，不能按标题文案猜测）；
 * `kind` 区分普通网页（page）与验证码（captcha，完成时应提交验证码文本）。
 * 该 DTO 与服务端 `SourceVerificationSession` 字段一一对应。
 */
export type SourceVerificationSession = {
  id: string
  sourceId: string
  url: string
  title: string
  state: 'queued' | 'loading' | 'interactive' | 'evaluating' | 'completed' | 'canceled' | 'error' | string
  mode: 'manual' | 'auto' | string
  kind: 'page' | 'captcha' | string
  error?: string | null
}

/** 人工验证操作使用远端视口的 CSS 像素。width/height 标明输入所对应的画面尺寸。 */
export type SourceVerificationInteraction =
  | { action: 'resize'; width: number; height: number }
  | { action: 'click'; x: number; y: number; width: number; height: number }
  | { action: 'type'; text: string }
  | { action: 'key'; key: string }
  | { action: 'scroll'; deltaX?: number; deltaY: number; x?: number; y?: number; width?: number; height?: number }
  | { action: 'back' }
  | { action: 'forward' }
  | { action: 'reload' }
  | { action: 'navigate'; text: string }

export type SourceVerificationResult = {
  url: string
  body: string
  status: number
  headers: Record<string, string[]>
}

const verificationPath = (sourceId: string, sessionId: string) =>
  `/api/sources/${encodeURIComponent(sourceId)}/verifications/${encodeURIComponent(sessionId)}`

const responseErrorMessage = async (response: Response) => {
  const body = await response.json().catch(() => null) as { message?: string; error?: { message?: string } } | null
  return body?.error?.message ?? body?.message ?? i18n.t('toast.requestFailed', '请求失败')
}

let csrfToken: string | null = null
export const setCsrfToken = (token: string | null) => { csrfToken = token }

export class ApiRequestError extends Error {
  constructor(message: string, public readonly status: number, public readonly code?: string) {
    super(message)
    this.name = 'ApiRequestError'
  }
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers)
  if (init.body) headers.set('Content-Type', 'application/json')
  if (init.method && !['GET', 'HEAD'].includes(init.method)) headers.set('X-CSRF-Token', csrfToken ?? '')
  headers.set('Accept-Language', getCurrentLocale())
  const response = await fetch(path, { ...init, headers, credentials: 'same-origin' })
  if (!response.ok) {
    const body = await response.json().catch(() => ({ message: response.statusText })) as { message?: string; error?: { message?: string; code?: string } }
    throw new ApiRequestError(body.error?.message ?? body.message ?? i18n.t('toast.requestFailed', '请求失败'), response.status, body.error?.code)
  }
  return response.status === 204 ? undefined as T : response.json() as Promise<T>
}

export const api = {
  session: () => request<{ authenticated: boolean; csrfToken?: string }>('/api/auth/session'),
  login: (password: string) => request<{ csrfToken: string }>('/api/auth/login', { method: 'POST', body: JSON.stringify({ password }) }),
  logout: () => request<void>('/api/auth/logout', { method: 'POST' }),
  sources: (query = '') => request<SourceSummary[]>(`/api/sources?q=${encodeURIComponent(query)}`),
  source: (id: string) => request<SourceRecord>(`/api/sources/${encodeURIComponent(id)}`),
  save: (id: string, json: string, version?: number) => request<SourceRecord>(`/api/sources/${encodeURIComponent(id)}`, { method: 'PUT', body: JSON.stringify({ json, version }) }),
  remove: (id: string) => request<void>(`/api/sources/${encodeURIComponent(id)}`, { method: 'DELETE' }),
  batchSources: (action: BatchSourceAction, ids: string[], group?: string) =>
    request<BatchSourceResponse>('/api/sources/batch', { method: 'POST', body: JSON.stringify({ action, ids, group }) }),
  healthCheckSources: (ids?: string[], timeoutMs = 5000) =>
    request<SourceHealthCheckResponse>('/api/sources/health-check', { method: 'POST', body: JSON.stringify({ ids, timeoutMs }) }),
  exportSources: (ids?: string[]) =>
    request<string[]>(`/api/sources/export${ids && ids.length > 0 ? `?${ids.map(id => `id=${encodeURIComponent(id)}`).join('&')}` : ''}`),
  /** 浏览器直接上传 Android Legado 备份 ZIP。 */
  importBackupFile: async (file: File): Promise<BackupImportSummary> => {
    const formData = new FormData()
    formData.append('file', file, file.name)
    const headers = new Headers({ 'Accept-Language': getCurrentLocale() })
    if (csrfToken) headers.set('X-CSRF-Token', csrfToken)
    const response = await fetch('/api/webdav/import/upload', {
      method: 'POST',
      headers,
      credentials: 'same-origin',
      body: formData,
    })
    if (!response.ok) {
      throw new ApiRequestError(await responseErrorMessage(response), response.status)
    }
    return response.json() as Promise<BackupImportSummary>
  },
  /** 读取任意外部 WebDAV 的 Android 备份列表；凭据仅用于本次请求。 */
  listExternalWebDavBackups: (connection: ExternalWebDavConfig) =>
    request<ExternalWebDavListResponse>('/api/webdav/import/external/list', {
      method: 'POST',
      body: JSON.stringify(connection),
    }),
  /** 从外部 WebDAV 下载并导入选中的 Android 备份。 */
  importExternalWebDavBackup: (connection: ExternalWebDavConfig, href: string) =>
    request<BackupImportSummary>('/api/webdav/import/external', {
      method: 'POST',
      body: JSON.stringify({ connection, href }),
    }),
  validate: (id: string) => request<{ valid: boolean; errors: string[]; warnings: string[] }>(`/api/sources/${encodeURIComponent(id)}/validate`, { method: 'POST' }),
  /** 网络导入第一步：服务端代抓 + 逐条试解析，只回元数据与一次性票据（避开跨域与体积搬运）。 */
  previewNetworkImport: (url: string) => request<NetworkImportPreview>('/api/sources/import-url/preview', { method: 'POST', body: JSON.stringify({ url }) }),
  /**
   * 本地书源文件预览：把文件原文交给服务端解析，拿回与网络导入**同一结构**的预览。
   *
   * 复用同一个票据（[commitNetworkImport]），因此本地与网络两条导入路径的
   * 判定口径与落库流程完全一致。
   */
  previewLocalSourceJson: (content: string, label: string) =>
    request<NetworkImportPreview>('/api/sources/import-json/preview', { method: 'POST', body: JSON.stringify({ content, label }) }),
  /** 网络导入第二步：按票据与勾选下标落库；`group` 为空表示不改动分组。 */
  commitNetworkImport: (token: string, selected: number[], group?: string | null) => request<ImportResponse>('/api/sources/import-url/commit', { method: 'POST', body: JSON.stringify({ token, selected, group: group ?? null }) }),
  /** 书源分组列表（不含「未分组」，它由前端用 UNGROUPED_SOURCE_GROUP 单独提供） */
  sourceGroups: () => request<SourceGroupSummary[]>('/api/source-groups'),
  /** 书库搜索范围选择器候选：按名称、地址或分组查询，服务端不截断匹配结果。 */
  sourcePicker: (query = '', groups: string[] = [], signal?: AbortSignal) => {
    const params = new URLSearchParams()
    if (query.trim()) params.set('q', query.trim())
    groups.filter(Boolean).forEach(group => params.append('group', group))
    const suffix = params.toString() ? `?${params.toString()}` : ''
    return request<SourcePickerResponse>(`/api/sources/picker${suffix}`, { signal })
  },
  /** 书源分组改名；目标分组已存在时等价于合并 */
  renameSourceGroup: (from: string, to: string) =>
    request<SourceGroupMutationResponse>('/api/source-groups/rename', { method: 'PUT', body: JSON.stringify({ from, to }) }),
  /** 删除书源分组：只把这些书源变为未分组，**不删除书源** */
  clearSourceGroup: (name: string) =>
    request<SourceGroupMutationResponse>(`/api/source-groups?name=${encodeURIComponent(name)}`, { method: 'DELETE' }),
  getSourceLoginUi: (sourceId: string) => request<SourceLoginUiResponse>(`/api/sources/${encodeURIComponent(sourceId)}/login-ui`),
  saveSourceLoginInfo: (sourceId: string, loginInfo: Record<string, string>) => request<{ ok: boolean }>(`/api/sources/${encodeURIComponent(sourceId)}/login-info`, { method: 'POST', body: JSON.stringify({ loginInfo }) }),
  saveSourceLoginHeader: (sourceId: string, loginHeader: string) => request<{ ok: boolean }>(`/api/sources/${encodeURIComponent(sourceId)}/login-header`, { method: 'POST', body: JSON.stringify({ loginHeader }) }),
  saveSourceCookie: (sourceId: string, cookie: string, url?: string) => request<{ ok: boolean; message?: string }>(`/api/sources/${encodeURIComponent(sourceId)}/login-cookie`, { method: 'POST', body: JSON.stringify({ cookie, url }) }),
  clearSourceLoginInfo: (sourceId: string) => request<{ ok: boolean }>(`/api/sources/${encodeURIComponent(sourceId)}/login-info`, { method: 'DELETE' }),
  clearSourceLoginHeader: (sourceId: string) => request<{ ok: boolean }>(`/api/sources/${encodeURIComponent(sourceId)}/login-header`, { method: 'DELETE' }),
  executeSourceLoginAction: async (sourceId: string, action: string, loginData: Record<string, string>, isLongClick = false, context?: SourceLoginContext) => {
    const response = await request<SourceLoginActionResult>(`/api/sources/${encodeURIComponent(sourceId)}/login-action`, {
      method: 'POST',
      body: JSON.stringify({ action, loginData, isLongClick, ...context }),
    })
    const fresh = response.bookRefresh?.content
    if (fresh && context?.chapter) {
      void putOfflineChapter(sourceId, context.book.bookUrl, context.chapter.url, fresh.title ?? null, fresh.content)
        .catch(() => undefined)
    }
    return response
  },
  checkSourceLogin: (sourceId: string) => request<SourceLoginCheckResult>(`/api/sources/${encodeURIComponent(sourceId)}/login-check`),
  createSourceBrowserSession: (sourceId: string, url?: string) => request<SourceBrowserSession>(`/api/sources/${encodeURIComponent(sourceId)}/browser/session`, { method: 'POST', body: JSON.stringify({ url }) }),
  closeSourceBrowserSession: (sourceId: string, token: string) => request<void>(`/api/sources/${encodeURIComponent(sourceId)}/browser/session?t=${encodeURIComponent(token)}`, { method: 'DELETE' }),
  sourceBrowserCookies: (sourceId: string) => request<SourceBrowserCookies>(`/api/sources/${encodeURIComponent(sourceId)}/browser/cookies`),
  sourceBrowserPageUrl: (sourceId: string, token: string, target: string) =>
    `/api/sources/${encodeURIComponent(sourceId)}/browser/page?t=${encodeURIComponent(token)}&u=${encodeURIComponent(target)}`,
  /** 书源 JS 生成的数据地址页面：交给服务端解码托管，避免超长 URL 触发请求行 8192 上限 */
  registerSourceBrowserInline: (sourceId: string, token: string, url: string) =>
    request<{ key: string }>(`/api/sources/${encodeURIComponent(sourceId)}/browser/inline`, { method: 'POST', body: JSON.stringify({ token, url }) }),
  /** 书源自生成页面的设置结果回传：服务端校验票据后写入源变量。 */
  saveSourceBrowserResult: (sourceId: string, token: string, settings: Record<string, unknown>, resultId = '') =>
    request<SourceBrowserResult>(`/api/sources/${encodeURIComponent(sourceId)}/browser/result`, { method: 'POST', body: JSON.stringify({ token, settings, resultId }) }),
  sourceBrowserInlineUrl: (sourceId: string, token: string, key: string) =>
    `/api/sources/${encodeURIComponent(sourceId)}/browser/page?t=${encodeURIComponent(token)}&i=${encodeURIComponent(key)}`,
  /**
   * 全局人工验证会话列表（服务端已只返回人工会话；这里再按 `mode` 兜底过滤）。
   * 自动 webView 抓取任务不得进入验证面板，也不应弹验证码。
   */
  verifications: (signal?: AbortSignal) => request<SourceVerificationSession[]>('/api/verifications', { signal }),
  verification: (sourceId: string, sessionId: string, signal?: AbortSignal) =>
    request<SourceVerificationSession>(verificationPath(sourceId, sessionId), { signal }),
  /** 实时浏览器 WebSocket。浏览器 WebSocket 不能自定义 CSRF header，因此用查询参数绑定当前登录会话。 */
  verificationStreamUrl: (sourceId: string, sessionId: string) =>
    `${verificationPath(sourceId, sessionId)}/stream?csrf=${encodeURIComponent(csrfToken ?? '')}`,
  /**
   * 会话截图：必须 `cache: 'no-store'` 拉取并转成一次性 blob URL，绝不进浏览器缓存，
   * 否则用户会对着旧画面点击，坐标全部错位。
   */
  verificationScreenshot: async (sourceId: string, sessionId: string, signal?: AbortSignal): Promise<Blob> => {
    const response = await fetch(`${verificationPath(sourceId, sessionId)}/screenshot`, {
      credentials: 'same-origin',
      cache: 'no-store',
      signal,
      headers: { Accept: 'image/png', 'Accept-Language': getCurrentLocale() },
    })
    if (!response.ok) throw new ApiRequestError(await responseErrorMessage(response), response.status)
    return response.blob()
  },
  /** 按截图像素坐标点击/输入/按键/滚动（见 [SourceVerificationInteraction]）。写请求由 request() 统一带 CSRF。 */
  verificationInteract: (sourceId: string, sessionId: string, interaction: SourceVerificationInteraction) =>
    request<void>(`${verificationPath(sourceId, sessionId)}/interact`, { method: 'POST', body: JSON.stringify(interaction) }),
  /** 手动完成会话；验证码会话必须把用户输入的验证码作为 `input` 提交。 */
  verificationComplete: (sourceId: string, sessionId: string, input?: string) =>
    request<SourceVerificationSession>(`${verificationPath(sourceId, sessionId)}/complete`, {
      method: 'POST',
      body: JSON.stringify({ input: input ?? null }),
    }),
  verificationCancel: (sourceId: string, sessionId: string) =>
    request<void>(`${verificationPath(sourceId, sessionId)}/cancel`, { method: 'POST', body: JSON.stringify({}) }),
  /** 会话结果：`202 Accepted` 表示仍在进行，返回 null（不是错误）。 */
  verificationResult: async (sourceId: string, sessionId: string, signal?: AbortSignal): Promise<SourceVerificationResult | null> => {
    const response = await fetch(`${verificationPath(sourceId, sessionId)}/result`, {
      credentials: 'same-origin',
      cache: 'no-store',
      signal,
      headers: { Accept: 'application/json', 'Accept-Language': getCurrentLocale() },
    })
    if (response.status === 202) return null
    if (!response.ok) throw new ApiRequestError(await responseErrorMessage(response), response.status)
    return response.json() as Promise<SourceVerificationResult>
  },
  search: (keyword: string, sourceIds?: string[], signal?: AbortSignal, groups?: string[], page = 1) =>
    request<SearchResult[]>('/api/search', { method: 'POST', body: JSON.stringify({ keyword, sourceIds, groups, page }), signal }),
  details: (sourceId: string, bookUrl: string, context?: BookRequestContext, signal?: AbortSignal) =>
    request<BookDetails>('/api/books/details', { method: 'POST', body: JSON.stringify({ sourceId, bookUrl, ...context }), signal }),
  chapters: (sourceId: string, bookUrl: string, tocUrl?: string, context?: BookRequestContext, signal?: AbortSignal) =>
    request<Chapter[]>('/api/books/chapters', { method: 'POST', body: JSON.stringify({ sourceId, bookUrl, tocUrl, ...context }), signal }),
  content: async (sourceId: string, chapterUrl: string, bookUrl?: string, signal?: AbortSignal, context?: BookRequestContext) => {
    try {
      const res = await request<{ title?: string; content: string }>('/api/books/content', {
        method: 'POST',
        body: JSON.stringify({
          sourceId,
          chapterUrl,
          bookUrl,
          bookName: context?.name,
          bookAuthor: context?.author,
          bookKind: context?.bookKind,
          variables: context?.variables,
        }),
        signal,
      })
      if (res?.content && bookUrl) {
        void putOfflineChapter(sourceId, bookUrl, chapterUrl, res.title || null, res.content)
      }
      return res
    } catch (err) {
      if (bookUrl) {
        const offline = await getOfflineChapter(sourceId, bookUrl, chapterUrl)
        if (offline && offline.content) {
          return { title: offline.title ?? undefined, content: offline.content }
        }
      }
      throw err
    }
  },
  /**
   * 换源时仅读取一章用于统计字数，不写入浏览器离线缓存。
   *
   * Android「加载字数」只计算当前章长度，不把预取内容保存到书架离线数据；
   * 因此不能复用会自动落 IndexedDB 的 `content()`。
   */
  contentPreview: (sourceId: string, chapterUrl: string, bookUrl: string, context?: BookRequestContext, signal?: AbortSignal) =>
    request<{ title?: string; content: string }>('/api/books/content', {
      method: 'POST',
      body: JSON.stringify({
        sourceId,
        chapterUrl,
        bookUrl,
        bookName: context?.name,
        bookAuthor: context?.author,
        bookKind: context?.bookKind,
        variables: context?.variables,
      }),
      signal,
    }),
  progress: (sourceId: string, bookUrl: string, signal?: AbortSignal) => request<ReadingProgress | undefined>(`/api/reading-progress?sourceId=${encodeURIComponent(sourceId)}&bookUrl=${encodeURIComponent(bookUrl)}`, { signal }),
  saveProgress: async (sourceId: string, bookUrl: string, chapterUrl: string, chapterIndex: number, scrollPosition: number, chapterTitle?: string, positionMs?: number, bookKind?: string) => {
    const progressItem = { sourceId, bookUrl, chapterUrl, chapterIndex, scrollPosition, positionMs, bookKind, updatedAt: Date.now() }
    const queueKey = `${sourceId}\u0000${bookUrl}`
    const previous = progressSaveQueues.get(queueKey) ?? Promise.resolve()
    const operation = previous.catch(() => undefined).then(async () => {
      enqueueOfflineProgress(progressItem)
      try {
        // chapterTitle 一并提交，服务端写 bookProgress 进度文件时直接用，免去回查目录缓存；
        // positionMs 只在有声书里带（服务端 `position_ms`，与手机端 durChapterPos 同语义）；
        // bookKind 用于区分小说/听书/漫画进度文件，避免同名书籍互相覆盖
        const res = await request<ReadingProgress>('/api/reading-progress', { method: 'PUT', body: JSON.stringify({ sourceId, bookUrl, chapterUrl, chapterIndex, scrollPosition, chapterTitle, positionMs, bookKind }) })
        void flushOfflineProgress(async (item) => {
          await request<ReadingProgress>('/api/reading-progress', { method: 'PUT', body: JSON.stringify(item) })
        })
        return res
      } catch {
        return { sourceId, bookUrl, chapterUrl, chapterIndex, scrollPosition, positionMs, bookKind, updatedAt: progressItem.updatedAt }
      }
    })
    const marker = operation.then(() => undefined, () => undefined)
    progressSaveQueues.set(queueKey, marker)
    try {
      return await operation
    } finally {
      if (progressSaveQueues.get(queueKey) === marker) progressSaveQueues.delete(queueKey)
    }
  },
  bookshelf: async () => {
    try {
      const list = await request<BookshelfItem[]>('/api/bookshelf')
      saveShelfSnapshot(list)
      return list
    } catch (err) {
      const snapshot = getShelfSnapshot()
      if (snapshot && snapshot.length > 0) {
        return snapshot as BookshelfItem[]
      }
      throw err
    }
  },
  addToBookshelf: (book: BookshelfWrite) => request<BookshelfItem>('/api/bookshelf', { method: 'POST', body: JSON.stringify(book) }),
  removeFromBookshelf: (sourceId: string, bookUrl: string) => request<void>(`/api/bookshelf?sourceId=${encodeURIComponent(sourceId)}&bookUrl=${encodeURIComponent(bookUrl)}`, { method: 'DELETE' }),
  startBookshelfExport: (data: BookshelfExportRequest) =>
    request<BookshelfExportStatus>('/api/bookshelf/export', { method: 'POST', body: JSON.stringify(data) }),
  bookshelfExportStatus: (jobId: string, signal?: AbortSignal) =>
    request<BookshelfExportStatus>(`/api/bookshelf/export/${encodeURIComponent(jobId)}`, { signal }),
  kindleDevices: () => request<KindleDevicesResponse>('/api/v1/devices'),
  createKindlePairingCode: (deviceName = 'Kindle') =>
    request<KindlePairingCode>('/api/v1/devices/pairing-codes', {
      method: 'POST',
      body: JSON.stringify({ device_name: deviceName }),
    }),
  revokeKindleDevice: (deviceId: string) =>
    request<void>(`/api/v1/devices/${encodeURIComponent(deviceId)}`, { method: 'DELETE' }),
  deleteKindleDevice: (deviceId: string) =>
    request<void>(`/api/v1/devices/${encodeURIComponent(deviceId)}?purge=true`, { method: 'DELETE' }),
  kindlePushDeliveries: () => request<KindlePushDeliveriesResponse>('/api/v1/push/deliveries'),
  kindleDraft: () => request<KindleDraftResponse>('/api/v1/draft'),
  kindleAutoPublishStatus: () => request<KindleAutoPublishStatus>('/api/v1/publish/auto-status'),
  retryKindleAutoPublish: () =>
    request<KindleAutoPublishStatus>('/api/v1/publish/auto-retry', { method: 'POST' }),
  publishKindleDraft: (draftVersion: string, requestId: string) =>
    request<KindlePublication>('/api/v1/publish', {
      method: 'POST',
      body: JSON.stringify({ request_id: requestId, draft_version: draftVersion }),
    }),
  kindleProgressConflicts: () => request<KindleProgressConflictsResponse>('/api/v1/progress/conflicts'),
  resolveKindleProgressConflict: (
    conflictId: string,
    resolution: 'server' | 'kindle',
    expectedProgressVersion?: string | null,
  ) => request<KindleConflictResolutionResponse>(
    `/api/v1/progress/conflicts/${encodeURIComponent(conflictId)}/resolve`,
    {
      method: 'POST',
      body: JSON.stringify({
        resolution,
        expected_progress_version: expectedProgressVersion ?? undefined,
      }),
    },
  ),
  cacheBookshelfBook: (sourceId: string, bookUrl: string, chapterConcurrency?: number) =>
    request<{ status: string }>('/api/bookshelf/cache', {
      method: 'POST',
      body: JSON.stringify({ sourceId, bookUrl, chapterConcurrency }),
    }),
  ignoreFailedEmptyChapter: (sourceId: string, bookUrl: string) =>
    request<{ status: string; title: string }>(
      `/api/bookshelf/cache/ignore-failed-empty?sourceId=${encodeURIComponent(sourceId)}&bookUrl=${encodeURIComponent(bookUrl)}`,
      { method: 'POST' },
    ),
  refreshBookshelf: (data: { books?: BookshelfRefreshTarget[]; onlyFinished?: boolean; concurrency?: number }) =>
    request<BookshelfRefreshStatus>('/api/bookshelf/refresh', {
      method: 'POST',
      body: JSON.stringify(data),
    }),
  bookshelfRefreshStatus: () => request<BookshelfRefreshStatus>('/api/bookshelf/refresh/status'),
  setBookshelfCanUpdate: (sourceId: string, bookUrl: string, canUpdate: boolean) =>
    request<BookshelfItem>('/api/bookshelf/update-enabled', {
      method: 'PUT',
      body: JSON.stringify({ sourceId, bookUrl, canUpdate }),
    }),
  clearBookCacheData: (sourceId: string, bookUrl: string) =>
    request<void>(`/api/bookshelf/cache?sourceId=${encodeURIComponent(sourceId)}&bookUrl=${encodeURIComponent(bookUrl)}&clearData=true`, { method: 'DELETE' }),
  cancelBookCache: (sourceId: string, bookUrl: string) => request<void>(`/api/bookshelf/cache?sourceId=${encodeURIComponent(sourceId)}&bookUrl=${encodeURIComponent(bookUrl)}`, { method: 'DELETE' }),
  setBookshelfCompleted: (sourceId: string, bookUrl: string, completed: boolean) => request<BookshelfItem>('/api/bookshelf/status', { method: 'PUT', body: JSON.stringify({ sourceId, bookUrl, completed }) }),
  recleanBookCache: (sourceId: string, bookUrl: string) =>
    request<BookRecleanResponse>('/api/bookshelf/reclean', { method: 'POST', body: JSON.stringify({ sourceId, bookUrl }) }),
  batchRecleanBookCache: (books: { sourceId: string; bookUrl: string }[]) =>
    request<BatchBookRecleanResponse>('/api/bookshelf/batch-reclean', { method: 'POST', body: JSON.stringify({ books }) }),
  /**
   * 用「存量原始文件」重新解析本地书，覆盖目录与正文缓存。
   *
   * 专治「解析器缺陷修复之前导入的本地书」：正文早就在导入时落库，解析器修好也不会自动变好。
   * 原始文件仍在 `local_books` 目录，因此无需重新上传；`local://<bookId>` 不变，进度与书签延续。
   * 不传参数则处理全部本地书。
   */
  reparseLocalBooks: (filter?: { sourceId?: string; bookUrl?: string }) =>
    request<LocalReparseResponse>('/api/bookshelf/reparse-local', { method: 'POST', body: JSON.stringify(filter ?? {}) }),
  // customVariable：书籍变量里的 `custom` 键（Legado 的 `putCustomVariable`）。
  // 省略 = 不动已有变量；传字符串 = 写入。有声书用它切换朗读者/音色。
  updateBookshelfInfo: (data: { sourceId: string; bookUrl: string; name: string; author?: string; coverUrl?: string; coverKey?: string; groupName?: string; alternateSources?: SearchResult[]; customVariable?: string }) => request<BookshelfItem>('/api/bookshelf/info', { method: 'PUT', body: JSON.stringify(data) }),
  switchBookshelfSource: (value: BookshelfSourceSwitch) => request<BookshelfItem>('/api/bookshelf/switch-source', { method: 'POST', body: JSON.stringify(value) }),
  importLocalBooks: async (files: File[]): Promise<LocalBookImportResponse> => {
    const formData = new FormData()
    for (const file of files) {
      formData.append('file', file, file.name)
    }
    const headers = new Headers()
    if (csrfToken) headers.set('X-CSRF-Token', csrfToken)
    const response = await fetch('/api/bookshelf/import-local', {
      method: 'POST',
      headers,
      credentials: 'same-origin',
      body: formData,
    })
    if (!response.ok) {
      const err = await response.json().catch(() => ({ message: response.statusText })) as { message?: string }
      throw new Error(err.message ?? i18n.t('shelf.importLocalBooksFailed', '本地书籍上传失败'))
    }
    return response.json() as Promise<LocalBookImportResponse>
  },
  bookGroups: () => request<BookGroup[]>('/api/bookshelf/groups'),
  createBookGroup: (name: string) => request<BookGroup>('/api/bookshelf/groups', { method: 'POST', body: JSON.stringify({ name }) }),
  renameBookGroup: (oldName: string, newName: string) => request<BookGroup>('/api/bookshelf/groups/rename', { method: 'PUT', body: JSON.stringify({ oldName, newName }) }),
  reorderBookGroups: (groupNames: string[]) => request<BookGroup[]>('/api/bookshelf/groups/order', { method: 'PUT', body: JSON.stringify({ groupNames }) }),
  deleteBookGroup: (name: string) => request<void>(`/api/bookshelf/groups?name=${encodeURIComponent(name)}`, { method: 'DELETE' }),
  updateBookGroup: (sourceId: string, bookUrl: string, groupName?: string | null) => request<BookshelfItem>('/api/bookshelf/group', { method: 'PUT', body: JSON.stringify({ sourceId, bookUrl, groupName }) }),
  batchBookshelf: (data: BookshelfBatchRequest) => request<{ affected: number }>('/api/bookshelf/batch', { method: 'POST', body: JSON.stringify(data) }),
  cover: (key: string) => `/api/covers/${encodeURIComponent(key)}`,
  uploadCover: async (file: File): Promise<CoverUploadResponse> => {
    const formData = new FormData()
    formData.append('file', file, file.name)
    const headers = new Headers()
    if (csrfToken) headers.set('X-CSRF-Token', csrfToken)
    const response = await fetch('/api/covers/upload', {
      method: 'POST',
      headers,
      credentials: 'same-origin',
      body: formData,
    })
    if (!response.ok) {
      const err = await response.json().catch(() => ({ message: response.statusText })) as { message?: string }
      throw new Error(err.message ?? i18n.t('shelf.uploadCoverFailed', '上传封面失败'))
    }
    return response.json() as Promise<CoverUploadResponse>
  },
  mergeProgress: (data: { sourceId: string; bookUrl: string; chapters: Chapter[]; bookKind?: string }) =>
    request<ProgressMergeResponse>('/api/progress-sync/merge', { method: 'POST', body: JSON.stringify(data) }),
}

/**
 * 流式搜索（WebSocket）。
 *
 * @param groups 书源分组列表（`UNGROUPED_SOURCE_GROUP` 表示未分组）；
 *   分组与 sourceIds 按并集搜索，重复书源由服务端去重。
 *   最后一个参数也接受旧版单个 group 字符串，便于已有换源流程平滑过渡。
 */
export function streamSearch(
  keyword: string,
  sourceIds: string[] | undefined,
  onEvent: (event: SearchStreamEvent) => void,
  onError: (message: string) => void,
  onClose: () => void,
  groups?: string[] | string,
  page = 1,
): WebSocket {
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:'
  const socket = new WebSocket(`${protocol}//${location.host}/api/search/stream?csrf=${encodeURIComponent(csrfToken ?? '')}`)
  let reported = false
  socket.addEventListener('open', () => queueMicrotask(() => {
    if (socket.readyState === WebSocket.OPEN) {
       const payload = typeof groups === 'string'
         ? (groups ? { keyword, sourceIds, group: groups, page } : { keyword, sourceIds, page })
         : (groups?.length ? { keyword, sourceIds, groups, page } : { keyword, sourceIds, page })
       socket.send(JSON.stringify(payload))
    }
  }))
  socket.addEventListener('message', event => {
    try { onEvent(JSON.parse(event.data) as SearchStreamEvent) }
    catch { reported = true; onError(i18n.t('search.invalidFormat', '搜索响应格式无效')) }
  })
  socket.addEventListener('error', () => { if (!reported) { reported = true; onError(i18n.t('search.connectionInterrupted', '搜索连接中断，请重试')) } })
  socket.addEventListener('close', () => { if (!reported) onClose() })
  return socket
}
