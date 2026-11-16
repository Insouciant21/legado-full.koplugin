import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  api,
  type BookshelfItem,
  type BookshelfRefreshStatus,
  type KindleAutoPublishStatus,
  type KindlePushDelivery,
} from './api'
import { ButtonSpinner } from './ButtonSpinner'
import { Icon } from './icons'

type AutomationCenterProps = {
  items: BookshelfItem[]
  refreshStatus: BookshelfRefreshStatus | null
  caching: boolean
  onOpenBook: (item: BookshelfItem) => void
  onOpenTasks: () => void
}

type TaskTone = 'active' | 'warning' | 'ready' | 'idle'

function formatTime(value?: string | null): string {
  if (!value) return ''
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return date.toLocaleString('zh-CN', {
    month: 'numeric',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function autoStatusCopy(status: KindleAutoPublishStatus | null): { title: string; detail: string; tone: TaskTone } {
  if (!status) return { title: '正在读取 Kindle 状态', detail: '加载设备与上架信息', tone: 'idle' }
  if (!status.enabled || status.state === 'disabled') {
    return { title: '自动上架未启用', detail: '可在设备与任务中启用并查看设备', tone: 'idle' }
  }
  if (status.state === 'publishing') {
    return {
      title: status.current_book_title ? `正在上架《${status.current_book_title}》` : '正在上架书架',
      detail: '完成后 Kindle 联网即可领取',
      tone: 'active',
    }
  }
  if (status.state === 'caching') {
    return {
      title: `${status.blockers.length} 本等待缓存完成`,
      detail: '缓存完一本会立即上架一本',
      tone: 'active',
    }
  }
  if (status.state === 'waiting') {
    return {
      title: status.current_book_title ? `等待上架《${status.current_book_title}》` : '等待上架',
      detail: '全书缓存已完成，正在进行短暂防抖',
      tone: 'active',
    }
  }
  if (status.state === 'blocked' || status.state === 'failed') {
    return {
      title: status.state === 'blocked' ? '自动上架等待处理' : '最近一次自动上架失败',
      detail: status.last_error || '打开设备与任务查看失败书籍',
      tone: 'warning',
    }
  }
  if (status.changes > 0) {
    return {
      title: `${status.changes} 项书架改动待处理`,
      detail: '系统会在缓存完成后逐本上架',
      tone: 'active',
    }
  }
  return {
    title: 'Kindle 书架已同步',
    detail: status.last_published_at ? `上次上架 ${formatTime(status.last_published_at)}` : '当前没有待上架改动',
    tone: 'ready',
  }
}

export function AutomationCenter({
  items,
  refreshStatus,
  caching,
  onOpenBook,
  onOpenTasks,
}: AutomationCenterProps) {
  const [deliveries, setDeliveries] = useState<KindlePushDelivery[]>([])
  const [autoStatus, setAutoStatus] = useState<KindleAutoPublishStatus | null>(null)
  const [loading, setLoading] = useState(true)
  const [offline, setOffline] = useState(false)

  const loadKindle = useCallback(async (silent = false) => {
    if (!silent) setLoading(true)
    const [deliveryResult, statusResult] = await Promise.allSettled([
      api.kindlePushDeliveries(),
      api.kindleAutoPublishStatus(),
    ])
    if (deliveryResult.status === 'fulfilled') setDeliveries(deliveryResult.value.deliveries)
    if (statusResult.status === 'fulfilled') setAutoStatus(statusResult.value)
    setOffline(deliveryResult.status === 'rejected' && statusResult.status === 'rejected')
    if (!silent) setLoading(false)
  }, [])

  useEffect(() => {
    void loadKindle()
    const timer = window.setInterval(() => void loadKindle(true), 5000)
    return () => window.clearInterval(timer)
  }, [loadKindle])

  const cacheTasks = useMemo(() => items.filter(item => item.cacheState === 'caching'), [items])
  const problemItems = useMemo(
    () => items.filter(item => item.cacheState === 'failed' || item.cacheState === 'paused' || item.updateError),
    [items],
  )
  const pendingDeliveries = useMemo(
    () => deliveries.filter(delivery => delivery.state === 'queued' || delivery.state === 'partial'),
    [deliveries],
  )
  const refreshActive = refreshStatus?.state === 'running'
  const refreshDone = refreshStatus?.state === 'completed' ? refreshStatus : null
  const autoCopy = autoStatusCopy(autoStatus)

  const taskCount =
    cacheTasks.length +
    problemItems.length +
    pendingDeliveries.length +
    (refreshActive ? 1 : 0) +
    (autoStatus?.state === 'publishing' || autoStatus?.state === 'waiting' || autoStatus?.state === 'caching' ? 1 : 0)

  return (
    <section className={`automation-center ${taskCount > 0 ? 'has-tasks' : 'is-clear'}`} aria-label="正在处理">
      <header className="automation-center-header">
        <div>
          <span className="automation-center-kicker">
            <Icon name={taskCount > 0 ? 'activity' : 'check'} className={taskCount > 0 && (caching || refreshActive) ? 'spin' : ''} />
            正在处理
          </span>
          <strong>
            {taskCount > 0 ? `${taskCount} 项任务在后台推进` : '当前没有待处理任务'}
          </strong>
          <small>
            {taskCount > 0
              ? '可以离开书架继续搜书；完成一本处理一本。'
              : '缓存、目录更新、上架和推送会在这里集中显示。'}
          </small>
        </div>
        <button type="button" className="automation-center-link" onClick={onOpenTasks}>
          <Icon name="device" />
          打开设备与任务
          <Icon name="arrowRight" />
        </button>
      </header>

      <div className="automation-task-grid">
        <article className={`automation-task ${cacheTasks.length ? 'is-active' : ''}`}>
          <span className="automation-task-icon"><Icon name="cloudDownload" /></span>
          <div>
            <small>离线缓存</small>
            <strong>{cacheTasks.length > 0 ? `${cacheTasks.length} 本正在缓存` : '没有缓存任务'}</strong>
            {cacheTasks[0] ? (
              <button type="button" onClick={() => onOpenBook(cacheTasks[0])} title={cacheTasks[0].name}>
                {cacheTasks[0].name} · {cacheTasks[0].cachedChapters}/{cacheTasks[0].totalChapters || '?'}
              </button>
            ) : (
              <span>{items.filter(item => item.cacheState === 'ready').length} 本已可离线阅读</span>
            )}
          </div>
        </article>

        <article className={`automation-task ${refreshActive ? 'is-active' : refreshDone ? 'is-ready' : ''}`}>
          <span className="automation-task-icon"><Icon name="refresh" className={refreshActive ? 'spin' : ''} /></span>
          <div>
            <small>目录更新</small>
            <strong>
              {refreshActive
                ? `正在更新 ${refreshStatus?.completed ?? 0}/${refreshStatus?.total ?? 0}`
                : refreshDone
                  ? `更新完成 · 新增 ${refreshDone.items.reduce((total, item) => total + Math.max(0, item.newChapters), 0)} 章`
                  : '没有目录任务'}
            </strong>
            <span>{refreshActive ? '可以继续浏览页面，进度会自动刷新' : '书架目录状态正常'}</span>
          </div>
        </article>

        <article className={`automation-task ${autoCopy.tone === 'active' ? 'is-active' : ''} ${autoCopy.tone === 'warning' ? 'is-warning' : ''} ${autoCopy.tone === 'ready' ? 'is-ready' : ''}`}>
          <span className="automation-task-icon"><Icon name="device" /></span>
          <div>
            <small>Kindle 上架</small>
            <strong>{loading && !autoStatus ? <><ButtonSpinner size={12} /> 正在读取</> : autoCopy.title}</strong>
            <span>{autoCopy.detail}</span>
          </div>
        </article>

        <article className={`automation-task ${pendingDeliveries.length ? 'is-active' : ''}`}>
          <span className="automation-task-icon"><Icon name="upload" /></span>
          <div>
            <small>推送队列</small>
            <strong>{pendingDeliveries.length > 0 ? `${pendingDeliveries.length} 本等待领取` : '队列为空'}</strong>
            {pendingDeliveries[0] ? (
              <button type="button" onClick={onOpenTasks}>
                {pendingDeliveries[0].book_name} · {pendingDeliveries[0].delivered_count}/{pendingDeliveries[0].target_count} 台
              </button>
            ) : (
              <span>{offline ? '暂时无法读取 Kindle 状态' : '设备联网后会在这里领取'}</span>
            )}
          </div>
        </article>
      </div>

      {(problemItems.length > 0 || pendingDeliveries.length > 0) && (
        <footer className="automation-center-footer">
          {problemItems.length > 0 && (
            <span className="automation-attention">
              <Icon name="activity" />
              {problemItems.length} 本需要处理
            </span>
          )}
          {problemItems.slice(0, 3).map(item => (
            <button key={`${item.sourceId}\u0000${item.bookUrl}`} type="button" onClick={() => onOpenBook(item)}>
              {item.name}
            </button>
          ))}
          {problemItems.length > 3 && <small>+{problemItems.length - 3}</small>}
        </footer>
      )}
    </section>
  )
}
