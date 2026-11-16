import { useEffect, useState } from 'react'
import {
  api,
  KindleAutoPublishBlocker,
  KindleAutoPublishStatus,
  KindleDevice,
  KindleDraftResponse,
  KindlePairingCode,
  KindleProgressConflict,
  KindleProgressPosition,
  KindlePublication,
  KindlePushDelivery,
} from './api'
import { ButtonSpinner } from './ButtonSpinner'
import { Icon } from './icons'

type Props = {
  theme: string
  onClose?: () => void
  mode?: 'modal' | 'page'
}

type KindleTab = 'devices' | 'sync' | 'publish' | 'queue' | 'completed'
type DeliveryTab = 'queue' | 'completed'

function formatSeen(value?: string | null): string {
  if (!value) return '尚未连接'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString('zh-CN')
}

function formatBytes(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return '0 B'
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MB`
  return `${(value / 1024 / 1024 / 1024).toFixed(2)} GB`
}

function progressPositionLabel(position?: KindleProgressPosition | null): string {
  if (!position) return '暂无已保存位置'
  const percent = Math.max(0, Math.min(100, position.chapter_progress * 100))
  return `第 ${position.chapter_index + 1} 章 · ${percent.toFixed(percent >= 10 ? 0 : 1)}%`
}

function progressPositionMeta(position?: KindleProgressPosition | null): string {
  if (!position) return '服务器还没有记录'
  const device = position.device_name || 'WebUI'
  return `${device} · ${formatSeen(position.recorded_at)}`
}

function deliveryStateLabel(delivery: KindlePushDelivery): string {
  if (delivery.state === 'delivered') return '已完成'
  if (delivery.state === 'canceled') return '已取消'
  if (delivery.state === 'partial') return '部分已领取'
  return '等待领取'
}

function draftOperationLabel(operation: string): string {
  if (operation === 'add_book') return '新增'
  if (operation === 'delete_book') return '移出'
  if (operation === 'change_source') return '换源'
  if (operation === 'update_book') return '更新'
  return operation
}

function autoBlockerStateLabel(state: string): string {
  if (state === 'not_started') return '等待开始缓存'
  if (state === 'idle') return '等待缓存'
  if (state === 'pending') return '缓存排队中'
  if (state === 'caching') return '正在缓存'
  if (state === 'partial') return '仅完成部分缓存'
  if (state === 'failed') return '缓存失败'
  if (state === 'paused') return '缓存已暂停'
  return state
}

function autoPublishStateLabel(status: KindleAutoPublishStatus): string {
  if (!status.enabled || status.state === 'disabled') return '自动上架已关闭'
  if (status.state === 'observing') {
    return status.changes > 0 ? '正在检查上架条件' : '正在监听书架改动'
  }
  if (status.state === 'caching') return '等待书籍完成缓存'
  if (status.state === 'blocked') return '缓存失败，自动上架已暂停'
  if (status.state === 'waiting') {
    return status.current_book_title
      ? `《${status.current_book_title}》缓存完成，等待上架`
      : '缓存已完成，等待上架'
  }
  if (status.state === 'publishing') {
    return status.current_book_title
      ? `正在将《${status.current_book_title}》上架到 Kindle`
      : '正在上架到 Kindle 书架'
  }
  if (status.state === 'failed') return '自动上架暂时失败'
  return status.state
}

function autoPublishStateHint(status: KindleAutoPublishStatus): string {
  if (!status.enabled || status.state === 'disabled') {
    return '可通过 LEGADO_KINDLE_AUTO_PUBLISH=true 启用。'
  }
  if (status.state === 'observing') {
    return status.changes > 0
      ? `${status.changes} 项改动正在等待缓存检查。`
      : '当前书架与已上架版本一致。'
  }
  if (status.state === 'caching') {
    return `缓存完一本就上架一本，其他书不会阻塞；当前共 ${status.changes} 项改动，其中 ${status.blockers.length} 本仍在缓存。`
  }
  if (status.state === 'blocked') {
    return '当前没有可上架书籍；请恢复或重试失败项的缓存。其他已就绪书籍仍会优先上架。'
  }
  if (status.state === 'waiting') {
    return '全书缓存门槛已通过，等待短暂防抖后自动上架；不会等待其他书。'
  }
  if (status.state === 'publishing') {
    return '上架完成后 Kindle 下次联网即可拉取。'
  }
  if (status.state === 'failed') {
    return status.next_retry_at
      ? `将在 ${formatSeen(status.next_retry_at)} 后重试。`
      : '可以手动请求立即重试。'
  }
  return ''
}

function autoBlockerProgress(blocker: KindleAutoPublishBlocker): number {
  if (blocker.total_chapters <= 0) return 0
  return Math.max(0, Math.min(100, Math.round(
    blocker.cached_chapters / blocker.total_chapters * 100,
  )))
}

function publishRequestId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID()
  }
  return `publish_${Date.now()}_${Math.random().toString(36).slice(2)}`
}

function DeliveryList({
  deliveries,
  loading,
  kind,
}: {
  deliveries: KindlePushDelivery[]
  loading: boolean
  kind: DeliveryTab
}) {
  if (loading) {
    return <p className="kindle-device-empty"><ButtonSpinner size={16} />正在读取推送记录…</p>
  }
  if (deliveries.length === 0) {
    return (
      <p className="kindle-device-empty">
        <Icon name={kind === 'queue' ? 'clock' : 'check'} />
        {kind === 'queue' ? '推送队列为空。' : '还没有已完成的推送。'}
      </p>
    )
  }

  return (
    <div className="kindle-delivery-list" aria-live="polite">
      {deliveries.map(delivery => {
        const progress = delivery.target_count > 0
          ? Math.min(100, Math.round(delivery.delivered_count / delivery.target_count * 100))
          : 0
        const waitingOrCanceled = delivery.pending_count + delivery.canceled_count
        return (
          <article key={delivery.delivery_id} className={`kindle-delivery-card state-${delivery.state}`}>
            <div className="kindle-delivery-book-icon"><Icon name="book" /></div>
            <div className="kindle-delivery-content">
              <div className="kindle-delivery-heading">
                <strong>{delivery.book_name}</strong>
                <span className="kindle-delivery-state">{deliveryStateLabel(delivery)}</span>
              </div>
              <div className="kindle-delivery-meta">
                <span>{delivery.format.toUpperCase()}</span>
                <span>{delivery.file_count} 个文件</span>
                <span>{formatBytes(delivery.total_bytes)}</span>
              </div>
              <div className="kindle-delivery-progress" aria-label={`已领取 ${delivery.delivered_count}/${delivery.target_count} 台`}>
                <i style={{ width: `${progress}%` }} />
              </div>
              <div className="kindle-delivery-detail">
                <span>已领取 {delivery.delivered_count}/{delivery.target_count} 台</span>
                {delivery.pending_count > 0 && <span>等待 {delivery.pending_count} 台</span>}
                {delivery.canceled_count > 0 && <span>取消 {delivery.canceled_count} 台</span>}
                {waitingOrCanceled === 0 && <span>全部设备已领取</span>}
              </div>
              <small title={`创建于 ${formatSeen(delivery.created_at)}`}>更新于 {formatSeen(delivery.updated_at)}</small>
            </div>
          </article>
        )
      })}
    </div>
  )
}

export function KindleDevicesModal({ theme, onClose, mode = 'modal' }: Props) {
  const [devices, setDevices] = useState<KindleDevice[]>([])
  const [deliveries, setDeliveries] = useState<KindlePushDelivery[]>([])
  const [conflicts, setConflicts] = useState<KindleProgressConflict[]>([])
  const [devicesLoading, setDevicesLoading] = useState(true)
  const [deliveriesLoading, setDeliveriesLoading] = useState(true)
  const [conflictsLoading, setConflictsLoading] = useState(true)
  const [draft, setDraft] = useState<KindleDraftResponse | null>(null)
  const [draftLoading, setDraftLoading] = useState(true)
  const [autoStatus, setAutoStatus] = useState<KindleAutoPublishStatus | null>(null)
  const [autoStatusLoading, setAutoStatusLoading] = useState(true)
  const [autoRetrying, setAutoRetrying] = useState(false)
  const [publishing, setPublishing] = useState(false)
  const [lastPublication, setLastPublication] = useState<KindlePublication | null>(null)
  const [busy, setBusy] = useState('')
  const [error, setError] = useState('')
  const [pairing, setPairing] = useState<KindlePairingCode | null>(null)
  const [activeTab, setActiveTab] = useState<KindleTab>('devices')

  const loadDevices = (silent = false) => {
    if (!silent) setDevicesLoading(true)
    return api.kindleDevices()
      .then(result => setDevices(result.devices))
      .catch(err => {
        if (!silent) setError(err instanceof Error ? err.message : '读取 Kindle 设备失败')
      })
      .finally(() => {
        if (!silent) setDevicesLoading(false)
      })
  }

  const loadDeliveries = (silent = false) => {
    if (!silent) setDeliveriesLoading(true)
    return api.kindlePushDeliveries()
      .then(result => setDeliveries(result.deliveries))
      .catch(err => {
        if (!silent) setError(err instanceof Error ? err.message : '读取推送记录失败')
      })
      .finally(() => {
        if (!silent) setDeliveriesLoading(false)
      })
  }

  const loadDraft = (silent = false) => {
    if (!silent) setDraftLoading(true)
    return api.kindleDraft()
      .then(result => {
        setDraft(result)
      })
      .catch(err => {
        if (!silent) setError(err instanceof Error ? err.message : '读取待上架书架失败')
      })
      .finally(() => {
        if (!silent) setDraftLoading(false)
      })
  }

  const loadAutoStatus = (silent = false) => {
    if (!silent) setAutoStatusLoading(true)
    return api.kindleAutoPublishStatus()
      .then(setAutoStatus)
      .catch(err => {
        if (!silent) setError(err instanceof Error ? err.message : '读取自动上架状态失败')
      })
      .finally(() => {
        if (!silent) setAutoStatusLoading(false)
      })
  }

  const loadConflicts = (silent = false) => {
    if (!silent) setConflictsLoading(true)
    return api.kindleProgressConflicts()
      .then(result => setConflicts(result.conflicts))
      .catch(err => {
        if (!silent) setError(err instanceof Error ? err.message : '读取阅读进度冲突失败')
      })
      .finally(() => {
        if (!silent) setConflictsLoading(false)
      })
  }

  useEffect(() => {
    void loadDevices()
    void loadDeliveries()
    void loadDraft()
    void loadAutoStatus()
    void loadConflicts()
    const deliveryTimer = window.setInterval(() => void loadDeliveries(true), 5_000)
    const autoStatusTimer = window.setInterval(() => void loadAutoStatus(true), 5_000)
    const draftTimer = window.setInterval(() => void loadDraft(true), 10_000)
    const conflictTimer = window.setInterval(() => void loadConflicts(true), 10_000)
    return () => {
      window.clearInterval(deliveryTimer)
      window.clearInterval(autoStatusTimer)
      window.clearInterval(draftTimer)
      window.clearInterval(conflictTimer)
    }
  }, [])

  const queueDeliveries = deliveries.filter(item => item.state === 'queued' || item.state === 'partial')
  const completedDeliveries = deliveries.filter(item => item.state === 'delivered' || item.state === 'canceled')
  const activeLoading = activeTab === 'devices'
    ? devicesLoading
    : activeTab === 'sync'
      ? conflictsLoading
      : activeTab === 'publish'
        ? draftLoading || autoStatusLoading
        : deliveriesLoading

  const createCode = async () => {
    setBusy('pair')
    setError('')
    try {
      setPairing(await api.createKindlePairingCode('Kindle'))
    } catch (err) {
      setError(err instanceof Error ? err.message : '生成配对码失败')
    } finally {
      setBusy('')
    }
  }

  const revoke = async (device: KindleDevice) => {
    if (!window.confirm(`撤销设备“${device.device_name}”吗？该设备之后将无法领取推送，尚未领取的投递会取消。`)) return
    setBusy(device.device_id)
    setError('')
    try {
      await api.revokeKindleDevice(device.device_id)
      await Promise.all([loadDevices(), loadDeliveries()])
    } catch (err) {
      setError(err instanceof Error ? err.message : '撤销设备失败')
    } finally {
      setBusy('')
    }
  }

  const refreshActiveTab = () => {
    setError('')
    if (activeTab === 'devices') {
      void loadDevices()
    } else if (activeTab === 'sync') {
      void loadConflicts()
    } else if (activeTab === 'publish') {
      void Promise.all([loadDraft(), loadAutoStatus()])
    } else {
      void loadDeliveries()
    }
  }

  const publishDraft = async () => {
    if (!draft || draft.changes.length === 0 || publishing) return
    if (!window.confirm('手动上架会跳过“等待全书缓存完成”的自动门槛。确定继续吗？')) return
    setPublishing(true)
    setError('')
    try {
      const publication = await api.publishKindleDraft(draft.draft_version, publishRequestId())
      setLastPublication(publication)
      await Promise.all([loadDraft(), loadAutoStatus(true)])
    } catch (err) {
      setError(err instanceof Error ? err.message : '上架书架失败')
    } finally {
      setPublishing(false)
    }
  }

  const retryAutoPublish = async () => {
    if (autoRetrying) return
    setAutoRetrying(true)
    setError('')
    try {
      setAutoStatus(await api.retryKindleAutoPublish())
      await Promise.all([loadAutoStatus(true), loadDraft(true)])
    } catch (err) {
      setError(err instanceof Error ? err.message : '请求自动上架重试失败')
    } finally {
      setAutoRetrying(false)
    }
  }

  const resolveConflict = async (conflict: KindleProgressConflict, resolution: 'server' | 'kindle') => {
    const busyKey = `${conflict.conflict_id}:${resolution}`
    setBusy(busyKey)
    setError('')
    try {
      await api.resolveKindleProgressConflict(
        conflict.conflict_id,
        resolution,
        conflict.current?.progress_version,
      )
      await loadConflicts()
    } catch (err) {
      setError(err instanceof Error ? err.message : '解决阅读进度冲突失败')
      await loadConflicts(true)
    } finally {
      setBusy('')
    }
  }

  const content = (
      <section
        className={`kindle-devices-modal ${mode === 'page' ? 'kindle-devices-page' : ''}`}
        role={mode === 'modal' ? 'dialog' : undefined}
        aria-modal={mode === 'modal' ? true : undefined}
        aria-label="Kindle 同步中心"
        onClick={mode === 'modal' ? event => event.stopPropagation() : undefined}
      >
        <header className="kindle-devices-header">
          <div>
            <span className="section-kicker">Kindle</span>
            <h2>Kindle 同步中心</h2>
            <p>逐本上架持续同步的书架，处理多端阅读进度冲突，并查看 EPUB 推送记录。</p>
          </div>
          {mode === 'modal' && onClose && (
            <button type="button" className="subtle-button close-btn" onClick={onClose} aria-label="关闭">
              <Icon name="close" />
            </button>
          )}
        </header>

        <nav className="kindle-modal-tabs" role="tablist" aria-label="Kindle 推送视图">
          <button
            type="button"
            role="tab"
            aria-selected={activeTab === 'devices'}
            className={activeTab === 'devices' ? 'active' : ''}
            onClick={() => setActiveTab('devices')}
          >
            <Icon name="book" />
            <span>设备</span>
            <b>{devices.length}</b>
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={activeTab === 'sync'}
            className={activeTab === 'sync' ? 'active' : ''}
            onClick={() => {
              setActiveTab('sync')
              void loadConflicts()
            }}
          >
            <Icon name="refresh" />
            <span>同步</span>
            <b>{conflicts.length}</b>
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={activeTab === 'publish'}
            className={activeTab === 'publish' ? 'active' : ''}
            onClick={() => {
              setActiveTab('publish')
              void loadDraft()
            }}
          >
            <Icon name="upload" />
            <span>上架</span>
            <b>{draft?.changes.length ?? 0}</b>
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={activeTab === 'queue'}
            className={activeTab === 'queue' ? 'active' : ''}
            onClick={() => setActiveTab('queue')}
          >
            <Icon name="clock" />
            <span>队列</span>
            <b>{queueDeliveries.length}</b>
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={activeTab === 'completed'}
            className={activeTab === 'completed' ? 'active' : ''}
            onClick={() => setActiveTab('completed')}
          >
            <Icon name="check" />
            <span>完成</span>
            <b>{completedDeliveries.length}</b>
          </button>
        </nav>

        {activeTab === 'devices' && (
          <>
            <div className="kindle-device-actions">
              <button type="button" className="primary-button" onClick={() => void createCode()} disabled={busy === 'pair'}>
                {busy === 'pair' ? <ButtonSpinner size={14} /> : <Icon name="plus" />}
                <span>{busy === 'pair' ? '正在生成…' : '生成配对码'}</span>
              </button>
              <button type="button" className="subtle-button" onClick={refreshActiveTab} disabled={activeLoading}>
                {activeLoading ? <ButtonSpinner size={14} /> : <Icon name="refresh" />}
                <span>刷新状态</span>
              </button>
            </div>

            {pairing && (
              <section className="kindle-pairing-code">
                <span>在 KOReader 的 Legado server → Find server on LAN 中选择此服务器并输入配对码；无法自动发现时改用 Pair manually。</span>
                <strong>{pairing.pairing_code}</strong>
                <small>5 分钟内有效：{formatSeen(pairing.expires_at)}</small>
              </section>
            )}

            <div className="kindle-device-list">
              {devicesLoading && <p className="kindle-device-empty"><ButtonSpinner size={16} />正在读取设备…</p>}
              {!devicesLoading && devices.length === 0 && <p className="kindle-device-empty">还没有配对设备。</p>}
              {devices.map(device => (
                <article key={device.device_id} className={device.revoked_at ? 'revoked' : ''}>
                  <div className="kindle-device-icon"><Icon name="book" /></div>
                  <div>
                    <strong>{device.device_name}</strong>
                    <small>{device.revoked_at ? `已撤销 · ${formatSeen(device.revoked_at)}` : `最后连接：${formatSeen(device.last_seen_at)}`}</small>
                  </div>
                  {!device.revoked_at && (
                    <button
                      type="button"
                      className="subtle-button danger-text"
                      disabled={busy === device.device_id}
                      onClick={() => void revoke(device)}
                    >
                      {busy === device.device_id ? <ButtonSpinner size={14} /> : <Icon name="trash" />}
                      <span>撤销</span>
                    </button>
                  )}
                </article>
              ))}
            </div>
          </>
        )}

        {activeTab === 'sync' && (
          <>
            <div className="kindle-device-actions kindle-delivery-actions">
              <button type="button" className="subtle-button" onClick={refreshActiveTab} disabled={activeLoading}>
                {activeLoading ? <ButtonSpinner size={14} /> : <Icon name="refresh" />}
                <span>刷新冲突</span>
              </button>
              <small>Kindle 联网后会自动上传进度并拉取新章节；并发修改会保留在这里。</small>
            </div>

            {conflictsLoading ? (
              <p className="kindle-device-empty"><ButtonSpinner size={16} />正在读取阅读进度…</p>
            ) : conflicts.length === 0 ? (
              <section className="kindle-publish-empty">
                <div className="kindle-publish-empty-icon"><Icon name="check" /></div>
                <div>
                  <strong>阅读进度已同步</strong>
                  <small>当前没有需要人工处理的位置冲突。</small>
                </div>
              </section>
            ) : (
              <div className="kindle-conflict-list" aria-live="polite">
                {conflicts.map(conflict => {
                  const serverBusy = busy === `${conflict.conflict_id}:server`
                  const kindleBusy = busy === `${conflict.conflict_id}:kindle`
                  return (
                    <article key={conflict.conflict_id} className="kindle-conflict-card">
                      <header>
                        <div>
                          <strong>{conflict.title}</strong>
                          <small>创建于 {formatSeen(conflict.created_at)}</small>
                        </div>
                        <span>待处理</span>
                      </header>
                      <div className="kindle-conflict-comparison">
                        <section>
                          <small>服务端当前位置</small>
                          <strong>{progressPositionLabel(conflict.current)}</strong>
                          <span>{progressPositionMeta(conflict.current)}</span>
                        </section>
                        <section>
                          <small>Kindle 上报位置</small>
                          <strong>{progressPositionLabel(conflict.candidate)}</strong>
                          <span>{progressPositionMeta(conflict.candidate)}</span>
                        </section>
                      </div>
                      <footer>
                        <button
                          type="button"
                          className="subtle-button"
                          disabled={Boolean(busy)}
                          onClick={() => void resolveConflict(conflict, 'server')}
                        >
                          {serverBusy ? <ButtonSpinner size={14} /> : <Icon name="check" />}
                          <span>保留服务端</span>
                        </button>
                        <button
                          type="button"
                          className="primary-button"
                          disabled={Boolean(busy)}
                          onClick={() => void resolveConflict(conflict, 'kindle')}
                        >
                          {kindleBusy ? <ButtonSpinner size={14} /> : <Icon name="download" />}
                          <span>使用 Kindle</span>
                        </button>
                      </footer>
                    </article>
                  )
                })}
              </div>
            )}
          </>
        )}

        {activeTab === 'publish' && (
          <>
            <div className="kindle-device-actions kindle-delivery-actions">
              <button type="button" className="subtle-button" onClick={refreshActiveTab} disabled={activeLoading || publishing}>
                {activeLoading ? <ButtonSpinner size={14} /> : <Icon name="refresh" />}
                <span>刷新上架状态</span>
              </button>
              <small>自动上架每 5 秒刷新；Kindle 只负责阅读书架内容</small>
            </div>

            {autoStatusLoading && !autoStatus ? (
              <p className="kindle-device-empty"><ButtonSpinner size={16} />正在读取自动上架状态…</p>
            ) : autoStatus ? (
              <section className={`kindle-auto-publish state-${autoStatus.state}`} aria-live="polite">
                <header className="kindle-auto-publish-heading">
                  <div className="kindle-auto-publish-icon"><Icon name="activity" /></div>
                  <div>
                    <strong>{autoPublishStateLabel(autoStatus)}</strong>
                    <small>{autoPublishStateHint(autoStatus)}</small>
                  </div>
                  <span>{autoStatus.enabled ? '自动' : '关闭'}</span>
                </header>

                {autoStatus.blockers.length > 0 && (
                  <div className="kindle-auto-publish-blockers">
                    {autoStatus.blockers.map(blocker => {
                      const progress = autoBlockerProgress(blocker)
                      return (
                        <article key={blocker.book_id}>
                          <div>
                            <strong>{blocker.title}</strong>
                            <small>
                              {autoBlockerStateLabel(blocker.state)}
                              {blocker.total_chapters > 0
                                ? ` · ${blocker.cached_chapters}/${blocker.total_chapters}`
                                : ''}
                            </small>
                          </div>
                          {blocker.total_chapters > 0 && (
                            <div
                              className="kindle-auto-publish-progress"
                              aria-label={`缓存进度 ${blocker.cached_chapters}/${blocker.total_chapters}`}
                            >
                              <i style={{ width: `${progress}%` }} />
                            </div>
                          )}
                          {blocker.last_error && <p>{blocker.last_error}</p>}
                        </article>
                      )
                    })}
                  </div>
                )}

                {(autoStatus.last_published_at || autoStatus.last_error) && (
                  <div className="kindle-auto-publish-meta">
                    {autoStatus.last_published_at && (
                      <span>上次自动上架：{formatSeen(autoStatus.last_published_at)}</span>
                    )}
                    {autoStatus.last_error && <span className="error-text">{autoStatus.last_error}</span>}
                  </div>
                )}

                {autoStatus.enabled && autoStatus.blockers.length === 0 &&
                  (autoStatus.state === 'waiting' || autoStatus.state === 'failed') && (
                    <footer className="kindle-auto-publish-footer">
                      <small>该操作只会跳过防抖，不会绕过全书缓存门槛。</small>
                      <button
                        type="button"
                        className="primary-button"
                        disabled={autoRetrying}
                        onClick={() => void retryAutoPublish()}
                      >
                        {autoRetrying ? <ButtonSpinner size={14} /> : <Icon name="upload" />}
                        <span>{autoRetrying ? '正在请求…' : '立即上架已就绪书籍'}</span>
                      </button>
                    </footer>
                  )}
              </section>
            ) : null}

            {draftLoading ? (
              <p className="kindle-device-empty"><ButtonSpinner size={16} />正在读取书架改动…</p>
            ) : !draft ? (
              <p className="kindle-device-empty">暂时无法读取待上架书架。</p>
            ) : draft.changes.length === 0 ? (
              <section className="kindle-publish-empty">
                <div className="kindle-publish-empty-icon"><Icon name="check" /></div>
                <div>
                  <strong>已上架书架与当前书架一致</strong>
                  <small>
                    {autoStatus?.last_published_at
                      ? `上次自动上架：${formatSeen(autoStatus.last_published_at)}`
                      : lastPublication
                      ? `刚刚上架：${formatSeen(lastPublication.published_at)}`
                      : draft.base_publication_id
                        ? `当前上架版本：${draft.base_publication_id}`
                        : '还没有需要上架的书架改动。'}
                  </small>
                </div>
              </section>
            ) : (
              <section className="kindle-publish-panel">
                <div className="kindle-publish-summary">
                  <div className="kindle-publish-icon"><Icon name="upload" /></div>
                  <div>
                    <strong>{draft.base_publication_id ? '待上架书架改动' : '首次上架书架'}</strong>
                    <small>
                      {draft.changes.length} 项改动 · {draft.base_publication_id ? '更新已有上架版本' : '建立第一份 Kindle 上架版本'}
                    </small>
                  </div>
                  <b>{draft.changes.length}</b>
                </div>

                <p className="kindle-publish-note">
                  一本书的全文缓存成功后，Server 会立即为这本书生成独立上架版本。
                  其他书仍在缓存或失败不会阻塞它，也不会把未完成的书上架给 Kindle。
                </p>

                <div className="kindle-draft-list" aria-label="待上架书架改动">
                  {draft.changes.map(change => (
                    <article key={`${change.operation}:${change.book_id}`}>
                      <span className={`kindle-draft-operation operation-${change.operation}`}>
                        {draftOperationLabel(change.operation)}
                      </span>
                      <strong>{change.title}</strong>
                      <small title={change.book_id}>{change.book_id}</small>
                    </article>
                  ))}
                </div>

                <details className="kindle-manual-publish">
                  <summary>高级操作：手动上架</summary>
                  <p>仅用于排障。手动上架会跳过全书缓存完成检查。</p>
                  <button
                    type="button"
                    className="subtle-button"
                    disabled={publishing || autoStatus?.state === 'publishing'}
                    onClick={() => void publishDraft()}
                  >
                    {publishing ? <ButtonSpinner size={14} /> : <Icon name="upload" />}
                    <span>{publishing ? '正在上架…' : '强制上架当前改动'}</span>
                  </button>
                </details>
              </section>
            )}
          </>
        )}

        {(activeTab === 'queue' || activeTab === 'completed') && (
          <>
            <div className="kindle-device-actions kindle-delivery-actions">
              <button type="button" className="subtle-button" onClick={refreshActiveTab} disabled={activeLoading}>
                {activeLoading ? <ButtonSpinner size={14} /> : <Icon name="refresh" />}
                <span>刷新记录</span>
              </button>
              <small>队列每 5 秒自动刷新</small>
            </div>
            <DeliveryList
              deliveries={activeTab === 'queue' ? queueDeliveries : completedDeliveries}
              loading={deliveriesLoading}
              kind={activeTab}
            />
          </>
        )}

        {error && <p className="form-error" role="alert">{error}</p>}
      </section>
  )

  if (mode === 'page') return content

  return (
    <div className={`modal-backdrop kindle-devices-backdrop theme-${theme}`} onClick={onClose}>
      {content}
    </div>
  )
}
