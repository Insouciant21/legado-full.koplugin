import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import {
  api,
  type BackupImportSummary,
  type ExternalWebDavBackup,
  type ExternalWebDavConfig,
} from './api'
import { ButtonSpinner } from './ButtonSpinner'
import { Icon } from './icons'

type Props = {
  theme: string
  onClose: () => void
  onImported: (summary: BackupImportSummary) => void
}

type Mode = 'file' | 'webdav'

const CONNECTION_STORAGE_KEY = 'legado-config-import-connection-v1'
const MAX_ZIP_BYTES = 256 * 1024 * 1024

function defaultConnection(): ExternalWebDavConfig {
  const fallback: ExternalWebDavConfig = {
    url: 'https://dav.jianguoyun.com/dav/',
    username: '',
    password: '',
    directory: 'legado',
  }
  try {
    const saved = JSON.parse(localStorage.getItem(CONNECTION_STORAGE_KEY) ?? 'null') as Partial<ExternalWebDavConfig> | null
    if (!saved) return fallback
    return {
      url: typeof saved.url === 'string' ? saved.url : fallback.url,
      username: typeof saved.username === 'string' ? saved.username : '',
      password: '',
      directory: typeof saved.directory === 'string' ? saved.directory : fallback.directory,
    }
  } catch {
    return fallback
  }
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B'
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

function formatDate(value: number): string {
  if (!value) return ''
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? '' : date.toLocaleString('zh-CN')
}

export function ConfigImportModal({ theme, onClose, onImported }: Props) {
  const { t } = useTranslation()
  const [mode, setMode] = useState<Mode>('file')
  const [selectedFile, setSelectedFile] = useState<File | null>(null)
  const [connection, setConnection] = useState<ExternalWebDavConfig>(defaultConnection)
  const [files, setFiles] = useState<ExternalWebDavBackup[]>([])
  const [rootUrl, setRootUrl] = useState('')
  const [busy, setBusy] = useState('')
  const [error, setError] = useState('')
  const [summary, setSummary] = useState<BackupImportSummary | null>(null)

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [onClose])

  const updateConnection = (patch: Partial<ExternalWebDavConfig>) => {
    setConnection(previous => {
      const next = { ...previous, ...patch }
      try {
        localStorage.setItem(CONNECTION_STORAGE_KEY, JSON.stringify({
          url: next.url,
          username: next.username,
          directory: next.directory,
        }))
      } catch {
        // Private browsing can reject storage without preventing the import.
      }
      return next
    })
  }

  const finishImport = (result: BackupImportSummary) => {
    setSummary(result)
    setError('')
    onImported(result)
  }

  const importFile = async () => {
    if (!selectedFile) {
      setError(t('webdav.chooseZipFirst', '请先选择备份 ZIP'))
      return
    }
    if (selectedFile.size > MAX_ZIP_BYTES) {
      setError(t('webdav.zipTooLarge', '备份 ZIP 超过 256 MiB'))
      return
    }
    if (!window.confirm(t('webdav.confirmFileImport', {
      name: selectedFile.name,
      defaultValue: `导入“${selectedFile.name}”中的 Android 配置吗？现有数据会按 Android 的合并规则更新。`,
    }))) return
    setBusy('file')
    setSummary(null)
    setError('')
    try {
      finishImport(await api.importBackupFile(selectedFile))
    } catch (importError) {
      setError(errorMessage(importError, t('webdav.backupImportFailed', '备份导入失败')))
    } finally {
      setBusy('')
    }
  }

  const loadRemoteFiles = async () => {
    if (!connection.url.trim()) {
      setError(t('webdav.urlRequired', '请填写 WebDAV 地址'))
      return
    }
    setBusy('list')
    setError('')
    setSummary(null)
    try {
      const result = await api.listExternalWebDavBackups(connection)
      setFiles(result.files)
      setRootUrl(result.rootUrl)
    } catch (listError) {
      setFiles([])
      setRootUrl('')
      setError(errorMessage(listError, t('webdav.readStatusFailed', '读取 WebDAV 失败')))
    } finally {
      setBusy('')
    }
  }

  const importRemoteFile = async (file: ExternalWebDavBackup) => {
    if (!window.confirm(t('webdav.confirmRemoteImport', {
      name: file.name,
      defaultValue: `从 WebDAV 导入“${file.name}”吗？现有数据会按 Android 的合并规则更新。`,
    }))) return
    setBusy(file.href)
    setSummary(null)
    setError('')
    try {
      finishImport(await api.importExternalWebDavBackup(connection, file.href))
    } catch (importError) {
      setError(errorMessage(importError, t('webdav.backupImportFailed', '备份导入失败')))
    } finally {
      setBusy('')
    }
  }

  return (
    <div className={`modal-backdrop config-import-backdrop theme-${theme}`} onClick={onClose}>
      <section
        className="config-import-modal"
        role="dialog"
        aria-modal="true"
        aria-label={t('header.webdavTitle', 'Android 备份导入')}
        onClick={event => event.stopPropagation()}
      >
        <header className="config-import-header">
          <div>
            <span className="section-kicker">{t('webdav.sectionKicker', 'Android 备份导入')}</span>
            <h2>{t('header.webdavTitle', 'Android 备份导入')}</h2>
            <p>{t('webdav.importIntro', '从本地 ZIP 或任意外部 WebDAV 恢复书源、规则、书架、进度、分组和书签。')}</p>
          </div>
          <button type="button" className="subtle-button close-btn" onClick={onClose} aria-label={t('common.close', '关闭')}>
            <Icon name="close" />
          </button>
        </header>

        <div className="config-import-tabs" role="tablist" aria-label={t('webdav.importSources', '导入来源')}>
          <button
            type="button"
            role="tab"
            aria-selected={mode === 'file'}
            className={mode === 'file' ? 'active' : ''}
            onClick={() => { setMode('file'); setError(''); setSummary(null) }}
          >
            <Icon name="importFile" />
            <span>{t('webdav.localZip', '本地 ZIP')}</span>
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={mode === 'webdav'}
            className={mode === 'webdav' ? 'active' : ''}
            onClick={() => { setMode('webdav'); setError(''); setSummary(null) }}
          >
            <Icon name="cloudDownload" />
            <span>{t('webdav.externalWebdav', '外部 WebDAV')}</span>
          </button>
        </div>

        <div className="config-import-body">
          <p className="config-import-support-note">
            {t('webdav.supportedData', '当前会导入：书源及分组、替换规则、在线书架、阅读进度、书架分组和书签。手机本机文件会被跳过。')}
          </p>

          {mode === 'file' ? (
            <section className="config-import-panel" role="tabpanel">
              <div className="config-import-file-picker">
                <div className="config-import-file-icon"><Icon name="file" /></div>
                <div>
                  <strong>{selectedFile?.name ?? t('webdav.chooseZip', '选择一个 Android 备份 ZIP')}</strong>
                  <small>{selectedFile
                    ? `${formatBytes(selectedFile.size)} · ${t('webdav.readyToImport', '可以导入')}`
                    : t('webdav.zipOnlyWarning', '只支持上传 Android Legado 备份 ZIP。')}</small>
                </div>
                <label className={`subtle-button config-import-file-button ${busy ? 'disabled' : ''}`}>
                  <Icon name="upload" />
                  <span>{t('webdav.chooseFile', '选择文件')}</span>
                  <input
                    type="file"
                    accept=".zip,application/zip,application/x-zip-compressed"
                    disabled={Boolean(busy)}
                    onChange={event => {
                      setSelectedFile(event.target.files?.[0] ?? null)
                      setError('')
                      setSummary(null)
                      event.target.value = ''
                    }}
                  />
                </label>
              </div>
              <button type="button" className="primary-button config-import-submit" disabled={!selectedFile || Boolean(busy)} onClick={() => void importFile()}>
                {busy === 'file' ? <ButtonSpinner size={14} /> : <Icon name="importFile" />}
                <span>{busy === 'file' ? t('webdav.importing', '导入中…') : t('webdav.startImport', '开始导入')}</span>
              </button>
            </section>
          ) : (
            <section className="config-import-panel" role="tabpanel">
              <div className="config-import-fields">
                <label>
                  <span>{t('webdav.url', 'WebDAV 地址')}</span>
                  <input
                    type="url"
                    value={connection.url}
                    placeholder="https://dav.jianguoyun.com/dav/"
                    onChange={event => updateConnection({ url: event.target.value })}
                  />
                </label>
                <div className="config-import-field-row">
                  <label>
                    <span>{t('webdav.username', '用户名')}</span>
                    <input
                      type="text"
                      autoComplete="username"
                      value={connection.username}
                      onChange={event => updateConnection({ username: event.target.value })}
                    />
                  </label>
                  <label>
                    <span>{t('webdav.password', '密码')}</span>
                    <input
                      type="password"
                      autoComplete="current-password"
                      value={connection.password}
                      onChange={event => updateConnection({ password: event.target.value })}
                    />
                  </label>
                </div>
                <label>
                  <span>{t('webdav.directory', '子目录')}</span>
                  <input
                    type="text"
                    value={connection.directory}
                    placeholder="legado"
                    onChange={event => updateConnection({ directory: event.target.value })}
                  />
                </label>
              </div>
              <p className="config-import-credential-note">
                {t('webdav.credentialNote', 'WebDAV 密码只用于本次请求，不会保存到服务器；地址、用户名和子目录会保存在当前浏览器。')}
              </p>
              <button type="button" className="primary-button config-import-submit" disabled={Boolean(busy)} onClick={() => void loadRemoteFiles()}>
                {busy === 'list' ? <ButtonSpinner size={14} /> : <Icon name="refresh" />}
                <span>{busy === 'list' ? t('webdav.loadingDirectory', '正在读取备份目录…') : t('webdav.readBackups', '读取备份列表')}</span>
              </button>
              {rootUrl && (
                <p className="config-import-root" title={rootUrl}>
                  {t('webdav.scanningDirectory', '扫描目录')}：<code>{rootUrl}</code>
                </p>
              )}
              <div className="config-import-backup-list">
                {files.map(file => (
                  <article key={file.href}>
                    <div className="config-import-backup-icon"><Icon name="file" /></div>
                    <div>
                      <strong title={file.name}>{file.name}</strong>
                      <small>{formatBytes(file.size)}{file.modifiedAt ? ` · ${formatDate(file.modifiedAt)}` : ''}</small>
                    </div>
                    <button
                      type="button"
                      className="subtle-button"
                      disabled={Boolean(busy)}
                      onClick={() => void importRemoteFile(file)}
                    >
                      {busy === file.href ? <ButtonSpinner size={13} /> : <Icon name="importFile" />}
                      <span>{busy === file.href ? t('webdav.importing', '导入中…') : t('common.import', '导入')}</span>
                    </button>
                  </article>
                ))}
                {rootUrl && files.length === 0 && (
                  <p className="config-import-empty">{t('webdav.noBackups', '该目录下没有 backup 开头的 ZIP 备份。')}</p>
                )}
              </div>
            </section>
          )}

          {error && <p className="form-error config-import-error" role="alert">{error}</p>}

          {summary && (
            <section className="config-import-summary" aria-live="polite">
              <header>
                <div className="config-import-success-icon"><Icon name="check" /></div>
                <div>
                  <strong>{t('webdav.importComplete', '配置导入完成')}</strong>
                  <small>{t('webdav.importCompleteHint', '书源、书架和分组已在后台刷新。')}</small>
                </div>
              </header>
              <div className="config-import-counts">
                <span>{t('webdav.sourcesCount', '书源')} <b>{summary.sources + summary.sourcesUpdated}</b></span>
                <span>{t('webdav.rulesCount', '替换规则')} <b>{summary.rules + summary.rulesUpdated}</b></span>
                <span>{t('webdav.booksCount', '书籍')} <b>{summary.books + summary.booksUpdated}</b></span>
                <span>{t('webdav.progressCount', '阅读进度')} <b>{summary.progress}</b></span>
                <span>{t('webdav.bookmarksCount', '书签')} <b>{summary.bookmarks}</b></span>
                <span>{t('webdav.skippedLocalCount', '跳过本机书')} <b>{summary.skippedLocal}</b></span>
              </div>
              {(summary.coversQueued > 0 || summary.coversFailed > 0) && (
                <p>
                  {summary.coversQueued > 0 && t('webdav.coversQueued', '{{count}} 本书的封面已转入后台补抓。', { count: summary.coversQueued })}
                  {summary.coversFailed > 0 && t('webdav.coversFailed', ' {{count}} 张封面补抓失败，不影响阅读。', { count: summary.coversFailed })}
                </p>
              )}
            </section>
          )}
        </div>

        <footer className="config-import-footer">
          <span>{t('webdav.safeMergeHint', '导入采用增量合并，不删除 Server 中备份包未包含的数据。')}</span>
          <button type="button" className="subtle-button" onClick={onClose}>{t('common.close', '关闭')}</button>
        </footer>
      </section>
    </div>
  )
}
