import { useEffect, useState } from 'react'
import { api, BookshelfExportRequest, BookshelfExportStatus, BookshelfItem, KindleDevice, KindlePushDelivery } from './api'
import { Icon } from './icons'

type Props = {
  item: BookshelfItem
  onClose: () => void
}

export function BookExportModal({ item, onClose }: Props) {
  const [format, setFormat] = useState<'txt' | 'epub'>('epub')
  const [parallel, setParallel] = useState(false)
  const [useReplace, setUseReplace] = useState(true)
  const [includeChapterTitle, setIncludeChapterTitle] = useState(true)
  const [epubScope, setEpubScope] = useState('')
  const [epubSize, setEpubSize] = useState(1)
  const [charset, setCharset] = useState('UTF-8')
  const [job, setJob] = useState<BookshelfExportStatus | null>(null)
  const [starting, setStarting] = useState(false)
  const [error, setError] = useState('')
  const [devices, setDevices] = useState<KindleDevice[]>([])
  const [devicesLoading, setDevicesLoading] = useState(true)
  const [pushToKindle, setPushToKindle] = useState(false)
  const [selectedDeviceIds, setSelectedDeviceIds] = useState<string[]>([])
  const [pushDelivery, setPushDelivery] = useState<KindlePushDelivery | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    void api.kindleDevices()
      .then(result => {
        if (controller.signal.aborted) return
        const active = result.devices.filter(device => !device.revoked_at)
        setDevices(active)
        let stored: string | null = null
        try {
          stored = window.localStorage.getItem('legado-kindle-push-enabled')
        } catch {
          stored = null
        }
        const preferred = stored === null ? true : stored === '1'
        setPushToKindle(active.length > 0 && preferred)
        setSelectedDeviceIds(active.map(device => device.device_id))
      })
      .catch(() => {
        if (!controller.signal.aborted) setDevices([])
      })
      .finally(() => {
        if (!controller.signal.aborted) setDevicesLoading(false)
      })
    return () => controller.abort()
  }, [])

  useEffect(() => {
    if (!job || job.status === 'ready' || job.status === 'failed') return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      void api.bookshelfExportStatus(job.jobId, controller.signal)
        .then(setJob)
        .catch(err => {
          if (!controller.signal.aborted) {
            const message = err instanceof Error ? err.message : '查询导出进度失败'
            setError(message)
            setJob(current => current ? { ...current, status: 'failed', message } : current)
          }
        })
    }, 800)
    return () => {
      window.clearTimeout(timer)
      controller.abort()
    }
  }, [job])

  useEffect(() => {
    if (!job?.kindleDeliveryId || (job.kindlePushState !== 'queued' && job.kindlePushState !== 'partial')) return
    let active = true
    let timer = 0
    const poll = async () => {
      try {
        const result = await api.kindlePushDeliveries()
        if (!active) return
        const current = result.deliveries.find(item => item.delivery_id === job.kindleDeliveryId)
        if (current) setPushDelivery(current)
        if (!current || current.state === 'queued' || current.state === 'partial') {
          timer = window.setTimeout(() => void poll(), 3000)
        }
      } catch {
        if (active) timer = window.setTimeout(() => void poll(), 5000)
      }
    }
    void poll()
    return () => {
      active = false
      window.clearTimeout(timer)
    }
  }, [job?.kindleDeliveryId, job?.kindlePushState])

  const start = async () => {
    if (starting) return
    setStarting(true)
    setError('')
    setJob(null)
    const request: BookshelfExportRequest = {
      sourceId: item.sourceId,
      bookUrl: item.bookUrl,
      format,
      parallel,
      useReplace,
      includeChapterTitle,
      epubSize,
      charset,
      ...(format === 'epub' && epubScope.trim() ? { epubScope: epubScope.trim() } : {}),
      ...(format === 'epub' && pushToKindle && selectedDeviceIds.length > 0
        ? { pushToKindle: true, kindleDeviceIds: selectedDeviceIds }
        : {}),
    }
    try {
      setJob(await api.startBookshelfExport(request))
    } catch (err) {
      setError(err instanceof Error ? err.message : '启动导出失败')
    } finally {
      setStarting(false)
    }
  }

  const progress = job && job.selectedChapters > 0
    ? Math.min(100, Math.round(job.processedChapters / job.selectedChapters * 100))
    : 0

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <section className="export-modal" onClick={event => event.stopPropagation()} role="dialog" aria-modal="true" aria-label={`导出《${item.name}》`}>
        <header className="export-modal-header">
          <div>
            <span className="section-kicker">下载与导出</span>
            <h2>{item.name}</h2>
            <p>{item.author || '未知作者'}</p>
          </div>
          <button type="button" className="subtle-button close-btn" onClick={onClose} aria-label="关闭">
            <Icon name="close" />
          </button>
        </header>

        <div className="export-form">
          <label>
            <span>格式</span>
            <select
              value={format}
              onChange={event => {
                const next = event.target.value as 'txt' | 'epub'
                setFormat(next)
                if (next === 'txt') setPushToKindle(false)
              }}
              disabled={Boolean(job && !['ready', 'failed'].includes(job.status))}
            >
              <option value="epub">EPUB 2.0</option>
              <option value="txt">TXT</option>
            </select>
          </label>
          {format === 'txt' ? (
            <>
              <label>
                <span>编码</span>
                <select value={charset} onChange={event => setCharset(event.target.value)}>
                  <option value="UTF-8">UTF-8</option>
                  <option value="GB18030">GB18030</option>
                  <option value="GBK">GBK</option>
                  <option value="UTF-16LE">UTF-16LE</option>
                </select>
              </label>
              <label className="export-check">
                <input type="checkbox" checked={includeChapterTitle} onChange={event => setIncludeChapterTitle(event.target.checked)} />
                <span>包含章节标题</span>
              </label>
            </>
          ) : (
            <div className="export-epub-grid">
              <label>
                <span>章节范围（可空）</span>
                <input value={epubScope} onChange={event => setEpubScope(event.target.value)} placeholder="例如 1-20,25,30-40" />
              </label>
              <label>
                <span>每个文件章节数</span>
                <input type="number" min={1} value={epubSize} onChange={event => setEpubSize(Math.max(1, Number(event.target.value) || 1))} />
              </label>
            </div>
          )}
          <label className="export-check">
            <input type="checkbox" checked={parallel} onChange={event => setParallel(event.target.checked)} />
            <span>章节并发下载（最多 9 章）</span>
          </label>
          <label className="export-check">
            <input type="checkbox" checked={useReplace} onChange={event => setUseReplace(event.target.checked)} />
            <span>应用正文与标题净化规则</span>
          </label>
          <section className="export-kindle-push">
            <label className="export-check">
              <input
                type="checkbox"
                checked={format === 'epub' && pushToKindle}
                disabled={format !== 'epub' || devicesLoading || devices.length === 0}
                onChange={event => {
                  const checked = event.target.checked
                  setPushToKindle(checked)
                  try {
                    window.localStorage.setItem('legado-kindle-push-enabled', checked ? '1' : '0')
                  } catch {
                    // The choice still applies to this export when storage is unavailable.
                  }
                }}
              />
              <span>导出完成后自动推送到 Kindle</span>
            </label>
            {format !== 'epub' ? (
              <small>Kindle 推送仅支持 EPUB。</small>
            ) : devicesLoading ? (
              <small>正在检查配对设备…</small>
            ) : devices.length === 0 ? (
              <small>还没有配对设备，请前往“设备与任务”完成配对。</small>
            ) : devices.length > 1 && pushToKindle ? (
              <div className="export-kindle-devices">
                {devices.map(device => (
                  <label key={device.device_id} className="export-check compact">
                    <input
                      type="checkbox"
                      checked={selectedDeviceIds.includes(device.device_id)}
                      onChange={event => {
                        setSelectedDeviceIds(current => event.target.checked
                          ? [...new Set([...current, device.device_id])]
                          : current.filter(id => id !== device.device_id))
                      }}
                    />
                    <span>{device.device_name}</span>
                  </label>
                ))}
              </div>
            ) : (
              <small>{devices[0]?.device_name} 下次联网时会自动领取。</small>
            )}
          </section>
        </div>

        {error && <p className="form-error" role="alert">{error}</p>}

        {job && (
          <section className={`export-progress export-${job.status}`}>
            <div className="export-progress-heading">
              <strong>{job.message}</strong>
              <span>{job.processedChapters}/{job.selectedChapters || '?'} 章</span>
            </div>
            <div className="export-progress-track"><i style={{ width: `${progress}%` }} /></div>
            <small>
              单书章节并发 {job.chapterConcurrency} · 多书串行 {job.bookConcurrency}
              {job.failedChapters > 0 ? ` · 失败 ${job.failedChapters} 章` : ''}
              {job.imageFailures > 0 ? ` · 图片失败 ${job.imageFailures} 张` : ''}
            </small>
            {job.files.length > 0 && (
              <div className="export-files">
                {job.files.map(file => (
                  <a key={file.fileId} className="primary-button export-download" href={file.downloadUrl} download={file.fileName}>
                    <Icon name="download" />
                    <span>{file.fileName}</span>
                  </a>
                ))}
              </div>
            )}
            {(pushDelivery?.state || job.kindlePushState) && (
              <div className={`export-kindle-state state-${pushDelivery?.state || job.kindlePushState}`}>
                <Icon name="book" />
                <span>
                  {pushDelivery
                    ? pushDelivery.state === 'delivered'
                      ? 'Kindle 已领取全部文件'
                      : pushDelivery.state === 'canceled'
                        ? '目标设备已撤销，未领取的投递已取消'
                      : `已领取 ${pushDelivery.delivered_count} 台，仍有 ${pushDelivery.pending_count} 台等待领取`
                        + (pushDelivery.canceled_count > 0 ? `；${pushDelivery.canceled_count} 台已撤销` : '')
                    : job.kindlePushMessage || 'Kindle 投递状态已更新'}
                </span>
              </div>
            )}
          </section>
        )}

        <footer className="export-modal-footer">
          <button type="button" className="subtle-button" onClick={onClose}>关闭</button>
          <button
            type="button"
            className="primary-button"
            onClick={() => void start()}
            disabled={starting || Boolean(job && !['ready', 'failed'].includes(job.status)) ||
              (format === 'epub' && pushToKindle && selectedDeviceIds.length === 0)}
          >
            {starting ? '正在创建任务…' : job && !['ready', 'failed'].includes(job.status) ? '正在导出…' : '开始导出'}
          </button>
        </footer>
      </section>
    </div>
  )
}
